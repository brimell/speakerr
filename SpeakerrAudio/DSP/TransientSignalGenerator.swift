import Foundation

final class TransientSignalGenerator {
    private let period: UnsafeMutablePointer<Float>
    private let periodFrames: Int
    private var position = 0

    init(sampleRate: Double, level: Float = 0.15) {
        periodFrames = max(1, Int(sampleRate * 0.75))
        period = .allocate(capacity: periodFrames)
        period.initialize(repeating: 0, count: periodFrames)

        let burstFrames = max(2, Int(sampleRate * 0.02))
        var state: UInt64 = 0x5350_4541_4B45_5252
        var previous: Float = 0
        for frame in 0..<min(burstFrames, periodFrames) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let white = Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
            let highPassed = white - previous * 0.85
            previous = white
            let window = Float(0.5 - 0.5 * cos(2 * .pi * Double(frame) / Double(burstFrames - 1)))
            period[frame] = max(-1, min(1, highPassed)) * window * level
        }
    }

    deinit {
        period.deinitialize(count: periodFrames)
        period.deallocate()
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        for frame in 0..<frameCount {
            let sample = period[position]
            left[frame] = sample
            right[frame] = sample
            position = (position + 1) % periodFrames
        }
    }
}
