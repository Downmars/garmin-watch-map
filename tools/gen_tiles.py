#!/usr/bin/env python3
"""Generate aligned z15 map tiles (512px = 2x2 tiles) and emit MapData + drawables."""
import argparse
import io
import json
import math
import os
import time
import urllib.request

from PIL import Image

TILE_URL = "https://a.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png"
Z = 15
WORLD = 256 << Z


def lon_to_x(lon):
    return (lon + 180.0) / 360.0 * WORLD


def lat_to_y(lat):
    rad = math.radians(lat)
    return (1.0 - math.log(math.tan(rad) + 1.0 / math.cos(rad)) / math.pi) / 2.0 * WORLD


def fetch(z, x, y, cache):
    key = (z, x, y)
    if key in cache:
        return cache[key]
    last = None
    for host in ("a", "b", "c"):
        for attempt in range(3):
            url = f"https://{host}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png"
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "offline-map-builder/1.0"})
                with urllib.request.urlopen(req, timeout=25) as resp:
                    data = resp.read()
                img = Image.open(io.BytesIO(data)).convert("RGB")
                cache[key] = img
                return img
            except Exception as exc:
                last = exc
                time.sleep(1 + attempt)
    print(f"  ! give up {z}/{x}/{y}: {last}", flush=True)
    img = Image.new("RGB", (256, 256), (232, 232, 228))
    cache[key] = img
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", type=float, required=True)
    ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--cols", type=int, default=5)
    ap.add_argument("--rows", type=int, default=5)
    ap.add_argument("--app", required=True)
    ap.add_argument("--outdir", required=True)
    args = ap.parse_args()

    size = 512
    cx = lon_to_x(args.lon)
    cy = lat_to_y(args.lat)
    gx0 = int(math.floor((cx - args.cols * size / 2.0) / size) * size)
    gy0 = int(math.floor((cy - args.rows * size / 2.0) / size) * size)

    drawables = os.path.join(args.app, "resources", "drawables")
    os.makedirs(drawables, exist_ok=True)
    os.makedirs(args.outdir, exist_ok=True)
    cache = {}

    for j in range(args.rows):
        for i in range(args.cols):
            tile = Image.new("RGB", (size, size))
            tx = int(gx0 / 256) + i * 2
            ty = int(gy0 / 256) + j * 2
            for b in range(2):
                for a in range(2):
                    img = fetch(Z, tx + a, ty + b, cache)
                    tile.paste(img, (a * 256, b * 256))
            name = f"tile_{j}_{i}.png"
            tile.save(os.path.join(args.outdir, name), "PNG", optimize=True)
            tile.save(os.path.join(drawables, name), "PNG", optimize=True)

    lines = []
    for j in range(args.rows):
        for i in range(args.cols):
            lines.append(f"    const TILE_{j}_{i} = Rez.Drawables.Tile{j}{i};\n")
    tile_lines = "".join(
        f"    const TILE_{j}_{i} = Rez.Drawables.Tile{j}{i};\n"
        for j in range(args.rows) for i in range(args.cols)
    )
    all_entries = "".join(
        f"        TILE_{j}_{i},\n"
        for j in range(args.rows) for i in range(args.cols)
    )
    data = (
        "module MapData {\n"
        f"    const ORIGIN_X = {gx0};\n"
        f"    const ORIGIN_Y = {gy0};\n"
        f"    const ZOOM_LEVEL = {Z};\n"
        f"    const WORLD = {WORLD};\n"
        f"    const TILE = {size};\n"
        f"    const COLS = {args.cols};\n"
        f"    const ROWS = {args.rows};\n"
        "    const SCALE = \"231m\";\n"
        "    const W = 260;\n"
        "    const H = 260;\n"
        + tile_lines
        + "    const ALL = [\n"
        + all_entries
        + "    ];\n"
        + "}\n"
    )
    with open(os.path.join(args.app, "source", "MapData.mc"), "w", encoding="utf-8") as fh:
        fh.write(data)

    xml = ["<drawables>\n"]
    for j in range(args.rows):
        for i in range(args.cols):
            xml.append(f'  <bitmap id="Tile{j}{i}" filename="tile_{j}_{i}.png"/>\n')
    xml.append('  <bitmap id="LauncherIcon" filename="launcher.png"/>\n</drawables>\n')
    with open(os.path.join(drawables, "drawables.xml"), "w", encoding="utf-8") as fh:
        fh.write("".join(xml))
    print(f"tiles {args.cols}x{args.rows} origin=({gx0},{gy0})")


if __name__ == "__main__":
    main()
