import AppKit
import CoreText
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
        var diagnostics: MissionControlDiagnostics? {
            didSet { if diagnostics != oldValue { needsDisplay = true } }
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
            diagnostics?.draw(in: bounds)
        }
    }

    private struct Overlay {
        let window: NSPanel
        let strip: StripView
    }

    private struct Expansion {
        struct Anchor {
            let entry: PointerSample
            let before: PointerSample

            var isReliable: Bool {
                entry.time - before.time <= 0.08 &&
                    abs(entry.point.x - before.point.x) <= 16
            }
        }

        var compactEntry: PointerSample?
        var entryAnchor: Anchor?
        var offset: CGFloat?
        var predictionDeferred = false
        var hasLeftStrip = false
        var trail: [PointerSample] = []
        var firstShift: CGFloat?
        var selectedSpace: String?
    }

    private struct TrackedDisplay {
        let screen: NSScreen
        let row: PreviewRow
        let slots: [DisplaySpaces.Slot]
    }

    private struct PointerSample {
        let point: CGPoint
        let time: CFTimeInterval
        let polled: Bool
    }

    // Keep enough input to cover the gap between Mission Control window polls.
    private static let pointerLookback: CFTimeInterval = 0.20
    private static let compactStripHeight: CGFloat = 40
    private var overlays: [String: Overlay] = [:]
    private var expansions: [String: Expansion] = [:]
    private var trackedDisplays: [String: TrackedDisplay] = [:]
    private var pointerScreens: [NSScreen] = []
    private var pendingPointer: [PointerSample] = []
    private var diagnosticHistory: [PointerSample] = []
    private var lastApproachTime: CFTimeInterval = -.infinity
    private var lastApproachFrame: CGRect?
    private var previousPointer: PointerSample?
    private var mouseTap: CFMachPort?
    private var mouseMonitor: Any?
    private var pointerTimer: Timer?
    private let nativePreviews = DockPreviewFrames()
    private var dockPID: pid_t?
    private var dockCheck: CFTimeInterval = 0
    var diagnosticsEnabled = false {
        didSet {
            if !diagnosticsEnabled { diagnosticHistory.removeAll() }
        }
    }

    deinit {
        stopMouseMonitoring()
        pointerTimer?.invalidate()
    }

    private func clearSession() {
        overlays.values.forEach { $0.window.orderOut(nil) }
        overlays.removeAll()
        expansions.removeAll()
        trackedDisplays.removeAll()
        diagnosticHistory.removeAll()
        pointerTimer?.invalidate()
        pointerTimer = nil
        nativePreviews.reset()
    }

    func update(displays: [DisplaySpaces], names: [String: String]) -> Bool {
        guard diagnosticsEnabled || !names.isEmpty else {
            clearSession()
            pendingPointer.removeAll()
            lastApproachTime = -.infinity
            lastApproachFrame = nil
            previousPointer = nil
            pointerScreens.removeAll()
            stopMouseMonitoring()
            return false
        }

        pointerScreens = NSScreen.screens
        startMouseMonitoring()
        let now = ProcessInfo.processInfo.systemUptime
        let cursor = PointerSample(point: NSEvent.mouseLocation, time: now, polled: true)
        guard let screens = missionControlScreens(), !screens.isEmpty else {
            pendingPointer.removeAll { now - $0.time > Self.pointerLookback }
            if !trackedDisplays.isEmpty {
                lastApproachFrame = nil
                previousPointer = nil
            }
            clearSession()
            observePointer(cursor)
            return false
        }

        trackedDisplays.removeAll(keepingCapacity: true)
        for screen in screens {
            guard let display = displays.first(where: { $0.matches(screen) })
                    ?? (pointerScreens.count == 1 && displays.count == 1 ? displays.first : nil),
                  let row = PreviewRow(size: screen.frame.size, safeTop: screen.safeAreaInsets.top,
                                       count: display.slots.count) else { continue }
            trackedDisplays[display.identifier] = TrackedDisplay(screen: screen, row: row, slots: display.slots)
        }
        if !pendingPointer.isEmpty {
            previousPointer = nil
            for sample in pendingPointer.sorted(by: { $0.time < $1.time })
                where now - sample.time <= Self.pointerLookback {
                trackPointer(sample)
            }
        }
        pendingPointer.removeAll(keepingCapacity: true)
        lastApproachTime = -.infinity
        // Also sample the system pointer for events the Dock consumes directly.
        trackPointer(cursor)
        if let dockPID { nativePreviews.refresh(dockPID: dockPID) }

        var shown = Set<String>()
        for (key, display) in trackedDisplays {
            let frame = display.screen.frame
            let row = display.row
            let expanded = expansions[key]?.compactEntry.map { now - $0.time >= 0.22 } ?? false
            if expanded, var expansion = expansions[key], expansion.offset == nil, !expansion.predictionDeferred {
                if let anchor = expansion.entryAnchor, anchor.isReliable {
                    let x = anchor.entry.point.x - frame.minX
                    let slot = row.anchorSlot(at: x, slots: display.slots)
                    let priorSlot = row.anchorSlot(at: anchor.before.point.x - frame.minX, slots: display.slots)
                    if slot == priorSlot {
                        let offset = slot.map { x - row.center(at: $0) } ?? 0
                        expansion.offset = offset
                        if diagnosticsEnabled {
                            expansion.firstShift = offset
                            expansion.selectedSpace = slot.map { display.slots[$0].nativeTitle }
                        }
                    }
                }
                // A fast diagonal sweep can pass multiple compact titles between samples.
                expansion.predictionDeferred = expansion.offset == nil
                expansions[key] = expansion
            }

            let height = diagnosticsEnabled ? frame.height : Self.bandHeight(for: frame.size)
            let offset = expanded ? expansions[key]?.offset : nil
            let observed = row.observedCenters(in: nativePreviews.frames, screen: display.screen, count: display.slots.count)
            let centers = observed ?? offset.map { shift in
                display.slots.indices.map { row.center(at: $0) + shift }
            }
            let plates = centers.map {
                Self.layout(display.slots, names: names, centers: $0, step: row.step,
                            labelY: height - row.captionDepth)
            } ?? []
            guard diagnosticsEnabled || !plates.isEmpty else { continue }
            shown.insert(key)
            let band = CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
            let overlay = overlays[key] ?? makeOverlay(frame: band)
            overlays[key] = overlay
            if overlay.window.frame != band { overlay.window.setFrame(band, display: true) }
            overlay.strip.plates = plates
            overlay.strip.diagnostics = diagnosticsEnabled
                ? diagnostics(for: display, expansion: expansions[key], appliedOffset: offset, observed: observed)
                : nil
            if !overlay.window.isVisible { overlay.window.orderFrontRegardless() }
        }

        for key in Array(overlays.keys) where !shown.contains(key) {
            overlays.removeValue(forKey: key)?.window.orderOut(nil)
        }
        for key in Array(expansions.keys) where trackedDisplays[key] == nil {
            expansions.removeValue(forKey: key)
        }
        updatePointerSampling()
        return true
    }

    private func updatePointerSampling() {
        // Sample independently of the window scan until the pointer enters the strip.
        let waitingForEntry = trackedDisplays.keys.contains { expansions[$0]?.compactEntry == nil }
        if waitingForEntry, pointerTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 240, repeats: true) { [weak self] _ in
                self?.trackPointer(PointerSample(point: NSEvent.mouseLocation,
                    time: ProcessInfo.processInfo.systemUptime, polled: true))
            }
            RunLoop.main.add(timer, forMode: .common)
            pointerTimer = timer
        } else if !waitingForEntry {
            pointerTimer?.invalidate()
            pointerTimer = nil
        }
    }

    private func startMouseMonitoring() {
        guard mouseTap == nil, mouseMonitor == nil else { return }
        // Read mouse moves before the Dock consumes them. The tap observes
        // mouse movement only and is active before the first window poll.
        let mask = CGEventMask(1) << CGEventType.mouseMoved.rawValue
        if let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                       options: .listenOnly, eventsOfInterest: mask,
                                       callback: { _, type, event, context in
            guard let context else { return nil }
            let overlay = Unmanaged<MissionControlOverlay>.fromOpaque(context).takeUnretainedValue()
            switch type {
            case .mouseMoved:
                overlay.observeMouseEvent(event)
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let tap = overlay.mouseTap { CGEvent.tapEnable(tap: tap, enable: true) }
            default:
                break
            }
            return nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
           let source = CFMachPortCreateRunLoopSource(nil, tap, 0) {
            mouseTap = tap
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        } else {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                if let mouseEvent = event.cgEvent { self?.observeMouseEvent(mouseEvent) }
            }
        }
    }

    private func stopMouseMonitoring() {
        if let mouseTap { CFMachPortInvalidate(mouseTap) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseTap = nil
        mouseMonitor = nil
    }

    private func observeMouseEvent(_ event: CGEvent) {
        let time = Double(event.timestamp) / 1_000_000_000
        guard let top = pointerScreens.first?.frame.maxY,
              ProcessInfo.processInfo.systemUptime - time <= Self.pointerLookback else { return }
        let point = event.location
        observePointer(PointerSample(point: CGPoint(x: point.x, y: top - point.y), time: time, polled: false))
    }

    private func observePointer(_ sample: PointerSample) {
        if !trackedDisplays.isEmpty {
            trackPointer(sample)
            return
        }

        defer {
            if previousPointer.map({ $0.time <= sample.time }) ?? true { previousPointer = sample }
        }
        let approachFrame = pointerScreens.first {
            Self.isOnScreen(sample.point, frame: $0.frame) && sample.point.y >= Self.traceStartY(on: $0)
        }?.frame
        if let approachFrame, approachFrame != lastApproachFrame {
            lastApproachTime = sample.time
            if pendingPointer.isEmpty, let previousPointer,
               sample.time >= previousPointer.time, sample.time - previousPointer.time <= Self.pointerLookback {
                pendingPointer.append(previousPointer)
            }
        }
        lastApproachFrame = approachFrame
        // Only retain movements in and immediately after entry into a top strip.
        guard sample.time - lastApproachTime <= Self.pointerLookback else { return }
        pendingPointer.removeAll { sample.time - $0.time > Self.pointerLookback }
        pendingPointer.append(sample)
    }

    private static func isInCompactStrip(_ point: CGPoint, screen: NSScreen) -> Bool {
        let frame = screen.frame
        let depth = frame.maxY - point.y
        return point.x >= frame.minX && point.x < frame.maxX && depth >= 0 &&
            depth <= screen.safeAreaInsets.top + compactStripHeight
    }

    private static func traceStartY(on screen: NSScreen) -> CGFloat {
        // Keep the pointer's approach before it reaches the compact strip.
        screen.frame.maxY - screen.safeAreaInsets.top - 67
    }

    private func trackPointer(_ sample: PointerSample) {
        if diagnosticsEnabled {
            diagnosticHistory.removeAll { sample.time - $0.time > Self.pointerLookback }
            if diagnosticHistory.last?.point != sample.point { diagnosticHistory.append(sample) }
        }
        defer {
            if previousPointer.map({ $0.time <= sample.time }) ?? true { previousPointer = sample }
        }
        for (key, display) in trackedDisplays {
            let frame = display.screen.frame
            let x = sample.point.x - frame.minX
            let depth = frame.maxY - sample.point.y
            let inCompactStrip = Self.isInCompactStrip(sample.point, screen: display.screen)
            let traceStartY = Self.traceStartY(on: display.screen)
            let onScreen = Self.isOnScreen(sample.point, frame: frame)
            var expansion: Expansion
            if let existing = expansions[key] {
                expansion = existing
            } else {
                guard onScreen, sample.point.y >= traceStartY else { continue }
                expansion = Expansion()
                if diagnosticsEnabled {
                    expansion.trail = diagnosticHistory.filter { Self.isOnScreen($0.point, frame: frame) }
                }
            }
            guard !expansion.hasLeftStrip else { continue }
            if diagnosticsEnabled, expansion.offset == nil, !expansion.predictionDeferred, expansion.trail.count < 512,
               onScreen, expansion.trail.last?.point != sample.point {
                expansion.trail.append(sample)
            }

            if inCompactStrip, expansion.compactEntry.map({ sample.time < $0.time }) ?? true {
                expansion.compactEntry = sample
                expansion.entryAnchor = nil
                if let previousPointer, previousPointer.time < sample.time,
                   Self.isOnScreen(previousPointer.point, frame: frame) {
                    expansion.entryAnchor = Expansion.Anchor(entry: sample, before: previousPointer)
                }
            } else if expansion.compactEntry == nil, !onScreen || sample.point.y < traceStartY {
                expansions[key] = nil
                continue
            }
            if let entry = expansion.compactEntry, sample.time >= entry.time,
               x < 80 || x > frame.width - 80 || depth < 0 || depth > display.row.captionDepth + 14 {
                // The Dock keeps the row centered after the pointer leaves.
                expansion.offset = 0
                expansion.hasLeftStrip = true
            }
            expansions[key] = expansion
        }
    }

    private static func isOnScreen(_ point: CGPoint, frame: CGRect) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }

    private func diagnostics(for display: TrackedDisplay, expansion: Expansion?,
                             appliedOffset: CGFloat?, observed: [CGFloat]?) -> MissionControlDiagnostics {
        let frame = display.screen.frame
        let row = display.row
        func local(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        }
        let trail = expansion?.trail ?? diagnosticHistory.filter { Self.isOnScreen($0.point, frame: frame) }
        let anchor = expansion?.entryAnchor
        let centers = display.slots.indices.map { row.center(at: $0) }
        let method: String?
        if observed != nil {
            method = "Using Dock preview positions"
        } else if expansion?.predictionDeferred == true && appliedOffset == nil {
            method = "Entry too fast to place labels from pointer samples"
        } else {
            method = anchor == nil ? nil : "Compact strip entry"
        }
        return MissionControlDiagnostics(
            referenceY: frame.height - display.screen.safeAreaInsets.top - Self.compactStripHeight,
            labelY: frame.height - row.captionDepth,
            thumbnailSize: row.thumbnailSize,
            centeredXs: centers,
            trail: trail.map { .init(point: local($0.point), polled: $0.polled) },
            observedXs: observed,
            anchorX: anchor.map { $0.entry.point.x - frame.minX },
            anchorSamples: anchor.map { [local($0.before.point), local($0.entry.point)] } ?? [],
            anchorMethod: method,
            selectedSpace: expansion?.selectedSpace,
            appliedOffset: appliedOffset,
            firstShift: expansion?.firstShift,
            recentered: expansion?.hasLeftStrip == true
        )
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
        return pointerScreens.filter { screen in
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
        private let width: CGFloat
        private let first: CGFloat
        let step: CGFloat
        let captionDepth: CGFloat
        let thumbnailSize: CGSize

        init?(size: CGSize, safeTop: CGFloat, count: Int) {
            guard count > 0 else { return nil }
            let aspect = size.width / size.height
            let step = min(90 * aspect + Self.gap, size.width * 0.94 / CGFloat(count))
            guard step > Self.gap + 2 else { return nil }
            width = size.width
            self.step = step
            first = (size.width - step * CGFloat(count - 1)) / 2
            thumbnailSize = CGSize(width: step - Self.gap, height: (step - Self.gap) / aspect)
            captionDepth = max(27, safeTop + 13) + thumbnailSize.height + 15
        }

        func center(at index: Int) -> CGFloat { first + CGFloat(index) * step }

        func observedCenters(in frames: [CGRect], screen: NSScreen, count: Int) -> [CGFloat]? {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {
                return nil
            }
            let bounds = CGDisplayBounds(number)
            let centers = frames.filter { frame in
                bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) &&
                    frame.minY - bounds.minY >= 0 && frame.minY - bounds.minY < captionDepth &&
                    frame.height > 42 && frame.width >= thumbnailSize.width * 0.65 &&
                    frame.width <= thumbnailSize.width * 1.5 && frame.height <= thumbnailSize.height * 1.7
            }.map { $0.midX - bounds.minX }.sorted()
            guard centers.count == count,
                  zip(centers.dropFirst(), centers).allSatisfy({ $0 - $1 >= thumbnailSize.width * 0.65 }) else {
                return nil
            }
            return centers
        }

        func anchorSlot(at x: CGFloat, slots: [DisplaySpaces.Slot]) -> Int? {
            // The compact strip uses the text layer's measured width. Extra
            // padding here moves the hit boundary and can pick the next Space.
            let text = CATextLayer()
            text.fontSize = 12
            text.font = CTFontCreateUIFontForLanguage(.system, text.fontSize, nil)
            let widths = slots.map {
                text.string = $0.nativeTitle
                return min(500, ceil(text.preferredFrameSize().width))
            }
            let compactWidth = widths.reduce(0, +) + Self.gap * CGFloat(widths.count - 1)
            var left = (width - compactWidth) / 2
            guard x >= left, x <= left + compactWidth else { return nil }
            for (index, width) in widths.enumerated() {
                // If expansion starts in a gap, the Dock keeps the title on
                // its left as the anchor.
                if x < left + width + Self.gap { return index }
                left += width + Self.gap
            }
            return nil
        }
    }

    private static func layout(_ slots: [DisplaySpaces.Slot], names: [String: String], centers: [CGFloat],
                               step: CGFloat, labelY: CGFloat) -> [Plate] {
        return slots.enumerated().compactMap { index, item in
            guard let item = item.desktop, let name = names[item.id] else { return nil }
            let caption = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
            let width = min(max(76, ceil(caption.width) + 20), floor(step - 6))
            return Plate(name: name, frame: CGRect(x: (centers[index] - width / 2).rounded(),
                        y: (labelY - 12).rounded(), width: width, height: 24),
                        selected: item.isCurrent)
        }
    }

    private static func bandHeight(for size: CGSize) -> CGFloat { ceil(size.height * 0.22) }
}
