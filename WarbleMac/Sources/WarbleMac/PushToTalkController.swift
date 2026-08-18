import Foundation
import WhisperKit

/// Drives push-to-talk capture: starts mic recording on `start()`, polls the
/// audio processor's energy against `UtteranceSegmenter` to auto-finalize on
/// trailing silence or the max-duration cutoff, and transcribes the captured
/// utterance via WhisperKit once finalized.
@MainActor
final class PushToTalkController: ObservableObject {
    @Published private(set) var transcript: String = ""
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var errorMessage: String?

    private nonisolated(unsafe) let whisperKit: WhisperKit
    private let audioProcessor: any AudioProcessing
    private let segmenter: UtteranceSegmenter
    private let silenceThreshold: Float
    private let pollInterval: TimeInterval = 0.1

    private var pollTask: Task<Void, Never>?
    private var startDate: Date?

    init(
        whisperKit: WhisperKit,
        audioProcessor: any AudioProcessing = AudioProcessor(),
        segmenter: UtteranceSegmenter = UtteranceSegmenter(),
        silenceThreshold: Float = 0.3
    ) {
        self.whisperKit = whisperKit
        self.audioProcessor = audioProcessor
        self.segmenter = segmenter
        self.silenceThreshold = silenceThreshold
    }

    func start() throws {
        guard !isRecording else { return }
        errorMessage = nil
        segmenter.reset()
        startDate = Date()
        isRecording = true
        try audioProcessor.startRecordingLive(inputDeviceID: nil, callback: nil)
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    /// Manual release: stop capture immediately and transcribe whatever was said.
    func stopAndFinalize() async {
        guard isRecording else { return }
        await finalize()
    }

    private func pollLoop() async {
        while isRecording {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            guard isRecording, let startDate else { return }

            let elapsed = Date().timeIntervalSince(startDate)
            let nextBufferSeconds = Float(pollInterval)
            let isSpeech = AudioProcessor.isVoiceDetected(
                in: audioProcessor.relativeEnergy,
                nextBufferInSeconds: nextBufferSeconds,
                silenceThreshold: silenceThreshold
            )

            if segmenter.tick(isSpeech: isSpeech, elapsed: elapsed) == .finalize {
                await finalize()
                return
            }
        }
    }

    private func finalize() async {
        pollTask?.cancel()
        pollTask = nil
        isRecording = false
        audioProcessor.stopRecording()

        let samples = Array(audioProcessor.audioSamples)
        guard !samples.isEmpty else { return }

        do {
            let results = try await whisperKit.transcribe(audioArray: samples)
            transcript = results.map(\.text).joined(separator: " ")
        } catch {
            errorMessage = "Transcription failed: \(error)"
        }
    }
}
