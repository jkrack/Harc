import Foundation
import os.lock
import Synchronization
@preconcurrency import AVFoundation

/// A claimed preallocated tap buffer. Release it promptly after conversion.
public final class HarcMobileAudioHandoffLease: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let hostTime: UInt64
    public let droppedInputFramesBeforeThisBuffer: UInt64

    fileprivate let slot: Int

    fileprivate init(
        slot: Int,
        buffer: AVAudioPCMBuffer,
        hostTime: UInt64,
        droppedInputFramesBeforeThisBuffer: UInt64
    ) {
        self.slot = slot
        self.buffer = buffer
        self.hostTime = hostTime
        self.droppedInputFramesBeforeThisBuffer =
            droppedInputFramesBeforeThisBuffer
    }
}

/// Fixed-capacity bridge between the Core Audio callback and a writer queue.
///
/// The callback uses a try-lock and copies only into buffers allocated at
/// initialization. It never blocks, allocates, hashes, writes, or calls UI.
public final class HarcMobileAudioHandoff: @unchecked Sendable {
    public let available = DispatchSemaphore(value: 0)

    private enum SlotState { case free, ready, consuming }
    private struct Slot {
        let buffer: AVAudioPCMBuffer
        let byteCapacities: [UInt32]
        var state: SlotState = .free
        var hostTime: UInt64 = 0
        var droppedFramesBefore: UInt64 = 0
    }

    private var lock = os_unfair_lock_s()
    private var slots: [Slot]
    private var writeCursor = 0
    private var readCursor = 0
    private var pendingDroppedFrames: UInt64 = 0
    private let contendedDroppedFrames = Atomic<UInt64>(0)

    public init(
        format: AVAudioFormat,
        frameCapacity: AVAudioFrameCount,
        slotCount: Int = 8
    ) throws {
        guard frameCapacity > 0, slotCount >= 2 else {
            throw HarcMobileAudioConversionError.allocationFailed
        }
        var made: [Slot] = []
        made.reserveCapacity(slotCount)
        for _ in 0..<slotCount {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCapacity
            ) else {
                throw HarcMobileAudioConversionError.allocationFailed
            }
            buffer.frameLength = frameCapacity
            let capacities = UnsafeMutableAudioBufferListPointer(
                buffer.mutableAudioBufferList
            ).map(\.mDataByteSize)
            buffer.frameLength = 0
            made.append(Slot(buffer: buffer, byteCapacities: capacities))
        }
        slots = made
    }

    /// Real-time callback entry point. `false` means the buffer was dropped.
    @discardableResult
    public func offer(
        _ source: AVAudioPCMBuffer,
        hostTime: UInt64
    ) -> Bool {
        guard os_unfair_lock_trylock(&lock) else {
            contendedDroppedFrames.wrappingAdd(
                UInt64(source.frameLength),
                ordering: .relaxed
            )
            return false
        }
        defer { os_unfair_lock_unlock(&lock) }
        pendingDroppedFrames &+= contendedDroppedFrames.exchange(
            0,
            ordering: .acquiringAndReleasing
        )
        guard let index = nextFreeSlot() else {
            pendingDroppedFrames &+= UInt64(source.frameLength)
            return false
        }
        let destination = slots[index].buffer
        guard source.format == destination.format,
              source.frameLength <= destination.frameCapacity,
              copy(
                  source,
                  into: destination,
                  byteCapacities: slots[index].byteCapacities
              ) else {
            pendingDroppedFrames &+= UInt64(source.frameLength)
            return false
        }
        slots[index].hostTime = hostTime
        slots[index].droppedFramesBefore = pendingDroppedFrames
        pendingDroppedFrames = 0
        slots[index].state = .ready
        writeCursor = (index + 1) % slots.count
        available.signal()
        return true
    }

    public func take() -> HarcMobileAudioHandoffLease? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let index = nextReadySlot() else { return nil }
        slots[index].state = .consuming
        readCursor = (index + 1) % slots.count
        return HarcMobileAudioHandoffLease(
            slot: index,
            buffer: slots[index].buffer,
            hostTime: slots[index].hostTime,
            droppedInputFramesBeforeThisBuffer:
                slots[index].droppedFramesBefore
        )
    }

    public func release(_ lease: HarcMobileAudioHandoffLease) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard slots.indices.contains(lease.slot),
              slots[lease.slot].state == .consuming else { return }
        slots[lease.slot].buffer.frameLength = 0
        slots[lease.slot].state = .free
    }

    public var isEmpty: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return !slots.contains { $0.state == .ready }
    }

    /// Claims drops that occurred after the last accepted buffer.
    public func takePendingDroppedInputFrames() -> UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let result = pendingDroppedFrames &+ contendedDroppedFrames.exchange(
            0,
            ordering: .acquiringAndReleasing
        )
        pendingDroppedFrames = 0
        return result
    }

    private func nextFreeSlot() -> Int? {
        for offset in slots.indices {
            let index = (writeCursor + offset) % slots.count
            if slots[index].state == .free { return index }
        }
        return nil
    }

    private func nextReadySlot() -> Int? {
        for offset in slots.indices {
            let index = (readCursor + offset) % slots.count
            if slots[index].state == .ready { return index }
        }
        return nil
    }

    private func copy(
        _ source: AVAudioPCMBuffer,
        into destination: AVAudioPCMBuffer,
        byteCapacities: [UInt32]
    ) -> Bool {
        let sourceList = UnsafeMutableAudioBufferListPointer(
            source.mutableAudioBufferList
        )
        let destinationList = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )
        guard sourceList.count == destinationList.count,
              byteCapacities.count == destinationList.count else { return false }
        for index in sourceList.indices {
            let byteCount = Int(sourceList[index].mDataByteSize)
            guard byteCount <= Int(byteCapacities[index]),
                  let sourceData = sourceList[index].mData,
                  let destinationData = destinationList[index].mData else {
                return false
            }
            memcpy(destinationData, sourceData, byteCount)
            destinationList[index].mDataByteSize = UInt32(byteCount)
        }
        destination.frameLength = source.frameLength
        return true
    }
}
