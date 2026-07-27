import AVFoundation
import Foundation
import Observation

/// Web parity: `dirt_cue_mode_v1` / `dirt_cue_audio_v1`.
/// - all (`bends`): roadbook curves + junctions
/// - junctions: network / decision turns
/// - rally: geometry-derived roadbook curves only
enum NavigationCueMode: String, CaseIterable, Identifiable {
    case all = "bends"
    case junctions
    case rally

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .all: "ALL"
        case .junctions: "JCT"
        case .rally: "RALLY"
        }
    }

    var menuLabel: String {
        switch self {
        case .all: "All"
        case .junctions: "Junction"
        case .rally: "Rally"
        }
    }

    var statusToast: String {
        switch self {
        case .all: "Cues: all curves + junctions"
        case .junctions: "Cues: junctions only"
        case .rally: "Cues: rally curves only"
        }
    }

    static func fromStorage(_ raw: String?) -> NavigationCueMode {
        NavigationCueMode(rawValue: raw ?? "") ?? .all
    }
}

@Observable
final class NavigationCueSettings {
    private let modeKey = "dirt_cue_mode_v1"
    private let audioKey = "dirt_cue_audio_v1"

    var mode: NavigationCueMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
        }
    }

    var audioEnabled: Bool {
        didSet {
            UserDefaults.standard.set(audioEnabled ? "on" : "off", forKey: audioKey)
            if !audioEnabled {
                synthesizer.stopSpeaking(at: .immediate)
                lastSpokenKey = ""
            }
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpokenKey = ""

    init() {
        let defaults = UserDefaults.standard
        mode = NavigationCueMode.fromStorage(defaults.string(forKey: modeKey))
        audioEnabled = defaults.string(forKey: audioKey) != "off"
    }

    func speakCueIfNeeded(_ text: String, distanceMeters: Double?) {
        guard audioEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = "\(trimmed)|\(Int((distanceMeters ?? -1) / 50))"
        guard key != lastSpokenKey else { return }
        lastSpokenKey = key

        Self.activateSpeechSession()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.preUtteranceDelay = 0.05
        utterance.voice = AVSpeechSynthesisVoice(language: "en-CA")
            ?? AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    private static func activateSpeechSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            // Speech still attempted; session may already be owned by another audio client.
        }
    }
}

extension RouteManeuver {
    /// Whether this cue belongs in the active web-style cue filter.
    func matches(cueMode: NavigationCueMode) -> Bool {
        let normalized = (type ?? kind ?? "").lowercased()
        if normalized == "arrive" { return true }

        switch cueMode {
        case .all:
            return true
        case .rally:
            // Roadbook / geometry curves from the router (`type: bend`) or explicit curve kind.
            return normalized == "bend" || normalized == "curve" || kind?.lowercased() == "curve"
        case .junctions:
            if ["turn", "fork", "junction", "merge", "off ramp", "roundabout"].contains(normalized) {
                return true
            }
            if kind?.lowercased() == "junction" { return true }
            // Geometric bends with a sharp decision angle approximate junctions
            // until the backend ships richer junction cues.
            if normalized == "bend", let degrees, degrees >= 70 {
                return true
            }
            return false
        }
    }

    var isRallyCurve: Bool {
        let normalized = (type ?? kind ?? "").lowercased()
        return normalized == "bend" || normalized == "curve" || kind?.lowercased() == "curve"
    }

    var isJunctionCue: Bool {
        let normalized = (type ?? kind ?? "").lowercased()
        if ["turn", "fork", "junction", "merge", "off ramp", "roundabout"].contains(normalized) {
            return true
        }
        return kind?.lowercased() == "junction"
    }

    /// HUD label: Rally → "Right 6"; Junction → "Turn left".
    func displayLabel(cueMode: NavigationCueMode) -> String {
        let side = self.side?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cueMode == .rally || (cueMode == .all && isRallyCurve) {
            if let side, let number {
                return "\(side.capitalized) \(number)"
            }
        }
        if cueMode == .junctions || isJunctionCue {
            if let side, !side.isEmpty {
                return "Turn \(side)"
            }
        }
        if isRallyCurve, let side, let number {
            return "\(side.capitalized) \(number)"
        }
        return instruction ?? type ?? "Continue"
    }

    /// Spoken callout with optional distance preface (HTML speakCue bands).
    func spokenLabel(cueMode: NavigationCueMode, meters: Double?) -> String {
        let core = displayLabel(cueMode: cueMode)
        guard let meters else { return core }
        if meters < 40 {
            return "\(core) now"
        }
        if meters < 250 {
            return "In \(Int(meters.rounded())) metres, \(core)"
        }
        return core
    }

    /// SF Symbol for the cue card — junction ≈ 90°, rally severity varies (6 easy → 1 hairpin).
    func arrowSystemName(cueMode: NavigationCueMode) -> String {
        let left = side?.lowercased() == "left"
        if cueMode == .junctions || isJunctionCue {
            return left ? "arrow.turn.up.left" : "arrow.turn.up.right"
        }
        if cueMode == .rally || isRallyCurve {
            let n = number ?? 4
            switch n {
            case 1:
                return left ? "arrow.uturn.left" : "arrow.uturn.right"
            case 2:
                return left ? "arrow.turn.up.left" : "arrow.turn.up.right"
            case 3, 4:
                return left ? "arrow.up.left" : "arrow.up.right"
            default:
                return left ? "arrow.up.backward" : "arrow.up.forward"
            }
        }
        return left ? "arrow.turn.up.left" : "arrow.turn.up.right"
    }
}
