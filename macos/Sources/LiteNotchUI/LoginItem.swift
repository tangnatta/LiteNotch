import Foundation
import ServiceManagement

/// Whether LiteNotch starts when the user logs in. macOS owns this: the user
/// can also switch it in System Settings › General › Login Items, so it is
/// read from the system each time and never saved with the core's settings.
public enum LoginItemStatus: Equatable {
    case off
    case on
    /// Registered, but the user has not allowed it (or switched it off in
    /// System Settings); it takes effect once they allow it there.
    case needsApproval
    /// macOS cannot find the app to register (it is not in a place it accepts).
    case unavailable

    /// The row's name. "Launch", not "Open": it starts the app, it does not open the panel.
    public static let title = "Launch at login"

    public var isOn: Bool { self == .on }

    /// The line under the toggle.
    public var caption: String {
        switch self {
        case .off, .on: return "Starts LiteNotch automatically when you log in to your Mac."
        case .needsApproval: return "Allow LiteNotch in System Settings \u{203A} General \u{203A} Login Items."
        case .unavailable: return "macOS cannot register this copy. Move LiteNotch to Applications and try again."
        }
    }
}

/// The system side, behind a protocol so tests never touch the real login items.
public protocol LoginItemService {
    var status: LoginItemStatus { get }
    func set(_ enabled: Bool) throws
    func openSystemSettings()
}

public struct SystemLoginItem: LoginItemService {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notFound: return .unavailable
        case .notRegistered: return .off
        @unknown default: return .off
        }
    }

    public func set(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    }

    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
