#!/usr/bin/env python3
"""Emit MapData.mc plus drawable images for the multi-level map app."""
import argparse
import json
import os
from PIL import Image


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--city", default="")
    ap.add_argument("--wide", required=True)
    ap.add_argument("--mid", required=True)
    ap.add_argument("--detail", default="")
    ap.add_argument("--ultra", default="")
    ap.add_argument("--app", required=True)
    args = ap.parse_args()

    drawables = os.path.join(args.app, "resources", "drawables")
    os.makedirs(drawables, exist_ok=True)

    levels = []
    if args.city:
        levels.append(("CITY", args.city))
    levels.append(("WIDE", args.wide))
    levels.append(("MID", args.mid))
    if args.detail:
        levels.append(("DETAIL", args.detail))
    if args.ultra:
        levels.append(("ULTRA", args.ultra))

    blocks = []
    for prefix, meta_path in levels:
        with open(meta_path, encoding="utf-8") as fh:
            meta = json.load(fh)
        b = meta["bounds"]
        meters = round(60 * meta["km"] * 1000.0 / 520.0)
        scale = f"{meters / 1000.0:.1f}km" if meters >= 1000 else f"{meters}m"
        blocks.append(
            f"    const {prefix}_LAT_MIN = {b['latMin']:.6f};\n"
            f"    const {prefix}_LAT_MAX = {b['latMax']:.6f};\n"
            f"    const {prefix}_LON_MIN = {b['lonMin']:.6f};\n"
            f"    const {prefix}_LON_MAX = {b['lonMax']:.6f};\n"
            f"    const {prefix}_AREA_KM = {meta['km']:.6f};\n"
            f"    const {prefix}_SCALE = \"{scale}\";\n"
        )
        src = os.path.splitext(meta_path)[0] + ".png"
        dst = os.path.join(drawables, f"map_{prefix.lower()}.png")
        Image.open(src).convert("RGB").save(dst, "PNG", optimize=True)

    mid_src = os.path.splitext(args.mid)[0] + ".png"
    Image.open(mid_src).convert("RGB").resize((40, 40), Image.LANCZOS).save(
        os.path.join(drawables, "launcher.png"), "PNG", optimize=True
    )

    mc = os.path.join(args.app, "source", "MapData.mc")
    with open(mc, "w", encoding="utf-8") as fh:
        fh.write("module MapData {\n")
        fh.write("".join(blocks))
        fh.write("    const W = 260;\n    const H = 260;\n    const SRC = 520;\n}\n")
    print(f"updated {mc} ({len(levels)} levels)")


if __name__ == "__main__":
    main()
