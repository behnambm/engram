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
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Baseline the pasteboard before the slow startup work (store open, migrations,
        // thumbnail backfill, retention). The watcher is constructed afterwards; using
        // the *current* counter there would treat a copy made during startup as already
        // seen and drop it.
        let launchChangeCount = NSPasteboard.general.changeCount

        // A menu-bar agent has no visible window, so macOS App Naps it and throttles
        // timers. Hold an activity token so clipboard capture keeps running; idle CPU
        // stays at zero because a tick is a single integer comparison.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Record clipboard changes"
        )

        installMainMenu()
        installStatusItem()
        openStore(baselineChangeCount: launchChangeCount)
        registerHotKey()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(registerHotKey),
            name: .hotKeyDidChange,
            object: nil
        )
    }

    // MARK: - Main menu

    /// Engram is a menu-bar agent (`LSUIElement`), so it has no visible menu bar — but a
    /// main menu is still required for standard editing key equivalents (⌘A Select All,
    /// ⌘C/⌘V/⌘X, ⌘Z) to reach the search field's field editor. Without it, those
    /// shortcuts have no menu item to dispatch and ⌘A does nothing.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Engram",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            button.image = Self.makeMenuBarIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "Engram"
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusItem = item
    }

    /// The brain glyph with a status dot at its bottom-right. The brain is always white
    /// (it reads on a dark menu bar); the dot is green while recording and red while
    /// paused.
    private static func makeMenuBarIcon() -> NSImage {
        let canvas = NSSize(width: 22, height: 22)
        let brainColor: NSColor = .white

        let image = NSImage(size: canvas)
        image.lockFocus()

        if let brain = NSImage(systemSymbolName: "brain", accessibilityDescription: nil) {
            brain.isTemplate = false
            let brainSize = NSSize(width: 18, height: 18)
            let brainRect = NSRect(
                x: (canvas.width - brainSize.width) / 2,
                y: (canvas.height - brainSize.height) / 2,
                width: brainSize.width,
                height: brainSize.height
            )
            brain.tinted(with: brainColor).draw(in: brainRect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        let dotColor: NSColor = Settings.isPaused
            ? .systemRed
            : NSColor(calibratedRed: 0.22, green: 1.0, blue: 0.08, alpha: 1)  // neon green
        dotColor.setFill()
        let dotDiameter: CGFloat = 6
        let dot = NSRect(
            x: canvas.width - dotDiameter - 1,
            y: 1,
            width: dotDiameter,
            height: dotDiameter
        )
        NSBezierPath(ovalIn: dot).fill()

        image.unlockFocus()
        return image
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

        let pause = NSMenuItem(title: Settings.isPaused ? "Unpause" : "Pause", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        let settings = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Show as a context menu anchored to the button, so macOS positions it below the
        // icon at the correct screen spot instead of a hand-computed offset.
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    /// Toggles clipboard recording on/off and updates the menu-bar dot (green = recording,
    /// red = paused). The watcher checks `Settings.isPaused` before every capture.
    @objc private func togglePause() {
        Settings.isPaused.toggle()
        if !Settings.isPaused {
            // Discard any pasteboard change that occurred while paused, so it is not
            // captured by the first watcher tick after unpausing.
            watcher?.discardPendingChanges()
        }
        statusItem?.button?.image = Self.makeMenuBarIcon()
    }

    // MARK: - Clipboard history

    /// A history that cannot be opened is fatal for a clipboard manager: say so and stop
    /// rather than run in a state where nothing is recorded.
    private func openStore(baselineChangeCount: Int) {
        do {
            let store = try ClipStore()
            store.enforceRetention()

            let watcher = ClipboardWatcher(store: store, baselineChangeCount: baselineChangeCount)
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

    @objc private func showHistory() {
        guard let store else { return }

        if historyWindow == nil {
            historyWindow = HistoryWindowController(store: store)
        }
        // Present on the next run-loop turn so the menu (if this came from a right-click)
        // has closed and the window can actually become key.
        DispatchQueue.main.async { [weak self] in
            self?.historyWindow?.present()
        }
    }

    @objc private func openSettings() {
        guard let store else { return }

        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(store: store)
        }
        // Present on the next run-loop turn so the menu has closed and the window can
        // actually become key (otherwise it opens behind the previously focused app).
        DispatchQueue.main.async { [weak self] in
            self?.settingsWindow?.present()
        }
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

extension NSImage {
    /// Returns a copy of the image tinted with `color`. Works for template symbols too:
    /// the shape is filled with `color` while its alpha is preserved.
    func tinted(with color: NSColor) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        rect.fill(using: .sourceAtop)
        result.unlockFocus()
        return result
    }
}
