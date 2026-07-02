import Foundation
import M5WisprBridgeCore

func printAudioDevices() throws {
    let devices = try AudioDeviceRegistry.allDevices()
        .sorted { left, right in
            left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }

    for device in devices {
        print(
            "\(device.outputChannels > 0 ? "out" : "   ") " +
                "\(device.inputChannels > 0 ? "in" : "  ")  " +
                "\(device.name)  " +
                "uid=\(device.uid)  " +
                "channels=\(device.inputChannels)in/\(device.outputChannels)out  " +
                "rate=\(Int(device.nominalSampleRate.rounded()))Hz"
        )
    }
}

do {
    let options = try BridgeOptions.parse(arguments: CommandLine.arguments)

    if options.showHelp {
        print(BridgeOptions.usage)
        exit(0)
    }

    if options.selfTest {
        try runSelfTest()
        exit(0)
    }

    if options.listAudioDevices {
        try printAudioDevices()
        exit(0)
    }

    let audioDevice = try AudioDeviceRegistry.findOutputDevice(
        nameQuery: options.audioDeviceName,
        uid: options.audioDeviceUID
    )

    print("Using CoreAudio output: \(audioDevice.name) (\(audioDevice.outputChannels) channel(s), \(Int(audioDevice.nominalSampleRate.rounded())) Hz)")
    print("Output UID: \(audioDevice.uid)")
    print("Wispr Flow should use the matching BlackHole input device as its microphone.")

    if options.toneTest {
        try runToneTest(audioDevice: audioDevice)
        exit(0)
    }

    let bridge = BLEPCMBridge(options: options, audioDevice: audioDevice)
    bridge.start()
    RunLoop.main.run()
} catch {
    fputs("error: \(error)\n\n\(BridgeOptions.usage)\n", stderr)
    exit(1)
}
