import Foundation
import WhisperKit

/// Loads a converted CoreML Whisper model bundle from disk and reports basic info about it.
enum WhisperModelLoader {
    struct ModelInfo {
        let name: String
        let sizeBytes: Int64
    }

    enum LoadError: Error {
        case bundleNotFound(URL)
    }

    static func load(at bundleURL: URL) async throws -> ModelInfo {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw LoadError.bundleNotFound(bundleURL)
        }

        let whisperKit = try await WhisperKit(modelFolder: bundleURL.path, load: true, download: false)
        let sizeBytes = directorySize(at: bundleURL)

        return ModelInfo(name: "\(whisperKit.modelVariant)", sizeBytes: sizeBytes)
    }

    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }
}
