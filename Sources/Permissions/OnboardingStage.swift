/// The onboarding/permissions-recovery screen to show, derived from
/// `PermissionsMonitor`'s two booleans plus (for `welcome` vs. `degraded`)
/// one piece of state that lives outside this target — see
/// docs/architecture/chunks/permissions-model.md §4.
///
/// This type only names the states and what triggers each one; deriving a
/// live `OnboardingStage` value from `PermissionsProviding` and rendering
/// the corresponding screen is composition-root territory (the `MacGriddle`
/// executable target), not this target's job.
public enum OnboardingStage: Equatable {
    /// First launch, neither permission checked yet, or user hasn't
    /// dismissed the intro.
    case welcome

    /// `isAccessibilityGranted == false`. Auto-advances the instant it
    /// flips `true`.
    case requestingAccessibility

    /// `isAccessibilityGranted == true`, `isInputMonitoringGranted == false`.
    /// Auto-advances the instant `isInputMonitoringGranted` flips `true`.
    case requestingInputMonitoring

    /// Both booleans `true`. Hands off to the app's normal running state.
    case readyToUse

    /// Either boolean flipped `false` **after** onboarding already reached
    /// `readyToUse` once — a distinct "lost access" state, not a crash and
    /// not silence.
    case degraded(missing: MissingPermission)
}

/// Which permission(s) are missing in a `degraded` `OnboardingStage`.
public enum MissingPermission: Equatable {
    case accessibility
    case inputMonitoring
    case both
}
