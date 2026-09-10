import XCTest
@testable import SpeakerrAudio

final class SpeakerrAudioTests: XCTestCase {
    func testErrorIncludesOperation() {
        let error = CoreAudioError("Test operation", status: -1)
        XCTAssertTrue(error.localizedDescription.contains("Test operation"))
    }

    func testIntegerDelay() throws {
        let delay = try FractionalDelayLine(sampleRate: 1_000, initialDelayMilliseconds: 2)
        let result = delay.processForTesting(left: [1, 0, 0, 0], right: [0.5, 0, 0, 0])
        XCTAssertEqual(result.left, [0, 0, 1, 0])
        XCTAssertEqual(result.right, [0, 0, 0.5, 0])
    }

    func testFractionalDelayInterpolates() throws {
        let delay = try FractionalDelayLine(sampleRate: 1_000, initialDelayMilliseconds: 1.5)
        let result = delay.processForTesting(left: [1, 0, 0, 0], right: [1, 0, 0, 0])
        XCTAssertEqual(result.left[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.left[2], 0.5, accuracy: 0.0001)
    }

    func testDelayBoundsAreRejected() throws {
        XCTAssertThrowsError(try FractionalDelayLine(sampleRate: 48_000, initialDelayMilliseconds: -0.1))
        let delay = try FractionalDelayLine(sampleRate: 48_000)
        XCTAssertThrowsError(try delay.setDelay(milliseconds: 1000.1))
    }

    func testDelayCommandParsing() {
        XCTAssertEqual(InteractiveDelayCommand.parse("a +10"), .adjust(device: "a", milliseconds: 10))
        XCTAssertEqual(InteractiveDelayCommand.parse("B -0.1"), .adjust(device: "b", milliseconds: -0.1))
        XCTAssertEqual(InteractiveDelayCommand.parse("a 73.4"), .set(device: "a", milliseconds: 73.4))
        XCTAssertEqual(InteractiveDelayCommand.parse("status"), .status)
        XCTAssertEqual(InteractiveDelayCommand.parse("q"), .quit)
        XCTAssertNil(InteractiveDelayCommand.parse("c +1"))
    }

    func testDelayLineWrapsWithoutLosingStereoData() throws {
        let delay = try FractionalDelayLine(sampleRate: 4, initialDelayMilliseconds: 500)
        _ = delay.processForTesting(left: [1, 2, 3, 4], right: [5, 6, 7, 8])
        let result = delay.processForTesting(left: [9, 10, 11, 12], right: [13, 14, 15, 16])
        XCTAssertEqual(result.left, [3, 4, 9, 10])
        XCTAssertEqual(result.right, [7, 8, 13, 14])
    }

    func testStackedChannelAssignments() {
        let assignments = OutputChannelMap.assignments(channelCounts: [2, 1, 4])
        XCTAssertEqual(assignments, [
            OutputChannelAssignment(offset: 0, count: 2),
            OutputChannelAssignment(offset: 2, count: 1),
            OutputChannelAssignment(offset: 3, count: 4)
        ])
        XCTAssertEqual(assignments[0].source(forLocalChannel: 0), .left)
        XCTAssertEqual(assignments[0].source(forLocalChannel: 1), .right)
        XCTAssertEqual(assignments[1].source(forLocalChannel: 0), .mono)
        XCTAssertEqual(assignments[2].source(forLocalChannel: 2), .silence)
    }

    func testAggregateDescriptionUsesIndependentChannelsAndDrift() {
        let first = OutputDevice(id: "first", coreAudioID: 1, name: "First", transport: .bluetooth, sampleRate: 44_100, channelCount: 2)
        let second = OutputDevice(id: "second", coreAudioID: 2, name: "Second", transport: .usb, sampleRate: 44_100, channelCount: 2)
        let third = OutputDevice(id: "third", coreAudioID: 3, name: "Third", transport: .displayPort, sampleRate: 44_100, channelCount: 1)
        let description = AggregateDeviceManager.makeDescription(outputs: [first, second, third], uid: "aggregate")
        XCTAssertEqual(description["uid"] as? String, "aggregate")
        XCTAssertEqual(description["master"] as? String, "first")
        XCTAssertEqual(description["private"] as? Int, 1)
        XCTAssertEqual(description["stacked"] as? Int, 0)
        guard let subdevices = description["subdevices"] as? [[String: Any]] else {
            return XCTFail("Missing subdevice descriptions")
        }
        XCTAssertEqual(subdevices.count, 3)
        XCTAssertEqual(subdevices[0]["drift"] as? Int, 0)
        XCTAssertEqual(subdevices[1]["drift"] as? Int, 1)
        XCTAssertEqual(subdevices[2]["drift"] as? Int, 1)
    }

    func testDelayCanBeUpdatedAtomically() throws {
        let delay = try FractionalDelayLine(sampleRate: 48_000)
        try delay.setDelay(milliseconds: 73.4)
        XCTAssertEqual(delay.targetDelayMilliseconds, 73.4, accuracy: 0.000_001)
    }
}
