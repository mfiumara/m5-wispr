#!/usr/bin/env python3
"""Bridge the M5StickS3 BLE PCM stream to a Linux virtual microphone."""

import argparse
import asyncio
import shutil
import struct
import subprocess
import sys
from dataclasses import dataclass

SERVICE_UUID = "b3d7f070-3f2d-4c2e-94b8-1f0a95b7a100"
STREAM_UUID = "b3d7f071-3f2d-4c2e-94b8-1f0a95b7a100"
CONFIG_UUID = "b3d7f072-3f2d-4c2e-94b8-1f0a95b7a100"


@dataclass(frozen=True)
class StreamConfig:
    rate: int
    bits: int
    channels: int
    samples_per_packet: int
    header_bytes: int


@dataclass(frozen=True)
class Packet:
    sequence: int
    flags: int
    channels: int
    sample_count: int
    pcm: bytes

    @property
    def is_start(self):
        return bool(self.flags & 1)

    @property
    def is_stop(self):
        return bool(self.flags & 2)


def parse_config(data):
    if len(data) < 16:
        raise ValueError(f"config is too short: {len(data)} bytes")
    magic, rate, bits, channels, samples, header = struct.unpack("<4sIBBHI", data[:16])
    if magic != b"M5W1":
        raise ValueError(f"invalid config magic: {magic!r}")
    if not rate or bits != 16 or not channels or header != 8:
        raise ValueError(
            f"unsupported config: {rate} Hz, {bits}-bit, {channels} channel(s), {header}-byte header"
        )
    return StreamConfig(rate, bits, channels, samples, header)


def parse_packet(data):
    if len(data) < 8:
        raise ValueError(f"packet is too short: {len(data)} bytes")
    sequence, flags, channels, sample_count = struct.unpack("<IBBH", data[:8])
    expected = 8 + sample_count * 2
    if not channels:
        raise ValueError("packet has zero channels")
    if len(data) != expected:
        raise ValueError(f"packet length mismatch: expected {expected}, got {len(data)}")
    return Packet(sequence, flags, channels, sample_count, bytes(data[8:]))


class VirtualMic:
    def __init__(self, config):
        self.config = config
        self.module_id = None
        self.player = None

    def start(self):
        if not shutil.which("pactl"):
            raise RuntimeError("pactl is required (PipeWire Pulse or PulseAudio)")

        sinks = subprocess.run(
            ["pactl", "list", "short", "sinks"], check=True, capture_output=True, text=True
        ).stdout
        exists = any(line.split()[1:2] == ["m5wispr"] for line in sinks.splitlines())
        if not exists:
            result = subprocess.run(
                [
                    "pactl", "load-module", "module-null-sink",
                    "sink_name=m5wispr",
                    f"rate={self.config.rate}",
                    f"channels={self.config.channels}",
                    "sink_properties=device.description=M5_Wispr",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.module_id = result.stdout.strip()

        if shutil.which("pw-cat"):
            command = [
                "pw-cat", "--playback", "--raw", "--target", "m5wispr",
                "--format", "s16", "--rate", str(self.config.rate),
                "--channels", str(self.config.channels), "-",
            ]
        elif shutil.which("pacat"):
            command = [
                "pacat", "--playback", "--device=m5wispr", "--format=s16le",
                f"--rate={self.config.rate}", f"--channels={self.config.channels}",
            ]
        else:
            raise RuntimeError("pw-cat or pacat is required")

        self.player = subprocess.Popen(command, stdin=subprocess.PIPE)
        print("Virtual microphone ready: select m5wispr.monitor in your app")

    def write(self, pcm):
        if pcm and self.player and self.player.stdin:
            try:
                self.player.stdin.write(pcm)
                self.player.stdin.flush()
            except BrokenPipeError as error:
                raise RuntimeError("audio player exited") from error

    def close(self):
        if self.player:
            self.player.terminate()
            try:
                self.player.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.player.kill()
                self.player.wait()
        if self.module_id:
            subprocess.run(["pactl", "unload-module", self.module_id], check=False)


async def find_device(name, address):
    from bleak import BleakScanner

    if address:
        print(f"Looking for BLE address {address}...")
        return await BleakScanner.find_device_by_address(address, timeout=10)

    print(f"Scanning for {name} or service {SERVICE_UUID}...")

    def matches(device, advertisement):
        return device.name == name or advertisement.local_name == name or SERVICE_UUID in [
            uuid.lower() for uuid in advertisement.service_uuids
        ]

    return await BleakScanner.find_device_by_filter(matches, timeout=10)


async def run(args):
    from bleak import BleakClient

    mic = None
    try:
        while True:
            device = await find_device(args.name, args.address)
            if not device:
                print("Device not found; retrying...", file=sys.stderr)
                await asyncio.sleep(2)
                continue

            disconnected = asyncio.Event()
            try:
                async with BleakClient(device, disconnected_callback=lambda _client: disconnected.set()) as client:
                    config = parse_config(await client.read_gatt_char(CONFIG_UUID))
                    print(
                        f"Connected to {device.name or device.address}: "
                        f"{config.rate} Hz, {config.bits}-bit, {config.channels} channel(s)"
                    )
                    if mic is None:
                        mic = VirtualMic(config)
                        mic.start()
                    elif mic.config != config:
                        raise RuntimeError("audio config changed; restart the bridge")

                    expected = None

                    def notification(_characteristic, data):
                        nonlocal expected
                        try:
                            packet = parse_packet(data)
                            if packet.channels != config.channels:
                                raise ValueError(
                                    f"packet has {packet.channels} channels; expected {config.channels}"
                                )
                            if packet.is_start:
                                print(f"Stream started at sequence {packet.sequence}")
                            elif expected is not None and packet.sequence != expected:
                                print(
                                    f"warning: sequence gap; expected {expected}, got {packet.sequence}",
                                    file=sys.stderr,
                                )
                            expected = (packet.sequence + 1) & 0xFFFFFFFF
                            mic.write(packet.pcm)
                            if packet.is_stop:
                                print(f"Stream stopped at sequence {packet.sequence}")
                                expected = None
                        except (ValueError, RuntimeError) as error:
                            print(f"warning: dropped packet: {error}", file=sys.stderr)

                    await client.start_notify(STREAM_UUID, notification)
                    print("Subscribed; hold Button A to talk")
                    await disconnected.wait()
            except Exception as error:
                print(f"BLE connection ended: {error}", file=sys.stderr)

            if args.once:
                return
            print("Reconnecting...")
            await asyncio.sleep(1)
    finally:
        if mic:
            mic.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", default="m5sticks3", help="BLE device name")
    parser.add_argument("--address", help="exact BLE address")
    parser.add_argument("--once", action="store_true", help="exit after the first disconnect")
    args = parser.parse_args()
    try:
        asyncio.run(run(args))
    except (KeyboardInterrupt, RuntimeError, subprocess.CalledProcessError) as error:
        if str(error):
            print(f"fatal: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
