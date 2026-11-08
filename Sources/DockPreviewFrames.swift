import AppKit
import ApplicationServices
import QuartzCore

final class DockPreviewFrames {
    private let queue = DispatchQueue(label: "DeskRename.DockPreviewFrames", qos: .userInitiated)
    private var inFlight = false
    private var generation = 0
    private var nextRead: CFTimeInterval = 0
    private(set) var frames: [CGRect] = []

    func refresh(dockPID: pid_t) {
        let now = CACurrentMediaTime()
        guard !inFlight, now >= nextRead else { return }
        nextRead = now + 0.08
        guard AXIsProcessTrusted() else {
            frames = []
            return
        }
        inFlight = true
        let generation = generation
        queue.async { [weak self] in
            let frames = Self.read(dockPID: dockPID)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                if self.generation == generation { self.frames = frames }
            }
        }
    }

    func reset() {
        generation += 1
        frames.removeAll()
        nextRead = 0
    }

    private static func read(dockPID: pid_t) -> [CGRect] {
        let dock = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dock, 0.025)
        let deadline = CACurrentMediaTime() + 0.12
        var pending = [(dock, 0)]
        var frames: [CGRect] = []
        while let (element, depth) = pending.popLast(), CACurrentMediaTime() < deadline {
            guard depth < 12 else { continue }
            AXUIElementSetMessagingTimeout(element, 0.025)
            let role: String? = attribute(element, kAXRoleAttribute)
            // The Dock's list contains its app icons, outside Mission Control.
            if depth == 1 && role == kAXListRole { continue }
            if role == kAXButtonRole {
                if let frame = frame(of: element) { frames.append(frame) }
                continue
            }
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
            pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        return frames
    }

    private static func attribute<T>(_ element: AXUIElement, _ key: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(element, kAXPositionAttribute),
              let size: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }
}
