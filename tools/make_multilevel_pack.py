"""Build two aligned offline levels; activate resources only after all downloads succeed."""
import argparse
import json
import math
import os
from pathlib import Path
import shutil
import tempfile
import urllib.request

from PIL import Image
import make_city_pack as city
from map_source import quantize


def layer_grids(lat, lon, km):
    mpp = 156543.03392 * math.cos(math.radians(lat)) / (2 ** 15)
    cx, cy = city.lon_to_x(lon, 15), city.lat_to_y(lat, 15)
    half = km * 1000 / mpp / 2
    x = math.floor((cx - half) / 512) * 512
    y = math.floor((cy - half) / 512) * 512
    cols = math.ceil((cx + half - x) / 512)
    rows = math.ceil((cy + half - y) / 512)
    levels = []
    for z in (15, 13):
        scale = 2 ** (z - 15)
        ox = math.floor(x * scale / 512) * 512
        oy = math.floor(y * scale / 512) * 512
        levels.append(dict(zoom=z, scale=scale, origin_x=ox, origin_y=oy,
                           cols=math.ceil(((x + cols * 512) * scale - ox) / 512),
                           rows=math.ceil(((y + rows * 512) * scale - oy) / 512)))
    return levels


def generate(app, output, cache_dir, lat, lon, km, tag='', progress=None, source=None):
    if source is not None:
        source.require_offline()
    app, output = Path(app), Path(output)
    levels = layer_grids(lat, lon, km)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='layers-', dir=output) as scratch:
        stage = Path(scratch)
        names = []
        for layer in levels:
            cache = {}
            resources = []
            for row in range(layer['rows']):
                for col in range(layer['cols']):
                    tile = Image.new('RGB', (512, 512))
                    tx, ty = layer['origin_x'] // 256 + col * 2, layer['origin_y'] // 256 + row * 2
                    for dy in range(2):
                        for dx in range(2):
                            if source is None:
                                image = city.fetch_tile(layer['zoom'], tx + dx, ty + dy, cache,
                                                        cache_dir=str(cache_dir))
                            else:
                                image = source.fetch(layer['zoom'], tx + dx, ty + dy, cache, cache_dir)
                            tile.paste(image, (dx * 256, dy * 256))
                    name = f"tile_{tag}z{layer['zoom']}_{row}_{col}.png"
                    if source is not None:
                        quantize(tile).save(stage / name, 'PNG', optimize=True, bits=4)
                    else:
                        tile.save(stage / name, 'PNG', optimize=True)
                    resources.append(f"Rez.Drawables.Tile_{tag}z{layer['zoom']}_{row}_{col}")
                    names.append(name)
                    if progress is None:
                        print(f"ready {name}", flush=True)
                    else:
                        progress(name)
            layer['resources'] = resources
        base = levels[0]
        data = ('module MapData {\n'
                f'    const CENTER_LAT = {lat:.6f};\n    const CENTER_LON = {lon:.6f};\n'
                f"    const WORLD = {256 << 15};\n    const TILE = 512;\n"
                f"    const ORIGIN_X = {base['origin_x']};\n    const ORIGIN_Y = {base['origin_y']};\n"
                f"    const COLS = {base['cols']};\n    const ROWS = {base['rows']};\n"
                '    const W = 260;\n    const H = 260;\n'
                '    const ALL = [' + ','.join(base['resources']) + '];\n}\n')
        # Descriptor: zoom, scale from canonical z15, origin X/Y, columns/rows, resource IDs.
        descriptions = []
        for layer in levels:
            descriptions.append(f"[{layer['zoom']}, {float(layer['scale'])}, {layer['origin_x']}, {layer['origin_y']}, {layer['cols']}, {layer['rows']}, [" + ','.join(layer['resources']) + ']]')
        layers = 'module MapLayers {\n    var ALL = [\n        ' + ',\n        '.join(descriptions) + '\n    ];\n}\n'
        xml = '<drawables>\n' + ''.join(f'  <bitmap id="{name[:-4].replace("tile_", "Tile_")}" filename="{name}" compress="true"/>\n' for name in names)
        xml += '  <bitmap id="LauncherIcon" filename="launcher.png"/>\n</drawables>\n'
        # No active files are touched until every source tile has been validated and assembled.
        drawables = app / 'resources/drawables'
        drawables.mkdir(parents=True, exist_ok=True)
        (app / 'source').mkdir(parents=True, exist_ok=True)
        for name in names:
            shutil.copyfile(stage / name, drawables / (name + '.new'))
            os.replace(drawables / (name + '.new'), drawables / name)
        for dest, content in ((app / 'source/MapData.mc', data), (app / 'source/MapLayers.mc', layers),
                              (drawables / 'drawables.xml', xml)):
            temporary = dest.with_suffix(dest.suffix + '.new')
            temporary.write_text(content, encoding='utf-8')
            os.replace(temporary, dest)
        metadata = dict(center_wgs84=[lat, lon], requested_km=km, canonical_zoom=15, tile_pixels=512,
                        source='OpenStreetMap France HOT', levels=[{k:v for k,v in level.items() if k != 'resources'} for level in levels],
                        image_count=len(names), attribution='Map data (c) OpenStreetMap contributors, ODbL; tiles (c) OpenStreetMap France, CC BY-SA 2.0')
        if source is not None:
            metadata.update(source=source.credit, attribution=source.attribution, map_source=source.metadata())
        (output / 'multilevel-metadata.json').write_text(json.dumps(metadata, indent=2), encoding='utf-8')
        return metadata


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--lat', type=float, default=34.5)
    parser.add_argument('--lon', type=float, default=109.5)
    parser.add_argument('--km', type=float, default=20)
    parser.add_argument('--app', default='app')
    parser.add_argument('--outdir', default='maps/weinan-multilevel')
    parser.add_argument('--cache-dir', default='maps/cache/hot')
    parser.add_argument('--direct', action='store_true')
    args = parser.parse_args()
    if not (-85 < args.lat < 85 and -180 <= args.lon <= 180 and 0 < args.km <= 100):
        parser.error('Invalid region')
    if args.direct:
        urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))
    print(json.dumps(generate(args.app, args.outdir, args.cache_dir, args.lat, args.lon, args.km), indent=2))


if __name__ == '__main__':
    main()
