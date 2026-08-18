import AVFAudio
import XCTest
@testable import WarbleMac

final class TTSServiceTests: XCTestCase {
    func testSpeakInvokesSpeakClosureWithUtteranceText() {
        var spokenText: String?
        let service = TTSService(speakUtterance: { utterance in
            spokenText = utterance.speechString
        })

        service.speak("hello world")

        XCTAssertEqual(spokenText, "hello world")
    }

    func testSpeakWithEmptyTextDoesNothing() {
        var speakCallCount = 0
        let service = TTSService(speakUtterance: { _ in
            speakCallCount += 1
        })

        service.speak("")

        XCTAssertEqual(speakCallCount, 0)
    }
}
