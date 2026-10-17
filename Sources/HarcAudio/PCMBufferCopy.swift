@preconcurrency import AVFoundation

/// Copies whole PCM frames without assuming Float32 or planar storage. Capture
/// callbacks reuse their input memory; returned buffers own every copied byte.
enum PCMBufferCopy {
    static func copy(
        _ source: AVAudioPCMBuffer,
        repeatingLastFrame extraFrames: AVAudioFrameCount = 0
    ) throws -> AVAudioPCMBuffer {
        let (capacity, overflow) = source.frameLength.addingReportingOverflow(extraFrames)
        guard !overflow,
              let output = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: max(1, capacity))
        else { throw AudioError.conversionFailed("PCM copy allocation failed") }
        output.frameLength = capacity
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        let stride = Int(source.format.streamDescription.pointee.mBytesPerFrame)
        let inputBytes = Int(source.frameLength) * stride
        let outputBytes = Int(capacity) * stride
        guard stride > 0, sourceBuffers.count == outputBuffers.count else {
            throw AudioError.conversionFailed("PCM copy has an invalid buffer layout")
        }
        for index in sourceBuffers.indices {
            let input = sourceBuffers[index]
            let destination = outputBuffers[index]
            guard input.mNumberChannels == destination.mNumberChannels,
                  Int(input.mDataByteSize) >= inputBytes,
                  Int(destination.mDataByteSize) >= outputBytes,
                  let dst = destination.mData,
                  inputBytes == 0 || input.mData != nil
            else { throw AudioError.conversionFailed("PCM copy has incomplete frame storage") }
            if inputBytes > 0, let src = input.mData {
                dst.copyMemory(from: src, byteCount: inputBytes)
                for frame in 0..<Int(extraFrames) {
                    dst.advanced(by: inputBytes + frame * stride).copyMemory(
                        from: src.advanced(by: inputBytes - stride), byteCount: stride
                    )
                }
            } else {
                dst.initializeMemory(as: UInt8.self, repeating: 0, count: outputBytes)
            }
        }
        return output
    }
}
