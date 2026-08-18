import Foundation

/// Decides when a spoken utterance is finished, based on trailing silence after
/// speech or a hard maximum duration. Mirrors server/streaming.py's cut rule
/// (~0.7s trailing silence, 15s max) but is decoupled from audio I/O so it can
/// be driven by synthetic ticks in tests.
final class UtteranceSegmenter {
    enum Decision: Equatable {
        case continueRecording
        case finalize
    }

    private let trailingSilence: TimeInterval
    private let maxDuration: TimeInterval
    private var lastSpeechElapsed: TimeInterval?

    init(trailingSilence: TimeInterval = 0.7, maxDuration: TimeInterval = 15.0) {
        self.trailingSilence = trailingSilence
        self.maxDuration = maxDuration
    }

    func tick(isSpeech: Bool, elapsed: TimeInterval) -> Decision {
        if isSpeech {
            lastSpeechElapsed = elapsed
        }

        if elapsed >= maxDuration {
            return .finalize
        }

        if let lastSpeechElapsed, elapsed - lastSpeechElapsed >= trailingSilence {
            return .finalize
        }

        return .continueRecording
    }

    func reset() {
        lastSpeechElapsed = nil
    }
}
