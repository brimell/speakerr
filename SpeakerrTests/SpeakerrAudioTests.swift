import XCTest
@testable import SpeakerrAudio

final class SpeakerrAudioTests: XCTestCase {
    func testModuleIsAvailable() {
        XCTAssertEqual(SpeakerrAudioModule.version, "0.1.0")
    }
}
