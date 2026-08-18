import XCTest
@testable import WarbleMac

final class FeedbackStoreTests: XCTestCase {
    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedbackStoreTests-\(UUID().uuidString)")
        return dir
    }

    func testAddWritesWavFileWithValidPcm16Header() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FeedbackStore(directory: dir)

        let row = try store.add(samples: [0.0, 0.5, -0.5, 1.0], source: "live", predictedText: "hello world")

        let wavURL = dir.appendingPathComponent(row.fileName)
        let data = try Data(contentsOf: wavURL)

        XCTAssertEqual(data[0..<4], Data("RIFF".utf8))
        XCTAssertEqual(data[8..<12], Data("WAVE".utf8))
        XCTAssertEqual(data[12..<16], Data("fmt ".utf8))

        let numChannels = UInt16(data[22]) | (UInt16(data[23]) << 8)
        XCTAssertEqual(numChannels, 1)

        var sampleRate: UInt32 = 0
        sampleRate |= UInt32(data[24])
        sampleRate |= UInt32(data[25]) << 8
        sampleRate |= UInt32(data[26]) << 16
        sampleRate |= UInt32(data[27]) << 24
        XCTAssertEqual(sampleRate, 16000)

        let bitsPerSample = UInt16(data[34]) | (UInt16(data[35]) << 8)
        XCTAssertEqual(bitsPerSample, 16)
    }

    func testAddAppendsCsvRowWithFeedbackPySchema() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FeedbackStore(directory: dir)

        let row = try store.add(samples: [0.0, 0.5], source: "live", predictedText: "hello world")

        let csvURL = dir.appendingPathComponent("metadata.csv")
        let contents = try String(contentsOf: csvURL, encoding: .utf8)
        let lines = contents.components(separatedBy: "\r\n").filter { !$0.isEmpty }

        XCTAssertEqual(lines[0], "id,file_name,source,predicted_text,corrected_text,rating,created_at")
        XCTAssertEqual(lines.count, 2)

        let fields = lines[1].components(separatedBy: ",")
        XCTAssertEqual(fields[0], row.id)
        XCTAssertEqual(fields[1], row.fileName)
        XCTAssertEqual(fields[2], "live")
        XCTAssertEqual(fields[3], "hello world")
        XCTAssertEqual(fields[4], "")
        XCTAssertEqual(fields[5], "")
        XCTAssertFalse(fields[6].isEmpty)
    }

    func testMultipleAddCallsAppendWithoutClobberingPriorRows() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FeedbackStore(directory: dir)

        let first = try store.add(samples: [0.1], source: "live", predictedText: "first")
        let second = try store.add(samples: [0.2], source: "live", predictedText: "second")

        let csvURL = dir.appendingPathComponent("metadata.csv")
        let contents = try String(contentsOf: csvURL, encoding: .utf8)
        let lines = contents.components(separatedBy: "\r\n").filter { !$0.isEmpty }

        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].contains(first.id))
        XCTAssertTrue(lines[1].contains("first"))
        XCTAssertTrue(lines[2].contains(second.id))
        XCTAssertTrue(lines[2].contains("second"))
    }

    func testCsvEscapesPredictedTextContainingCommasAndQuotes() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FeedbackStore(directory: dir)

        _ = try store.add(samples: [0.1], source: "live", predictedText: "hello, \"world\"")

        let csvURL = dir.appendingPathComponent("metadata.csv")
        let contents = try String(contentsOf: csvURL, encoding: .utf8)
        let lines = contents.components(separatedBy: "\r\n").filter { !$0.isEmpty }

        XCTAssertTrue(lines[1].contains("\"hello, \"\"world\"\"\""))
    }
}
