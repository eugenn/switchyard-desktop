#!/usr/bin/env python3
"""Regenerate src-tauri/icons from src-tauri/icons/source/app-icon-foreground.svg.

Draws the dithered graphite tile, composes the SVG foreground on top, runs `tauri icon`
in a temporary directory and replaces only the icon files already tracked in src-tauri/icons
(the Android and iOS sets it also produces are discarded).
Requires rsvg-convert, Pillow, numpy and the project's npm dependencies.
"""
import io
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

DESKTOP = Path(__file__).resolve().parents[1]
ICONS = DESKTOP / "src-tauri/icons"
FOREGROUND = ICONS / "source/app-icon-foreground.svg"
SIZE = 1024
TILE = (100, 924, 185)  # start, end, corner radius on the 1024 macOS icon grid
TOP, BOTTOM, ACCENT = (0x1a, 0x20, 0x1e), (0x0b, 0x0f, 0x0e), (0x4f, 0xc9, 0x8a)


def tile_mask() -> Image.Image:
    scale = 4
    mask = Image.new("L", (SIZE * scale, SIZE * scale), 0)
    start, end, radius = (v * scale for v in TILE)
    ImageDraw.Draw(mask).rounded_rectangle([start, start, end, end], radius=radius, fill=255)
    return mask.resize((SIZE, SIZE), Image.LANCZOS)


def tile_background(mask: Image.Image) -> Image.Image:
    y, x = np.mgrid[0:SIZE, 0:SIZE].astype(np.float64)
    start, end, _ = TILE
    t = np.clip((y - start) / (end - start), 0, 1)[..., None]
    rgb = np.array(TOP, float) * (1 - t) + np.array(BOTTOM, float) * t
    glow = (np.clip(1 - np.hypot(x - 300, y - 512) / 520, 0, 1) ** 2 * 0.10)[..., None]
    rgb = rgb * (1 - glow) + np.array(ACCENT, float) * glow
    rgb += np.random.default_rng(7).uniform(-0.8, 0.8, rgb.shape)  # dither against banding
    tile = Image.fromarray(np.clip(np.round(rgb), 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    tile.putalpha(mask)
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow.putalpha(mask.point(lambda v: int(v * 0.35)))
    shadow = shadow.transform((SIZE, SIZE), Image.AFFINE, (1, 0, 0, 0, 1, -10)).filter(ImageFilter.GaussianBlur(14))
    return Image.alpha_composite(shadow, tile)


def render_master(path: Path) -> None:
    svg = subprocess.run(["rsvg-convert", "-w", str(SIZE), "-h", str(SIZE), str(FOREGROUND)],
                         capture_output=True, check=True).stdout
    foreground = Image.open(io.BytesIO(svg)).convert("RGBA")
    Image.alpha_composite(tile_background(tile_mask()), foreground).save(path)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="switchyard-icon-") as temporary:
        work = Path(temporary)
        master = work / "app-icon-1024.png"
        render_master(master)
        subprocess.run(["npx", "tauri", "icon", str(master), "-o", str(work / "out")],
                       cwd=DESKTOP, check=True, stdout=subprocess.DEVNULL)
        targets = sorted(p for p in ICONS.iterdir() if p.is_file())
        for target in targets:
            shutil.copyfile(work / "out" / target.name, target)
        print(f"Updated {len(targets)} icon files in {ICONS.relative_to(DESKTOP)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
