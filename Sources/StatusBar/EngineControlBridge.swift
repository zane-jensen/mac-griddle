import Combine

/// `StatusBar` deliberately does not depend on `Input` (see
/// `docs/architecture/chunks/statusbar-menu.md` §3) — the live "is the
/// gesture engine enabled" boolean, and the ability to change it, both have
/// to cross that gap via something the composition root builds from
/// whatever `Input` actually exposes. This struct is that bridge, scoped to
/// `StatusBar`'s own public API rather than `MacGriddleCore` — it only
/// exists to satisfy this module's `init`, it isn't a general-purpose
/// contract other modules need.
public struct EngineControlBridge {
    public let isEnabled: () -> Bool
    public let isEnabledPublisher: AnyPublisher<Bool, Never>
    public let setEnabled: (Bool) -> Void

    public init(
        isEnabled: @escaping () -> Bool,
        isEnabledPublisher: AnyPublisher<Bool, Never>,
        setEnabled: @escaping (Bool) -> Void
    ) {
        self.isEnabled = isEnabled
        self.isEnabledPublisher = isEnabledPublisher
        self.setEnabled = setEnabled
    }
}
