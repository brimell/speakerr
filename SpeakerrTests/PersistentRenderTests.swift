import AudioToolbox
import XCTest
@testable import SpeakerrAudio

private final class RenderFixture {
    let state: PersistentRenderState
    let transport: StereoRingBuffer
    let buffers: UnsafeMutableAudioBufferListPointer
    let frameCount: Int

    init(mode: SpeakerRoutingMode, channelCounts: [Int] = [2, 2], bufferChannels: [Int] = [1, 1, 1, 1], delays: [Double] = [0, 0], frameCount: Int = 64) throws {
        self.frameCount = frameCount
        transport = StereoRingBuffer(capacityFrames: frameCount * 4)
        state = try PersistentRenderState(sampleRate: 48_000, chirp: [0.25], transport: transport, channelCounts: channelCounts, delays: delays, routingMode: mode)
        state.setMasterEQBypass(true)
        buffers = AudioBufferList.allocate(maximumBuffers: bufferChannels.count)
        for (index, channels) in bufferChannels.enumerated() {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: channels * frameCount)
            samples.initialize(repeating: -99, count: channels * frameCount)
            buffers[index] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(channels * frameCount * 4), mData: samples)
        }
    }

    deinit {
        for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self).deallocate() }
        free(buffers.unsafeMutablePointer)
    }

    func programme(left: [Float], right: [Float]) -> [[Float]] {
        precondition(left.count == frameCount && right.count == frameCount)
        for _ in 0..<4 {
            _ = left.withUnsafeBufferPointer { l in
                right.withUnsafeBufferPointer { r in
                    transport.write(left: l.baseAddress!, right: r.baseAddress!, frameCount: frameCount)
                }
            }
        }
        state.setMode(.programme)
        return render()
    }

    func render() -> [[Float]] {
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .hostTimeValid
        timestamp.mHostTime = AudioGetCurrentHostTime()
        XCTAssertEqual(state.render(timestamp: &timestamp, ioData: buffers.unsafeMutablePointer, frameCount: UInt32(frameCount)), noErr)
        return buffers.flatMap { buffer -> [[Float]] in
            let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
            let channels = Int(buffer.mNumberChannels)
            return (0..<channels).map { channel in
                (0..<frameCount).map { samples[$0 * channels + channel] }
            }
        }
    }
}

final class PersistentRenderTests: XCTestCase {
    func testMappedRoutesUseAggregateSubdeviceOffsets() {
        let assignments = OutputChannelMap.assignments(channelCounts: [2, 2, 2], offsets: [2, 4, 0])

        XCTAssertEqual(assignments.map(\.offset), [2, 4, 0])
        XCTAssertEqual(assignments.map(\.count), [2, 2, 2])
    }

    func testStereoReachesBothSpeakersAcrossBufferLayouts() throws {
        for layout in [[1, 1, 1, 1], [2, 2], [4]] {
            let fixture = try RenderFixture(mode: .stereo, bufferChannels: layout)
            let left = [Float](repeating: 0.8, count: 64)
            let right = [Float](repeating: 0.2, count: 64)
            let channels = fixture.programme(left: left, right: right)
            XCTAssertEqual(channels, [left, right, left, right], "Layout: \(layout)")
        }
    }

    func testMonoKeepsIndependentVolumeAndDelayForEachSpeaker() throws {
        for layout in [[1, 1, 1, 1], [2, 2], [4]] {
            // 0.5 ms at 48 kHz = 24 frames, applied only to speaker B.
            let fixture = try RenderFixture(mode: .mono, bufferChannels: layout, delays: [0, 0.5])
            fixture.state.setRouteVolume(route: 0, volume: 0.8)
            fixture.state.setRouteVolume(route: 1, volume: 0.2)
            let channels = fixture.programme(left: .init(repeating: 0.8, count: 64), right: .init(repeating: 0.2, count: 64))
            for frame in 0..<64 {
                XCTAssertEqual(channels[0][frame], 0.4, accuracy: 0.00001)
                XCTAssertEqual(channels[1][frame], 0.4, accuracy: 0.00001)
                XCTAssertEqual(channels[2][frame], frame < 24 ? 0 : 0.1, accuracy: 0.00001)
                XCTAssertEqual(channels[3][frame], frame < 24 ? 0 : 0.1, accuracy: 0.00001)
            }
        }
    }

    func testMutingFirstSpeakerDoesNotMuteSecondInEitherMode() throws {
        for mode in SpeakerRoutingMode.allCases {
            let fixture = try RenderFixture(mode: mode)
            fixture.state.setRouteVolume(route: 0, volume: 0)
            let channels = fixture.programme(left: .init(repeating: 0.5, count: 64), right: .init(repeating: 0.5, count: 64))
            XCTAssertEqual(channels[0], .init(repeating: 0, count: 64))
            XCTAssertEqual(channels[1], .init(repeating: 0, count: 64))
            XCTAssertEqual(channels[2], .init(repeating: 0.5, count: 64))
            XCTAssertEqual(channels[3], .init(repeating: 0.5, count: 64))
        }
    }

    func testMonoKeepsSecondSpeakersEQ() throws {
        let fixture = try RenderFixture(mode: .mono, frameCount: 1024)
        fixture.state.setRouteEQBands(route: 1, bands: [.init(type: .peak, frequency: 1000, gain: -12, q: 1)])
        let tone = (0..<1024).map { Float(sin(Double($0) * 2 * .pi * 1000 / 48_000)) * 0.25 }
        let channels = fixture.programme(left: tone, right: tone)
        let firstEnergy = channels[0].suffix(512).reduce(Float(0)) { $0 + $1 * $1 }
        let secondEnergy = channels[2].suffix(512).reduce(Float(0)) { $0 + $1 * $1 }
        XCTAssertGreaterThan(firstEnergy, 1)
        XCTAssertLessThan(secondEnergy, firstEnergy * 0.1)
        XCTAssertEqual(channels[0], channels[1])
        XCTAssertEqual(channels[2], channels[3])
    }

    func testMonoAndStereoDevicesKeepTheirOwnChannelRanges() throws {
        let fixture = try RenderFixture(mode: .stereo, channelCounts: [1, 2], bufferChannels: [1, 2])
        let channels = fixture.programme(left: .init(repeating: 0.8, count: 64), right: .init(repeating: 0.2, count: 64))
        XCTAssertEqual(channels[0], .init(repeating: 0.5, count: 64))
        XCTAssertEqual(channels[1], .init(repeating: 0.8, count: 64))
        XCTAssertEqual(channels[2], .init(repeating: 0.2, count: 64))
    }

    func testCalibrationStillEmitsOnlyOnRequestedSpeaker() throws {
        let fixture = try RenderFixture(mode: .mono)
        fixture.state.setMode(.calibration)
        _ = fixture.state.requestEmission(speaker: 1)
        var channels: [[Float]] = []
        // The chirp starts 512 frames after the first block's end.
        for _ in 0..<10 { channels = fixture.render() }
        XCTAssertEqual(channels[0], .init(repeating: 0, count: 64))
        XCTAssertEqual(channels[1], .init(repeating: 0, count: 64))
        XCTAssertEqual(channels[2][0], 0.25)
        XCTAssertEqual(channels[3][0], 0.25)
    }

    func testCalibrationRoutesSpeakerTwoProbeOnlyToThirdOutput() throws {
        let fixture = try RenderFixture(mode: .mono, channelCounts: [2, 2, 2], bufferChannels: [1, 1, 1, 1, 1, 1], delays: [0, 0, 0])
        fixture.state.setMode(.calibration)
        _ = fixture.state.requestEmission(speaker: 2)
        var channels: [[Float]] = []
        for _ in 0..<10 { channels = fixture.render() }

        XCTAssertEqual(channels.count, 6)
        XCTAssertEqual(channels[0], .init(repeating: 0, count: 64))
        XCTAssertEqual(channels[1], .init(repeating: 0, count: 64))
        XCTAssertEqual(channels[2], .init(repeating: 0, count: 64))
        XCTAssertEqual(channels[3], .init(repeating: 0, count: 64))
        XCTAssertEqual(channels[4][0], 0.25)
        XCTAssertEqual(channels[5][0], 0.25)
    }

    func testCalibrationEmissionRequestsZeroOneAndTwoSelectMatchingRoutes() throws {
        for requestedSpeaker in 0..<3 {
            let fixture = try RenderFixture(mode: .mono, channelCounts: [2, 2, 2], bufferChannels: [1, 1, 1, 1, 1, 1], delays: [0, 0, 0])
            fixture.state.setMode(.calibration)
            _ = fixture.state.requestEmission(speaker: requestedSpeaker)
            var channels: [[Float]] = []
            for _ in 0..<10 { channels = fixture.render() }

            for route in 0..<3 {
                let expected: Float = route == requestedSpeaker ? 0.25 : 0
                XCTAssertEqual(channels[route * 2][0], expected, accuracy: 0.00001, "requested speaker \(requestedSpeaker), route \(route)")
                XCTAssertEqual(channels[route * 2 + 1][0], expected, accuracy: 0.00001, "requested speaker \(requestedSpeaker), route \(route)")
            }
        }
    }
}
