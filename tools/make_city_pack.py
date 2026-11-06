#!/usr/bin/env python3
"""一键生成城市离线瓦片 App。

用法示例：
  python make_city_pack.py --name beijing --lat 39.9042 --lon 116.4074 --km 20 --zoom 15 --out dist/Beijing.prg
  python make_city_pack.py --name qingdao --lat 36.10 --lon 120.43 --km 24 --zoom 15

流程：下载 z 瓦片 -> 拼接 512px 大瓦片 -> 生成 MapData.mc/drawables.xml -> 调用 monkeyc 编译。
"""
import argparse
import io
import json
import math
import os
import shutil
import subprocess
import sys
import time
import urllib.request

from PIL import Image

TILE_SIZE = 512
Z_TILE = 256
HOSTS = ("a", "b", "c")
UA = "garmin-watch-map/1.1 (+https://github.com/cc2994358194-create/garmin-watch-map)"


def lon_to_x(lon, z):
    return (lon + 180.0) / 360.0 * (Z_TILE << z)


def lat_to_y(lat, z):
    rad = math.radians(lat)
    return (1.0 - math.log(math.tan(rad) + 1.0 / math.cos(rad)) / math.pi) / 2.0 * (Z_TILE << z)


def fetch_tile(z, x, y, cache, retries=3, cache_dir=None):
    key = (z, x, y)
    if key in cache:
        return cache[key]
    disk = os.path.join(cache_dir, str(z), str(x), f"{y}.png") if cache_dir else None
    if disk and os.path.isfile(disk):
        with Image.open(disk) as saved:
            saved.load()
            if saved.size != (Z_TILE, Z_TILE):
                raise ValueError(f"Invalid cached tile size: {disk}")
            cache[key] = saved.convert("RGB")
        return cache[key]
    last = None
    for host in HOSTS:
        for attempt in range(retries):
            url = f"https://{host}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png"
            try:
                req = urllib.request.Request(url, headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=25) as resp:
                    img = Image.open(io.BytesIO(resp.read())).convert("RGB")
                if img.size != (Z_TILE, Z_TILE):
                    raise ValueError(f"Invalid tile size from {url}: {img.size}")
                if disk:
                    os.makedirs(os.path.dirname(disk), exist_ok=True)
                    img.save(disk + ".tmp", "PNG")
                    os.replace(disk + ".tmp", disk)
                cache[key] = img
                time.sleep(0.25)
                return img
            except Exception as exc:  # noqa: BLE001
                last = exc
                time.sleep(1 + attempt)
    raise RuntimeError(f"Tile download failed {z}/{x}/{y}: {last}. Rerun to resume from cache.") from last


def build_tiles(lat, lon, km, zoom, outdir, cache, cache_dir=None):
    world = Z_TILE << zoom
    mpp = 156543.03392 * math.cos(math.radians(lat)) / (2 ** zoom)
    cx = lon_to_x(lon, zoom)
    cy = lat_to_y(lat, zoom)
    half = km * 1000.0 / mpp / 2.0
    gx0 = int(math.floor((cx - half) / TILE_SIZE) * TILE_SIZE)
    gy0 = int(math.floor((cy - half) / TILE_SIZE) * TILE_SIZE)
    cols = int(math.ceil((cx + half - gx0) / TILE_SIZE))
    rows = int(math.ceil((cy + half - gy0) / TILE_SIZE))
    print(f"      {cols}x{rows} map images, {cols * rows * 4} source tiles", flush=True)

    os.makedirs(outdir, exist_ok=True)
    names = []
    for j in range(rows):
        for i in range(cols):
            tx = gx0 // Z_TILE + i * 2
            ty = gy0 // Z_TILE + j * 2
            canvas = Image.new("RGB", (TILE_SIZE, TILE_SIZE))
            for b in range(2):
                for a in range(2):
                    canvas.paste(fetch_tile(zoom, tx + a, ty + b, cache, cache_dir=cache_dir), (a * Z_TILE, b * Z_TILE))
            fn = f"tile_{j}_{i}.png"
            canvas.save(os.path.join(outdir, fn), "PNG", optimize=True)
            names.append(fn)
            print(f"      [{len(names)}/{cols * rows}] {fn}", flush=True)
    return gx0, gy0, cols, rows, names, mpp


def emit_sources(app_dir, gx0, gy0, cols, rows, names, mpp, outdir, world, lat, lon):
    src = os.path.join(app_dir, "source")
    res = os.path.join(app_dir, "resources", "drawables")
    os.makedirs(src, exist_ok=True)
    os.makedirs(res, exist_ok=True)

    for old in os.listdir(res):
        if old.startswith("tile_") and old.endswith(".png"):
            os.remove(os.path.join(res, old))
    for fn in names:
        shutil.copyfile(os.path.join(outdir, fn), os.path.join(res, fn))

    tile_lines = "".join(
        f"    const TILE_{j}_{i} = Rez.Drawables.Tile_{j}_{i};\n" for j in range(rows) for i in range(cols)
    )
    all_entries = "".join(f"        TILE_{j}_{i},\n" for j in range(rows) for i in range(cols))
    scale_m = round(60 * mpp)
    scale = f"{scale_m / 1000.0:.1f}km" if scale_m >= 1000 else f"{scale_m}m"
    data = (
        "module MapData {\n"
        f"    const CENTER_LAT = {lat:.6f};\n"
        f"    const CENTER_LON = {lon:.6f};\n"
        f"    const ORIGIN_X = {gx0};\n"
        f"    const ORIGIN_Y = {gy0};\n"
        f"    const WORLD = {world};\n"
        f"    const TILE = {TILE_SIZE};\n"
        f"    const COLS = {cols};\n"
        f"    const ROWS = {rows};\n"
        f"    const SCALE = \"{scale}\";\n"
        "    const W = 260;\n"
        "    const H = 260;\n"
        + tile_lines
        + "    const ALL = [\n"
        + all_entries
        + "    ];\n"
        + "}\n"
    )
    with open(os.path.join(src, "MapData.mc"), "w", encoding="utf-8") as fh:
        fh.write(data)

    xml = ["<drawables>\n"]
    for j in range(rows):
        for i in range(cols):
            xml.append(f'  <bitmap id="Tile_{j}_{i}" filename="tile_{j}_{i}.png" compress="true"/>\n')
    xml.append('  <bitmap id="LauncherIcon" filename="launcher.png"/>\n</drawables>\n')
    with open(os.path.join(res, "drawables.xml"), "w", encoding="utf-8") as fh:
        fh.write("".join(xml))


def _device_data_root(sdk_dir):
    """Locate the folder that owns Garmin\\ConnectIQ\\Devices.

    Device profiles (fr255, venu441mm, ...) are not inside the SDK; monkeyc
    looks them up under <data-root>\\Garmin\\ConnectIQ\\Devices, where
    <data-root> is normally %APPDATA%. A portable SDK drop keeps the same
    layout next to the SDK, i.e. <sdk>\\..\\..\\..\\..
    """
    explicit = os.environ.get("CIQ_APPDATA")
    if explicit:
        return explicit
    candidate = os.path.abspath(os.path.join(sdk_dir, "..", "..", "..", ".."))
    if os.path.isdir(os.path.join(candidate, "Garmin", "ConnectIQ", "Devices")):
        return candidate
    return None


def compile_app(app_dir, sdk_dir, key, out_prg, device="fr255"):
    os.makedirs(os.path.dirname(out_prg) or ".", exist_ok=True)
    env = dict(os.environ)
    env["_JAVA_OPTIONS"] = "-Xmx4g"

    data_root = _device_data_root(sdk_dir)
    if data_root:
        env["APPDATA"] = data_root
    else:
        print("[warn] no device profiles found next to the SDK; "
              "falling back to system APPDATA")

    monkeyc = os.path.join(sdk_dir, "bin", "monkeyc.bat")
    if not os.path.isfile(monkeyc):
        monkeyc = os.path.join(sdk_dir, "bin", "monkeyc")
    cmd = [monkeyc, "-f", os.path.join(app_dir, "monkey.jungle"),
           "-o", out_prg, "-d", device, "-y", key]
    print("compile:", " ".join(cmd))
    subprocess.check_call(cmd, env=env)


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True, help="城市名，仅用于输出文件名")
    ap.add_argument("--lat", type=float, required=True)
    ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--km", type=float, required=True, help="覆盖边长（公里）")
    ap.add_argument("--zoom", type=int, default=15, help="瓦片级别，15≈2m/px")
    ap.add_argument("--app", default="app", help="CIQ 工程目录")
    ap.add_argument("--outdir", default="maps")
    ap.add_argument("--out", default="", help="输出 .prg 路径")
    ap.add_argument("--sdk", help="Connect IQ SDK 目录")
    ap.add_argument("--key", help="developer_key.der")
    ap.add_argument("--device", default="fr255")
    ap.add_argument("--tiles-only", action="store_true", help="只生成地图与资源，不编译")
    ap.add_argument("--cache-dir", default="maps/cache/hot", help="原始瓦片持久缓存目录")
    ap.add_argument("--direct", action="store_true", help="本次下载不使用系统代理")
    ARGS = ap.parse_args()
    if not (-85 < ARGS.lat < 85 and -180 <= ARGS.lon <= 180 and 1 <= ARGS.zoom <= 19 and ARGS.km > 0):
        ap.error("Invalid latitude, longitude, zoom or coverage size")
    if not ARGS.tiles_only:
        if not ARGS.sdk or not os.path.isfile(os.path.join(ARGS.sdk, "bin", "monkeybrains.jar")):
            ap.error("Provide --sdk pointing to an installed Connect IQ SDK")
        if not ARGS.key or not os.path.isfile(ARGS.key):
            ap.error("Provide --key pointing to a developer signing key")
    if ARGS.direct:
        urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))

    out_prg = ARGS.out or os.path.join("dist", f"{ARGS.name}.prg")
    cache = {}
    print(f"[1/3] 生成瓦片 {ARGS.name}: {ARGS.km}km @z{ARGS.zoom}")
    gx0, gy0, cols, rows, names, mpp = build_tiles(ARGS.lat, ARGS.lon, ARGS.km, ARGS.zoom, ARGS.outdir, cache, ARGS.cache_dir)
    print(f"      {cols}x{rows} = {cols * rows} 张，约 {mpp:.2f} m/px")

    print("[2/3] 生成资源")
    emit_sources(ARGS.app, gx0, gy0, cols, rows, names, mpp, ARGS.outdir, Z_TILE << ARGS.zoom, ARGS.lat, ARGS.lon)
    metadata = dict(name=ARGS.name, center_lat=ARGS.lat, center_lon=ARGS.lon,
                    requested_km=ARGS.km, zoom=ARGS.zoom, origin_x=gx0, origin_y=gy0,
                    cols=cols, rows=rows, tile_pixels=TILE_SIZE, meters_per_pixel=mpp,
                    source="OpenStreetMap France HOT", attribution="Map data (c) OpenStreetMap contributors, ODbL; tiles (c) OpenStreetMap France, CC BY-SA 2.0",
                    tiles=names)
    with open(os.path.join(ARGS.outdir, "metadata.json"), "w", encoding="utf-8") as fh:
        json.dump(metadata, fh, ensure_ascii=False, indent=2)
    if ARGS.tiles_only:
        print("Map resources ready; compilation skipped.")
        return

    print("[3/3] 编译")
    compile_app(ARGS.app, ARGS.sdk, ARGS.key, out_prg, ARGS.device)
    size = os.path.getsize(out_prg) / 1e6
    print(f"完成: {out_prg} ({size:.1f} MB)")


if __name__ == "__main__":
    main()
