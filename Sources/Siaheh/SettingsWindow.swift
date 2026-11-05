import AppKit

/// The Settings window. Created on first use and reused afterwards; closing it
/// only hides it, so the app keeps running in the menu bar.
@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = Self.placeholderView()
        self.init(window: window)
    }

    func present() {
        // A background agent is not active, and macOS refuses focus requests that do
        // not follow user input. Ask for activation, make it key when we get it, and
        // order it above other apps regardless so it is never hidden behind them.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private static func placeholderView() -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: "Settings")
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }
}
