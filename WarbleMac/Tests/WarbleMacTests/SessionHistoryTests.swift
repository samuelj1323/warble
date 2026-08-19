import XCTest
@testable import WarbleMac

@MainActor
final class SessionHistoryTests: XCTestCase {
    func testRecordStartsASessionAutomaticallyWhenNoneExists() {
        let history = SessionHistory()

        history.record(.dictation(transcript: "hello world", pastedInto: nil))

        XCTAssertEqual(history.sessions.count, 1)
    }

    func testRecordAppendsAUserTurnThenAnAssistantTurnToTheCurrentSession() {
        let history = SessionHistory()

        history.record(.macControl(transcript: "open safari", reply: "Opened Safari."))

        let session = try! XCTUnwrap(history.currentSession)
        XCTAssertEqual(session.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(session.messages.map(\.text), ["open safari", "Opened Safari."])
    }

    func testStartNewSessionBeginsASeparateThread() {
        let history = SessionHistory()
        history.record(.dictation(transcript: "first thread", pastedInto: nil))
        let firstSessionID = history.currentSessionID

        history.startNewSession()
        history.record(.dictation(transcript: "second thread", pastedInto: "Safari"))

        XCTAssertEqual(history.sessions.count, 2)
        XCTAssertNotEqual(history.currentSessionID, firstSessionID)
        XCTAssertEqual(history.sessions[0].messages.map(\.text), ["first thread", "Pasted into focused app."])
        XCTAssertEqual(history.sessions[1].messages.map(\.text), ["second thread", "Pasted into Safari."])
    }
}
