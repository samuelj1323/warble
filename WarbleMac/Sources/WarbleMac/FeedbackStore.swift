import Foundation

/// Native port of server/feedback.py: saves each finalized utterance as a
/// 16 kHz PCM16 WAV in `directory`, with a matching row appended to
/// `metadata.csv` using the exact same schema, so
/// `training/prepare_dataset.py --include-feedback` needs no changes.
struct FeedbackRow {
    let id: String
    let fileName: String
    let source: String
    let predictedText: String
    let correctedText: String
    let rating: String
    let createdAt: String
}

final class FeedbackStore {
    private static let fields = [
        "id", "file_name", "source", "predicted_text",
        "corrected_text", "rating", "created_at",
    ]

    private let directory: URL
    private let csvURL: URL

    init(directory: URL) throws {
        self.directory = directory
        self.csvURL = directory.appendingPathComponent("metadata.csv")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: csvURL.path) {
            try (Self.fields.joined(separator: ",") + "\r\n").write(to: csvURL, atomically: true, encoding: .utf8)
        }
    }

    @discardableResult
    func add(samples: [Float], source: String, predictedText: String) throws -> FeedbackRow {
        let fid = Self.makeID()
        let fileName = "\(fid).wav"
        let wavData = Self.wavData(from: samples, sampleRate: 16000)
        try wavData.write(to: directory.appendingPathComponent(fileName))

        let row = FeedbackRow(
            id: fid,
            fileName: fileName,
            source: source,
            predictedText: predictedText,
            correctedText: "",
            rating: "",
            createdAt: Self.isoNow()
        )
        try append(row)
        return row
    }

    private func append(_ row: FeedbackRow) throws {
        let fields = [
            row.id, row.fileName, row.source, row.predictedText,
            row.correctedText, row.rating, row.createdAt,
        ]
        let line = fields.map(Self.csvEscape).joined(separator: ",") + "\r\n"
        let handle = try FileHandle(forWritingTo: csvURL)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
    }

    private static func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func makeID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let timestamp = formatter.string(from: Date())
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(6)
        return "\(timestamp)-\(suffix)"
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func wavData(from samples: [Float], sampleRate: UInt32) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count) * UInt32(bitsPerSample / 8)

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: numChannels)
        data.append(littleEndian: sampleRate)
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: dataSize)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let intSample = Int16(clamped * 32767.0)
            data.append(littleEndian: intSample)
        }

        return data
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(littleEndian value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(littleEndian value: Int16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
