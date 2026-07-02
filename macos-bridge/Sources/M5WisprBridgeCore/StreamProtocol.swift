import Foundation

public struct StreamConfig: Equatable, Sendable {
    public static let defaultValue = StreamConfig(
        sampleRateHz: 16_000,
        bitsPerSample: 16,
        channels: 1,
        samplesPerPacket: 0,
        streamHeaderBytes: 8
    )

    public let sampleRateHz: UInt32
    public let bitsPerSample: UInt8
    public let channels: UInt8
    public let samplesPerPacket: UInt16
    public let streamHeaderBytes: UInt32

    public init(
        sampleRateHz: UInt32,
        bitsPerSample: UInt8,
        channels: UInt8,
        samplesPerPacket: UInt16,
        streamHeaderBytes: UInt32
    ) {
        self.sampleRateHz = sampleRateHz
        self.bitsPerSample = bitsPerSample
        self.channels = channels
        self.samplesPerPacket = samplesPerPacket
        self.streamHeaderBytes = streamHeaderBytes
    }

    public static func parse(_ data: Data) throws -> StreamConfig {
        guard data.count >= 16 else {
            throw StreamProtocolError.configTooShort(actualBytes: data.count)
        }

        let bytes = [UInt8](data.prefix(16))
        let magic = String(decoding: bytes[0..<4], as: UTF8.self)
        guard magic == "M5W1" else {
            throw StreamProtocolError.invalidConfigMagic(magic)
        }

        let sampleRateHz = littleEndianUInt32(bytes, at: 4)
        let bitsPerSample = bytes[8]
        let channels = bytes[9]
        let samplesPerPacket = littleEndianUInt16(bytes, at: 10)
        let streamHeaderBytes = littleEndianUInt32(bytes, at: 12)

        guard sampleRateHz > 0 else {
            throw StreamProtocolError.unsupportedSampleRate(sampleRateHz)
        }
        guard bitsPerSample == 16 else {
            throw StreamProtocolError.unsupportedBitsPerSample(bitsPerSample)
        }
        guard channels > 0 else {
            throw StreamProtocolError.unsupportedChannelCount(channels)
        }

        return StreamConfig(
            sampleRateHz: sampleRateHz,
            bitsPerSample: bitsPerSample,
            channels: channels,
            samplesPerPacket: samplesPerPacket,
            streamHeaderBytes: streamHeaderBytes
        )
    }
}

public struct PCMStreamPacket: Equatable, Sendable {
    public let sequence: UInt32
    public let flags: UInt8
    public let channels: UInt8
    public let sampleCount: UInt16
    public let pcmData: Data

    public var isStart: Bool {
        flags & 0x01 != 0
    }

    public var isStop: Bool {
        flags & 0x02 != 0
    }

    public static func parse(_ data: Data) throws -> PCMStreamPacket {
        guard data.count >= 8 else {
            throw StreamProtocolError.packetTooShort(actualBytes: data.count)
        }

        let header = [UInt8](data.prefix(8))
        let sequence = littleEndianUInt32(header, at: 0)
        let flags = header[4]
        let channels = header[5]
        let sampleCount = littleEndianUInt16(header, at: 6)
        let expectedByteCount = 8 + Int(sampleCount) * MemoryLayout<Int16>.size

        guard channels > 0 else {
            throw StreamProtocolError.unsupportedChannelCount(channels)
        }
        guard data.count == expectedByteCount else {
            throw StreamProtocolError.packetLengthMismatch(
                expectedBytes: expectedByteCount,
                actualBytes: data.count
            )
        }

        return PCMStreamPacket(
            sequence: sequence,
            flags: flags,
            channels: channels,
            sampleCount: sampleCount,
            pcmData: data.subdata(in: 8..<expectedByteCount)
        )
    }
}

public enum StreamProtocolError: Error, CustomStringConvertible, Equatable {
    case configTooShort(actualBytes: Int)
    case invalidConfigMagic(String)
    case unsupportedSampleRate(UInt32)
    case unsupportedBitsPerSample(UInt8)
    case unsupportedChannelCount(UInt8)
    case packetTooShort(actualBytes: Int)
    case packetLengthMismatch(expectedBytes: Int, actualBytes: Int)

    public var description: String {
        switch self {
        case .configTooShort(let actualBytes):
            return "config characteristic is too short: \(actualBytes) bytes"
        case .invalidConfigMagic(let magic):
            return "config characteristic has invalid magic: \(magic)"
        case .unsupportedSampleRate(let sampleRate):
            return "unsupported sample rate: \(sampleRate) Hz"
        case .unsupportedBitsPerSample(let bits):
            return "unsupported bits per sample: \(bits)"
        case .unsupportedChannelCount(let channels):
            return "unsupported channel count: \(channels)"
        case .packetTooShort(let actualBytes):
            return "stream packet is too short: \(actualBytes) bytes"
        case .packetLengthMismatch(let expectedBytes, let actualBytes):
            return "stream packet length mismatch: expected \(expectedBytes), got \(actualBytes)"
        }
    }
}

private func littleEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    UInt16(bytes[offset])
        | (UInt16(bytes[offset + 1]) << 8)
}

private func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}
