import Darwin
import Foundation
import M5WisprBridgeCore

func runToneTest(audioDevice: AudioDevice) throws {
    let config = StreamConfig(
        sampleRateHz: UInt32(max(8_000, audioDevice.nominalSampleRate.rounded())),
        bitsPerSample: 16,
        channels: 1,
        samplesPerPacket: 160,
        streamHeaderBytes: 8
    )
    let output = try AudioQueuePCMOutput(config: config, device: audioDevice)
    let sampleRate = Double(config.sampleRateHz)
    let frequency = 440.0
    let amplitude = 12_000.0
    let chunkFrames = max(1, Int(config.sampleRateHz) / 100)
    let chunks = 500
    var phase = 0.0
    let phaseStep = (2.0 * Double.pi * frequency) / sampleRate

    print("Playing 5 second test tone into \(audioDevice.name). Wispr Flow should show input activity if it is listening to the matching BlackHole input.")

    for _ in 0..<chunks {
        var pcm = Data(capacity: chunkFrames * MemoryLayout<Int16>.size)
        for _ in 0..<chunkFrames {
            let sample = Int16((sin(phase) * amplitude).rounded())
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { pcm.append(contentsOf: $0) }
            phase += phaseStep
            if phase >= 2.0 * Double.pi {
                phase -= 2.0 * Double.pi
            }
        }
        try output.enqueueTonePCM(pcm, sampleRateHz: config.sampleRateHz, channels: config.channels)
        usleep(10_000)
    }

    usleep(300_000)
    print("Tone test complete.")
}
