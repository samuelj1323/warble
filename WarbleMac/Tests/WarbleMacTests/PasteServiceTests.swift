import AppKit
import XCTest
@testable import WarbleMac

@MainActor
final class PasteServiceTests: XCTestCase {
    func testPasteWritesTextToPasteboard() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.warble.test.\(UUID().uuidString)"))
        var keystrokeSent = false
        let service = PasteService(
            pasteboard: pasteboard,
            sendPasteKeystroke: { keystrokeSent = true },
            frontmostAppName: { "TestApp" }
        )

        let appName = await service.paste(text: "hello world")

        XCTAssertEqual(pasteboard.string(forType: .string), "hello world")
        XCTAssertTrue(keystrokeSent)
        XCTAssertEqual(appName, "TestApp")
    }

    func testPasteWithEmptyTextDoesNothing() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.warble.test.\(UUID().uuidString)"))
        pasteboard.setString("preexisting", forType: .string)
        var keystrokeSent = false
        let service = PasteService(pasteboard: pasteboard, sendPasteKeystroke: { keystrokeSent = true })

        let appName = await service.paste(text: "")

        XCTAssertEqual(pasteboard.string(forType: .string), "preexisting")
        XCTAssertFalse(keystrokeSent)
        XCTAssertNil(appName)
    }
}
