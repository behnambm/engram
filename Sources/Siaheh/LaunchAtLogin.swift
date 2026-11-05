import Foundation
import ServiceManagement

/// Login-item state. The system owns this, not UserDefaults: the user can turn the
/// item off in System Settings at any time, so we always read it back from there.
enum LaunchAtLogin {
    private static var service: SMAppService { .mainApp }

    /// Registered at all — includes the case where the user still has to approve it.
    static var isOn: Bool {
        switch service.status {
        case .enabled, .requiresApproval: true
        default: false
        }
    }

    /// macOS registered the item but wants the user to confirm it in System Settings.
    static var needsApproval: Bool {
        service.status == .requiresApproval
    }

    static func set(_ on: Bool) throws {
        if on {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}
