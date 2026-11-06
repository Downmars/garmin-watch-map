#!/usr/bin/env python3
"""Turn generated map JSON files into Connect IQ app resources."""
import argparse
import json
import os
from PIL import Image


def load(meta_path):
    with open(meta_path, encoding="utf-8") as fh:
        return json.load(fh)


def save_260(src_png, size, dst):
    img = Image.open(src_png).convert("RGB")
    if size != 260:
        img = img.resize((260, 260), Image.LANCZOS)
    img.save(dst, "PNG", optimize=True)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--meta", required=True)
    ap.add_argument("--detail", default="")
    ap.add_argument("--app", required=True)
    args = ap.parse_args()

    wide = load(args.meta)
    drawables = os.path.join(args.app, "resources", "drawables")
    os.makedirs(drawables, exist_ok=True)

    wide_img = save_260(os.path.splitext(args.meta)[0] + ".png", wide["size"], os.path.join(drawables, "map_wide.png"))
    wide_img.resize((40, 40), Image.LANCZOS).save(os.path.join(drawables, "launcher.png"), "PNG", optimize=True)

    detail = None
    if args.detail:
        detail = load(args.detail)
        save_260(os.path.splitext(args.detail)[0] + ".png", detail["size"], os.path.join(drawables, "map_detail.png"))

    def block(prefix, meta):
        b = meta["bounds"]
        return (
            f"    const {prefix}_LAT_MIN = {b['latMin']:.6f};\n"
            f"    const {prefix}_LAT_MAX = {b['latMax']:.6f};\n"
            f"    const {prefix}_LON_MIN = {b['lonMin']:.6f};\n"
            f"    const {prefix}_LON_MAX = {b['lonMax']:.6f};\n"
        )

    mc = os.path.join(args.app, "source", "MapData.mc")
    with open(mc, "w", encoding="utf-8") as fh:
        fh.write("module MapData {\n")
        fh.write(block("WIDE", wide))
        if detail is not None:
            fh.write(block("DETAIL", detail))
        fh.write("    const W = 260;\n")
        fh.write("    const H = 260;\n")
        fh.write("}\n")

    print(f"updated {mc}")
    print(f"wide -> {drawables}\\map_wide.png")
    if detail is not None:
        print(f"detail -> {drawables}\\map_detail.png")


if __name__ == "__main__":
    main()
