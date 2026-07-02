import CoreAudio
import Foundation

public struct AudioDevice: Equatable, Sendable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let nominalSampleRate: Double
}

public enum AudioDeviceRegistry {
    public static func allDevices() throws -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        try check(
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize
            ),
            "read CoreAudio device list size"
        )

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else {
            return []
        }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        try ids.withUnsafeMutableBytes { rawBuffer in
            try check(
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &dataSize,
                    rawBuffer.baseAddress!
                ),
                "read CoreAudio device list"
            )
        }

        return ids.compactMap { id in
            guard let name = stringProperty(deviceID: id, selector: kAudioObjectPropertyName),
                  let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID) else {
                return nil
            }

            return AudioDevice(
                id: id,
                name: name,
                uid: uid,
                inputChannels: channelCount(deviceID: id, scope: kAudioDevicePropertyScopeInput),
                outputChannels: channelCount(deviceID: id, scope: kAudioDevicePropertyScopeOutput),
                nominalSampleRate: nominalSampleRate(deviceID: id)
            )
        }
    }

    public static func outputDevices() throws -> [AudioDevice] {
        try allDevices().filter { $0.outputChannels > 0 }
    }

    public static func findOutputDevice(nameQuery: String?, uid: String?) throws -> AudioDevice {
        let outputs = try outputDevices()

        if let uid, !uid.isEmpty {
            guard let device = outputs.first(where: { $0.uid == uid }) else {
                throw AudioDeviceError.outputDeviceNotFound("uid \(uid)")
            }
            return device
        }

        let query = (nameQuery?.isEmpty == false ? nameQuery : "BlackHole") ?? "BlackHole"
        guard let device = outputs.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) else {
            throw AudioDeviceError.outputDeviceNotFound("name containing \(query)")
        }

        return device
    }

    private static func stringProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                UnsafeMutableRawPointer(pointer)
            )
        }

        guard status == noErr else {
            return nil
        }

        return value as String
    }

    private static func channelCount(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return 0
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            rawBuffer.deallocate()
        }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawBuffer) == noErr else {
            return 0
        }

        let audioBufferList = rawBuffer.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(audioBufferList).reduce(0) { total, buffer in
            total + Int(buffer.mNumberChannels)
        }
    }

    private static func nominalSampleRate(deviceID: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Float64(0)
        var dataSize = UInt32(MemoryLayout<Float64>.size)

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value) == noErr,
              value > 0 else {
            return 0
        }

        return Double(value)
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw AudioDeviceError.coreAudioFailure(operation: operation, status: status)
        }
    }
}

public enum AudioDeviceError: Error, CustomStringConvertible {
    case coreAudioFailure(operation: String, status: OSStatus)
    case outputDeviceNotFound(String)

    public var description: String {
        switch self {
        case .coreAudioFailure(let operation, let status):
            return "\(operation) failed with OSStatus \(status)"
        case .outputDeviceNotFound(let query):
            return "no CoreAudio output device found for \(query)"
        }
    }
}
