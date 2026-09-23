import AppKit

/// Deep links into the two System Settings privacy panes MacGriddle needs,
/// for the onboarding fallback path when the one-shot system prompt has
/// already been consumed by a prior run.
///
/// Both privacy panes are addressable via the `x-apple.systempreferences:`
/// URL scheme. The Accessibility fragment is confirmed directly in
/// `docs/RESEARCH.md` (B.1.1); the Input Monitoring fragment
/// (`Privacy_ListenEvent`) was verified against Apple's current System
/// Settings URL scheme for macOS 13 (Ventura) specifically, since the two
/// panes use different anchor names and getting this wrong silently opens
/// the generic Privacy & Security pane instead of jumping straight to the
/// right section.
///
/// See docs/architecture/chunks/permissions-model.md §4.
public enum SystemSettingsDeepLink {
    case accessibility
    case inputMonitoring

    public var url: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        }
    }

    public func open() {
        NSWorkspace.shared.open(url)
    }
}
