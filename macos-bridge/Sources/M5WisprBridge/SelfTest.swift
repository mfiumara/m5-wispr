import Foundation
import M5WisprBridgeCore

func runSelfTest() throws {
    let configData = Data([
        0x4d, 0x35, 0x57, 0x31,
        0x80, 0x3e, 0x00, 0x00,
        0x10,
        0x01,
        0xa0, 0x00,
        0x08, 0x00, 0x00, 0x00
    ])

    let config = try StreamConfig.parse(configData)
    try require(config.sampleRateHz, equals: 16_000, label: "sample rate")
    try require(config.bitsPerSample, equals: 16, label: "bits per sample")
    try require(config.channels, equals: 1, label: "channels")
    try require(config.samplesPerPacket, equals: 160, label: "samples per packet")
    try require(config.streamHeaderBytes, equals: 8, label: "header bytes")

    let packetData = Data([
        0x2a, 0x00, 0x00, 0x00,
        0x01,
        0x01,
        0x03, 0x00,
        0x00, 0x00,
        0xff, 0x7f,
        0x00, 0x80
    ])

    let packet = try PCMStreamPacket.parse(packetData)
    try require(packet.sequence, equals: 42, label: "packet sequence")
    try require(packet.isStart, equals: true, label: "start flag")
    try require(packet.isStop, equals: false, label: "stop flag")
    try require(packet.channels, equals: 1, label: "packet channels")
    try require(packet.sampleCount, equals: 3, label: "sample count")
    try require(packet.pcmData, equals: Data([0x00, 0x00, 0xff, 0x7f, 0x00, 0x80]), label: "pcm payload")

    let truncatedPacket = Data([
        0x01, 0x00, 0x00, 0x00,
        0x00,
        0x01,
        0x02, 0x00,
        0x11, 0x22
    ])

    do {
        _ = try PCMStreamPacket.parse(truncatedPacket)
        throw SelfTestError.failure("truncated packet was accepted")
    } catch StreamProtocolError.packetLengthMismatch(let expectedBytes, let actualBytes) {
        try require(expectedBytes, equals: 12, label: "truncated expected length")
        try require(actualBytes, equals: 10, label: "truncated actual length")
    }

    print("self-test passed: config and PCM packet parsers")
}

private func require<T: Equatable>(_ actual: T, equals expected: T, label: String) throws {
    guard actual == expected else {
        throw SelfTestError.failure("\(label): expected \(expected), got \(actual)")
    }
}

private enum SelfTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message):
            return "self-test failed: \(message)"
        }
    }
}
