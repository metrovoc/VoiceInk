import Foundation

/// A fixed-capacity PCM store with absolute sample addressing.
///
/// Samples are copied into fixed-size blocks held by a circular table. Appends
/// and front trims never shift the retained audio, and released blocks are
/// immediately reusable. The store seals instead of evicting audio when its
/// capacity is exhausted: callers must fall back to the complete recording
/// rather than transcribe a silently discontinuous realtime stream.
final class SegmentedPCMBuffer: @unchecked Sendable {
    enum BufferError: Error, Equatable {
        case capacityExceeded(
            maximumSamples: Int,
            retainedSamples: Int,
            incomingSamples: Int
        )
        case unavailableRange(
            requested: Range<Int64>,
            retained: Range<Int64>
        )
        case windowTooLarge(maximumSamples: Int, requestedSamples: Int)
    }

    struct Window: Sendable, Equatable {
        let range: Range<Int64>
        let samples: [Float]
    }

    struct Snapshot: Sendable, Equatable {
        let retainedRange: Range<Int64>
        let retainedSamples: Int
        let blockCount: Int
        let blockSlotCapacity: Int
        let peakRetainedSamples: Int
        let peakBlockCount: Int
        let totalAppendedSamples: Int64
        let totalDiscardedSamples: Int64
        let isSealed: Bool
    }

    private final class Block {
        let absoluteStart: Int64
        var samples: [Float]
        var readableIndex = 0

        init(absoluteStart: Int64, capacity: Int) {
            self.absoluteStart = absoluteStart
            samples = []
            samples.reserveCapacity(capacity)
        }

        var absoluteReadableStart: Int64 {
            absoluteStart + Int64(readableIndex)
        }

        var absoluteEnd: Int64 {
            absoluteStart + Int64(samples.count)
        }

        var readableCount: Int {
            samples.count - readableIndex
        }
    }

    let maximumRetainedSamples: Int
    let blockSize: Int

    private let lock = NSLock()
    private var blocks: [Block?]
    private var head = 0
    private var blockCount = 0
    private var absoluteEnd: Int64 = 0
    private var retainedSamples = 0
    private var peakRetainedSamples = 0
    private var peakBlockCount = 0
    private var totalAppendedSamples: Int64 = 0
    private var totalDiscardedSamples: Int64 = 0
    private var sealedError: BufferError?

    init(maximumRetainedSamples: Int, blockSize: Int = 4_096) {
        precondition(maximumRetainedSamples > 0)
        precondition(blockSize > 0)
        self.maximumRetainedSamples = maximumRetainedSamples
        self.blockSize = blockSize

        // A partially consumed head block can coexist with ceil(capacity / block)
        // subsequent blocks. One spare slot keeps insertion independent of
        // alignment while the sample-count limit remains the true memory bound.
        let slots = ((maximumRetainedSamples + blockSize - 1) / blockSize) + 1
        blocks = Array(repeating: nil, count: slots)
    }

    @discardableResult
    func append(_ samples: [Float]) throws -> Range<Int64> {
        lock.lock()
        defer { lock.unlock() }

        if let sealedError {
            throw sealedError
        }

        let rangeStart = absoluteEnd
        guard !samples.isEmpty else { return rangeStart..<rangeStart }

        guard samples.count <= maximumRetainedSamples - retainedSamples else {
            let error = BufferError.capacityExceeded(
                maximumSamples: maximumRetainedSamples,
                retainedSamples: retainedSamples,
                incomingSamples: samples.count
            )
            sealedError = error
            throw error
        }

        var sourceIndex = 0
        while sourceIndex < samples.count {
            let block = writableTailBlockLocked()
            let copyCount = min(blockSize - block.samples.count, samples.count - sourceIndex)
            block.samples.append(contentsOf: samples[sourceIndex..<(sourceIndex + copyCount)])
            sourceIndex += copyCount
            absoluteEnd += Int64(copyCount)
            retainedSamples += copyCount
        }

        totalAppendedSamples += Int64(samples.count)
        peakRetainedSamples = max(peakRetainedSamples, retainedSamples)
        peakBlockCount = max(peakBlockCount, blockCount)
        return rangeStart..<absoluteEnd
    }

    /// Releases every retained sample strictly before `absoluteOffset`.
    /// Each block is released at most once over the lifetime of the stream.
    func discard(before absoluteOffset: Int64) {
        lock.lock()
        defer { lock.unlock() }

        let target = min(max(absoluteOffset, retainedStartLocked()), absoluteEnd)
        var discarded = 0

        while blockCount > 0, let block = blocks[head] {
            if target >= block.absoluteEnd {
                discarded += block.readableCount
                blocks[head] = nil
                head = (head + 1) % blocks.count
                blockCount -= 1
                continue
            }

            let readableStart = block.absoluteReadableStart
            guard target > readableStart else { break }
            let count = Int(target - readableStart)
            block.readableIndex += count
            discarded += count
            break
        }

        retainedSamples -= discarded
        totalDiscardedSamples += Int64(discarded)
    }

    /// Materializes one bounded contiguous ASR window. The requested range must
    /// still be fully retained; clamping would silently lose unconfirmed speech.
    func window(
        from absoluteStart: Int64,
        through absoluteRequestedEnd: Int64,
        maximumSamples: Int
    ) throws -> Window? {
        lock.lock()
        defer { lock.unlock() }

        let retainedRange = retainedStartLocked()..<absoluteEnd
        let requestedRange = absoluteStart..<absoluteRequestedEnd
        guard absoluteStart >= retainedRange.lowerBound,
              absoluteRequestedEnd <= retainedRange.upperBound,
              absoluteStart <= absoluteRequestedEnd else {
            throw BufferError.unavailableRange(
                requested: requestedRange,
                retained: retainedRange
            )
        }

        let requestedCount = Int(absoluteRequestedEnd - absoluteStart)
        guard requestedCount <= maximumSamples else {
            throw BufferError.windowTooLarge(
                maximumSamples: maximumSamples,
                requestedSamples: requestedCount
            )
        }
        guard requestedCount > 0 else { return nil }

        var result: [Float] = []
        result.reserveCapacity(requestedCount)

        for logicalIndex in 0..<blockCount {
            guard let block = blocks[(head + logicalIndex) % blocks.count] else {
                continue
            }
            let lower = max(absoluteStart, block.absoluteReadableStart)
            let upper = min(absoluteRequestedEnd, block.absoluteEnd)
            guard lower < upper else { continue }

            let localLower = Int(lower - block.absoluteStart)
            let localUpper = Int(upper - block.absoluteStart)
            result.append(contentsOf: block.samples[localLower..<localUpper])
        }

        guard result.count == requestedCount else {
            throw BufferError.unavailableRange(
                requested: requestedRange,
                retained: retainedRange
            )
        }
        return Window(range: requestedRange, samples: result)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            retainedRange: retainedStartLocked()..<absoluteEnd,
            retainedSamples: retainedSamples,
            blockCount: blockCount,
            blockSlotCapacity: blocks.count,
            peakRetainedSamples: peakRetainedSamples,
            peakBlockCount: peakBlockCount,
            totalAppendedSamples: totalAppendedSamples,
            totalDiscardedSamples: totalDiscardedSamples,
            isSealed: sealedError != nil
        )
    }

    func reset() {
        lock.lock()
        blocks = Array(repeating: nil, count: blocks.count)
        head = 0
        blockCount = 0
        absoluteEnd = 0
        retainedSamples = 0
        peakRetainedSamples = 0
        peakBlockCount = 0
        totalAppendedSamples = 0
        totalDiscardedSamples = 0
        sealedError = nil
        lock.unlock()
    }

    private func retainedStartLocked() -> Int64 {
        guard blockCount > 0, let block = blocks[head] else { return absoluteEnd }
        return block.absoluteReadableStart
    }

    private func writableTailBlockLocked() -> Block {
        if blockCount > 0,
           let tail = blocks[(head + blockCount - 1) % blocks.count],
           tail.samples.count < blockSize {
            return tail
        }

        precondition(blockCount < blocks.count, "PCM block table exhausted below sample capacity")
        let index = (head + blockCount) % blocks.count
        let block = Block(absoluteStart: absoluteEnd, capacity: blockSize)
        blocks[index] = block
        blockCount += 1
        return block
    }
}
