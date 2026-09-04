import Foundation
import Synchronization

public final class FractionalDelayLine: @unchecked Sendable {
    public static let maximumDelayMilliseconds = 1000.0

    private let sampleRate: Double
    private let capacity: Int
    private let leftStorage: UnsafeMutablePointer<Float>
    private let rightStorage: UnsafeMutablePointer<Float>
    private let targetDelayBits: Atomic<UInt64>
    private var writeIndex = 0
    private var currentDelayFrames: Double

    public init(sampleRate: Double, initialDelayMilliseconds: Double = 0) throws {
        guard (0...Self.maximumDelayMilliseconds).contains(initialDelayMilliseconds) else {
            throw AudioRoutingError.delayOutOfRange(initialDelayMilliseconds)
        }
        self.sampleRate = sampleRate
        capacity = Int(ceil(sampleRate * Self.maximumDelayMilliseconds / 1000.0)) + 2
        leftStorage = .allocate(capacity: capacity)
        rightStorage = .allocate(capacity: capacity)
        leftStorage.initialize(repeating: 0, count: capacity)
        rightStorage.initialize(repeating: 0, count: capacity)
        currentDelayFrames = initialDelayMilliseconds * sampleRate / 1000.0
        targetDelayBits = Atomic(currentDelayFrames.bitPattern)
    }

    deinit {
        leftStorage.deinitialize(count: capacity)
        rightStorage.deinitialize(count: capacity)
        leftStorage.deallocate()
        rightStorage.deallocate()
    }

    public var targetDelayMilliseconds: Double {
        Double(bitPattern: targetDelayBits.load(ordering: .relaxed)) * 1000.0 / sampleRate
    }

    public func setDelay(milliseconds: Double) throws {
        guard (0...Self.maximumDelayMilliseconds).contains(milliseconds) else {
            throw AudioRoutingError.delayOutOfRange(milliseconds)
        }
        targetDelayBits.store((milliseconds * sampleRate / 1000.0).bitPattern, ordering: .relaxed)
    }

    public func reset() {
        leftStorage.update(repeating: 0, count: capacity)
        rightStorage.update(repeating: 0, count: capacity)
        writeIndex = 0
        currentDelayFrames = Double(bitPattern: targetDelayBits.load(ordering: .relaxed))
    }

    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        let target = Double(bitPattern: targetDelayBits.load(ordering: .relaxed))
        let delayStep = (target - currentDelayFrames) / Double(frameCount)

        for frame in 0..<frameCount {
            currentDelayFrames += delayStep
            leftStorage[writeIndex] = left[frame]
            rightStorage[writeIndex] = right[frame]

            var readPosition = Double(writeIndex) - currentDelayFrames
            while readPosition < 0 { readPosition += Double(capacity) }
            let earlierIndex = Int(floor(readPosition)) % capacity
            let laterIndex = (earlierIndex + 1) % capacity
            let fraction = Float(readPosition - floor(readPosition))
            outputLeft[frame] = leftStorage[earlierIndex] + (leftStorage[laterIndex] - leftStorage[earlierIndex]) * fraction
            outputRight[frame] = rightStorage[earlierIndex] + (rightStorage[laterIndex] - rightStorage[earlierIndex]) * fraction
            writeIndex = (writeIndex + 1) % capacity
        }
        currentDelayFrames = target
    }

    func processForTesting(left: [Float], right: [Float]) -> (left: [Float], right: [Float]) {
        precondition(left.count == right.count)
        var outputLeft = [Float](repeating: 0, count: left.count)
        var outputRight = [Float](repeating: 0, count: right.count)
        left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                outputLeft.withUnsafeMutableBufferPointer { outputLeftBuffer in
                    outputRight.withUnsafeMutableBufferPointer { outputRightBuffer in
                        process(left: leftBuffer.baseAddress!, right: rightBuffer.baseAddress!, outputLeft: outputLeftBuffer.baseAddress!, outputRight: outputRightBuffer.baseAddress!, frameCount: left.count)
                    }
                }
            }
        }
        return (outputLeft, outputRight)
    }
}
