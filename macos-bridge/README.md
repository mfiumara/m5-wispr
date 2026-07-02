# M5 Wispr macOS Bridge

Command-line bridge for the M5StickS3 firmware's custom BLE PCM service.

The firmware does not expose a Bluetooth microphone profile, so macOS will not show `m5sticks3` as an input device by itself. This bridge subscribes to the custom BLE GATT PCM characteristic and plays the signed 16-bit PCM stream into an existing CoreAudio output device. The practical first target is BlackHole: the bridge outputs to BlackHole, then Wispr Flow selects the corresponding BlackHole input as its microphone. The M5 stream is 16 kHz mono; the bridge resamples it to the selected CoreAudio device's native rate and duplicates it to stereo when the output is a two-channel loopback device such as BlackHole 2ch.

## Requirements

- macOS with SwiftPM/Xcode command line tools.
- A CoreAudio loopback device such as BlackHole 2ch or BlackHole 16ch.
- The M5StickS3 firmware advertising as `m5sticks3`.

Creating a native named CoreAudio microphone directly from this repo is intentionally out of scope for this first version. On modern macOS that means shipping a CoreAudio HAL server plug-in or DriverKit-style audio driver with signing, installation, privacy, and lifecycle handling. Feeding BlackHole keeps this bridge user-space, buildable with system frameworks, and easy to replace later if a native virtual microphone becomes worth the extra packaging.

## Build

From this directory:

```bash
swift build
swift run m5-wispr-bridge --self-test
```

No Swift package dependencies are downloaded; the bridge uses `CoreBluetooth`, `CoreAudio`, and `AudioToolbox`.

To test the BlackHole/Wispr side without BLE, play a five second tone into the selected loopback output:

```bash
swift run m5-wispr-bridge --audio-device "BlackHole 2ch" --tone-test
```

## Find the BlackHole Device

```bash
swift run m5-wispr-bridge --list-audio-devices
```

Look for an output device named like `BlackHole 2ch` or `BlackHole 16ch`. If multiple devices match, pass the exact UID shown by the list command.

## Run

Default device names:

```bash
swift run m5-wispr-bridge
```

Explicit BlackHole name:

```bash
swift run m5-wispr-bridge --audio-device "BlackHole 2ch"
```

Exact CoreAudio UID:

```bash
swift run m5-wispr-bridge --audio-device-uid "BlackHole2ch_UID"
```

Exact BLE peripheral identifier, useful after a successful scan has printed it:

```bash
swift run m5-wispr-bridge --peripheral-id "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
```

Then configure Wispr Flow to use the matching BlackHole input as its microphone. Hold Button A on the M5StickS3 to start the stream.

If macOS reports Bluetooth authorization errors, grant Bluetooth access to the terminal app running `swift run` in System Settings > Privacy & Security > Bluetooth.

## Protocol

The bridge uses the firmware defaults:

- BLE device name: `m5sticks3`
- Service UUID: `b3d7f070-3f2d-4c2e-94b8-1f0a95b7a100`
- Notify stream characteristic: `b3d7f071-3f2d-4c2e-94b8-1f0a95b7a100`
- Read config characteristic: `b3d7f072-3f2d-4c2e-94b8-1f0a95b7a100`

Stream packets are parsed as:

```text
u32 sequence_le
u8  flags        bit0=start, bit1=stop
u8  channels     currently 1
u16 sample_count_le
i16 pcm[sample_count] little-endian
```
