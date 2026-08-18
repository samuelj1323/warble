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

    private var hotkeyManager: HotkeyManager?
    private var trayIcon: TrayIconController?
    private var statusObservation: Task<Void, Never>?

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

            if let controller = appModel.pushToTalk {
                PushToTalkView(controller: controller)
            } else {
                ProgressView()
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
