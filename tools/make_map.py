#!/usr/bin/env python3
"""Download a small OSM raster area and stitch it into one offline map PNG.

MVP scope: one fixed area, one zoom level, a handful of tiles. Please keep
usage small and identify the client; OSM tile servers forbid bulk scraping.
"""
import argparse
import io
import json
import math
import os
import time
import urllib.request
from PIL import Image

TILE = 256
USER_AGENT = "GarminMapMVP/0.1 (personal offline map; one-shot small area)"


def lonlat_to_pixel(lat, lon, z):
    n = 2 ** z
    x = (lon + 180.0) / 360.0 * n * TILE
    sin_lat = math.sin(math.radians(lat))
    y = (0.5 - math.log((1 + sin_lat) / (1 - sin_lat)) / (4 * math.pi)) * n * TILE
    return x, y


def fetch_tile(url, x, y, z, retries=2):
    u = url.format(z=z, x=x, y=y)
    last = None
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(u, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=20) as resp:
                data = resp.read()
            return Image.open(io.BytesIO(data)).convert("RGB")
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(0.8 * (attempt + 1))
    print(f"  ! tile {z}/{x}/{y} failed: {last}")
    return Image.new("RGB", (TILE, TILE), (32, 34, 40))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--lat", type=float, required=True)
    ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--km", type=float, default=6.0, help="map width in km")
    ap.add_argument("--zoom", type=int, default=15)
    ap.add_argument("--size", type=int, default=780, help="output pixel size")
    ap.add_argument("--outdir", default=os.path.join(os.path.dirname(__file__), "..", "maps"))
    ap.add_argument("--tile-url", default="https://a.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png")
    args = ap.parse_args()

    half_km = args.km / 2.0
    dlat = half_km / 110.574
    dlon = half_km / (111.320 * math.cos(math.radians(args.lat)))
    lat_min, lat_max = args.lat - dlat, args.lat + dlat
    lon_min, lon_max = args.lon - dlon, args.lon + dlon

    px_min, py_min = lonlat_to_pixel(lat_max, lon_min, args.zoom)
    px_max, py_max = lonlat_to_pixel(lat_min, lon_max, args.zoom)

    tx0, ty0 = int(px_min // TILE), int(py_min // TILE)
    tx1, ty1 = int(px_max // TILE), int(py_max // TILE)
    nx, ny = tx1 - tx0 + 1, ty1 - ty0 + 1
    total = nx * ny
    print(f"area {args.name}: {nx}x{ny} = {total} tiles at z{args.zoom}")
    if total > 64:
        raise SystemExit("too many tiles (>64); reduce --km or --zoom")

    canvas = Image.new("RGB", (nx * TILE, ny * TILE), (32, 34, 40))
    for i, ty in enumerate(range(ty0, ty1 + 1)):
        for j, tx in enumerate(range(tx0, tx1 + 1)):
            tile = fetch_tile(args.tile_url, tx, ty, args.zoom)
            canvas.paste(tile, (j * TILE, i * TILE))
            time.sleep(0.12)
        print(f"  row {i + 1}/{ny}")

    box = (
        int(round(px_min - tx0 * TILE)),
        int(round(py_min - ty0 * TILE)),
        int(round(px_max - tx0 * TILE)),
        int(round(py_max - ty0 * TILE)),
    )
    cropped = canvas.crop(box).resize((args.size, args.size), Image.LANCZOS)

    os.makedirs(args.outdir, exist_ok=True)
    slug = args.name.replace(" ", "_")
    png = os.path.join(args.outdir, f"{slug}.png")
    meta_path = os.path.join(args.outdir, f"{slug}.json")
    cropped.save(png, "PNG", optimize=True)

    meta = {
        "name": args.name,
        "center": {"lat": args.lat, "lon": args.lon},
        "km": args.km,
        "zoom": args.zoom,
        "size": args.size,
        "bounds": {"latMin": lat_min, "latMax": lat_max, "lonMin": lon_min, "lonMax": lon_max},
        "attribution": "Map data © OpenStreetMap contributors (ODbL)",
        "tileSource": args.tile_url,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    with open(meta_path, "w", encoding="utf-8") as fh:
        json.dump(meta, fh, ensure_ascii=False, indent=2)

    print(f"saved {png} ({os.path.getsize(png) // 1024} KB)")
    print(f"saved {meta_path}")


if __name__ == "__main__":
    main()
