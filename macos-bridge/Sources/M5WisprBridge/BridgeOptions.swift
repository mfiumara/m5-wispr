import Foundation

struct BridgeOptions {
    static let serviceUUIDString = "b3d7f070-3f2d-4c2e-94b8-1f0a95b7a100"
    static let streamCharacteristicUUIDString = "b3d7f071-3f2d-4c2e-94b8-1f0a95b7a100"
    static let configCharacteristicUUIDString = "b3d7f072-3f2d-4c2e-94b8-1f0a95b7a100"

    var deviceName = "m5sticks3"
    var audioDeviceName = "BlackHole"
    var audioDeviceUID: String?
    var peripheralID: UUID?
    var listAudioDevices = false
    var selfTest = false
    var toneTest = false
    var showHelp = false
    var reconnect = true

    static func parse(arguments: [String]) throws -> BridgeOptions {
        var options = BridgeOptions()
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "-h", "--help":
                options.showHelp = true
            case "--device-name":
                options.deviceName = try value(after: argument, in: arguments, index: &index)
            case "--audio-device":
                options.audioDeviceName = try value(after: argument, in: arguments, index: &index)
            case "--audio-device-uid":
                options.audioDeviceUID = try value(after: argument, in: arguments, index: &index)
            case "--peripheral-id":
                let rawValue = try value(after: argument, in: arguments, index: &index)
                guard let uuid = UUID(uuidString: rawValue) else {
                    throw OptionError.invalidUUID(rawValue)
                }
                options.peripheralID = uuid
            case "--list-audio-devices":
                options.listAudioDevices = true
            case "--self-test":
                options.selfTest = true
            case "--tone-test":
                options.toneTest = true
            case "--no-reconnect":
                options.reconnect = false
            default:
                throw OptionError.unknownArgument(argument)
            }

            index += 1
        }

        return options
    }

    static let usage = """
    Usage:
      swift run m5-wispr-bridge [options]

    Options:
      --device-name NAME        BLE peripheral name to connect to. Default: m5sticks3
      --audio-device NAME       CoreAudio output device name substring. Default: BlackHole
      --audio-device-uid UID    Exact CoreAudio output device UID. Overrides --audio-device.
      --peripheral-id UUID      Exact CoreBluetooth peripheral identifier.
      --list-audio-devices      Print CoreAudio devices and exit.
      --self-test               Run parser self-tests and exit.
      --tone-test               Play a 5 second test tone into the selected output and exit.
      --no-reconnect            Exit after a BLE disconnect instead of scanning again.
      -h, --help                Show this help.

    Fixed BLE UUIDs:
      service: \(serviceUUIDString)
      stream:  \(streamCharacteristicUUIDString)
      config:  \(configCharacteristicUUIDString)
    """

    private static func value(
        after flag: String,
        in arguments: [String],
        index: inout Int
    ) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw OptionError.missingValue(flag)
        }
        index = valueIndex
        return arguments[valueIndex]
    }
}

enum OptionError: Error, CustomStringConvertible {
    case missingValue(String)
    case unknownArgument(String)
    case invalidUUID(String)

    var description: String {
        switch self {
        case .missingValue(let flag):
            return "missing value for \(flag)"
        case .unknownArgument(let argument):
            return "unknown argument \(argument)"
        case .invalidUUID(let value):
            return "invalid UUID \(value)"
        }
    }
}
