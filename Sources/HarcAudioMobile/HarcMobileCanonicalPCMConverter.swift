import Foundation
@preconcurrency import AVFoundation

public enum HarcMobileAudioConversionError: Error, Equatable, Sendable {
    case unsupportedInputFormat
    case allocationFailed
    case conversionFailed(String)
    case malformedOutput
}

/// Stateful hardware-native PCM to Harc canonical PCM converter.
///
/// Keep one instance on the capture writer queue. `AVAudioConverter` retains
/// its sample-rate filter between input blocks so normal tap boundaries do not
/// become audible discontinuities.
public final class HarcMobileCanonicalPCMConverter {
    public static let outputFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private var converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private var fractionalOutputFrames = 0.0
    private var totalInputFrames: UInt64 = 0
    private var totalOutputFrames: UInt64 = 0
    private var lastFramePlanes: [Data] = []

    public init(inputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate.isFinite,
              inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let converter = AVAudioConverter(
                  from: inputFormat,
                  to: Self.outputFormat
              ) else {
            throw HarcMobileAudioConversionError.unsupportedInputFormat
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.primeMethod = .pre
        self.inputFormat = inputFormat
        self.converter = converter
    }

    public func convert(_ input: AVAudioPCMBuffer) throws -> Data {
        guard input.format == inputFormat else {
            throw HarcMobileAudioConversionError.unsupportedInputFormat
        }
        let exactFrames = Double(input.frameLength) * 16_000
            / inputFormat.sampleRate + fractionalOutputFrames
        let expectedFrames = max(1, Int(exactFrames.rounded(.down)))
        fractionalOutputFrames = exactFrames - Double(expectedFrames)
        let capacity = AVAudioFrameCount(expectedFrames + 128)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: Self.outputFormat,
            frameCapacity: capacity
        ) else {
            throw HarcMobileAudioConversionError.allocationFailed
        }

        var conversionError: NSError?
        let provider = HarcMobileConverterInputProvider(source: input)
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { requestedFrames, inputStatus in
            provider.next(
                maximumFrames: requestedFrames,
                status: inputStatus
            )
        }
        if let providerError = provider.error { throw providerError }
        if status == .error {
            throw HarcMobileAudioConversionError.conversionFailed(
                conversionError?.localizedDescription ?? "unknown AVAudioConverter error"
            )
        }
        totalInputFrames += UInt64(input.frameLength)
        lastFramePlanes = try Self.lastFramePlanes(in: input)
        guard output.frameLength > 0 else { return Data() }
        let list = UnsafeMutableAudioBufferListPointer(
            output.mutableAudioBufferList
        )
        guard list.count == 1,
              let base = list[0].mData,
              list[0].mDataByteSize == output.frameLength * 2 else {
            throw HarcMobileAudioConversionError.malformedOutput
        }
        totalOutputFrames += UInt64(output.frameLength)
        return Data(bytes: base, count: Int(list[0].mDataByteSize))
    }

    /// Drains the sample-rate filter after the tap has been removed.
    public func finish() throws -> Data {
        let expectedFrames = UInt64(
            (Double(totalInputFrames) * 16_000 / inputFormat.sampleRate)
                .rounded(.down)
        )
        guard expectedFrames > totalOutputFrames,
              !lastFramePlanes.isEmpty else { return Data() }
        let missingFrames = expectedFrames - totalOutputFrames
        let paddingFrameCount = AVAudioFrameCount(max(
            256,
            Int(ceil(
                Double(missingFrames + 128) * inputFormat.sampleRate / 16_000
            ))
        ))
        let padding = try makeTailPadding(frameCount: paddingFrameCount)
        let capacity = AVAudioFrameCount(missingFrames + 256)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: Self.outputFormat,
            frameCapacity: capacity
        ) else {
            throw HarcMobileAudioConversionError.allocationFailed
        }
        var conversionError: NSError?
        let provider = HarcMobileConverterInputProvider(source: padding)
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { requestedFrames, inputStatus in
            provider.next(maximumFrames: requestedFrames, status: inputStatus)
        }
        if let providerError = provider.error { throw providerError }
        if status == .error {
            throw HarcMobileAudioConversionError.conversionFailed(
                conversionError?.localizedDescription
                    ?? "unknown AVAudioConverter drain error"
            )
        }
        guard UInt64(output.frameLength) >= missingFrames else {
            throw HarcMobileAudioConversionError.conversionFailed(
                "sample-rate converter did not drain its held frames"
            )
        }
        let list = UnsafeMutableAudioBufferListPointer(
            output.mutableAudioBufferList
        )
        guard list.count == 1, let base = list[0].mData else {
            throw HarcMobileAudioConversionError.malformedOutput
        }
        totalOutputFrames += missingFrames
        return Data(bytes: base, count: Int(missingFrames * 2))
    }

    private static func lastFramePlanes(
        in input: AVAudioPCMBuffer
    ) throws -> [Data] {
        guard input.frameLength > 0 else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(
            input.mutableAudioBufferList
        )
        return try list.map { buffer in
            guard let base = buffer.mData else {
                throw HarcMobileAudioConversionError.unsupportedInputFormat
            }
            let bytesPerFrame = Int(buffer.mDataByteSize)
                / Int(input.frameLength)
            return Data(
                bytes: base.advanced(
                    by: (Int(input.frameLength) - 1) * bytesPerFrame
                ),
                count: bytesPerFrame
            )
        }
    }

    private func makeTailPadding(
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let padding = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: frameCount
        ) else {
            throw HarcMobileAudioConversionError.allocationFailed
        }
        padding.frameLength = frameCount
        let list = UnsafeMutableAudioBufferListPointer(
            padding.mutableAudioBufferList
        )
        guard list.count == lastFramePlanes.count else {
            throw HarcMobileAudioConversionError.unsupportedInputFormat
        }
        for index in list.indices {
            guard let destination = list[index].mData else {
                throw HarcMobileAudioConversionError.unsupportedInputFormat
            }
            let frame = lastFramePlanes[index]
            frame.withUnsafeBytes { source in
                guard let sourceBase = source.baseAddress else { return }
                for outputFrame in 0..<Int(frameCount) {
                    memcpy(
                        destination.advanced(by: outputFrame * frame.count),
                        sourceBase,
                        frame.count
                    )
                }
            }
            list[index].mDataByteSize = UInt32(Int(frameCount) * frame.count)
        }
        return padding
    }
}

private final class HarcMobileConverterInputProvider: @unchecked Sendable {
    let source: AVAudioPCMBuffer
    var cursor: AVAudioFrameCount = 0
    var error: HarcMobileAudioConversionError?

    init(source: AVAudioPCMBuffer) { self.source = source }

    func next(
        maximumFrames: AVAudioPacketCount,
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        guard error == nil, cursor < source.frameLength else {
            status.pointee = .noDataNow
            return nil
        }
        let remaining = source.frameLength - cursor
        let count = min(remaining, AVAudioFrameCount(maximumFrames))
        guard count > 0 else {
            status.pointee = .noDataNow
            return nil
        }
        if cursor == 0, count == source.frameLength {
            cursor = source.frameLength
            status.pointee = .haveData
            return source
        }
        guard let slice = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: count
        ) else {
            error = .allocationFailed
            status.pointee = .noDataNow
            return nil
        }
        slice.frameLength = count
        let sourceList = UnsafeMutableAudioBufferListPointer(
            source.mutableAudioBufferList
        )
        let destinationList = UnsafeMutableAudioBufferListPointer(
            slice.mutableAudioBufferList
        )
        guard sourceList.count == destinationList.count else {
            error = .unsupportedInputFormat
            status.pointee = .noDataNow
            return nil
        }
        for index in sourceList.indices {
            guard let sourceData = sourceList[index].mData,
                  let destinationData = destinationList[index].mData,
                  source.frameLength > 0 else {
                error = .unsupportedInputFormat
                status.pointee = .noDataNow
                return nil
            }
            let bytesPerFrame = Int(sourceList[index].mDataByteSize)
                / Int(source.frameLength)
            let byteCount = Int(count) * bytesPerFrame
            memcpy(
                destinationData,
                sourceData.advanced(by: Int(cursor) * bytesPerFrame),
                byteCount
            )
            destinationList[index].mDataByteSize = UInt32(byteCount)
        }
        cursor += count
        status.pointee = .haveData
        return slice
    }
}
