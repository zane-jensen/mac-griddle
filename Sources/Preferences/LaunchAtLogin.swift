import ServiceManagement

/// Thin wrapper around `SMAppService` for the "Launch at Login" preference.
/// Deliberately stateless: every read goes straight to `SMAppService`
/// rather than caching a boolean, because the user can add/remove the
/// login item from System Settings > General > Login Items at any time
/// outside the app, and the toggle must not silently drift out of sync
/// with that. See docs/architecture/chunks/project-structure.md §4.
public enum LaunchAtLogin {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when registered but the user still needs to flip it on in
    /// System Settings > General > Login Items — worth deep-linking there
    /// from the UI when this is true.
    public static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
