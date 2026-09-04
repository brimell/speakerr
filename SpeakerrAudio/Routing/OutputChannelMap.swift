import Foundation

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
}
