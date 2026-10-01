import AudioToolbox
import CoreAudio
import Foundation

/// Everything the real-time IO callback touches, in one object the callback owns.
///
/// The callback must not depend on the lifetime of whoever installed it. Capturing
/// the tap weakly looks safe but isn't: ARC may release the tap the moment its last
/// use goes out of scope, after which the callback quietly stops doing anything and
/// the visualizer just sits at zero. Capturing this sink strongly instead ties the
/// audio path's lifetime to the IO proc itself, where it belongs.
final class TapSink: @unchecked Sendable {
    let ring: AudioRingBuffer
    private var scratchLeft: [Float]
    private var scratchRight: [Float]
    /// Written from the IO thread, read for diagnostics — approximate by design.
    private(set) var callbackCount = 0

    init(ring: AudioRingBuffer, maximumFrames: Int = 8192) {
        self.ring = ring
        scratchLeft = .init(repeating: 0, count: maximumFrames)
        scratchRight = .init(repeating: 0, count: maximumFrames)
    }

    func resetStatistics() { callbackCount = 0 }

    /// Splits the tap's audio into left/right, handling planar, interleaved and mono.
    func receive(_ bufferList: UnsafePointer<AudioBufferList>) {
        callbackCount += 1
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = buffers.first, first.mDataByteSize > 0, first.mData != nil else { return }

        if buffers.count > 1 {
            // Planar: one buffer per channel.
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0,
                  let leftData = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let rightData = buffers.count > 1
                ? (buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? leftData)
                : leftData
            ring.write(left: leftData, right: rightData, count: min(frames, scratchLeft.count))
        } else {
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            guard frames > 0, let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
            let n = min(frames, scratchLeft.count)

            if channels == 1 {
                ring.write(left: data, right: data, count: n)
            } else {
                scratchLeft.withUnsafeMutableBufferPointer { leftOut in
                    scratchRight.withUnsafeMutableBufferPointer { rightOut in
                        guard let leftBase = leftOut.baseAddress,
                              let rightBase = rightOut.baseAddress else { return }
                        for i in 0..<n {
                            leftBase[i] = data[i * channels]
                            rightBase[i] = data[i * channels + 1]
                        }
                        ring.write(left: leftBase, right: rightBase, count: n)
                    }
                }
            }
        }
    }
}
