import AppKit
import QuartzCore

final class MissionControlOverlay {
    private struct Plate: Equatable {
        let name: String
        let frame: CGRect
        let selected: Bool
    }

    private final class StripView: NSView {
        var plates: [Plate] = [] {
            didSet { if plates != oldValue { needsDisplay = true } }
        }

        override func draw(_ dirtyRect: NSRect) {
            for plate in plates where dirtyRect.intersects(plate.frame) {
                let frame = plate.frame
                let path = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
                NSColor(white: plate.selected ? 0.29 : 0.12, alpha: 1).setFill()
                path.fill()

                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                paragraph.lineBreakMode = .byTruncatingTail
                let font = NSFont.systemFont(ofSize: 13, weight: .medium)
                let lineHeight = ceil(font.ascender - font.descender + font.leading)
                let textFrame = CGRect(x: frame.minX + 7, y: floor(frame.midY - lineHeight / 2),
                                       width: frame.width - 14, height: lineHeight)
                (plate.name as NSString).draw(with: textFrame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
            }
        }
    }

    private struct Overlay {
        let window: NSPanel
        let strip: StripView
    }

    private var overlays: [String: Overlay] = [:]
    private var expanded = Set<String>()
    private var dockPID: pid_t?
    private var dockCheck: CFTimeInterval = 0
    private var hoverStart: [String: CFTimeInterval] = [:]

    func clear() {
        overlays.values.forEach { $0.window.orderOut(nil) }
        overlays.removeAll()
        expanded.removeAll()
        hoverStart.removeAll()
    }

    func update(displays: [DisplaySpaces], names: [String: String]) -> Bool {
        guard !names.isEmpty, let screens = missionControlScreens(), !screens.isEmpty else {
            clear()
            return false
        }

        let cursor = NSEvent.mouseLocation
        let now = CACurrentMediaTime()
        var shown = Set<String>()
        for screen in screens {
            guard let display = displays.first(where: { $0.matches(screen) })
                    ?? (NSScreen.screens.count == 1 && displays.count == 1 ? displays.first : nil) else { continue }
            let key = display.identifier
            let frame = screen.frame

            // On Tahoe, hovering in the top strip expands the desktop thumbnails.
            // Latch the first entry so moving down onto the thumbnails during
            // the animation doesn't cancel it. Include the very top screen edge.
            if !expanded.contains(key) {
                if let start = hoverStart[key] {
                    if now - start >= 0.22 { expanded.insert(key) }
                } else {
                    let depth = frame.maxY - cursor.y
                    if cursor.x >= frame.minX && cursor.x < frame.maxX &&
                        depth >= 0 && depth <= max(40, screen.safeAreaInsets.top + 18) {
                        hoverStart[key] = now
                    }
                }
            }
            guard expanded.contains(key) else { continue }

            let plates = Self.layout(display.slots, names: names, screen: screen)
            guard !plates.isEmpty else { continue }
            shown.insert(key)
            // Give the transparent window just enough area for the caption row.
            let height = Self.bandHeight(for: frame.size)
            let band = CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
            let overlay = overlays[key] ?? makeOverlay(frame: band)
            overlays[key] = overlay
            if overlay.window.frame != band { overlay.window.setFrame(band, display: true) }
            overlay.strip.plates = plates
            if !overlay.window.isVisible { overlay.window.orderFrontRegardless() }
        }

        for key in Array(overlays.keys) where !shown.contains(key) {
            overlays.removeValue(forKey: key)?.window.orderOut(nil)
        }
        return true
    }

    private func makeOverlay(frame: CGRect) -> Overlay {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let strip = StripView(frame: CGRect(origin: .zero, size: frame.size))
        strip.autoresizingMask = [.width, .height]
        panel.contentView = strip
        return Overlay(window: panel, strip: strip)
    }

    private func missionControlScreens() -> [NSScreen]? {
        let now = CACurrentMediaTime()
        if now >= dockCheck {
            dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
            dockCheck = now + 3
        }
        guard let dockPID,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let bounds = list.compactMap { entry -> CGRect? in
            // The Dock can have a full-display layer-20 window even on the
            // ordinary desktop. The layer-18 surface appears with Mission Control.
            guard (entry[kCGWindowOwnerPID as String] as? Int32) == dockPID,
                  (entry[kCGWindowLayer as String] as? Int) == 18,
                  let value = entry[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: value as CFDictionary)
        }
        return NSScreen.screens.filter { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return false }
            let display = CGDisplayBounds(number)
            return bounds.contains {
                $0.intersection(display).width >= display.width * 0.9 &&
                $0.intersection(display).height >= display.height * 0.9
            }
        }
    }

    private static func layout(_ slots: [Desktop?], names: [String: String], screen: NSScreen) -> [Plate] {
        guard !slots.isEmpty else { return [] }
        let size = screen.frame.size
        let bandHeight = bandHeight(for: size)
        // The expanded strip is centered. Measure the spacing in points from
        // the thumbnail height and display aspect ratio, rather than as a
        // percentage of the screen width. Crowded rows shrink the thumbnails.
        let aspect = size.width / size.height
        let gap: CGFloat = 32
        let step = min(90 * aspect + gap, size.width * 0.94 / CGFloat(slots.count))
        guard step > gap + 2 else { return [] }
        let thumbnailHeight = (step - gap) / aspect
        let first = (size.width - step * CGFloat(slots.count - 1)) / 2
        let thumbnailTop = max(27, screen.safeAreaInsets.top + 13)
        let captionDepth = thumbnailTop + thumbnailHeight + 15
        let midY = bandHeight - captionDepth
        return slots.enumerated().compactMap { index, item in
            guard let item, let name = names[item.id] else { return nil }
            let caption = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
            let width = min(max(76, ceil(caption.width) + 20), floor(step - 6))
            return Plate(name: name, frame: CGRect(x: (first + CGFloat(index) * step - width / 2).rounded(),
                        y: (midY - 12).rounded(), width: width, height: 24),
                        selected: item.isCurrent)
        }
    }

    private static func bandHeight(for size: CGSize) -> CGFloat { ceil(size.height * 0.22) }
}
