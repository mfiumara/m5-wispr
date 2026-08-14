# M5 Wispr Windows Bridge

This CLI receives the M5StickS3's custom 16-bit PCM stream over BLE and plays it into a Windows playback endpoint. Use a virtual cable so Wispr Flow can read the cable's matching recording endpoint.

## Requirements

- Windows 10 version 2004 or newer, or Windows 11, x64, with Bluetooth LE.
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).
- A virtual audio cable such as [VB-CABLE](https://vb-audio.com/Cable/). Install it, then restart Windows if its installer asks.

## Build and test

From `windows-bridge` in PowerShell:

```powershell
dotnet build -c Release
dotnet run -c Release -- --self-test
```

The self-test checks the config and PCM packet parsers without Bluetooth hardware.

## Run

Find the virtual cable's **playback** endpoint:

```powershell
dotnet run -c Release -- --list-devices
```

Start the bridge using its name (or the exact endpoint ID printed above):

```powershell
dotnet run -c Release -- --device "CABLE Input"
```

In Wispr Flow, select the cable's matching **recording** endpoint (normally `CABLE Output`) as the microphone. Hold Button A on the M5StickS3 to talk. The bridge reconnects after a BLE disconnect; press Ctrl+C to quit.

If Windows does not discover the stick, remove any stale `m5sticks3` entry from Settings > Bluetooth & devices, make sure no other bridge is connected, and wake the stick before retrying.

## Protocol

- Device name: `m5sticks3`
- Service: `b3d7f070-3f2d-4c2e-94b8-1f0a95b7a100`
- Notify stream characteristic: `b3d7f071-3f2d-4c2e-94b8-1f0a95b7a100`
- Read config characteristic: `b3d7f072-3f2d-4c2e-94b8-1f0a95b7a100`

Each stream notification starts with:

```text
u32 sequence_le
u8  flags        bit0=start, bit1=stop
u8  channels
u16 sample_count_le
i16 pcm[sample_count] little-endian
```

The bridge warns about sequence gaps, clears queued audio on start, and keeps the playback endpoint alive with silence between recordings.
