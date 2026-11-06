#!/usr/bin/env python3
"""High-quality map-style launcher icon: renders at 320px then downsamples to 40px.

Run from anywhere; output paths are derived from this file's location:

    <repo>/maps/icon_final_320.png
    <repo>/maps/icon_final_160.png
    <repo>/app/resources/drawables/launcher.png

Requires Pillow:  pip install pillow
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

S = 320
OUT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

os.makedirs(os.path.join(OUT, "maps"), exist_ok=True)
os.makedirs(os.path.join(OUT, "app", "resources", "drawables"), exist_ok=True)

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# --- base card ---
card = Image.new("RGBA", (S, S), (0, 0, 0, 0))
cd = ImageDraw.Draw(card)
cd.rounded_rectangle([8, 8, S - 8, S - 8], radius=72, fill=(250, 248, 242, 255))
img.alpha_composite(card)
d = ImageDraw.Draw(img)

# --- soft map blocks ---
blocks = [
    (34, 46, 150, 132, (238, 234, 224, 255)),
    (186, 40, 286, 112, (238, 234, 224, 255)),
    (176, 196, 286, 276, (238, 234, 224, 255)),
    (40, 210, 140, 288, (242, 239, 230, 255)),
]
for x0, y0, x1, y1, c in blocks:
    d.rounded_rectangle([x0, y0, x1, y1], radius=14, fill=c)

# --- green park ---
park = Image.new("RGBA", (S, S), (0, 0, 0, 0))
pd = ImageDraw.Draw(park)
pd.ellipse([196, 118, 306, 214], fill=(196, 228, 186, 255))
pd.ellipse([176, 168, 250, 232], fill=(196, 228, 186, 255))
img.alpha_composite(park)
d = ImageDraw.Draw(img)

# --- water ---
water = Image.new("RGBA", (S, S), (0, 0, 0, 0))
wd = ImageDraw.Draw(water)
wd.rounded_rectangle([24, 232, 150, 300], radius=26, fill=(170, 209, 235, 255))
img.alpha_composite(water)
d = ImageDraw.Draw(img)


# --- roads ---
def curve(points, width, color):
    d.line(points, fill=color, width=width, joint="curve")
    r = width // 2
    for px, py in points:
        d.ellipse([px - r, py - r, px + r, py + r], fill=color)


# yellow highway with white casing
main = [(6, 196), (86, 176), (168, 190), (250, 168), (314, 182)]
curve(main, 30, (255, 255, 255, 255))
curve(main, 18, (255, 205, 92, 255))

# secondary grey road
side = [(60, 316), (92, 244), (140, 186), (176, 132), (196, 70)]
curve(side, 16, (255, 255, 255, 255))
curve(side, 9, (206, 200, 189, 255))

# --- location arrow ---
arrow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ad = ImageDraw.Draw(arrow)
cx, cy = 176, 150
size = 92
rot = math.radians(38)
base = [(0, -1.0), (0.62, 0.78), (0, 0.52), (-0.62, 0.78)]
pts = []
for bx, by in base:
    x, y = bx * size, by * size
    pts.append(
        (
            cx + x * math.cos(rot) - y * math.sin(rot),
            cy + x * math.sin(rot) + y * math.cos(rot),
        )
    )
# shadow
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.polygon([(x + 4, y + 8) for x, y in pts], fill=(0, 0, 0, 60))
shadow = shadow.filter(ImageFilter.GaussianBlur(6))
img.alpha_composite(shadow)
d = ImageDraw.Draw(img)
# white outline + blue fill
ad.polygon(pts, fill=(255, 255, 255, 255))
inner = [(cx + (x - cx) * 0.78, cy + (y - cy) * 0.78) for x, y in pts]
ad.polygon(inner, fill=(255, 0, 0, 255))
ad.ellipse([cx - 12, cy - 12, cx + 12, cy + 12], fill=(255, 255, 255, 255))
img.alpha_composite(arrow)
d = ImageDraw.Draw(img)

# --- subtle inner border ---
d.rounded_rectangle([8, 8, S - 8, S - 8], radius=72, outline=(226, 221, 210, 255), width=3)

img.save(os.path.join(OUT, "maps", "icon_final_320.png"), "PNG")
img.resize((160, 160), Image.LANCZOS).save(os.path.join(OUT, "maps", "icon_final_160.png"), "PNG")
img.resize((40, 40), Image.LANCZOS).save(
    os.path.join(OUT, "app", "resources", "drawables", "launcher.png"), "PNG", optimize=True
)
print("icon rendered ->", os.path.join(OUT, "app", "resources", "drawables", "launcher.png"))
