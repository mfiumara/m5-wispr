"""Convert an animated gif into raw big-endian RGB565 frames for the M5 LCD.

Scales each frame, crops to the target size around a configurable focus point,
and packs pixels as swap565 (big-endian RGB565) the way LovyanGFX
pushImage(uint16_t*) expects with swapBytes=false. Also writes a preview
montage PNG re-decoded from the packed bytes so what you see is exactly what
the panel will get.

Usage:
  python3 tools/gif2rgb565.py IN.gif OUT.rgb565 PREVIEW.png \
      [--size WxH] [--focus-x FRACTION] [--zoom FRACTION]

  --size     target frame size (default 135x240, StickS3 portrait)
  --focus-x  horizontal crop center as a fraction of source width (default 0.5)
  --zoom     scale relative to full-cover; below 1.0 zooms out and letterboxes
             on black to keep more of the source visible (default 1.0)
"""
import argparse

from PIL import Image, ImageSequence

parser = argparse.ArgumentParser()
parser.add_argument("src")
parser.add_argument("dst")
parser.add_argument("preview")
parser.add_argument("--size", default="135x240")
parser.add_argument("--focus-x", type=float, default=0.5)
parser.add_argument("--zoom", type=float, default=1.0)
args = parser.parse_args()

TW, TH = (int(v) for v in args.size.split("x"))

frames_565 = []
durations = []
with Image.open(args.src) as gif:
    for frame in ImageSequence.Iterator(gif):
        durations.append(frame.info.get("duration", 0))
        rgb = frame.convert("RGB")
        scale = max(TW / rgb.width, TH / rgb.height) * args.zoom
        scaled = rgb.resize(
            (round(rgb.width * scale), round(rgb.height * scale)),
            Image.LANCZOS,
        )
        canvas = Image.new("RGB", (TW, TH))
        left = round(scaled.width * args.focus_x) - TW // 2
        left = max(0, min(left, max(0, scaled.width - TW)))
        top = max(0, (scaled.height - TH) // 2)
        window = scaled.crop((
            left,
            top,
            min(scaled.width, left + TW),
            top + min(scaled.height, TH),
        ))
        canvas.paste(
            window,
            ((TW - window.width) // 2, (TH - window.height) // 2),
        )
        frames_565.append(canvas)

out = bytearray()
for img in frames_565:
    for r, g, b in img.getdata():
        value = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        out += value.to_bytes(2, "big")

with open(args.dst, "wb") as f:
    f.write(out)

# Preview: decode the packed bytes back to RGB and tile all frames.
cols = 8 if TW < TH else 4
rows = (len(frames_565) + cols - 1) // cols
montage = Image.new("RGB", (TW * cols, TH * rows))
for index in range(len(frames_565)):
    tile = Image.new("RGB", (TW, TH))
    base = index * TW * TH * 2
    pixels = []
    for p in range(TW * TH):
        value = int.from_bytes(out[base + p * 2 : base + p * 2 + 2], "big")
        r = (value >> 11) << 3
        g = ((value >> 5) & 0x3F) << 2
        b = (value & 0x1F) << 3
        pixels.append((r, g, b))
    tile.putdata(pixels)
    montage.paste(tile, ((index % cols) * TW, (index // cols) * TH))
montage.save(args.preview)

print(f"frames={len(frames_565)} bytes={len(out)} durations_ms={sorted(set(durations))}")
