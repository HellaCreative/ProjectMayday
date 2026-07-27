import Foundation
import Observation

/// How a trial prompt should be presented.
enum TrialPresentation: Equatable {
    /// Dismissible nudge (X in the corner).
    case soft
    /// Blocking gate — the only way forward is to start the trial.
    case hard
}

/// Drives the delayed-trial paywall.
///
/// Escalation (measured in cumulative *map foreground* seconds, persisted
/// on-device):
/// 1. **90s** → soft prompt (dismissible)
/// 2. **next launch, or +5 min after the 1st** → soft prompt (dismissible)
/// 3. **3rd exposure (≈+5 min after the 2nd) or 15 min cumulative — whichever
///    first** → hard gate (no X)
///
/// A live subscription clears everything and stops all prompting.
@Observable
@MainActor
final class TrialGateModel {
    private enum Key {
        static let seconds = "dirt_trial_map_seconds_v1"
        static let exposures = "dirt_trial_exposures_v1"
        static let lastExposure = "dirt_trial_last_exposure_seconds_v1"
    }

    // Thresholds (seconds of cumulative map use).
    private let firstPromptAt: Double = 90
    private let followUpGap: Double = 300      // +5 min between prompts
    private let hardCumulative: Double = 900   // 15 min absolute ceiling

    private let defaults = UserDefaults.standard

    private(set) var mapSeconds: Double
    private(set) var exposures: Int
    private var lastExposureSeconds: Double

    /// A fresh launch qualifies the user for the 2nd nudge once they've already
    /// seen the first one.
    private var launchPromptPending: Bool

    var isSubscribed = false {
        didSet {
            if isSubscribed { presentation = nil }
        }
    }

    /// Non-nil when the paywall should be on screen.
    private(set) var presentation: TrialPresentation?

    init() {
        let storedExposures = defaults.integer(forKey: Key.exposures)
        mapSeconds = defaults.double(forKey: Key.seconds)
        exposures = storedExposures
        lastExposureSeconds = defaults.double(forKey: Key.lastExposure)
        launchPromptPending = storedExposures == 1
    }

    /// Called once per second while the map is foreground and visible.
    /// `canPresent` is false during active navigation so the gate never
    /// interrupts a live ride (time still accrues; the prompt waits for idle).
    func tick(canPresent: Bool = true) {
        guard !isSubscribed, presentation == nil else { return }
        mapSeconds += 1
        defaults.set(mapSeconds, forKey: Key.seconds)
        if canPresent { evaluate() }
    }

    /// Re-check without advancing the clock (e.g. right after the map appears,
    /// to fire a pending next-launch nudge).
    func evaluate() {
        guard !isSubscribed, presentation == nil else { return }
        let secs = mapSeconds

        if secs >= hardCumulative {
            present(.hard)
            return
        }

        switch exposures {
        case 0:
            if secs >= firstPromptAt { present(.soft) }
        case 1:
            if launchPromptPending || secs >= lastExposureSeconds + followUpGap {
                present(.soft)
            }
        default:
            if secs >= lastExposureSeconds + followUpGap { present(.hard) }
        }
    }

    /// Dismiss a soft prompt (hard gates ignore this).
    func dismissSoft() {
        guard presentation == .soft else { return }
        presentation = nil
    }

    /// Trial started / subscription active — stand down permanently.
    func markSubscribed() {
        isSubscribed = true
        presentation = nil
    }

    private func present(_ kind: TrialPresentation) {
        presentation = kind
        exposures += 1
        lastExposureSeconds = mapSeconds
        launchPromptPending = false
        defaults.set(exposures, forKey: Key.exposures)
        defaults.set(lastExposureSeconds, forKey: Key.lastExposure)
    }

    /// Wipes the usage clock so the escalation can be re-tested from scratch.
    func resetForTesting() {
        mapSeconds = 0
        exposures = 0
        lastExposureSeconds = 0
        launchPromptPending = false
        presentation = nil
        defaults.removeObject(forKey: Key.seconds)
        defaults.removeObject(forKey: Key.exposures)
        defaults.removeObject(forKey: Key.lastExposure)
    }
}
