import AppKit
import Carbon.HIToolbox

/// System-wide shortcut. Carbon's `RegisterEventHotKey` is the only API that works
/// without the Accessibility permission, so it stays sandbox- and App Store-safe.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private static let signature: OSType = 0x454E_4752  // 'ENGR'
    private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var action: (@MainActor () -> Void)?

    private init() {}

    /// Registers `combo`. Returns `false` when the shortcut is already taken by
    /// something else — registration is exclusive and macOS does not tell us who owns it.
    @discardableResult
    func register(_ combo: HotKeyCombo, action: @escaping @MainActor () -> Void) -> Bool {
        unregister()

        // A bare key as a global shortcut would swallow ordinary typing everywhere.
        guard combo.modifiers != 0 else { return false }

        self.action = action
        installEventHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, ref != nil else {
            self.action = nil
            return false
        }

        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        action = nil
    }

    fileprivate func fire() {
        action?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }
}

/// Carbon calls this on the main thread; hop through `assumeIsolated` to reach the
/// main-actor state without tripping Swift 6 concurrency checking.
private let hotKeyEventHandler: EventHandlerUPP = { _, event, _ in
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == 0x454E_4752 else { return status }

    DispatchQueue.main.async {
        MainActor.assumeIsolated { GlobalHotKey.shared.fire() }
    }
    return noErr
}
