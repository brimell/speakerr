import XCTest
@testable import SpeakerrAudio

final class StereoRingBufferTests: XCTestCase {
    func testRoundTripAndWrap() {
        let ring = StereoRingBuffer(capacityFrames: 5)
        write([1, 2, 3], [11, 12, 13], to: ring)
        XCTAssertEqual(read(2, from: ring).0, [1, 2])
        write([4, 5, 6, 7], [14, 15, 16, 17], to: ring)
        let result = read(5, from: ring)
        XCTAssertEqual(result.0, [3, 4, 5, 6, 7])
        XCTAssertEqual(result.1, [13, 14, 15, 16, 17])
    }

    func testUnderflowReturnsSilenceAndCountsIt() {
        let ring = StereoRingBuffer(capacityFrames: 4)
        write([1], [2], to: ring)
        XCTAssertEqual(read(3, from: ring).0, [1, 0, 0])
        XCTAssertEqual(ring.counters().underflowCallbacks, 1)
        XCTAssertEqual(ring.counters().renderedFrames, 3)
    }

    func testOverflowDropsNewestFramesAndCountsThem() {
        let ring = StereoRingBuffer(capacityFrames: 3)
        write([1, 2], [1, 2], to: ring)
        let accepted = write([3, 4, 5], [3, 4, 5], to: ring)
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(read(3, from: ring).0, [1, 2, 3])
        XCTAssertEqual(ring.counters().overflowCallbacks, 1)
        XCTAssertEqual(ring.counters().droppedFrames, 2)
    }

    func testDiscardIsIdempotent() {
        let ring = StereoRingBuffer(capacityFrames: 4)
        write([1, 2], [3, 4], to: ring)
        ring.discardAll()
        ring.discardAll()
        XCTAssertEqual(ring.availableFrames, 0)
    }

    func testSampleRateConversionPlan() {
        let unchanged = SampleRateConversionPlan(captureRate: 44_100, renderRate: 44_100)
        XCTAssertFalse(unchanged.requiresConversion)
        XCTAssertEqual(unchanged.ratio, 1)
        let converted = SampleRateConversionPlan(captureRate: 48_000, renderRate: 44_100)
        XCTAssertTrue(converted.requiresConversion)
        XCTAssertEqual(converted.ratio, 0.91875, accuracy: 0.000_001)
    }

    @discardableResult
    private func write(_ left: [Float], _ right: [Float], to ring: StereoRingBuffer) -> Int {
        left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in ring.write(left: l.baseAddress!, right: r.baseAddress!, frameCount: left.count) } }
    }

    private func read(_ count: Int, from ring: StereoRingBuffer) -> ([Float], [Float]) {
        var left = [Float](repeating: -1, count: count)
        var right = left
        left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in _ = ring.read(left: l.baseAddress!, right: r.baseAddress!, frameCount: count) } }
        return (left, right)
    }
}
