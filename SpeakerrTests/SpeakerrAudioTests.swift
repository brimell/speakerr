import XCTest
@testable import SpeakerrAudio

final class SpeakerrAudioTests: XCTestCase {
    func testErrorIncludesOperation() {
        let error = CoreAudioError("Test operation", status: -1)
        XCTAssertTrue(error.localizedDescription.contains("Test operation"))
    }
}
