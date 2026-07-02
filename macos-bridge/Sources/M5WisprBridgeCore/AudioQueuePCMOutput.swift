import AudioToolbox
import Foundation

public final class AudioQueuePCMOutput {
    public let config: StreamConfig
    public let device: AudioDevice

    private var queue: AudioQueueRef?
    private let outputChannels: UInt8
    private let outputSampleRateHz: UInt32
    private let bytesPerFrame: Int
    private let bufferByteSize: UInt32
    private let maxPendingBytes: Int

    private let pendingLock = NSLock()
    private var pending = Data()

    private static let bufferCount = 4
    private static let bufferSeconds = 0.02
    private static let maxPendingSeconds = 10.0

    public init(config: StreamConfig, device: AudioDevice) throws {
        self.config = config
        self.device = device
        self.outputChannels = config.channels == 1 && device.outputChannels >= 2 ? 2 : config.channels
        self.outputSampleRateHz = device.nominalSampleRate >= 8_000
            ? UInt32(device.nominalSampleRate.rounded())
            : config.sampleRateHz
        self.bytesPerFrame = Int(outputChannels) * MemoryLayout<Int16>.size

        let bufferFrames = max(64, Int(Double(outputSampleRateHz) * Self.bufferSeconds))
        self.bufferByteSize = UInt32(bufferFrames * bytesPerFrame)
        self.maxPendingBytes = Int(Double(outputSampleRateHz) * Self.maxPendingSeconds) * bytesPerFrame

        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: Float64(outputSampleRateHz),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(outputChannels) * 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(outputChannels) * 2,
            mChannelsPerFrame: UInt32(outputChannels),
            mBitsPerChannel: UInt32(config.bitsPerSample),
            mReserved: 0
        )

        var createdQueue: AudioQueueRef?
        try check(
            AudioQueueNewOutput(
                &streamFormat,
                audioQueueOutputCallback,
                Unmanaged.passUnretained(self).toOpaque(),
                nil,
                nil,
                0,
                &createdQueue
            ),
            "create AudioQueue output"
        )

        guard let createdQueue else {
            throw AudioOutputError.audioQueueNotCreated
        }

        var deviceUID = device.uid as CFString
        try withUnsafePointer(to: &deviceUID) { pointer in
            try check(
                AudioQueueSetProperty(
                    createdQueue,
                    kAudioQueueProperty_CurrentDevice,
                    UnsafeRawPointer(pointer),
                    UInt32(MemoryLayout<CFString>.size)
                ),
                "select CoreAudio output device \(device.name)"
            )
        }

        // Prime the queue with silence before starting. A playback queue that is
        // started empty underruns immediately, and buffers enqueued after an
        // underrun are consumed without being rendered; the callback keeps these
        // fixed buffers cycling forever, filling silence when no PCM is pending.
        for _ in 0..<Self.bufferCount {
            var buffer: AudioQueueBufferRef?
            try check(
                AudioQueueAllocateBuffer(createdQueue, bufferByteSize, &buffer),
                "allocate AudioQueue buffer"
            )
            guard let buffer else {
                AudioQueueDispose(createdQueue, true)
                throw AudioOutputError.audioQueueBufferNotCreated
            }
            memset(buffer.pointee.mAudioData, 0, Int(bufferByteSize))
            buffer.pointee.mAudioDataByteSize = bufferByteSize
            try check(
                AudioQueueEnqueueBuffer(createdQueue, buffer, 0, nil),
                "prime AudioQueue buffer"
            )
        }

        try check(AudioQueueStart(createdQueue, nil), "start AudioQueue output")
        queue = createdQueue
    }

    deinit {
        if let queue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
    }

    public func reset() {
        pendingLock.lock()
        pending.removeAll(keepingCapacity: true)
        pendingLock.unlock()
    }

    public func enqueue(packet: PCMStreamPacket) throws {
        guard packet.channels == config.channels else {
            throw AudioOutputError.incompatibleChannelCount(
                packetChannels: packet.channels,
                configuredChannels: config.channels
            )
        }

        try enqueuePCM(convertPCM(packet.pcmData, inputChannels: packet.channels))
    }

    private func convertPCM(_ pcmData: Data, inputChannels: UInt8) -> Data {
        guard inputChannels == 1 else {
            return pcmData
        }

        let inputFrameCount = pcmData.count / MemoryLayout<Int16>.size
        guard inputFrameCount > 0 else {
            return pcmData
        }

        let outputFrameCount = max(
            1,
            (inputFrameCount * Int(outputSampleRateHz) + Int(config.sampleRateHz) - 1)
                / Int(config.sampleRateHz)
        )
        var samples = [Int16]()
        samples.reserveCapacity(inputFrameCount)
        var index = pcmData.startIndex
        while index < pcmData.endIndex {
            let low = pcmData[index]
            let high = pcmData[pcmData.index(after: index)]
            samples.append(Int16(bitPattern: UInt16(low) | (UInt16(high) << 8)))
            index = pcmData.index(index, offsetBy: 2)
        }

        var output = Data(capacity: outputFrameCount * Int(outputChannels) * MemoryLayout<Int16>.size)
        for outputFrame in 0..<outputFrameCount {
            let sourceFrame = min(
                inputFrameCount - 1,
                (outputFrame * Int(config.sampleRateHz)) / Int(outputSampleRateHz)
            )
            var sample = samples[sourceFrame].littleEndian
            for _ in 0..<outputChannels {
                withUnsafeBytes(of: &sample) { output.append(contentsOf: $0) }
            }
        }

        return output
    }

    public func enqueueTonePCM(_ pcmData: Data, sampleRateHz: UInt32, channels: UInt8) throws {
        guard channels == 1, sampleRateHz == outputSampleRateHz else {
            try enqueuePCM(pcmData)
            return
        }

        if outputChannels == 1 {
            try enqueuePCM(pcmData)
            return
        }

        var stereo = Data(capacity: pcmData.count * Int(outputChannels))
        var index = pcmData.startIndex
        while index < pcmData.endIndex {
            let low = pcmData[index]
            let high = pcmData[pcmData.index(after: index)]
            for _ in 0..<outputChannels {
                stereo.append(low)
                stereo.append(high)
            }
            index = pcmData.index(index, offsetBy: 2)
        }
        try enqueuePCM(stereo)
    }

    public func enqueuePCM(_ pcmData: Data) throws {
        guard !pcmData.isEmpty else {
            return
        }
        guard queue != nil else {
            throw AudioOutputError.audioQueueNotCreated
        }
        guard pcmData.count % bytesPerFrame == 0 else {
            throw AudioOutputError.unalignedPCMBytes(byteCount: pcmData.count, frameBytes: bytesPerFrame)
        }

        pendingLock.lock()
        pending.append(pcmData)
        if pending.count > maxPendingBytes {
            pending.removeFirst(pending.count - maxPendingBytes)
        }
        pendingLock.unlock()
    }

    fileprivate func refill(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)

        pendingLock.lock()
        let available = min(capacity, pending.count)
        if available > 0 {
            pending.withUnsafeBytes { rawBuffer in
                if let source = rawBuffer.baseAddress {
                    buffer.pointee.mAudioData.copyMemory(from: source, byteCount: available)
                }
            }
            pending.removeFirst(available)
        }
        pendingLock.unlock()

        if available < capacity {
            memset(buffer.pointee.mAudioData.advanced(by: available), 0, capacity - available)
        }
        buffer.pointee.mAudioDataByteSize = UInt32(capacity)
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw AudioOutputError.coreAudioFailure(operation: operation, status: status)
        }
    }
}

private let audioQueueOutputCallback: AudioQueueOutputCallback = { userData, queue, buffer in
    guard let userData else {
        AudioQueueFreeBuffer(queue, buffer)
        return
    }
    Unmanaged<AudioQueuePCMOutput>.fromOpaque(userData)
        .takeUnretainedValue()
        .refill(queue: queue, buffer: buffer)
}

public enum AudioOutputError: Error, CustomStringConvertible {
    case audioQueueNotCreated
    case audioQueueBufferNotCreated
    case bufferTooLarge(Int)
    case unalignedPCMBytes(byteCount: Int, frameBytes: Int)
    case incompatibleChannelCount(packetChannels: UInt8, configuredChannels: UInt8)
    case coreAudioFailure(operation: String, status: OSStatus)

    public var description: String {
        switch self {
        case .audioQueueNotCreated:
            return "AudioQueue output was not created"
        case .audioQueueBufferNotCreated:
            return "AudioQueue buffer was not created"
        case .bufferTooLarge(let byteCount):
            return "PCM buffer is too large for AudioQueue: \(byteCount) bytes"
        case .unalignedPCMBytes(let byteCount, let frameBytes):
            return "PCM byte count \(byteCount) is not aligned to \(frameBytes)-byte audio frames"
        case .incompatibleChannelCount(let packetChannels, let configuredChannels):
            return "packet has \(packetChannels) channel(s), but stream config has \(configuredChannels)"
        case .coreAudioFailure(let operation, let status):
            return "\(operation) failed with OSStatus \(status)"
        }
    }
}
