import Foundation
import os

/// Single-producer / single-consumer stereo ring of audio samples.
///
/// The Core Audio IO proc writes from a real-time thread; the renderer reads from
/// the main thread once per frame. The critical section is a bounded `memcpy`, far
/// shorter than the buffer duration it protects.
///
/// The lock is a raw `os_unfair_lock` rather than `OSAllocatedUnfairLock` because the
/// closure-based API can't take the unsafe pointers this class traffics in without
/// tripping Swift 6's `Sendable` checks — and a real-time audio path is the last
/// place to be smuggling values through a `@Sendable` closure.
final class AudioRingBuffer: @unchecked Sendable {
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    private var writeIndex = 0
    private var totalFrames = 0

    init(capacity: Int = 1 << 15) {
        self.capacity = capacity
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        left.deinitialize(count: capacity)
        right.deinitialize(count: capacity)
        left.deallocate()
        right.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Total frames ever written — lets the UI tell "silent" apart from "not running".
    var framesWritten: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return totalFrames
    }

    func write(left leftSource: UnsafePointer<Float>,
               right rightSource: UnsafePointer<Float>,
               count: Int) {
        guard count > 0 else { return }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        // A burst larger than the ring can only leave its tail behind.
        let n = min(count, capacity)
        let skip = count - n
        let firstChunk = min(n, capacity - writeIndex)
        (left + writeIndex).update(from: leftSource + skip, count: firstChunk)
        (right + writeIndex).update(from: rightSource + skip, count: firstChunk)
        if firstChunk < n {
            left.update(from: leftSource + skip + firstChunk, count: n - firstChunk)
            right.update(from: rightSource + skip + firstChunk, count: n - firstChunk)
        }
        writeIndex = (writeIndex + n) % capacity
        totalFrames += n
    }

    /// Copies the most recent `count` frames of both channels in chronological order.
    func readLatest(left leftDestination: UnsafeMutablePointer<Float>,
                    right rightDestination: UnsafeMutablePointer<Float>,
                    count: Int) {
        let n = min(count, capacity)
        os_unfair_lock_lock(lock)
        let start = ((writeIndex - n) % capacity + capacity) % capacity
        let firstChunk = min(n, capacity - start)
        leftDestination.update(from: left + start, count: firstChunk)
        rightDestination.update(from: right + start, count: firstChunk)
        if firstChunk < n {
            (leftDestination + firstChunk).update(from: left, count: n - firstChunk)
            (rightDestination + firstChunk).update(from: right, count: n - firstChunk)
        }
        os_unfair_lock_unlock(lock)

        if count > n {
            (leftDestination + n).update(repeating: 0, count: count - n)
            (rightDestination + n).update(repeating: 0, count: count - n)
        }
    }

    func clear() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        left.update(repeating: 0, count: capacity)
        right.update(repeating: 0, count: capacity)
        writeIndex = 0
    }
}
