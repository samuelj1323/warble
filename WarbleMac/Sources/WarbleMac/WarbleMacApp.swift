import SwiftUI

@main
struct WarbleMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await loadModelAndReportInfo()
                }
        }
    }

    private func loadModelAndReportInfo() async {
        let path = ProcessInfo.processInfo.environment["WARBLE_MODEL_PATH"]
            ?? FileManager.default.currentDirectoryPath + "/models/whisper-warble-coreml"
        let bundleURL = URL(fileURLWithPath: path)

        do {
            let info = try await WhisperModelLoader.load(at: bundleURL)
            print("Loaded Whisper model: \(info.name) (\(info.sizeBytes) bytes)")
        } catch {
            print("Failed to load Whisper model at \(bundleURL.path): \(error)")
        }
        fflush(stdout)
    }
}

struct ContentView: View {
    var body: some View {
        Text("Warble")
            .frame(minWidth: 400, minHeight: 300)
    }
}
