import XCTest
@testable import WarbleMac

final class PendingEditApplyTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testAppliesEditByReplacingOldTextWithNewText() throws {
        let filePath = tempDir.appendingPathComponent("a.txt")
        try "hello".write(to: filePath, atomically: true, encoding: .utf8)

        try applyPendingEdits([
            PendingEdit(filePath: filePath.path, oldText: "hello", newText: "hey there")
        ])

        let contents = try String(contentsOf: filePath, encoding: .utf8)
        XCTAssertEqual(contents, "hey there")
    }

    func testAppliesWriteEditByCreatingNewFile() throws {
        let filePath = tempDir.appendingPathComponent("new.txt")

        try applyPendingEdits([
            PendingEdit(filePath: filePath.path, oldText: "", newText: "brand new content")
        ])

        let contents = try String(contentsOf: filePath, encoding: .utf8)
        XCTAssertEqual(contents, "brand new content")
    }

    func testThrowsAndLeavesFileUnchangedWhenOldTextNotFound() throws {
        let filePath = tempDir.appendingPathComponent("a.txt")
        try "hello".write(to: filePath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try applyPendingEdits([
            PendingEdit(filePath: filePath.path, oldText: "not present", newText: "hey there")
        ]))

        let contents = try String(contentsOf: filePath, encoding: .utf8)
        XCTAssertEqual(contents, "hello")
    }
}
