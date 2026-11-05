import AppKit

/// Minimal menu-bar shell: a paperclip in the status bar, with a right-click menu.
/// No window, no menu-bar left-click behaviour, no Dock icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            let icon = NSImage(systemSymbolName: "paperclip",
                               accessibilityDescription: "Clipboard")
            icon?.isTemplate = true
            button.image = icon
            button.toolTip = "Siaheh"
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusItem = item
    }

    @objc private func handleClick() {
        guard NSApp.currentEvent?.type == .rightMouseUp else { return }
        showMenu()
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }

        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
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
