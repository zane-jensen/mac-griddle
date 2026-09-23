import Combine

extension PermissionsProviding {
    /// `objectWillChange` itself doesn't compile when accessed directly
    /// through a `PermissionsProviding` existential (Swift can't resolve
    /// the associated `ObjectWillChangePublisher` type without a concrete
    /// or generic binding on `Self`) — but a protocol-extension member
    /// dispatches through the existential's witness table with `Self`
    /// already bound internally, so this computed property works from an
    /// existential-typed call site (`permissions.changePublisher`) even
    /// though `permissions.objectWillChange` directly does not.
    ///
    /// Discovered while integrating the composition root, specifically
    /// reading an implicitly-unwrapped-optional stored property
    /// (`AppDelegate`'s `permissions: PermissionsProviding!`) — a local free
    /// generic function (`func f<P: PermissionsProviding>(_ p: P)`) failed
    /// to resolve existential opening in that exact shape. `Input` and
    /// `StatusBar` independently solved the same underlying problem with
    /// their own private generic-method workarounds, called on a plain
    /// (non-IUO) `let`/parameter rather than an IUO read — both of those
    /// compile and work correctly, so the failure mode is narrower than "free
    /// generic functions never work here," and is specific to the IUO case.
    /// This extension property is the one fix proven to work in every case;
    /// prefer it for any new call site rather than reintroducing another
    /// local variant.
    public var changePublisher: AnyPublisher<Void, Never> {
        objectWillChange
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
