import AppKit

/// The Settings window. Created on first use and reused afterwards; closing it
/// only hides it, so the app keeps running in the menu bar.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let launchAtLoginButton = NSButton(
        checkboxWithTitle: "Start Siaheh at system startup",
        target: nil,
        action: nil
    )

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
        self.init(window: window)
        window.contentView = makeContentView()
        refreshLaunchAtLogin()
    }

    func present() {
        refreshLaunchAtLogin()

        // A background agent is not active, and macOS refuses focus requests that do
        // not follow user input. Ask for activation, make it key when we get it, and
        // order it above other apps regardless so it is never hidden behind them.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func makeContentView() -> NSView {
        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(toggleLaunchAtLogin)
        launchAtLoginButton.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(launchAtLoginButton)
        NSLayoutConstraint.activate([
            launchAtLoginButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            launchAtLoginButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            launchAtLoginButton.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                                          constant: -20),
        ])
        return container
    }

    /// Reads the state back from the system, which is the only source of truth: the
    /// user can remove the login item in System Settings while this window is open.
    private func refreshLaunchAtLogin() {
        launchAtLoginButton.state = LaunchAtLogin.isOn ? .on : .off
        launchAtLoginButton.toolTip = LaunchAtLogin.needsApproval
            ? "Allow Siaheh in System Settings → General → Login Items"
            : nil
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.set(launchAtLoginButton.state == .on)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshLaunchAtLogin()
    }
}
