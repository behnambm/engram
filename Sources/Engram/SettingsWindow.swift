import AppKit

/// The Settings window. Created on first use and reused afterwards; closing it
/// only hides it, so the app keeps running in the menu bar.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let store: ClipStore
    private let launchAtLoginButton = NSButton(
        checkboxWithTitle: "Start Engram at system startup",
        target: nil,
        action: nil
    )
    private let retentionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hotKeyButton = ShortcutRecorderButton()

    /// `0` means no limit.
    private static let retentionChoices: [(title: String, limit: Int)] = [
        ("No limit", 0),
        ("100 clips", 100),
        ("500 clips", 500),
        ("1,000 clips", 1_000),
        ("5,000 clips", 5_000),
        ("10,000 clips", 10_000),
    ]

    init(store: ClipStore) {
        self.store = store
        super.init(window: NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        ))
        window?.title = "Settings"
        window?.isReleasedWhenClosed = false
        window?.center()
        window?.contentView = makeContentView()
        refreshControls()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        refreshControls()

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

        retentionPopup.addItems(withTitles: Self.retentionChoices.map(\.title))
        retentionPopup.target = self
        retentionPopup.action = #selector(changeRetention)

        hotKeyButton.onCapture = { [weak self] combo in
            Settings.hotKey = combo
            self?.refreshControls()
        }

        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [
            launchAtLoginButton,
            separator,
            row(title: "History retention:", control: retentionPopup),
            row(title: "Open history:", control: hotKeyButton),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return container
    }

    private func row(title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    /// Everything is read back from its source of truth: the system for the login item,
    /// `UserDefaults` for the rest. Nothing is cached in the window.
    private func refreshControls() {
        launchAtLoginButton.state = LaunchAtLogin.isOn ? .on : .off
        launchAtLoginButton.toolTip = LaunchAtLogin.needsApproval
            ? "Allow Engram in System Settings → General → Login Items"
            : nil

        let limit = Settings.retentionLimit
        let index = Self.retentionChoices.firstIndex { $0.limit == limit } ?? 0
        retentionPopup.selectItem(at: index)

        hotKeyButton.show(Settings.hotKey)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.set(launchAtLoginButton.state == .on)
        } catch {
            presentError("Could not change the login item", error)
        }
        refreshControls()
    }

    @objc private func changeRetention() {
        let index = max(retentionPopup.indexOfSelectedItem, 0)
        Settings.retentionLimit = Self.retentionChoices[index].limit
        store.enforceRetention()
        refreshControls()
    }

    private func presentError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

/// A button that records the next key combination the user presses.
@MainActor
final class ShortcutRecorderButton: NSButton {
    var onCapture: ((HotKeyCombo) -> Void)?

    private var combo = HotKeyCombo.default
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    func show(_ combo: HotKeyCombo) {
        self.combo = combo
        isRecording = false
        title = combo.displayString
    }

    @objc private func beginRecording() {
        isRecording = true
        title = "Press keys…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }

        if event.keyCode == 53 {  // Escape cancels
            show(combo)
            return
        }

        let label = event.charactersIgnoringModifiers?.uppercased() ?? "?"
        guard let captured = HotKeyCombo(
            keyCode: UInt32(event.keyCode),
            modifierFlags: event.modifierFlags,
            keyLabel: label
        ) else {
            NSSound.beep()  // a modifier is required
            return
        }

        show(captured)
        onCapture?(captured)
    }
}
