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

    private struct Expansion {
        let beganAt: CFTimeInterval
        var offset: CGFloat
    }

    private var overlays: [String: Overlay] = [:]
    private var expansions: [String: Expansion] = [:]
    private var dockPID: pid_t?
    private var dockCheck: CFTimeInterval = 0

    func clear() {
        overlays.values.forEach { $0.window.orderOut(nil) }
        overlays.removeAll()
        expansions.removeAll()
    }

    func update(displays: [DisplaySpaces], names: [String: String]) -> Bool {
        guard !names.isEmpty, let screens = missionControlScreens(), !screens.isEmpty else {
            clear()
            return false
        }

        let cursor = NSEvent.mouseLocation
        let now = CACurrentMediaTime()
        var shown = Set<String>()
        var active = Set<String>()
        for screen in screens {
            guard let display = displays.first(where: { $0.matches(screen) })
                    ?? (NSScreen.screens.count == 1 && displays.count == 1 ? displays.first : nil) else { continue }
            let key = display.identifier
            let frame = screen.frame
            guard let row = PreviewRow(size: frame.size, safeTop: screen.safeAreaInsets.top,
                                       count: display.slots.count) else { continue }
            active.insert(key)

            let x = cursor.x - frame.minX
            let depth = frame.maxY - cursor.y
            if expansions[key] == nil, x >= 0, x < frame.width,
               depth >= 0, depth <= max(40, screen.safeAreaInsets.top + 18) {
                // The Dock puts the preview for the compact title under the
                // pointer. Latch that offset when the strip begins expanding.
                expansions[key] = Expansion(beganAt: now, offset: row.offset(at: x, slots: display.slots))
            }
            guard var expansion = expansions[key] else { continue }
            if x < 80 || x > frame.width - 80 || depth < 0 || depth > row.captionDepth + 14 {
                // Once the pointer leaves the strip, the Dock centers the row
                // again and keeps it centered until Mission Control closes.
                expansion.offset = 0
                expansions[key] = expansion
            }
            guard now - expansion.beganAt >= 0.22 else { continue }

            let plates = Self.layout(display.slots, names: names, row: row, offset: expansion.offset)
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
        for key in Array(expansions.keys) where !active.contains(key) {
            expansions.removeValue(forKey: key)
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

    private struct PreviewRow {
        private static let gap: CGFloat = 32
        private let size: CGSize
        private let first: CGFloat
        let step: CGFloat
        let captionDepth: CGFloat

        init?(size: CGSize, safeTop: CGFloat, count: Int) {
            guard count > 0 else { return nil }
            let aspect = size.width / size.height
            let step = min(90 * aspect + Self.gap, size.width * 0.94 / CGFloat(count))
            guard step > Self.gap + 2 else { return nil }
            self.size = size
            self.step = step
            first = (size.width - step * CGFloat(count - 1)) / 2
            captionDepth = max(27, safeTop + 13) + (step - Self.gap) / aspect + 15
        }

        var labelY: CGFloat { MissionControlOverlay.bandHeight(for: size) - captionDepth }

        func center(at index: Int) -> CGFloat { first + CGFloat(index) * step }

        func offset(at x: CGFloat, slots: [DisplaySpaces.Slot]) -> CGFloat {
            let font = NSFont.systemFont(ofSize: 12)
            let widths = slots.map {
                min(500, ceil(($0.nativeTitle as NSString).size(withAttributes: [.font: font]).width) + 20)
            }
            let compactWidth = widths.reduce(0, +) + Self.gap * CGFloat(widths.count - 1)
            var left = (size.width - compactWidth) / 2
            guard x >= left, x <= left + compactWidth else { return 0 }
            for (index, width) in widths.enumerated() {
                // If expansion starts in a gap, the Dock keeps the title on
                // its left as the anchor.
                if x < left + width + Self.gap { return x - center(at: index) }
                left += width + Self.gap
            }
            return 0
        }
    }

    private static func layout(_ slots: [DisplaySpaces.Slot], names: [String: String], row: PreviewRow,
                               offset: CGFloat) -> [Plate] {
        return slots.enumerated().compactMap { index, item in
            guard let item = item.desktop, let name = names[item.id] else { return nil }
            let caption = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
            let width = min(max(76, ceil(caption.width) + 20), floor(row.step - 6))
            return Plate(name: name, frame: CGRect(x: (row.center(at: index) + offset - width / 2).rounded(),
                        y: (row.labelY - 12).rounded(), width: width, height: 24),
                        selected: item.isCurrent)
        }
    }

    private static func bandHeight(for size: CGSize) -> CGFloat { ceil(size.height * 0.22) }
}
