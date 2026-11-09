import AppKit

/// Menu-bar agent: a brain in the status bar, a global shortcut that opens the
/// clipboard history, and the history recorder behind both.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var store: ClipStore?
    private var watcher: ClipboardWatcher?
    private var historyWindow: HistoryWindowController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        openStore()
        registerHotKey()
        applyStatusItemPosition(restartMenuBar: false)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(registerHotKey),
            name: .hotKeyDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshStatusItemPosition),
            name: .statusItemPositionDidChange,
            object: nil
        )
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            let icon = NSImage(systemSymbolName: "brain", accessibilityDescription: "Engram")
            icon?.isTemplate = true
            button.image = icon
            button.toolTip = "Engram"
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusItem = item
    }

    @objc private func handleClick() {
        // Left-click opens the history; right-click keeps the Settings/Quit menu.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            showHistory()
        }
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }

        let menu = NSMenu()

        let clipboard = NSMenuItem(title: "Clipboard History", action: #selector(showHistory), keyEquivalent: "")
        clipboard.target = self
        menu.addItem(clipboard)

        let settings = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    // MARK: - Clipboard history

    /// A history that cannot be opened is fatal for a clipboard manager: say so and stop
    /// rather than run in a state where nothing is recorded.
    private func openStore() {
        do {
            let store = try ClipStore()
            store.enforceRetention()

            let watcher = ClipboardWatcher(store: store)
            watcher.start()

            self.store = store
            self.watcher = watcher
        } catch {
            let alert = NSAlert()
            alert.messageText = "Engram could not open its clipboard history"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    @objc private func registerHotKey() {
        let combo = Settings.hotKey
        let registered = GlobalHotKey.shared.register(combo) { [weak self] in
            self?.showHistory()
        }

        if !registered {
            NSLog("Engram: \(combo.displayString) is already taken; pick another shortcut in Settings")
        }
    }

    // MARK: - Status item position

    /// The anchor the icon is placed immediately before when "right edge" is on.
    /// Control Center is the first system icon at the right of the menu bar, so this
    /// puts Engram as far right as a third-party icon can go. Change it (e.g. to the
    /// clock's bundle id) if a different spot is wanted.
    private static let rightEdgeAnchor = "com.apple.controlcenter"

    @objc private func refreshStatusItemPosition() {
        applyStatusItemPosition(restartMenuBar: true)
    }

    /// Menu-bar icon ordering has no public API. It lives in the systemuiserver
    /// preference domain under "NSStatusItem Preferred Position <bundle>", so writing
    /// that key (and restarting SystemUIServer to reload it) is the only way to move
    /// the icon. Removing the key returns it to its default position.
    private func applyStatusItemPosition(restartMenuBar: Bool) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.engram.app"
        let key = "NSStatusItem Preferred Position \(bundleID)"

        if Settings.statusItemAtRightEdge {
            run("/usr/bin/defaults", ["write", "com.apple.systemuiserver", key, "-string", Self.rightEdgeAnchor])
        } else {
            run("/usr/bin/defaults", ["delete", "com.apple.systemuiserver", key])
        }

        if restartMenuBar {
            run("/usr/bin/killall", ["SystemUIServer"])
        }
    }

    private func run(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("Engram: could not run \(executable): \(error.localizedDescription)")
        }
    }

    @objc private func showHistory() {
        guard let store else { return }

        if historyWindow == nil {
            historyWindow = HistoryWindowController(store: store)
        }
        historyWindow?.present()
    }

    @objc private func openSettings() {
        guard let store else { return }

        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(store: store)
        }
        settingsWindow?.present()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
