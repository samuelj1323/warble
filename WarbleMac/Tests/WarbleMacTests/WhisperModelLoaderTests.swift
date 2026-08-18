import XCTest
@testable import WarbleMac

final class WhisperModelLoaderTests: XCTestCase {
    func testLoadThrowsForMissingBundle() async {
        let missingURL = URL(fileURLWithPath: "/nonexistent/path/whisper-warble-coreml")

        do {
            _ = try await WhisperModelLoader.load(at: missingURL)
            XCTFail("expected load to throw for a missing model bundle")
        } catch is WhisperModelLoader.LoadError {
            // expected
        } catch {
            XCTFail("expected WhisperModelLoader.LoadError, got \(error)")
        }
    }
}
