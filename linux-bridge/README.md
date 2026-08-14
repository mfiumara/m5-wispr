# M5 Wispr Linux bridge

This CLI receives the M5StickS3's custom BLE PCM stream and writes it to a
PipeWire/PulseAudio virtual microphone. It uses `pactl` to create the virtual
sink and `pw-cat` (or `pacat`) to feed it. No audio framework is bundled.

## Install

Install your distribution's PipeWire Pulse compatibility tools (or PulseAudio),
Python 3.9+, and Bluetooth support. On Debian/Ubuntu with PipeWire:

```sh
sudo apt install python3-venv pipewire-pulse pipewire-bin pulseaudio-utils bluez
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

Your user must be allowed to use Bluetooth. Start the normal desktop Bluetooth
service; running the bridge as root usually connects it to the wrong audio
session.

## Run

```sh
. .venv/bin/activate
python3 m5wispr_bridge.py
```

The bridge scans for `m5sticks3`, reads its audio config characteristic,
subscribes to PCM notifications, and reconnects after deep sleep. In a Linux
app, select **m5wispr.monitor** (shown as "Monitor of M5_Wispr") as the
microphone. Hold Button A to talk. Wispr Flow does not currently offer a native
Linux app.

Useful options:

```text
--address AA:BB:CC:DD:EE:FF  connect to one exact device
--name NAME                  override the default BLE name
--once                       exit instead of reconnecting
```

The virtual device is removed on a clean exit. If the process was killed and a
stale `m5wispr` sink remains, remove it with `pactl list short modules` followed
by `pactl unload-module MODULE_ID`.

## Protocol check

This needs no Bluetooth or Linux audio hardware:

```sh
python3 test_protocol.py
```

Fixed BLE UUIDs:

- Service: `b3d7f070-3f2d-4c2e-94b8-1f0a95b7a100`
- PCM notifications: `b3d7f071-3f2d-4c2e-94b8-1f0a95b7a100`
- Stream config: `b3d7f072-3f2d-4c2e-94b8-1f0a95b7a100`

Packets contain `u32 sequence`, start/stop flags, channel count, `u16` sample
count, then little-endian signed 16-bit PCM. The config characteristic supplies
the sample rate and channel count used for the virtual microphone.
