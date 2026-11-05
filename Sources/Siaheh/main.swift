import AppKit

/// Minimal menu-bar shell: a clipboard icon in the status bar and nothing else.
/// No window, no menu, no Dock icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            let icon = NSImage(systemSymbolName: "doc.on.clipboard",
                               accessibilityDescription: "Clipboard")
            icon?.isTemplate = true
            button.image = icon
            button.toolTip = "Siaheh"
        }

        statusItem = item
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
