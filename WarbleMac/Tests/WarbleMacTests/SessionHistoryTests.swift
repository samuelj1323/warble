import XCTest
@testable import WarbleMac

@MainActor
final class SessionHistoryTests: XCTestCase {
    func testRecordAppendsAnEntryOfTheGivenKind() {
        let history = SessionHistory()

        history.record(.dictation(transcript: "hello world"))

        XCTAssertEqual(history.entries.map(\.kind), [.dictation(transcript: "hello world")])
    }

    func testRecordPreservesInsertionOrderAcrossDifferentKinds() {
        let history = SessionHistory()

        history.record(.dictation(transcript: "open safari"))
        history.record(.macControl(reply: "Opened Safari."))
        history.record(.codeChange)

        XCTAssertEqual(history.entries.map(\.kind), [
            .dictation(transcript: "open safari"),
            .macControl(reply: "Opened Safari."),
            .codeChange
        ])
    }
}
