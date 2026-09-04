import Foundation
import Synchronization

public struct AudioTransportCounters: Sendable, Equatable {
    public let capturedFrames: UInt64
    public let renderedFrames: UInt64
    public let underflowCallbacks: UInt64
    public let overflowCallbacks: UInt64
    public let droppedFrames: UInt64

    public init(capturedFrames: UInt64 = 0, renderedFrames: UInt64 = 0, underflowCallbacks: UInt64 = 0, overflowCallbacks: UInt64 = 0, droppedFrames: UInt64 = 0) {
        self.capturedFrames = capturedFrames
        self.renderedFrames = renderedFrames
        self.underflowCallbacks = underflowCallbacks
        self.overflowCallbacks = overflowCallbacks
        self.droppedFrames = droppedFrames
    }
}

/// A preallocated single-producer/single-consumer stereo FIFO. The producer and
/// consumer own separate monotonic indices; neither callback waits for the other.
public final class StereoRingBuffer: @unchecked Sendable {
    public let capacityFrames: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let readPosition = Atomic<Int>(0)
    private let writePosition = Atomic<Int>(0)
    private let capturedFrames = Atomic<UInt64>(0)
    private let renderedFrames = Atomic<UInt64>(0)
    private let underflows = Atomic<UInt64>(0)
    private let overflows = Atomic<UInt64>(0)
    private let droppedFrames = Atomic<UInt64>(0)

    public init(capacityFrames: Int) {
        precondition(capacityFrames > 0)
        self.capacityFrames = capacityFrames
        left = .allocate(capacity: capacityFrames)
        right = .allocate(capacity: capacityFrames)
        left.initialize(repeating: 0, count: capacityFrames)
        right.initialize(repeating: 0, count: capacityFrames)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    public var availableFrames: Int {
        max(0, writePosition.load(ordering: .acquiring) - readPosition.load(ordering: .acquiring))
    }

    /// Writes as much of the block as fits and drops its newest tail on overflow.
    @discardableResult
    public func write(left inputLeft: UnsafePointer<Float>, right inputRight: UnsafePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let write = writePosition.load(ordering: .relaxed)
        let read = readPosition.load(ordering: .acquiring)
        let accepted = min(frameCount, max(0, capacityFrames - (write - read)))
        copy(source: inputLeft, destination: left, position: write, count: accepted)
        copy(source: inputRight, destination: right, position: write, count: accepted)
        writePosition.store(write + accepted, ordering: .releasing)
        capturedFrames.wrappingAdd(UInt64(accepted), ordering: .relaxed)
        if accepted < frameCount {
            overflows.wrappingAdd(1, ordering: .relaxed)
            droppedFrames.wrappingAdd(UInt64(frameCount - accepted), ordering: .relaxed)
        }
        return accepted
    }

    /// Reads available frames and zero-fills the remainder on underflow.
    @discardableResult
    public func read(left outputLeft: UnsafeMutablePointer<Float>, right outputRight: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let read = readPosition.load(ordering: .relaxed)
        let write = writePosition.load(ordering: .acquiring)
        let fetched = min(frameCount, max(0, write - read))
        copy(source: left, destination: outputLeft, position: read, count: fetched)
        copy(source: right, destination: outputRight, position: read, count: fetched)
        if fetched < frameCount {
            outputLeft.advanced(by: fetched).initialize(repeating: 0, count: frameCount - fetched)
            outputRight.advanced(by: fetched).initialize(repeating: 0, count: frameCount - fetched)
            underflows.wrappingAdd(1, ordering: .relaxed)
        }
        readPosition.store(read + fetched, ordering: .releasing)
        renderedFrames.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
        return fetched
    }

    public func discardAll() {
        // Call only while producer/consumer AudioUnits are stopped or programme
        // capture is suspended.
        readPosition.store(writePosition.load(ordering: .acquiring), ordering: .releasing)
    }

    public func counters() -> AudioTransportCounters {
        AudioTransportCounters(
            capturedFrames: capturedFrames.load(ordering: .relaxed),
            renderedFrames: renderedFrames.load(ordering: .relaxed),
            underflowCallbacks: underflows.load(ordering: .relaxed),
            overflowCallbacks: overflows.load(ordering: .relaxed),
            droppedFrames: droppedFrames.load(ordering: .relaxed)
        )
    }

    private func copy(source: UnsafePointer<Float>, destination: UnsafeMutablePointer<Float>, position: Int, count: Int) {
        guard count > 0 else { return }
        let offset = position % capacityFrames
        let first = min(count, capacityFrames - offset)
        memcpy(destination.advanced(by: offset), source, first * MemoryLayout<Float>.size)
        if first < count {
            memcpy(destination, source.advanced(by: first), (count - first) * MemoryLayout<Float>.size)
        }
    }

    private func copy(source: UnsafeMutablePointer<Float>, destination: UnsafeMutablePointer<Float>, position: Int, count: Int) {
        guard count > 0 else { return }
        let offset = position % capacityFrames
        let first = min(count, capacityFrames - offset)
        memcpy(destination, source.advanced(by: offset), first * MemoryLayout<Float>.size)
        if first < count {
            memcpy(destination.advanced(by: first), source, (count - first) * MemoryLayout<Float>.size)
        }
    }
}
