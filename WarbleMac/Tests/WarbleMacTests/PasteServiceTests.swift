import AppKit
import XCTest
@testable import WarbleMac

final class PasteServiceTests: XCTestCase {
    func testPasteWritesTextToPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.warble.test.\(UUID().uuidString)"))
        var keystrokeSent = false
        let service = PasteService(pasteboard: pasteboard, sendPasteKeystroke: { keystrokeSent = true })

        service.paste(text: "hello world")

        XCTAssertEqual(pasteboard.string(forType: .string), "hello world")
        XCTAssertTrue(keystrokeSent)
    }

    func testPasteWithEmptyTextDoesNothing() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.warble.test.\(UUID().uuidString)"))
        pasteboard.setString("preexisting", forType: .string)
        var keystrokeSent = false
        let service = PasteService(pasteboard: pasteboard, sendPasteKeystroke: { keystrokeSent = true })

        service.paste(text: "")

        XCTAssertEqual(pasteboard.string(forType: .string), "preexisting")
        XCTAssertFalse(keystrokeSent)
    }
}
