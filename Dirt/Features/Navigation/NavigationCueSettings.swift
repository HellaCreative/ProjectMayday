import AVFoundation
import Foundation
import Observation
import os

private let cueSpeechLog = Logger(subsystem: "app.mayday.dirt", category: "CueSpeech")

/// Picks the most natural on-device English voice for navigation cues.
/// Prefers premium/enhanced (Settings → Accessibility → Spoken Content → Voices)
/// when the rider has downloaded them; falls back to compact Samantha / language default.
enum CueSpeechVoice {
    /// Preferred natural voices (female first — clearer for short rally/junction callouts).
    private static let preferredNames = [
        "Zoe", "Samantha", "Nicky", "Ava", "Allison", "Susan", "Nora", "Martha",
        "Aaron", "Evan", "Nathan", "Tom", "Daniel", "Gordon",
    ]

    private static let preferredLanguages = ["en-CA", "en-US", "en-AU", "en-GB", "en-IE"]

    /// Novelty / Eloquence effect voices — unusable for riding cues.
    private static let excludedNameFragments = [
        "Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos",
        "Eddy", "Flo", "Fred", "Good News", "Grandma", "Grandpa", "Jester",
        "Junior", "Kathy", "Organ", "Ralph", "Reed", "Rocko", "Sandy", "Shelley",
        "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox", "Princess",
        "Hysterical", "Deranged",
    ]

    private static var cached: AVSpeechSynthesisVoice?
    private static var didLogSelection = false

    static func preferred() -> AVSpeechSynthesisVoice? {
        if let cached { return cached }
        let voice = selectBest()
        cached = voice
        logSelectionOnce(voice)
        return voice
    }

    /// Force re-resolve (e.g. after the user downloads an Enhanced voice).
    static func refresh() {
        cached = nil
        didLogSelection = false
        _ = preferred()
    }

    private static func selectBest() -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { isUsableCueVoice($0) }
        if let best = candidates.max(by: { score($0) < score($1) }) {
            return best
        }
        // Last resort: system language default (may be compact/super-compact).
        return AVSpeechSynthesisVoice(language: "en-CA")
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private static func isUsableCueVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        guard voice.language.hasPrefix("en") else { return false }
        let name = voice.name
        if excludedNameFragments.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
            return false
        }
        // Eloquence bundle identifiers are novelty-style even when names look plain.
        if voice.identifier.contains("eloquence") { return false }
        return true
    }

    private static func score(_ voice: AVSpeechSynthesisVoice) -> Int {
        var value = 0
        switch voice.quality {
        case .premium: value += 300
        case .enhanced: value += 200
        case .default: value += 0
        @unknown default: value += 0
        }

        if let langIndex = preferredLanguages.firstIndex(of: voice.language) {
            value += 50 - langIndex
        } else if voice.language.hasPrefix("en") {
            value += 10
        }

        let baseName = voice.name
            .replacingOccurrences(of: " (Enhanced)", with: "")
            .replacingOccurrences(of: " (Premium)", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let nameIndex = preferredNames.firstIndex(where: {
            baseName.localizedCaseInsensitiveCompare($0) == .orderedSame
        }) {
            value += 40 - nameIndex
        }

        if voice.gender == .female { value += 5 }
        // Prefer full compact over super-compact when quality ties.
        if voice.identifier.contains("super-compact") { value -= 15 }
        return value
    }

    private static func logSelectionOnce(_ voice: AVSpeechSynthesisVoice?) {
        guard !didLogSelection else { return }
        didLogSelection = true
        guard let voice else {
            cueSpeechLog.warning("No AVSpeech voice available for cues")
            return
        }
        let qualityLabel: String
        switch voice.quality {
        case .premium: qualityLabel = "premium"
        case .enhanced: qualityLabel = "enhanced"
        case .default: qualityLabel = "default/compact"
        @unknown default: qualityLabel = "unknown"
        }
        if voice.quality == .default {
            cueSpeechLog.info(
                "Cue voice: \(voice.name, privacy: .public) (\(voice.language, privacy: .public), \(qualityLabel, privacy: .public)). Download Enhanced/Premium in Settings → Accessibility → Spoken Content → Voices for a more natural sound."
            )
        } else {
            cueSpeechLog.info(
                "Cue voice: \(voice.name, privacy: .public) (\(voice.language, privacy: .public), \(qualityLabel, privacy: .public))"
            )
        }
    }
}

/// Pref keys: `dirt_cue_mode_v1` / `dirt_cue_audio_v1`.
/// - junctions: network / decision turns
/// - rally: geometry-derived roadbook curves only
nonisolated enum NavigationCueMode: String, CaseIterable, Identifiable, Sendable {
    case junctions
    case rally

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .junctions: "JCT"
        case .rally: "RALLY"
        }
    }

    var menuLabel: String {
        switch self {
        case .junctions: "Junction"
        case .rally: "Rally"
        }
    }

    var statusToast: String {
        switch self {
        case .junctions: "Cues: junctions only"
        case .rally: "Cues: rally curves only"
        }
    }

    static func fromStorage(_ raw: String?) -> NavigationCueMode {
        switch raw {
        case NavigationCueMode.rally.rawValue:
            return .rally
        case NavigationCueMode.junctions.rawValue, "bends", nil, "":
            // `bends` was the removed All mode. Migrate it to the safer,
            // quieter Junction mode instead of silently preserving curve spam.
            return .junctions
        default:
            return .junctions
        }
    }
}

/// Distance bands for spoken cadence (now / near / mid ≈ 40 / 180 / 450 m).
enum NavigationCueBand: Int, Sendable {
    case now = 0
    case near = 1
    case mid = 2
    case far = 3
    case none = -1

    static func band(forMeters meters: Double?) -> NavigationCueBand {
        guard let meters else { return .none }
        if meters < 40 { return .now }
        if meters < 180 { return .near }
        if meters < 450 { return .mid }
        return .far
    }

    /// Bands that should trigger a spoken callout.
    var shouldSpeak: Bool {
        switch self {
        case .now, .near, .mid: return true
        case .far, .none: return false
        }
    }
}

/// Spoken delivery moves forward only: prepare → now → passed.
nonisolated enum NavigationCuePhase: String, Hashable, Sendable {
    case prepare
    case now

    static func phase(forMeters meters: Double, speedMPS: Double) -> NavigationCuePhase? {
        // A stopped/slow GPS sample must use the minimum lead, not invent a
        // highway pace and call a turn 240 m early.
        let planningSpeed = speedMPS > 2 ? speedMPS : 8
        let prepareLead = min(600, max(160, planningSpeed * 20))
        let nowLead = min(80, max(25, planningSpeed * 3))
        if meters <= nowLead { return .now }
        if meters <= prepareLead { return .prepare }
        return nil
    }
}

@MainActor
@Observable
final class NavigationCueSettings: NSObject, AVSpeechSynthesizerDelegate {
    private let modeKey = "dirt_cue_mode_v1"
    private let audioKey = "dirt_cue_audio_v1"

    /// Mix voiceovers under Music — slightly quieter than full volume, never duck.
    static let voiceoverVolume: Float = 0.72

    var mode: NavigationCueMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
        }
    }

    var audioEnabled: Bool {
        didSet {
            UserDefaults.standard.set(audioEnabled ? "on" : "off", forKey: audioKey)
            if !audioEnabled {
                speechQueue = []
                synthesizer.stopSpeaking(at: .immediate)
                lastSpokenKey = ""
                deactivateSpeechSessionSoon()
            } else {
                // Pick up Enhanced/Premium voices the rider may have just downloaded.
                CueSpeechVoice.refresh()
            }
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpokenKey = ""
    private var speechSessionActive = false
    private var deactivateWorkItem: DispatchWorkItem?
    private struct PendingSpeech {
        let text: String
        let announceKey: String
        let maneuverKey: String
        let isNow: Bool
    }
    private var speechQueue: [PendingSpeech] = []

    override init() {
        let defaults = UserDefaults.standard
        mode = NavigationCueMode.fromStorage(defaults.string(forKey: modeKey))
        audioEnabled = defaults.string(forKey: audioKey) != "off"
        super.init()
        synthesizer.delegate = self
    }

    /// Speak a cue once per stable `announceKey` (maneuver identity + band).
    /// Music stays up; the prompt mixes on top a notch quieter.
    func speakCueIfNeeded(_ text: String, announceKey: String) {
        guard audioEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty / punctuation-only cues produce AVAudioBuffer mDataByteSize(0).
        guard trimmed.count >= 2 else { return }
        guard announceKey != lastSpokenKey else { return }

        let parts = announceKey.split(separator: "|", maxSplits: 1).map(String.init)
        let maneuverKey = parts.first ?? announceKey
        let isNow = parts.last == NavigationCuePhase.now.rawValue
        guard !speechQueue.contains(where: { $0.announceKey == announceKey }) else { return }
        if isNow {
            speechQueue.removeAll { $0.maneuverKey == maneuverKey && !$0.isNow }
        }
        speechQueue.append(
            PendingSpeech(
                text: trimmed,
                announceKey: announceKey,
                maneuverKey: maneuverKey,
                isNow: isNow
            )
        )
        speakNextQueuedIfPossible()
    }

    private func speakNextQueuedIfPossible() {
        guard audioEnabled, !synthesizer.isSpeaking, !speechQueue.isEmpty else { return }
        guard activateSpeechSession() else { return }
        let next = speechQueue.removeFirst()
        lastSpokenKey = next.announceKey
        let utterance = AVSpeechUtterance(string: next.text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.90
        utterance.pitchMultiplier = 0.97
        utterance.preUtteranceDelay = 0.02
        utterance.volume = Self.voiceoverVolume
        utterance.voice = CueSpeechVoice.preferred()
        synthesizer.speak(utterance)
    }

    /// Stop cues when navigation ends. Music was never ducked.
    func stopSpeaking() {
        speechQueue = []
        synthesizer.stopSpeaking(at: .immediate)
        lastSpokenKey = ""
        deactivateSpeechSessionSoon()
    }

    /// Mix with other audio (Music stays up). No ducking — cues are a quieter voiceover.
    @discardableResult
    private func activateSpeechSession() -> Bool {
        deactivateWorkItem?.cancel()
        deactivateWorkItem = nil
        let session = AVAudioSession.sharedInstance()
        do {
            // Mix under Music — never duck. voicePrompt can empty-buffer on some OS builds.
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.mixWithOthers]
            )
            try session.setActive(true, options: [])
            speechSessionActive = true
            return true
        } catch {
            speechSessionActive = false
            return false
        }
    }

    private func deactivateSpeechSessionSoon() {
        deactivateWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.deactivateSpeechSessionNow()
            }
        }
        deactivateWorkItem = work
        // Short debounce so rapid successive cues keep one mixed session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func deactivateSpeechSessionNow() {
        guard speechSessionActive else { return }
        if !speechQueue.isEmpty { return }
        if synthesizer.isSpeaking { return }
        speechSessionActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Other apps may keep the session; ignore.
        }
    }

    // MARK: AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speakNextQueuedIfPossible()
            if self.speechQueue.isEmpty {
                self.deactivateSpeechSessionSoon()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speakNextQueuedIfPossible()
            if self.speechQueue.isEmpty {
                self.deactivateSpeechSessionSoon()
            }
        }
    }
}

extension RouteManeuver {
    /// Stable identity for announce dedupe (UUID `id` changes per decode).
    var announceIdentity: String {
        if let stableID, !stableID.isEmpty { return stableID }
        let along = Int((alongMeters ?? 0).rounded())
        let kindKey = (kind ?? type ?? "cue").lowercased()
        let sideKey = (side ?? "").lowercased()
        let numberKey = number.map(String.init) ?? ""
        return "\(along)-\(kindKey)-\(sideKey)-\(numberKey)"
    }

    /// Whether this cue belongs in the active cue filter.
    func matches(cueMode: NavigationCueMode) -> Bool {
        let normalized = (type ?? kind ?? "").lowercased()
        if normalized == "arrive" { return true }

        switch cueMode {
        case .rally:
            // Roadbook / geometry curves from the router (`type: bend`) or explicit curve kind.
            return isRallyCurve
        case .junctions:
            return isJunctionCue
                || (normalized == "bend" && (degrees ?? 0) >= 70)
        }
    }

    nonisolated var isRallyCurve: Bool {
        if isJunctionCue { return false }
        let normalized = (type ?? kind ?? "").lowercased()
        return normalized == "bend" || normalized == "curve" || kind?.lowercased() == "curve"
    }

    nonisolated var isJunctionCue: Bool {
        let normalized = (type ?? kind ?? "").lowercased()
        if ["turn", "continuestraight", "fork", "junction", "merge", "off ramp", "roundabout"].contains(normalized) {
            return true
        }
        return kind?.lowercased() == "junction"
    }

    /// HUD label: Rally → "Right 6"; Junction → "Turn left".
    func displayLabel(cueMode: NavigationCueMode) -> String {
        let side = self.side?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cueMode == .rally {
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

    /// Spoken callout. Junctions get distance bands ("In 200 metres, Turn left").
    /// Rally roadbook cues stay short ("right 6") — no distance preface.
    func spokenLabel(
        cueMode: NavigationCueMode,
        meters: Double?,
        phase: NavigationCuePhase? = nil
    ) -> String {
        let core = displayLabel(cueMode: cueMode)
        // Rally curves: number + side only.
        if cueMode == .rally {
            if let side = side?.lowercased(), let number {
                let spokenSide = side
                let base = number == 1
                    ? "\(spokenSide) 1 hairpin"
                    : "\(spokenSide) \(number)"
                if phase == .now { return "\(base) now" }
                if let meters {
                    let rounded = max(10, Int((meters / 10.0).rounded() * 10))
                    return "In \(rounded) metres, \(base)"
                }
                return base
            }
            return core.lowercased()
        }
        guard let meters else { return core }
        switch phase {
        case .now:
            return "\(core) now"
        case .prepare:
            let rounded = max(10, Int((meters / 10.0).rounded() * 10))
            return "In \(rounded) metres, \(core)"
        case nil:
            return core
        }
    }

    /// SF Symbol for the cue card — junction ≈ 90°, rally severity varies (6 easy → 1 hairpin).
    func arrowSystemName(cueMode: NavigationCueMode) -> String {
        let left = side?.lowercased() == "left"
        if cueMode == .junctions || isJunctionCue {
            if (type ?? kind ?? "").lowercased() == "continuestraight" {
                return "arrow.up"
            }
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

    /// Promote sharp geometric bends into junction decisions so Junction / All
    /// modes can speak "Turn left" (rally junction idea, without
    /// requiring live graph degree). Mild bends stay rally curves.
    static func enrichForVoiceCues(_ input: [RouteManeuver]) -> [RouteManeuver] {
        let junctionThreshold = 70.0
        var output: [RouteManeuver] = []
        output.reserveCapacity(input.count)

        for man in input {
            let normalized = (type: (man.type ?? "").lowercased(), kind: (man.kind ?? "").lowercased())
            if normalized.type == "arrive" || normalized.kind == "arrive" {
                output.append(man)
                continue
            }
            if man.isJunctionCue {
                let straight = normalized.type == "continuestraight"
                output.append(
                    RouteManeuver(
                        instruction: man.side.map { "Turn \($0)" } ?? man.instruction,
                        type: straight ? "continueStraight" : "turn",
                        stableID: man.stableID,
                        stageID: man.stageID,
                        kind: "junction",
                        side: man.side,
                        number: nil,
                        degrees: man.degrees,
                        distanceMeters: man.distanceMeters,
                        alongMeters: man.alongMeters
                    )
                )
                continue
            }
            if normalized.type == "bend" || normalized.kind == "curve" || normalized.type == "curve" {
                let deg = man.degrees ?? 0
                if deg >= junctionThreshold, let side = man.side, !side.isEmpty {
                    output.append(
                        RouteManeuver(
                            instruction: "Turn \(side)",
                            type: "turn",
                            stableID: man.stableID,
                            stageID: man.stageID,
                            kind: "junction",
                            side: side,
                            number: nil,
                            degrees: deg,
                            distanceMeters: man.distanceMeters,
                            alongMeters: man.alongMeters
                        )
                    )
                } else {
                    output.append(
                        RouteManeuver(
                            instruction: man.instruction,
                            type: "bend",
                            stableID: man.stableID,
                            stageID: man.stageID,
                            kind: "curve",
                            side: man.side,
                            number: man.number,
                            degrees: man.degrees,
                            distanceMeters: man.distanceMeters,
                            alongMeters: man.alongMeters
                        )
                    )
                }
                continue
            }
            output.append(man)
        }

        // Collapse near-duplicates: junction wins over overlapping curve.
        let mergeMeters = 55.0
        var merged: [RouteManeuver] = []
        for item in output.sorted(by: { ($0.alongMeters ?? 0) < ($1.alongMeters ?? 0) }) {
            guard let prev = merged.last,
                  let a = prev.alongMeters,
                  let b = item.alongMeters,
                  abs(a - b) < mergeMeters
            else {
                merged.append(item)
                continue
            }
            if item.isJunctionCue && !prev.isJunctionCue {
                merged[merged.count - 1] = item
            } else if !item.isJunctionCue && prev.isJunctionCue {
                // Keep junction.
            } else if item.isJunctionCue && prev.isJunctionCue {
                if (item.degrees ?? 0) > (prev.degrees ?? 0) {
                    merged[merged.count - 1] = item
                }
            } else if (item.number ?? 99) < (prev.number ?? 99) {
                merged[merged.count - 1] = item
            }
        }
        return merged
    }
}
