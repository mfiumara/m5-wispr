# M5 Wispr BLE Mic

[![CI](https://github.com/mfiumara/m5-wispr/actions/workflows/ci.yml/badge.svg)](https://github.com/mfiumara/m5-wispr/actions/workflows/ci.yml)

Rust ESP-IDF firmware for an M5StickS3 that behaves as a push-to-talk BLE remote for Wispr Flow.

Behavior:

- Button A held: hold the Wispr trigger key down, wake the LCD, show an audio-reactive colorful recording animation, and stream 16 kHz mono signed 16-bit PCM over BLE GATT notifications.
- Button A released: stop the PCM stream, release the trigger key, show battery level briefly, then sleep the LCD again to save power.
- Idle: LCD backlight is off and the display is in sleep / power-save mode.

## Important macOS Notes

The HID trigger is sent as held `Right Option` by default (`WISPR_HOTKEY_MODIFIERS = 0x40`, `WISPR_HOTKEY_USAGE = 0x00` in `src/main.rs`). Apple Fn/Globe is not a normal external BLE HID keyboard key, and normal keys such as Space can auto-repeat while held, so configure Wispr Flow to use Option as its hold key or change the constants in `src/main.rs`.

The audio stream is a custom BLE GATT PCM stream, not a Bluetooth LE Audio / CoreAudio microphone profile. macOS will not automatically list this device as a system microphone. Wispr Flow, or a small macOS bridge, needs to subscribe to the custom service and feed the PCM into the app.

A first bridge scaffold lives in `macos-bridge/`. It subscribes to this custom BLE PCM stream and plays it into an existing CoreAudio loopback output device such as BlackHole, so Wispr Flow can select the matching BlackHole input as its microphone.

BLE audio service:

- Service UUID: `b3d7f070-3f2d-4c2e-94b8-1f0a95b7a100`
- Notify stream characteristic: `b3d7f071-3f2d-4c2e-94b8-1f0a95b7a100`
- Read config characteristic: `b3d7f072-3f2d-4c2e-94b8-1f0a95b7a100`

Stream packet format:

```text
u32 sequence_le
u8  flags        bit0=start, bit1=stop
u8  channels     currently 1
u16 sample_count_le
i16 pcm[sample_count] little-endian
```

Config characteristic format:

```text
bytes 0..4   magic "M5W1"
bytes 4..8   sample_rate_hz u32 little-endian
byte  8      bits_per_sample
byte  9      channels
bytes 10..12 samples_per_packet u16 little-endian
bytes 12..16 stream_header_bytes u32 little-endian
```

## Wispr Flow Setup

This project uses two paths into Wispr Flow:

- BLE HID keyboard: the M5StickS3 holds `Right Option` while Button A is held.
- BLE PCM audio: the custom macOS bridge sends the M5 audio stream into a CoreAudio loopback device that Wispr Flow can select as a microphone.

Recommended macOS setup:

1. Install a CoreAudio loopback device such as BlackHole 2ch.
2. Build and flash the firmware onto the M5StickS3.
3. Pair `m5sticks3` in macOS System Settings > Bluetooth.
4. Configure Wispr Flow push-to-talk to use `Option` as the hold key.
5. Configure Wispr Flow microphone input to the BlackHole input.
6. Run the bridge and point it at the matching BlackHole output:

```bash
swift run --package-path macos-bridge m5-wispr-bridge --audio-device "BlackHole 2ch"
```

7. Hold Button A on the M5StickS3. The bridge should receive BLE PCM audio, play it into BlackHole, and Wispr Flow should see that audio on the BlackHole input while the Option hotkey is held.

If the bridge cannot scan or connect, grant Bluetooth access to the terminal app in System Settings > Privacy & Security > Bluetooth. If Wispr Flow sees the hotkey but no audio, verify the bridge can see BlackHole:

```bash
swift run --package-path macos-bridge m5-wispr-bridge --list-audio-devices
```

## Build

Install the esp-rs toolchain:

```bash
cargo +stable install espup
espup install
. ~/export-esp.sh
cargo +stable install ldproxy espflash
```

This firmware pins ESP-IDF to `tag:v5.1.6`. With ESP-IDF `v5.3.2`, the current
M5Unified/M5GFX component stack links both the legacy I2C driver and
`esp_driver_i2c`, which aborts before `app_main()` and prevents BLE from
advertising. `esp32-nimble` is patched locally under `vendor/esp32-nimble`
because ESP-IDF 5.1.6 backported newer NimBLE struct layouts.

Then build:

```bash
cargo build --release
```

## Flash

Put the M5StickS3 in download mode if needed, then:

```bash
cargo run --release
```

or explicitly:

```bash
espflash flash --monitor target/xtensa-esp32s3-espidf/release/m5-wispr
```

Pair `m5sticks3` in macOS Bluetooth settings. Configure Wispr Flow to use Option as its push-to-talk hold key unless you change the HID constants.

To watch boot and BLE logs:

```bash
espflash monitor --non-interactive --port /dev/cu.usbmodem21101 --elf target/xtensa-esp32s3-espidf/release/m5-wispr
```
