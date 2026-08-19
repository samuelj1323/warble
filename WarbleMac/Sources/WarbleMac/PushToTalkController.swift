import AppKit
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
    @Published private(set) var isTranscribing: Bool = false
    @Published private(set) var errorMessage: String?

    var status: DictationStatus {
        if isRecording { return .recording }
        if isTranscribing { return .transcribing }
        return .idle
    }

    private nonisolated(unsafe) let whisperKit: WhisperKit
    private let audioProcessor: any AudioProcessing
    private let segmenter: UtteranceSegmenter
    private let silenceThreshold: Float
    private let pollInterval: TimeInterval = 0.1
    private let feedbackStore: FeedbackStore?
    private let pasteService: PasteService?
    private let agentRouter: AgentRouter?
    private let isAgentModeEnabled: () -> Bool
    private let pasteTargetApp: () -> NSRunningApplication?
    private let onDictationFinalized: ((String, String?) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var startDate: Date?
    /// Audio for the whole recording session, accumulated across silence-triggered
    /// chunks so feedback logging still captures the full utterance even though
    /// each chunk's samples are purged from the live audio processor as it's
    /// transcribed.
    private var sessionSamples: [Float] = []

    init(
        whisperKit: WhisperKit,
        audioProcessor: any AudioProcessing = AudioProcessor(),
        segmenter: UtteranceSegmenter = UtteranceSegmenter(),
        silenceThreshold: Float = 0.3,
        feedbackStore: FeedbackStore? = nil,
        pasteService: PasteService? = nil,
        agentRouter: AgentRouter? = nil,
        isAgentModeEnabled: @escaping () -> Bool = { false },
        pasteTargetApp: @escaping () -> NSRunningApplication? = { nil },
        onDictationFinalized: ((String, String?) -> Void)? = nil
    ) {
        self.whisperKit = whisperKit
        self.audioProcessor = audioProcessor
        self.segmenter = segmenter
        self.silenceThreshold = silenceThreshold
        self.feedbackStore = feedbackStore
        self.pasteService = pasteService
        self.agentRouter = agentRouter
        self.isAgentModeEnabled = isAgentModeEnabled
        self.pasteTargetApp = pasteTargetApp
        self.onDictationFinalized = onDictationFinalized
    }

    /// Submits typed text (from the chat composer) the same way a finalized
    /// spoken utterance is handled: routed through the agent if agent mode is
    /// on, otherwise pasted into the configured target app (or whatever has
    /// focus) and recorded to session history.
    func submitTypedText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isAgentModeEnabled(), let agentRouter {
            _ = await agentRouter.handle(transcript: trimmed)
        } else {
            let appName = await pasteService?.paste(text: trimmed, targetApp: pasteTargetApp())
            onDictationFinalized?(trimmed, appName)
        }
    }

    func start() throws {
        guard !isRecording else { return }
        errorMessage = nil
        transcript = ""
        sessionSamples = []
        segmenter.reset()
        startDate = Date()
        isRecording = true
        try audioProcessor.startRecordingLive(inputDeviceID: nil, callback: nil)
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    /// Manual release: stop capture immediately, transcribe whatever's left, and finalize.
    func stopAndFinalize() async {
        guard isRecording else { return }
        await finalize(isFinal: true)
    }

    /// Hotkey-driven start/stop: starts if idle, finalizes if recording.
    func toggle() async {
        if isRecording {
            await finalize(isFinal: true)
        } else if !isTranscribing {
            try? start()
        }
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

            // Trailing silence transcribes the chunk spoken so far and appends it
            // to `transcript`, but keeps recording — like a streamed transcript —
            // so a pause mid-thought doesn't drop whatever's said next. Only an
            // explicit stop (toggle/stopAndFinalize) ends the session.
            if segmenter.tick(isSpeech: isSpeech, elapsed: elapsed) == .finalize {
                await finalize(isFinal: false)
            }
        }
    }

    private func finalize(isFinal: Bool) async {
        // Don't cancel pollTask here: when silence auto-finalizes, this method
        // runs inside pollTask itself, and cancelling your own running task
        // makes the transcribe() call below throw CancellationError.
        if isFinal {
            pollTask = nil
            isRecording = false
            audioProcessor.stopRecording()
        }

        let chunkSamples = Array(audioProcessor.audioSamples)
        audioProcessor.purgeAudioSamples(keepingLast: 0)
        segmenter.reset()
        startDate = Date()

        if !chunkSamples.isEmpty {
            sessionSamples.append(contentsOf: chunkSamples)
            isTranscribing = true
            do {
                let results = try await whisperKit.transcribe(audioArray: chunkSamples)
                let chunkText = results.map(\.text).joined(separator: " ")
                if !chunkText.isEmpty {
                    transcript = transcript.isEmpty ? chunkText : "\(transcript) \(chunkText)"
                }
            } catch {
                errorMessage = "Transcription failed: \(error)"
            }
            isTranscribing = false
        }

        guard isFinal, !sessionSamples.isEmpty else { return }

        _ = try? feedbackStore?.add(samples: sessionSamples, source: "live", predictedText: transcript)
        sessionSamples = []

        if isAgentModeEnabled(), let agentRouter {
            let reply = await agentRouter.handle(transcript: transcript)
            transcript = reply
        }
        // Non-agent dictation is left in `transcript` rather than pasted here:
        // the composer mirrors it live into its editable field, and only an
        // explicit Send (submitTypedText) actually pastes/records it.
    }
}
