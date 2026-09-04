import CoreAudio
import Foundation

public enum SpeakerRoutingMode: String, Codable, CaseIterable, Sendable {
    case stereo
    case mono

    public var displayName: String {
        switch self {
        case .stereo: "Stereo (L / R)"
        case .mono: "Mono (same signal)"
        }
    }
}

enum ChannelSource: Equatable {
    case mono, left, right, silence
}

struct OutputChannelAssignment: Equatable {
    let offset: Int
    let count: Int

    func source(forLocalChannel channel: Int) -> ChannelSource {
        if count == 1 { return .mono }
        if channel == 0 { return .left }
        if channel == 1 { return .right }
        return .silence
    }
}

enum OutputChannelMap {
    static func assignments(channelCounts: [Int]) -> [OutputChannelAssignment] {
        var offset = 0
        return channelCounts.map { count in
            defer { offset += count }
            return OutputChannelAssignment(offset: offset, count: count)
        }
    }

    static func channelCount(in buffers: UnsafeMutableAudioBufferListPointer) -> Int {
        buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func write(
        _ source: UnsafePointer<Float>,
        to buffers: UnsafeMutableAudioBufferListPointer,
        channel: Int,
        frameCount: Int
    ) {
        var channelOffset = channel
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            guard channelOffset < channels else {
                channelOffset -= channels
                continue
            }
            guard let destination = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            if channels == 1 {
                memcpy(destination, source, frameCount * MemoryLayout<Float>.size)
            } else {
                for frame in 0..<frameCount {
                    destination[frame * channels + channelOffset] = source[frame]
                }
            }
            return
        }
    }

    static func writeToAllChannels(
        _ source: UnsafePointer<Float>,
        to buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) {
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let destination = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            if channels == 1 {
                memcpy(destination, source, frameCount * MemoryLayout<Float>.size)
            } else {
                for frame in 0..<frameCount {
                    for channel in 0..<channels {
                        destination[frame * channels + channel] = source[frame]
                    }
                }
            }
        }
    }
}
