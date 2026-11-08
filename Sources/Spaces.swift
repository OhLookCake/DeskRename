import AppKit
import Darwin

struct Desktop: Equatable, Identifiable {
    let id: String
    let number: Int
    let isCurrent: Bool

    var title: String { "Desktop \(number)" }
}

struct DisplaySpaces: Equatable {
    struct Slot: Equatable {
        let desktop: Desktop?
        let nativeTitle: String
    }

    let identifier: String
    // Full-screen apps occupy a position in Mission Control but aren't desktops.
    let slots: [Slot]

    var desktops: [Desktop] { slots.compactMap(\.desktop) }

    func matches(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {
            return false
        }
        if identifier == "Main" { return number == CGMainDisplayID() }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String? else { return false }
        return identifier.caseInsensitiveCompare(string) == .orderedSame
    }
}

final class SpaceReader {
    private typealias Connection = @convention(c) () -> Int32
    private typealias CopyDisplays = @convention(c) (Int32) -> Unmanaged<CFArray>?

    // Keep the handle alive for the lifetime of the resolved function pointers.
    private let library: UnsafeMutableRawPointer?
    private let connect: Connection?
    private let copyDisplays: CopyDisplays?
    private let desktopTitleFormat = Bundle(path: "/System/Library/CoreServices/Dock.app")?
        .localizedString(forKey: "DesktopNum", value: "Desktop %@", table: nil) ?? "Desktop %@"

    init() {
        let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        self.library = library
        connect = library.flatMap { dlsym($0, "CGSMainConnectionID") }.map {
            unsafeBitCast($0, to: Connection.self)
        }
        copyDisplays = library.flatMap { dlsym($0, "CGSCopyManagedDisplaySpaces") }.map {
            unsafeBitCast($0, to: CopyDisplays.self)
        }
    }

    deinit {
        if let library { dlclose(library) }
    }

    func snapshot() -> [DisplaySpaces]? {
        guard let connect, let copyDisplays,
              let raw = copyDisplays(connect())?.takeRetainedValue() as? [[String: Any]],
              !raw.isEmpty else { return nil }

        var seen = Set<String>()
        return raw.compactMap { display in
            guard let identifier = display["Display Identifier"] as? String,
                  let slots = display["Spaces"] as? [[String: Any]],
                  !slots.isEmpty else { return nil }
            let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? UInt64
            var number = 0
            let previews: [DisplaySpaces.Slot] = slots.map { slot in
                guard (slot["type"] as? Int) == 0 else {
                    let layout = slot["TileLayoutManager"] as? [String: Any]
                    let tiles = layout?["TileSpaces"] as? [[String: Any]] ?? []
                    // Some Space snapshots omit appName even when the app is still running.
                    let apps = tiles.compactMap { tile in
                        (tile["appName"] as? String) ?? Self.runningAppName(in: tile)
                    }
                    let title = apps.isEmpty
                        ? (slot["name"] as? String ?? Self.runningAppName(in: slot) ?? "Full Screen")
                        : apps.joined(separator: " & ")
                    return .init(desktop: nil, nativeTitle: title)
                }
                number += 1
                let title = String(format: desktopTitleFormat, String(number))
                let unnamed = DisplaySpaces.Slot(desktop: nil, nativeTitle: title)
                guard let managedID = slot["ManagedSpaceID"] as? UInt64 else { return unnamed }
                // The original system desktop can have an empty UUID on some releases.
                let uuid = (slot["uuid"] as? String ?? "").lowercased()
                let id = uuid.isEmpty && managedID == 1 ? "original-desktop" : uuid
                guard !id.isEmpty, seen.insert(id).inserted else { return unnamed }
                let desktop = Desktop(id: id, number: number, isCurrent: current == managedID)
                return .init(desktop: desktop, nativeTitle: title)
            }
            return DisplaySpaces(identifier: identifier, slots: previews)
        }
    }

    private static func runningAppName(in space: [String: Any]) -> String? {
        guard let pid = space["pid"] as? Int32, pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
