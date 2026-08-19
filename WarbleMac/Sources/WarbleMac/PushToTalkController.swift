import AppKit
import Foundation
import WhisperKit

/// Drives push-to-talk capture: starts mic recording on `start()`, polls the
/// audio processor's energy against `UtteranceSegmenter` to auto-finalize on
/// trailing silence or the max-duration cutoff, and transcribes the captured
/// utterance via WhisperKit once finalized.
@MainActor
final class PushToTalkController: ObservableObject {
    /// Committed transcript: the concatenation of chunks already finalized on a
    /// trailing-silence pause (or the 15s cap). Feedback logging and agent
    /// dispatch use this authoritative text, not the live preview.
    @Published private(set) var transcript: String = ""
    /// What the composer mirrors: the committed `transcript` plus the live,
    /// still-being-spoken `partialText` preview, so words appear as you talk
    /// instead of only when you pause.
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var isTranscribing: Bool = false
    @Published private(set) var errorMessage: String?

    var status: DictationStatus {
        // Transcribing is checked first: a mid-session chunk (triggered by a
        // trailing-silence pause) transcribes while recording is still live, so
        // both flags are true at once. Reporting `.transcribing` in that overlap
        // is what surfaces "working on it" feedback for longer chunks — otherwise
        // `.recording` would always win and the transcribing state stayed hidden.
        if isTranscribing { return .transcribing }
        if isRecording { return .recording }
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
    private let pasteTarget: () -> PasteTarget
    /// Fired the instant an utterance is submitted (typed Send, or spoken finalize
    /// in agent mode), before any awaiting, so the transcript can show the user's
    /// message + a pending indicator while the reply/paste is worked out.
    private let onUserMessage: ((String) -> Void)?
    private let onDictationFinalized: ((String, String?) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var startDate: Date?
    /// Live preview of the current, not-yet-committed chunk. Produced by
    /// re-transcribing the growing audio buffer every `partialInterval` while
    /// recording, then cleared into `transcript` when the chunk is committed.
    private var partialText: String = ""
    /// When the last streaming preview transcription finished, used to throttle
    /// how often the whole growing buffer is re-transcribed.
    private var lastPartialAt: Date?
    private let partialInterval: TimeInterval = 1.0
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
        pasteTarget: @escaping () -> PasteTarget = { .focusedApp },
        onUserMessage: ((String) -> Void)? = nil,
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
        self.pasteTarget = pasteTarget
        self.onUserMessage = onUserMessage
        self.onDictationFinalized = onDictationFinalized
    }

    /// Submits typed text (from the chat composer) the same way a finalized
    /// spoken utterance is handled: routed through the agent if agent mode is
    /// on, otherwise pasted into the configured target app (or whatever has
    /// focus) and recorded to session history.
    func submitTypedText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Show the user's message (and the pending state) immediately, before any
        // awaiting, so hitting Send echoes into the transcript right away.
        onUserMessage?(trimmed)

        if isAgentModeEnabled(), let agentRouter {
            _ = await agentRouter.handle(transcript: trimmed)
        } else {
            let appName = await pasteService?.paste(text: trimmed, target: pasteTarget())
            onDictationFinalized?(trimmed, appName)
        }
    }

    func start() throws {
        guard !isRecording else { return }
        errorMessage = nil
        transcript = ""
        partialText = ""
        liveTranscript = ""
        lastPartialAt = nil
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
            } else {
                await streamPartialIfDue()
            }
        }
    }

    /// While recording, periodically re-transcribes the current (not-yet-purged)
    /// audio buffer to produce a live preview so words show up as they're spoken
    /// rather than only when a pause commits a chunk. Runs inline in the poll
    /// loop so it never overlaps a commit's transcription on the same WhisperKit
    /// instance. Deliberately does NOT touch `isTranscribing`: streaming stays in
    /// the "Listening" state — the appearing words are the feedback — while the
    /// spinner is reserved for the commit pass.
    private func streamPartialIfDue() async {
        if let lastPartialAt, Date().timeIntervalSince(lastPartialAt) < partialInterval {
            return
        }
        let snapshot = Array(audioProcessor.audioSamples)
        guard !snapshot.isEmpty else { return }

        let previous = partialText
        do {
            let results = try await whisperKit.transcribe(audioArray: snapshot)
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A commit may have run during the await (which purges the buffer and
            // clears partialText); only publish if we're still previewing the same
            // chunk this pass started on, so a stale preview can't clobber it.
            if isRecording, partialText == previous {
                partialText = text
                updateLiveTranscript()
            }
        } catch {
            // Preview passes are best-effort; a failed one is dropped silently and
            // the next commit still produces authoritative text.
        }
        lastPartialAt = Date()
    }

    private func updateLiveTranscript() {
        liveTranscript = [transcript, partialText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
        // The live preview for this chunk is superseded by the authoritative
        // transcription below, so drop it now (and stop any in-flight preview
        // pass from re-publishing it via its partialText == previous guard).
        partialText = ""
        lastPartialAt = nil

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
        updateLiveTranscript()

        guard isFinal, !sessionSamples.isEmpty else { return }

        _ = try? feedbackStore?.add(samples: sessionSamples, source: "live", predictedText: transcript)
        sessionSamples = []

        if isAgentModeEnabled(), let agentRouter {
            onUserMessage?(transcript)
            let reply = await agentRouter.handle(transcript: transcript)
            transcript = reply
            updateLiveTranscript()
        }
        // Non-agent dictation is left in `transcript` rather than pasted here:
        // the composer mirrors it live into its editable field, and only an
        // explicit Send (submitTypedText) actually pastes/records it.
    }
}
