// DietMotion.swift — om-a1-motion: single Reduce Motion gate.
//
// Every animated surface reads `@Environment(\.accessibilityReduceMotion)`
// and funnels through these pure helpers, so Reduce Motion users get
// instant state changes (no crossfade, no animated scroll) while the
// default path keeps the system-default animation. HIG: native behavior,
// no custom drivers.
import SwiftUI

/// Pure Reduce Motion gate. No view state — tests pin the contract.
public enum DietMotion {
    /// The animation to apply, or nil (instant, no animation) when
    /// Reduce Motion is on. Callers pass the result straight to
    /// `.animation(_:value:)` — nil disables the transition animation.
    public static func gated(
        _ base: Animation = .default, reduceMotion: Bool
    ) -> Animation? {
        reduceMotion ? nil : base
    }

    /// Whether a scroll (or any imperative change) may animate.
    /// Reduce Motion forces every scroll to land instantly, even when
    /// the caller requested animation.
    public static func scrollAnimated(
        requested: Bool, reduceMotion: Bool
    ) -> Bool {
        requested && !reduceMotion
    }
}
