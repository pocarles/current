import Foundation
import ServiceManagement

enum LoginItemStatus: Equatable {
    case enabled
    case disabled
    /// Registered, but the person still has to allow it in System Settings > General > Login Items.
    case needsApproval
    /// Not running from an app bundle macOS can register, for example `swift run` or tests.
    case unavailable
}

/// Open at login, through the system login-item service. Never changed without a person's choice.
@MainActor protocol LoginItemControl: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

@MainActor final class SystemLoginItem: LoginItemControl {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .needsApproval
        case .notRegistered: .disabled
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }
    func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
