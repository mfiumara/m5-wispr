import CoreBluetooth
import Darwin
import Foundation
import M5WisprBridgeCore

final class BLEPCMBridge: NSObject {
    private let options: BridgeOptions
    private let audioDevice: AudioDevice
    private let serviceUUID = CBUUID(string: BridgeOptions.serviceUUIDString)
    private let streamCharacteristicUUID = CBUUID(string: BridgeOptions.streamCharacteristicUUIDString)
    private let configCharacteristicUUID = CBUUID(string: BridgeOptions.configCharacteristicUUIDString)

    private lazy var central = CBCentralManager(delegate: self, queue: nil)
    private var peripheral: CBPeripheral?
    private var streamCharacteristic: CBCharacteristic?
    private var config: StreamConfig?
    private var audioOutput: AudioQueuePCMOutput?
    private var streamNotifyRequested = false
    private var expectedSequence: UInt32?
    private var packetsSinceLevelLog = 0

    init(options: BridgeOptions, audioDevice: AudioDevice) {
        self.options = options
        self.audioDevice = audioDevice
        super.init()
    }

    func start() {
        _ = central
    }

    private func connect(_ peripheral: CBPeripheral, reason: String) {
        central.stopScan()
        self.peripheral = peripheral
        streamCharacteristic = nil
        streamNotifyRequested = false
        expectedSequence = nil
        print("Connecting to \(displayName(for: peripheral)) (\(peripheral.identifier)) via \(reason)...")
        central.connect(peripheral, options: nil)
    }

    private func startScan() {
        print("Scanning for \(options.deviceName) or service \(BridgeOptions.serviceUUIDString)...")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func discoverOnConnectedPeripheral(_ peripheral: CBPeripheral) {
        peripheral.delegate = self
        print("Connected to \(displayName(for: peripheral)); discovering PCM service...")
        peripheral.discoverServices([serviceUUID])
    }

    private func matchesTarget(
        peripheral: CBPeripheral,
        advertisementData: [String: Any]
    ) -> Bool {
        if let peripheralID = options.peripheralID, peripheral.identifier == peripheralID {
            return true
        }

        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if peripheral.name == options.deviceName || advertisedName == options.deviceName {
            return true
        }

        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        return advertisedServices.contains(serviceUUID)
    }

    private func subscribeToStreamIfReady() {
        guard !streamNotifyRequested,
              let peripheral,
              let streamCharacteristic else {
            return
        }

        if config == nil {
            configureAudio(StreamConfig.defaultValue, source: "default 16 kHz mono fallback")
        }

        print("Subscribing to PCM stream characteristic...")
        streamNotifyRequested = true
        peripheral.setNotifyValue(true, for: streamCharacteristic)
    }

    private func configureAudio(_ newConfig: StreamConfig, source: String) {
        if config == newConfig, audioOutput != nil {
            return
        }

        do {
            audioOutput = try AudioQueuePCMOutput(config: newConfig, device: audioDevice)
            config = newConfig
            print(
                "Audio configured from \(source): \(newConfig.sampleRateHz) Hz, " +
                    "\(newConfig.bitsPerSample)-bit, \(newConfig.channels) channel(s), " +
                    "output \(audioDevice.name) at \(Int(audioDevice.nominalSampleRate.rounded())) Hz"
            )
        } catch {
            fputs("fatal: failed to configure audio output: \(error)\n", stderr)
            exit(2)
        }
    }

    private func handleStreamData(_ data: Data) {
        do {
            let packet = try PCMStreamPacket.parse(data)

            if packet.isStart {
                audioOutput?.reset()
                expectedSequence = packet.sequence &+ 1
                print("PCM stream started at sequence \(packet.sequence)")
            } else if let expectedSequence, packet.sequence != expectedSequence {
                print("warning: PCM sequence gap; expected \(expectedSequence), got \(packet.sequence)")
                self.expectedSequence = packet.sequence &+ 1
            } else {
                expectedSequence = packet.sequence &+ 1
            }

            if audioOutput == nil {
                configureAudio(config ?? .defaultValue, source: "first stream packet fallback")
            }

            logLevelIfNeeded(packet)
            try audioOutput?.enqueue(packet: packet)

            if packet.isStop {
                print("PCM stream stopped at sequence \(packet.sequence)")
                expectedSequence = nil
                packetsSinceLevelLog = 0
            }
        } catch {
            print("warning: dropped malformed PCM packet: \(error)")
        }
    }

    private func logLevelIfNeeded(_ packet: PCMStreamPacket) {
        guard !packet.pcmData.isEmpty else {
            return
        }

        packetsSinceLevelLog += 1
        guard packet.isStart || packetsSinceLevelLog >= 50 else {
            return
        }
        packetsSinceLevelLog = 0

        let stats = pcmLevelStats(packet.pcmData)
        let meter = String(repeating: "=", count: min(24, Int(stats.peak) / 1_365))
        print("PCM level avg=\(stats.average) peak=\(stats.peak) \(meter)")
    }

    private func pcmLevelStats(_ pcmData: Data) -> (average: UInt32, peak: UInt32) {
        var total: UInt64 = 0
        var peak: UInt32 = 0
        var samples: UInt32 = 0
        var index = pcmData.startIndex

        while pcmData.distance(from: index, to: pcmData.endIndex) >= 2 {
            let low = UInt16(pcmData[index])
            let high = UInt16(pcmData[pcmData.index(after: index)]) << 8
            let raw = Int16(bitPattern: low | high)
            let magnitude = raw == Int16.min ? UInt32(Int16.max) + 1 : UInt32(abs(Int(raw)))
            total += UInt64(magnitude)
            peak = max(peak, magnitude)
            samples += 1
            index = pcmData.index(index, offsetBy: 2)
        }

        return samples == 0 ? (0, 0) : (UInt32(total / UInt64(samples)), peak)
    }

    private func handleDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        if let error {
            print("Disconnected from \(displayName(for: peripheral)): \(error)")
        } else {
            print("Disconnected from \(displayName(for: peripheral))")
        }

        expectedSequence = nil
        streamCharacteristic = nil
        streamNotifyRequested = false

        guard options.reconnect else {
            exit(0)
        }

        startScan()
    }

    private func displayName(for peripheral: CBPeripheral) -> String {
        peripheral.name ?? options.deviceName
    }
}

extension BLEPCMBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if let peripheralID = options.peripheralID,
               let retrieved = central.retrievePeripherals(withIdentifiers: [peripheralID]).first {
                connect(retrieved, reason: "saved CoreBluetooth peripheral id")
                return
            }

            if let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
                connect(connected, reason: "already-connected peripheral with PCM service")
                return
            }

            startScan()
        case .poweredOff:
            print("Bluetooth is powered off.")
        case .unauthorized:
            print("Bluetooth permission is not granted for this terminal app.")
        case .unsupported:
            print("Bluetooth LE is not supported on this Mac.")
        case .resetting:
            print("Bluetooth is resetting...")
        case .unknown:
            print("Bluetooth state is unknown...")
        @unknown default:
            print("Bluetooth entered an unknown state.")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard matchesTarget(peripheral: peripheral, advertisementData: advertisementData) else {
            return
        }

        connect(peripheral, reason: "scan match, RSSI \(RSSI)")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        discoverOnConnectedPeripheral(peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        if let error {
            print("Failed to connect to \(displayName(for: peripheral)): \(error)")
        } else {
            print("Failed to connect to \(displayName(for: peripheral))")
        }
        startScan()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        handleDisconnect(peripheral, error: error)
    }
}

extension BLEPCMBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            print("Failed to discover services: \(error)")
            central.cancelPeripheralConnection(peripheral)
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            print("PCM service \(BridgeOptions.serviceUUIDString) was not found.")
            central.cancelPeripheralConnection(peripheral)
            return
        }

        peripheral.discoverCharacteristics(
            [streamCharacteristicUUID, configCharacteristicUUID],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            print("Failed to discover characteristics: \(error)")
            central.cancelPeripheralConnection(peripheral)
            return
        }

        let characteristics = service.characteristics ?? []
        streamCharacteristic = characteristics.first { $0.uuid == streamCharacteristicUUID }

        guard streamCharacteristic != nil else {
            print("PCM stream characteristic \(BridgeOptions.streamCharacteristicUUIDString) was not found.")
            central.cancelPeripheralConnection(peripheral)
            return
        }

        if let configCharacteristic = characteristics.first(where: { $0.uuid == configCharacteristicUUID }) {
            print("Reading stream config characteristic...")
            peripheral.readValue(for: configCharacteristic)
        } else {
            print("Config characteristic was not found; using 16 kHz mono fallback.")
            configureAudio(StreamConfig.defaultValue, source: "missing config characteristic fallback")
            subscribeToStreamIfReady()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if characteristic.uuid == configCharacteristicUUID {
            if let error {
                print("Failed to read stream config: \(error); using 16 kHz mono fallback.")
                configureAudio(StreamConfig.defaultValue, source: "failed config read fallback")
            } else if let data = characteristic.value {
                do {
                    configureAudio(try StreamConfig.parse(data), source: "config characteristic")
                } catch {
                    print("Invalid stream config: \(error); using 16 kHz mono fallback.")
                    configureAudio(StreamConfig.defaultValue, source: "invalid config fallback")
                }
            } else {
                print("Config characteristic was empty; using 16 kHz mono fallback.")
                configureAudio(StreamConfig.defaultValue, source: "empty config fallback")
            }

            subscribeToStreamIfReady()
            return
        }

        if characteristic.uuid == streamCharacteristicUUID, let data = characteristic.value {
            handleStreamData(data)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == streamCharacteristicUUID else {
            return
        }

        if let error {
            print("Failed to subscribe to PCM stream: \(error)")
        } else if characteristic.isNotifying {
            print("Subscribed. Hold Button A on the M5StickS3 to stream audio.")
        } else {
            print("PCM stream notifications stopped.")
        }
    }
}
