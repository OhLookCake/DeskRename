import AppKit
import ApplicationServices
import Combine
import SwiftUI

final class DesktopNames: ObservableObject {
    @Published private(set) var displays: [DisplaySpaces] = []
    @Published private(set) var unavailable = false
    @Published private(set) var names: [String: String]
    @Published var draft: [String: String] = [:]

    private let reader = SpaceReader()
    private let defaults = UserDefaults.standard
    private static let namesKey = "DesktopNamesBySpace"

    init() {
        names = defaults.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        refresh()
    }

    func refresh() {
        let snapshot = reader.snapshot()
        if let snapshot, snapshot.contains(where: { !$0.desktops.isEmpty }) {
            if snapshot != displays { displays = snapshot }
            if unavailable { unavailable = false }
        } else if displays.isEmpty && !unavailable {
            unavailable = true
        }
    }

    func save(_ draft: [String: String]) {
        var updated = names
        for (id, input) in draft {
            let singleLine = input.split(whereSeparator: \.isNewline).joined(separator: " ")
            let name = String(singleLine.trimmingCharacters(in: .whitespaces).prefix(80))
            updated[id] = name.isEmpty ? nil : name
        }
        guard updated != names else { return }
        names = updated
        defaults.set(updated, forKey: Self.namesKey)
    }
}

private struct NameEditor: View {
    @ObservedObject var model: DesktopNames
    var save: ([String: String]) -> Void
    var showMissionControl: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name your desktops").font(.title2.weight(.semibold))
                    Text("Find your Spaces by name in Mission Control.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(22)

            Divider()

            if model.displays.isEmpty {
                ContentUnavailableView("No desktops found", systemImage: "rectangle.on.rectangle",
                    description: Text(model.unavailable ? "DeskRename couldn’t read your Spaces. Open Mission Control, then try again." : "Looking for your Spaces…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.displays.filter { !$0.desktops.isEmpty }, id: \.identifier) { display in
                            if model.displays.count > 1 {
                                Text(screenName(display))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(display.desktops) { desktop in
                                HStack(spacing: 14) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(desktop.title).fontWeight(.medium)
                                        if desktop.isCurrent {
                                            Text("Current").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(width: 90, alignment: .leading)

                                    TextField("Custom name", text: Binding(
                                        get: { model.draft[desktop.id] ?? model.names[desktop.id] ?? "" },
                                        set: { model.draft[desktop.id] = $0 }
                                    ), prompt: Text(desktop.title))
                                    .accessibilityLabel("Name for \(desktop.title)")
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.large)
                                    .onSubmit { commit() }
                                }
                                .frame(minHeight: 38)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Clear a name to restore the default. In Mission Control, move the pointer to the top to reveal the desktop thumbnails.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Mission Control", action: showMissionControl)
                        .disabled(!model.draft.isEmpty)
                    Spacer()
                    Button("Save Names") { commit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.draft.isEmpty)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 450, minHeight: 310)
    }

    private func commit() {
        guard !model.draft.isEmpty else { return }
        save(model.draft)
        model.draft.removeAll()
    }

    private func screenName(_ display: DisplaySpaces) -> String {
        NSScreen.screens.first(where: { display.matches($0) })?.localizedName ?? "Display"
    }
}

final class DeskRenameApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let diagnosticsKey = "MissionControlDiagnostics"
    private let model = DesktopNames()
    private let overlay = MissionControlOverlay()
    private var timer: Timer?
    private var status: NSStatusItem!
    private var window: NSWindow?
    private var missionControlOpen = false
    private var lastRefresh = Date.distantPast
    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay.diagnosticsEnabled = UserDefaults.standard.bool(forKey: Self.diagnosticsKey)
        installKeyboardMenus()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "DeskRename")
        status.button?.setAccessibilityLabel("DeskRename")
        status.button?.toolTip = "DeskRename"
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        updateStatus()
        schedule(0.1)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        showEditor()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showEditor()
        return false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refresh()
        updateStatus()
        menu.removeAllItems()
        addItem("Rename Desktops…", action: #selector(showEditor), key: "r", to: menu)
        addItem("Open Mission Control", action: #selector(openMissionControl), key: "", to: menu)
        let diagnostics = addItem("Diagnostic Overlay", action: #selector(toggleDiagnostics), key: "", to: menu)
        diagnostics.state = overlay.diagnosticsEnabled ? .on : .off
        if !AXIsProcessTrusted() {
            addItem("Allow Reading Dock Preview Positions…", action: #selector(enableDockPositions), key: "", to: menu)
        }
        menu.addItem(.separator())
        addItem("Quit DeskRename", action: #selector(quit), key: "q", to: menu)
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, key: String, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func installKeyboardMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "DeskRename")
        addItem("Quit DeskRename", action: #selector(quit), key: "q", to: appMenu)
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"),
                                     ("Copy", #selector(NSText.copy(_:)), "c"),
                                     ("Paste", #selector(NSText.paste(_:)), "v"),
                                     ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func showEditor() {
        model.refresh()
        if window == nil {
            let editor = NameEditor(model: model, save: { [weak self] draft in
                self?.model.save(draft)
                self?.updateStatus()
            }, showMissionControl: { [weak self] in self?.openMissionControl() })
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 345),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "DeskRename"
            panel.isReleasedWhenClosed = false
            panel.contentMinSize = NSSize(width: 450, height: 310)
            panel.contentView = NSHostingView(rootView: editor)
            panel.center()
            window = panel
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openMissionControl() {
        window?.orderOut(nil)
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.showEditor()
                let alert = NSAlert(error: error)
                alert.messageText = "Couldn’t open Mission Control"
                alert.informativeText = "Use the Mission Control key or your usual trackpad gesture."
                if let window = self?.window { alert.beginSheetModal(for: window) }
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleDiagnostics() {
        overlay.diagnosticsEnabled.toggle()
        UserDefaults.standard.set(overlay.diagnosticsEnabled, forKey: Self.diagnosticsKey)
        tick()
    }

    @objc private func enableDockPositions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @objc private func spaceChanged() {
        model.refresh()
        updateStatus()
    }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = interval * 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        let tracking = missionControlOpen || window?.isVisible == true
        if tracking && now.timeIntervalSince(lastRefresh) >= 0.4 {
            model.refresh()
            lastRefresh = now
        }

        let open = overlay.update(displays: model.displays, names: model.names)
        if open != missionControlOpen {
            missionControlOpen = open
            model.refresh()
            updateStatus()
            schedule(open ? 0.04 : 0.10)
        }
    }

    private func updateStatus() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
        let display = screen.flatMap { screen in model.displays.first(where: { $0.matches(screen) }) }
            ?? model.displays.first
        let desktop = display?.desktops.first(where: \.isCurrent)
        let name = desktop.flatMap { model.names[$0.id] }
        let truncated = name.map { $0.count > 22 ? String($0.prefix(21)) + "…" : $0 } ?? ""
        status?.button?.imagePosition = truncated.isEmpty ? .imageOnly : .imageLeading
        status?.button?.title = truncated
        status?.button?.toolTip = name.map { "DeskRename: \($0)" } ?? "DeskRename"
        status?.button?.setAccessibilityLabel(status?.button?.toolTip)
    }
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = DeskRenameApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
