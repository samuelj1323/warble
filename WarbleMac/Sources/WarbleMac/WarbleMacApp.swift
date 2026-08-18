import SwiftUI
import WhisperKit

@main
struct WarbleMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var pushToTalk: PushToTalkController?
    @Published private(set) var statusMessage: String = "Loading model..."
    @Published var isAgentMode: Bool = false
    @Published var codeChangeRepoRoot: String = UserDefaults.standard.string(forKey: "codeChangeRepoRoot") ?? "" {
        didSet { UserDefaults.standard.set(codeChangeRepoRoot, forKey: "codeChangeRepoRoot") }
    }
    @Published private(set) var codeChangeSession: ClaudeCodeSession?

    private var hotkeyManager: HotkeyManager?
    private var trayIcon: TrayIconController?
    private var statusObservation: Task<Void, Never>?

    /// Runs the request against the existing ClaudeCodeSession if one is already
    /// open (so a follow-up spoken correction resumes the same conversation and
    /// accumulates onto its pending diff), or spawns a fresh one scoped to the
    /// configured repo root otherwise. Publishes the session so the UI can render
    /// its live transcript/diff. Returns a short spoken summary.
    func runCodeChange(prompt: String) async -> String {
        guard !codeChangeRepoRoot.isEmpty else {
            return "No code-change repo root is configured yet."
        }

        let session = codeChangeSession ?? ClaudeCodeSession(repoRoot: codeChangeRepoRoot)
        codeChangeSession = session
        await session.run(prompt: prompt)

        if let finalResultText = session.finalResultText {
            return finalResultText
        }
        let editCount = session.pendingEdits.count
        return editCount == 0
            ? "No changes were proposed."
            : "Proposed \(editCount) edit\(editCount == 1 ? "" : "s") for review."
    }

    func loadModelAndReportInfo() async {
        checkAccessibilityPermission()

        let path = ProcessInfo.processInfo.environment["WARBLE_MODEL_PATH"]
            ?? FileManager.default.currentDirectoryPath + "/models/whisper-warble-coreml"
        let bundleURL = URL(fileURLWithPath: path)

        do {
            let info = try await WhisperModelLoader.load(at: bundleURL)
            print("Loaded Whisper model: \(info.name) (\(info.sizeBytes) bytes)")
            fflush(stdout)
            let whisperKit = try await WhisperKit(modelFolder: bundleURL.path, load: true, download: false)
            let feedbackDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/data/feedback")
            let feedbackStore = try? FeedbackStore(directory: feedbackDir)
            let agentRouter = AgentRouter(
                tools: MacControlTools(),
                tts: TTSService(),
                classify: { transcript in
                    if #available(macOS 26.0, *) {
                        return await FoundationModelsAgentClassifier.classify(transcript)
                    }
                    return .chat(reply: "Agent mode requires macOS 26.")
                },
                runCodeChange: { [weak self] transcript in
                    await self?.runCodeChange(prompt: transcript) ?? "Code-change agent unavailable."
                }
            )
            let controller = PushToTalkController(
                whisperKit: whisperKit,
                feedbackStore: feedbackStore,
                pasteService: PasteService(),
                agentRouter: agentRouter,
                isAgentModeEnabled: { [weak self] in self?.isAgentMode ?? false }
            )
            pushToTalk = controller
            statusMessage = "Model loaded: \(info.name)"

            let trayIcon = TrayIconController()
            self.trayIcon = trayIcon
            hotkeyManager = HotkeyManager { [weak controller] in
                Task { await controller?.toggle() }
            }
            hotkeyManager?.register()
            observeStatus(of: controller, trayIcon: trayIcon)
        } catch {
            print("Failed to load Whisper model at \(bundleURL.path): \(error)")
            fflush(stdout)
            statusMessage = "Failed to load model: \(error)"
        }
    }

    private func observeStatus(of controller: PushToTalkController, trayIcon: TrayIconController) {
        statusObservation?.cancel()
        statusObservation = Task { [weak controller, weak trayIcon] in
            var lastStatus: DictationStatus?
            while !Task.isCancelled {
                if let controller, let trayIcon, controller.status != lastStatus {
                    lastStatus = controller.status
                    trayIcon.update(status: controller.status)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func checkAccessibilityPermission() {
        let options: [String: Any] = ["AXTrustedCheckOptionPrompt": true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !trusted {
            print("Warble needs Accessibility permission to paste dictated text into other apps — grant it in System Settings > Privacy & Security > Accessibility.")
            fflush(stdout)
        }
    }
}

struct ContentView: View {
    @StateObject private var appModel = AppModel()
    private let ttsService = TTSService()

    var body: some View {
        VStack(spacing: 16) {
            Text("Warble")
                .font(.title)

            Text(appModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Agent mode", isOn: $appModel.isAgentMode)
                .toggleStyle(.switch)

            HStack {
                Text("Code-change repo root:")
                TextField("/path/to/scratch-repo", text: $appModel.codeChangeRepoRoot)
            }

            if let controller = appModel.pushToTalk {
                PushToTalkView(controller: controller)
            } else {
                ProgressView()
            }

            if let session = appModel.codeChangeSession {
                ClaudeCodeSessionView(session: session)
            }

            // Temporary manual-verification button for TTSService (issue #5) — remove once
            // TTS is wired into the mac-control/code-change agent flows in later tickets.
            Button("Test TTS") {
                ttsService.speak("Warble text to speech is working.")
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
        .task {
            await appModel.loadModelAndReportInfo()
        }
    }
}

/// Renders a ClaudeCodeSession's live transcript and the diff it proposes.
/// View-only: no Apply/Discard here — that's #8, which also makes the session
/// multi-turn instead of one-shot.
struct ClaudeCodeSessionView: View {
    @ObservedObject var session: ClaudeCodeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Code-change session")
                    .font(.headline)
                if session.isRunning {
                    ProgressView().controlSize(.small)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(session.events.enumerated()), id: \.offset) { _, event in
                        Text(transcriptLine(for: event))
                            .font(.caption.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)

            if !session.pendingEdits.isEmpty {
                Text("Proposed changes")
                    .font(.subheadline.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(session.pendingEdits.enumerated()), id: \.offset) { _, edit in
                            DiffView(edit: edit)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)

                // Apply/Discard are the sole irreversible step (writing files to
                // disk) and are deliberately UI-only — never reachable via voice.
                HStack {
                    Button("Apply") {
                        try? session.apply()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Discard") {
                        session.discard()
                    }
                }
            }
        }
    }

    private func transcriptLine(for event: ClaudeStreamEvent) -> String {
        switch event {
        case .system(let subtype, _):
            return "[system] \(subtype)"
        case .assistant(let content):
            return content.map { item in
                switch item {
                case .thinking: return "[thinking]"
                case .text(let text): return text
                case .toolUse(_, let name, _): return "[tool: \(name)]"
                }
            }.joined(separator: " ")
        case .user(let results):
            return results.map { "[result] \($0.content)" }.joined(separator: " ")
        case .result(let text, _):
            return "[done] \(text)"
        }
    }
}

struct DiffView: View {
    let edit: PendingEdit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(edit.filePath)
                .font(.caption.bold())
            if !edit.oldText.isEmpty {
                Text(edit.oldText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .strikethrough()
            }
            Text(edit.newText)
                .font(.caption.monospaced())
                .foregroundStyle(.green)
        }
    }
}

struct PushToTalkView: View {
    @ObservedObject var controller: PushToTalkController

    var body: some View {
        VStack(spacing: 12) {
            Button(controller.isRecording ? "Release to stop" : "Hold to talk") {}
                .buttonStyle(.borderedProminent)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !controller.isRecording else { return }
                            try? controller.start()
                        }
                        .onEnded { _ in
                            Task { await controller.stopAndFinalize() }
                        }
                )

            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            ScrollView {
                Text(controller.transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
