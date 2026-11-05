import AppKit
import Carbon.HIToolbox

/// User-editable preferences. Launch-at-login is deliberately absent: the system owns
/// that state, so it lives in `LaunchAtLogin` and is never mirrored here.
@MainActor
enum Settings {
    private static let defaults = UserDefaults.standard
    private static let retentionKey = "retentionLimit"
    private static let hotKeyCodeKey = "hotKeyCode"
    private static let hotKeyModifiersKey = "hotKeyModifiers"
    private static let hotKeyLabelKey = "hotKeyLabel"

    /// How many clips to keep. `0` means no limit, which is the default.
    static var retentionLimit: Int {
        get { defaults.object(forKey: retentionKey) as? Int ?? 0 }
        set { defaults.set(newValue, forKey: retentionKey) }
    }

    /// The shortcut that opens the clipboard history.
    static var hotKey: HotKeyCombo {
        get {
            guard let code = defaults.object(forKey: hotKeyCodeKey) as? Int,
                  let modifiers = defaults.object(forKey: hotKeyModifiersKey) as? Int
            else { return .default }

            return HotKeyCombo(
                keyCode: UInt32(code),
                modifiers: UInt32(modifiers),
                keyLabel: defaults.string(forKey: hotKeyLabelKey) ?? "?"
            )
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: hotKeyCodeKey)
            defaults.set(Int(newValue.modifiers), forKey: hotKeyModifiersKey)
            defaults.set(newValue.keyLabel, forKey: hotKeyLabelKey)
            NotificationCenter.default.post(name: .hotKeyDidChange, object: nil)
        }
    }
}

struct HotKeyCombo: Equatable {
    /// Virtual key code (Carbon `kVK_*`).
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var modifiers: UInt32
    /// The key as the user pressed it, e.g. "V". Only used for display.
    var keyLabel: String

    static let `default` = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | optionKey),
        keyLabel: "V"
    )

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// Builds a combo from a recorded key press. Returns `nil` when no modifier is held:
    /// a bare key would swallow ordinary typing system-wide.
    init?(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags, keyLabel: String) {
        var modifiers: UInt32 = 0
        if modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard modifiers != 0 else { return nil }

        self.init(keyCode: keyCode, modifiers: modifiers, keyLabel: keyLabel)
    }

    /// e.g. "⌥⌘V". Modifier order follows Apple's convention: ⌃⌥⇧⌘.
    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel.uppercased()
    }
}

extension Notification.Name {
    static let hotKeyDidChange = Notification.Name("hotKeyDidChange")
}
