import XCTest
@testable import WarbleMac

final class TrayIconStateTests: XCTestCase {
    func testIdleGlyph() {
        XCTAssertEqual(TrayIconState.glyph(for: .idle), "🎙️")
    }

    func testRecordingGlyph() {
        XCTAssertEqual(TrayIconState.glyph(for: .recording), "🔴")
    }

    func testTranscribingGlyph() {
        XCTAssertEqual(TrayIconState.glyph(for: .transcribing), "⏳")
    }
}
