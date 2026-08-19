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
    let sessionHistory = SessionHistory()

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
                },
                onDispatch: { [weak self] transcript, intent, reply in
                    guard case .codeChange = intent else {
                        self?.sessionHistory.record(.macControl(transcript: transcript, reply: reply))
                        return
                    }
                    self?.sessionHistory.record(.codeChange(transcript: transcript, summary: reply))
                }
            )
            let controller = PushToTalkController(
                whisperKit: whisperKit,
                feedbackStore: feedbackStore,
                pasteService: PasteService(),
                agentRouter: agentRouter,
                isAgentModeEnabled: { [weak self] in self?.isAgentMode ?? false },
                onDictationFinalized: { [weak self] transcript in
                    self?.sessionHistory.record(.dictation(transcript: transcript))
                }
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

/// Cursor-like full-window layout: sidebar (mode toggle + session history) on
/// the left, live transcript/agent/code-change stream in the center. The tray
/// icon (TrayIconController) is separate from this window and keeps working
/// for hotkey-triggered dictation regardless of what's shown here.
struct ContentView: View {
    @StateObject private var appModel = AppModel()
    private let ttsService = TTSService()

    var body: some View {
        NavigationSplitView {
            SidebarView(appModel: appModel)
        } detail: {
            CenterPanelView(appModel: appModel, history: appModel.sessionHistory, ttsService: ttsService)
        }
        .task {
            await appModel.loadModelAndReportInfo()
        }
    }
}

struct SidebarView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Warble")
                .font(.title)

            Toggle("Agent mode", isOn: $appModel.isAgentMode)
                .toggleStyle(.switch)

            VStack(alignment: .leading) {
                Text("Code-change repo root:")
                TextField("/path/to/scratch-repo", text: $appModel.codeChangeRepoRoot)
            }

            Divider()

            HStack {
                Text("Sessions")
                    .font(.headline)
                Spacer()
                Button {
                    appModel.sessionHistory.startNewSession()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help("Start a new session")
            }
            SessionListView(history: appModel.sessionHistory)
        }
        .padding()
        .frame(minWidth: 220)
    }
}

/// Sidebar list of conversation threads — like a messaging app's contact
/// list: each row is a whole session, selecting one switches the center
/// panel's chat transcript to that thread.
struct SessionListView: View {
    @ObservedObject var history: SessionHistory

    var body: some View {
        List(history.sessions, selection: Binding(
            get: { history.currentSessionID },
            set: { history.currentSessionID = $0 }
        )) { session in
            SessionRowView(session: session).tag(session.id)
        }
        .listStyle(.sidebar)
    }
}

struct SessionRowView: View {
    @ObservedObject var session: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title)
                .font(.caption)
                .lineLimit(1)
            if let last = session.messages.last {
                Text(last.text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Renders the current session's turns as chat bubbles, like a messaging app
/// — you on the right, Warble on the left — scrolling to the newest turn as
/// the conversation grows. While the mic is live, an in-progress bubble tracks
/// `controller.transcript` word-for-word instead of waiting for finalization,
/// so partial dictation shows up as a message updating in place.
struct ChatTranscriptView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var controller: PushToTalkController

    private static let liveBubbleID = "live-bubble"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.messages) { message in
                        ChatBubbleView(message: message)
                    }
                    if isLive {
                        ChatBubbleView(message: ChatMessage(id: UUID(), role: .user, text: liveText))
                            .opacity(0.6)
                            .id(Self.liveBubbleID)
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
            .onChange(of: session.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: controller.transcript) { _, _ in scrollToBottom(proxy) }
        }
    }

    private var isLive: Bool {
        (controller.isRecording || controller.isTranscribing) && !controller.transcript.isEmpty
    }

    private var liveText: String { controller.transcript }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation {
            if isLive {
                proxy.scrollTo(Self.liveBubbleID, anchor: .bottom)
            } else if let lastID = session.messages.last?.id {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
}

struct ChatBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .font(.caption)
                .padding(8)
                .background(message.role == .user ? Color.accentColor.opacity(0.85) : Color.gray.opacity(0.2))
                .foregroundStyle(message.role == .user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
        .id(message.id)
    }
}

struct CenterPanelView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var history: SessionHistory
    let ttsService: TTSService

    var body: some View {
        VStack(spacing: 16) {
            Text(appModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let controller = appModel.pushToTalk {
                if let chatSession = history.currentSession {
                    ChatTranscriptView(session: chatSession, controller: controller)
                } else {
                    Spacer()
                    Text("Click below to start talking — this begins a new session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

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
    }
}

/// Renders a ClaudeCodeSession's live transcript, the diff it proposes, and
/// Apply/Discard buttons for reviewing it.
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

/// Just the mic control — the live transcript itself now lives in
/// `ChatTranscriptView`'s in-progress bubble, so this doesn't duplicate it.
struct PushToTalkView: View {
    @ObservedObject var controller: PushToTalkController

    var body: some View {
        VStack(spacing: 8) {
            Button(controller.isRecording ? "Click to stop" : "Click to talk") {
                Task { await controller.toggle() }
            }
            .buttonStyle(.borderedProminent)

            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
