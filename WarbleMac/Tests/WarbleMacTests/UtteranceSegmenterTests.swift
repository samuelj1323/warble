import XCTest
@testable import WarbleMac

final class UtteranceSegmenterTests: XCTestCase {
    func testFinalizesAfterTrailingSilenceFollowingSpeech() {
        let segmenter = UtteranceSegmenter(trailingSilence: 0.7, maxDuration: 15.0)

        XCTAssertEqual(segmenter.tick(isSpeech: true, elapsed: 0.0), .continueRecording)
        XCTAssertEqual(segmenter.tick(isSpeech: true, elapsed: 0.25), .continueRecording)
        XCTAssertEqual(segmenter.tick(isSpeech: false, elapsed: 0.5), .continueRecording)
        XCTAssertEqual(segmenter.tick(isSpeech: false, elapsed: 0.75), .continueRecording)
        XCTAssertEqual(segmenter.tick(isSpeech: false, elapsed: 1.0), .finalize)
    }

    func testFinalizesAtMaxDurationEvenWithContinuousSpeech() {
        let segmenter = UtteranceSegmenter(trailingSilence: 0.7, maxDuration: 15.0)

        XCTAssertEqual(segmenter.tick(isSpeech: true, elapsed: 14.5), .continueRecording)
        XCTAssertEqual(segmenter.tick(isSpeech: true, elapsed: 14.75), .continueRecording)
        XCTAssertEqual(segmenter.tick(isSpeech: true, elapsed: 15.0), .finalize)
    }

    func testDoesNotFinalizeOnLeadingSilenceBeforeAnySpeech() {
        let segmenter = UtteranceSegmenter(trailingSilence: 0.7, maxDuration: 15.0)

        XCTAssertEqual(segmenter.tick(isSpeech: false, elapsed: 0.5), .continueRecording)
        XCTAssertEqual(segmenter.tick(isSpeech: false, elapsed: 5.0), .continueRecording)
        XCTAssertEqual(segmenter.tick(isSpeech: false, elapsed: 10.0), .continueRecording)
    }
}
