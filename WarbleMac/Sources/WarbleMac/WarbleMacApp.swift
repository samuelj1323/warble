import AppKit
import SwiftUI
import WhisperKit

@main
struct WarbleMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// A bare `swift run` executable has no `.app` bundle, so macOS launches it as
/// a process without a proper "regular app" activation policy: its window shows
/// and looks clickable, but it never becomes the key/frontmost app, so text
/// fields can't actually hold keyboard focus. Forcing `.regular` policy and
/// activating at launch makes it behave like a normally-launched GUI app, which
/// is what lets the composer's text field take (and keep) keyboard input.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var pushToTalk: PushToTalkController?
    @Published private(set) var statusMessage: String = "Loading model..."
    let sessionHistory = SessionHistory()

    /// Running, regular (Dock-visible) apps other than Warble itself, offered
    /// as explicit paste targets in the sidebar picker.
    var pasteTargetOptions: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private var hotkeyManager: HotkeyManager?
    private var trayIcon: TrayIconController?
    private var statusObservation: Task<Void, Never>?

    /// Runs the request against the *current session's* own ClaudeCodeSession,
    /// scoped to that session's repo. Follow-ups within the same thread resume
    /// its claude conversation and accumulate onto its pending diff; a different
    /// thread pointed at a different repo runs independently. The resumable
    /// conversation id is mirrored back onto the session config for persistence.
    /// Returns a short spoken summary.
    func runCodeChange(prompt: String) async -> String {
        guard let session = sessionHistory.currentSession,
              let codeSession = session.codeSession else {
            return "No code-change repo root is configured for this session yet."
        }

        await codeSession.run(prompt: prompt)
        session.config.claudeSessionID = codeSession.sessionID

        if let finalResultText = codeSession.finalResultText {
            return finalResultText
        }
        let editCount = codeSession.pendingEdits.count
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
                classify: { transcript in
                    if #available(macOS 26.0, *) {
                        return await FoundationModelsAgentClassifier.classify(transcript)
                    }
                    return .chat(reply: "Agent mode requires macOS 26.")
                },
                runCodeChange: { [weak self] transcript in
                    await self?.runCodeChange(prompt: transcript) ?? "Code-change agent unavailable."
                },
                onDispatch: { [weak self] _, _, reply in
                    // The user turn was already echoed on submit (onUserMessage);
                    // here we just land the assistant's reply and clear pending.
                    self?.sessionHistory.appendAssistantMessage(reply)
                }
            )
            let controller = PushToTalkController(
                whisperKit: whisperKit,
                feedbackStore: feedbackStore,
                pasteService: PasteService(),
                agentRouter: agentRouter,
                isAgentModeEnabled: { [weak self] in self?.sessionHistory.currentSession?.config.agentModeEnabled ?? false },
                pasteTarget: { [weak self] in self?.sessionHistory.currentSession?.config.pasteTarget ?? .focusedApp },
                onUserMessage: { [weak self] text in
                    self?.sessionHistory.appendUserMessage(text)
                    self?.sessionHistory.setAwaitingReply(true)
                },
                onDictationFinalized: { [weak self] _, appName in
                    self?.sessionHistory.appendAssistantMessage("Pasted into \(appName ?? "focused app").")
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
            // Launched processes (e.g. via `swift run` from a script/tool rather
            // than double-clicked) don't always become the key/frontmost app on
            // their own, which leaves controls looking clickable but not actually
            // receiving keyboard focus. Force activation so the window — and the
            // composer's text field — can actually take input.
            NSApp.activate(ignoringOtherApps: true)
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
            HStack(spacing: 4) {
                Text(session.title)
                    .font(.caption)
                    .lineLimit(1)
                if !session.config.repoRoot.isEmpty {
                    Text(URL(fileURLWithPath: session.config.repoRoot).lastPathComponent)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .lineLimit(1)
                }
            }
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
/// the conversation grows. Dictation-in-progress no longer shows here as a
/// preview bubble: it streams live into the composer's editable text field
/// instead (see `ComposerView`), so you can adjust it before it's sent.
struct ChatTranscriptView: View {
    @ObservedObject var session: ChatSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.messages) { message in
                        ChatBubbleView(message: message)
                    }
                    if session.isAwaitingReply {
                        TypingIndicatorView()
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
            .onChange(of: session.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: session.isAwaitingReply) { _, _ in scrollToBottom(proxy) }
        }
    }

    private static let bottomAnchor = "bottom-anchor"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }
}

/// Assistant-side placeholder bubble shown while a reply is in flight, so a slow
/// on-device classification or code-change run reads as "working" rather than a
/// frozen transcript.
struct TypingIndicatorView: View {
    var body: some View {
        HStack {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Thinking…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color.gray.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Spacer(minLength: 40)
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
                    SessionConfigHeaderView(appModel: appModel, session: chatSession)
                    ChatTranscriptView(session: chatSession)
                } else {
                    Spacer()
                    Text("Click below to start talking — this begins a new session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                ComposerView(controller: controller)
            } else {
                ProgressView()
            }

            if let codeSession = history.currentSession?.codeSession {
                ClaudeCodeSessionView(session: codeSession)
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
        // A session is created lazily as soon as a repo is set, so stay hidden
        // until it actually has a running turn, transcript, or diff to show.
        if session.events.isEmpty, session.pendingEdits.isEmpty, !session.isRunning {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
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

/// Per-session config surfaced at the top of the center panel: which repo
/// code-changes target, where sent text is pasted, and whether utterances are
/// routed through the agent classifier. Editing any field mutates *this
/// session's* config (persisted immediately), so switching threads switches the
/// whole context — repo, destination, and mode — at once.
struct SessionConfigHeaderView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var session: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Repo:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(action: chooseRepo) {
                    Text(session.config.repoRoot.isEmpty
                        ? "Choose folder…"
                        : URL(fileURLWithPath: session.config.repoRoot).lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(session.config.repoRoot.isEmpty ? "Choose a repo folder for this session" : session.config.repoRoot)
                if !session.config.repoRoot.isEmpty {
                    Button {
                        session.config.repoRoot = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear repo")
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Text("Paste into:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $session.config.pasteTarget) {
                    Text("Focused app").tag(PasteTarget.focusedApp)
                    ForEach(targetOptions, id: \.self) { target in
                        Text(label(for: target)).tag(target)
                    }
                }
                .labelsHidden()
                .font(.caption)
                .frame(maxWidth: 200)

                Spacer()

                Toggle("Agent mode", isOn: $session.config.agentModeEnabled)
                    .toggleStyle(.switch)
                    .font(.caption)
            }
        }
        .padding(.bottom, 4)
    }

    /// Running apps offered as paste targets, plus the session's current target
    /// if it isn't currently running (so a persisted choice still shows selected
    /// and doesn't silently reset to "Focused app").
    private var targetOptions: [PasteTarget] {
        var options = appModel.pasteTargetOptions.compactMap { app -> PasteTarget? in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return .app(bundleID: bundleID, name: app.localizedName ?? bundleID)
        }
        if case .app(let id, _) = session.config.pasteTarget,
           !options.contains(where: { if case .app(let optID, _) = $0 { return optID == id } else { return false } }) {
            options.append(session.config.pasteTarget)
        }
        return options
    }

    private func label(for target: PasteTarget) -> String {
        if case .app(_, let name) = target { return name }
        return "Focused app"
    }

    /// Opens a directory picker so the repo is chosen by browsing rather than
    /// typing an exact path. Setting it once (vs. per keystroke) also keeps the
    /// persisted config from churning on every character.
    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the repository folder for this session"
        if !session.config.repoRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: session.config.repoRoot)
        }
        if panel.runModal() == .OK, let url = panel.url {
            session.config.repoRoot = url.path
        }
    }
}

/// Chat-composer-style input row at the bottom of the window: a live status
/// readout above a text field plus a mic button for push-to-talk, so either
/// typing or speaking can start/continue a session. While recording, the
/// field mirrors `controller.liveTranscript` word-for-word as it's transcribed,
/// so dictation lands here to review/edit rather than pasting immediately —
/// only an explicit Send commits it (paste into the session's configured target,
/// or agent dispatch when the session's agent mode is on). The paste target,
/// repo, and agent toggle live in `SessionConfigHeaderView` at the top of the
/// panel. Typed sends and dictated sends both funnel through
/// `PushToTalkController.submitTypedText`, so they're handled identically.
struct ComposerView: View {
    @ObservedObject var controller: PushToTalkController
    @State private var draftText: String = ""
    /// The last value auto-written into `draftText` from a live transcript
    /// update. As long as `draftText` still equals this, the field hasn't
    /// been hand-edited, so it's safe to keep overwriting it as new chunks
    /// of speech are transcribed. Once the two diverge — the user typed into
    /// the field mid-recording — auto-sync stops so their edit isn't clobbered
    /// by the next chunk.
    @State private var lastSyncedTranscript: String = ""
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                DictationStatusView(status: controller.status)
            }

            HStack(spacing: 8) {
                TextField("Type or speak a message…", text: $draftText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($isComposerFocused)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")

                Button {
                    Task { await controller.toggle() }
                } label: {
                    Image(systemName: controller.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title2)
                        .foregroundStyle(controller.isRecording ? .red : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(controller.isRecording ? "Click to stop" : "Click to talk")
            }

            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            isComposerFocused = true
        }
        .onChange(of: controller.isTranscribing) { wasTranscribing, isTranscribing in
            // Once a chunk finishes transcribing, keyboard focus should be sitting
            // in the composer field — not wherever it last was — so the highlighted
            // draft text is immediately editable without an extra click.
            guard wasTranscribing, !isTranscribing else { return }
            isComposerFocused = true
        }
        .onChange(of: controller.liveTranscript) { _, newValue in
            guard controller.isRecording || controller.isTranscribing else { return }
            guard draftText == lastSyncedTranscript else { return }
            draftText = newValue
            lastSyncedTranscript = newValue
        }
        .onChange(of: controller.isRecording) { _, isRecording in
            guard isRecording, draftText == lastSyncedTranscript else { return }
            draftText = ""
            lastSyncedTranscript = ""
        }
    }

    private func send() {
        let text = draftText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draftText = ""
        lastSyncedTranscript = ""
        Task { await controller.submitTypedText(text) }
    }
}

/// Live dictation-state readout for the composer. A natural pause mid-dictation
/// silently transcribes the chunk spoken so far and keeps recording, so without
/// a visible cue you can't tell whether the app is still listening, busy
/// transcribing, or idle. This mirrors the tray icon's idle/recording/
/// transcribing states inside the main window: a red dot while capturing, a
/// spinner while a chunk is being transcribed, and nothing when idle.
struct DictationStatusView: View {
    let status: DictationStatus

    var body: some View {
        HStack(spacing: 5) {
            switch status {
            case .idle:
                EmptyView()
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Listening…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
