"""Build a shareable FR255 atlas in a private staging directory."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

from gpx_route import read_gpx, simplify
from make_multilevel_pack import generate, layer_grids
from map_source import HOT_CREDIT, HOT_ATTRIBUTION, PALETTE, project_source, validate_template
from route_document import RouteDocument, validate_waypoints
from gpx_route import project as project_point

ROOT = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parents[1]))
VERSION = '0.8.0-alpha.3'
MAX_IMAGES = 180
MAX_BYTES = 15_000_000


def validate_label(item):
    name = item.get('name')
    if not isinstance(name, str) or not 1 <= len(name.strip()) <= 18 or any(
            not (c.isalnum() or c in ' -_.()（）') for c in name):
        raise ValueError("名称需为 1–18 个文字、数字、空格或短横线")
    if not re.fullmatch('[a-z][a-z0-9_]{0,31}', item.get('id', '')):
        raise ValueError("项目标识需以字母开头，使用小写字母、数字或下划线")


def online_config(project):
    source = project_source(project)
    if source is not None:
        return dict(url=source.url, credit=source.credit) if source.online else None
    config = project.get('online')
    if config is None:
        return None
    if not isinstance(config, dict):
        raise ValueError('在线底图设置无效')
    return validate_template(config.get('url'), config.get('credit'))


def configure_source(app, source):
    credit = source.credit if source else HOT_CREDIT
    colors = ','.join(f'0x{color:06X}' for color in PALETTE)
    content = ('module MapSource {\n    const CREDIT = '
               + json.dumps(credit, ensure_ascii=False)
               + ';\n    var PALETTE = [' + colors + '];\n}\n')
    (app/'source/MapSource.mc').write_text(content, encoding='utf-8')


def configure_network(app, config):
    if config is None:
        return
    # Compose literals and numeric coordinates separately; no user input is code.
    parts=re.split(r'(\{[zxy]\})',config['url'])
    expr=' + '.join(p[1]+'.toString()' if p in ('{x}','{y}','{z}') else json.dumps(p) for p in parts if p)
    src=('module OnlineSource {\n    const ENABLED = true;\n    const CREDIT = '
         +json.dumps(config['credit'],ensure_ascii=False)+';\n    function url(z,x,y) { return '+expr+'; }\n}\n')
    (app/'source/OnlineSource.mc').write_text(src,encoding='utf-8')
    shutil.copyfile(ROOT/'app/online/PhoneTileTransport.mc',app/'source/PhoneTileTransport.mc')
    namespace='http://www.garmin.com/xml/connectiq'
    ET.register_namespace('iq',namespace)
    tree=ET.parse(app/'manifest.xml')
    perms=tree.find('.//{'+namespace+'}permissions')
    ET.SubElement(perms,'{'+namespace+'}uses-permission',id='Communications')
    tree.write(app/'manifest.xml',encoding='utf-8',xml_declaration=True)


def prepare(project, folder, editing=False):
    online_config(project)
    if project.get('version') != 1:
        raise ValueError("不支持的项目版本")
    regions = project.get('regions')
    if not isinstance(regions, list) or not 1 <= len(regions) <= 8:
        raise ValueError("请添加 1–8 个地区")
    ids, summary, total = set(), [], 0
    for region in regions:
        validate_label(region)
        if region['id'] in ids:
            raise ValueError("地区标识重复")
        ids.add(region['id'])
        lat, lon, km = (region[k] for k in ('lat','lon','km'))
        if not (-85 < lat < 85 and -180 <= lon < 180 and 0.25 <= km <= 25):
            raise ValueError("中心经纬度或边长无效（边长 0.25–25 km）")
        layers = layer_grids(lat, lon, km)
        for layer in layers:
            world = 256 << layer['zoom']
            if (layer['origin_x'] < 0 or layer['origin_y'] < 0 or
                layer['origin_x'] + layer['cols']*512 > world or
                layer['origin_y'] + layer['rows']*512 > world):
                raise ValueError("当前地区跨越地图世界边界")
        total += sum(layer['cols'] * layer['rows'] for layer in layers)
        if total > MAX_IMAGES:
            raise ValueError(f"底图超过 {MAX_IMAGES} 张，请缩小地区或拆成两个安装包")
        base = layers[0]
        markers = validate_waypoints(region.get('waypoints',[]))
        synced = [item for item in markers if item['sync']]
        if not editing and len(synced)>32:
            raise ValueError('每个地区最多同步 32 个地点，请调整同步开关')
        for item in synced:
            x,y = project_point(item['lat'],item['lon'])
            if not editing and not (base['origin_x']<=x<base['origin_x']+base['cols']*512 and
                                    base['origin_y']<=y<base['origin_y']+base['rows']*512):
                raise ValueError(f"地点 {item['name']} 超出 {region['name']} 的离线范围")
        routes, route_ids = [], set()
        if len(region.get('routes', [])) > 16:
            raise ValueError("每个地区最多 16 条路线")
        for route in region.get('routes', []):
            validate_label(route)
            if route['id'] in route_ids:
                raise ValueError("同一地区的路线标识重复")
            route_ids.add(route['id'])
            if editing:
                document = RouteDocument.load(folder / route['gpx'])
                segments = [[project_point(*point) for point in segment] for segment in document.segments]
            else:
                segments = read_gpx(folder / route['gpx'])
            for seg in segments:
                for x,y in seg:
                    if not editing and not (base['origin_x'] <= x < base['origin_x'] + base['cols']*512 and
                            base['origin_y'] <= y < base['origin_y'] + base['rows']*512):
                        raise ValueError(f"{route['name']} 超出 {region['name']} 范围，请调整中心/边长")
            routes.append((route, [] if editing else simplify(segments)))
        summary.append((region, layers, routes))
    return summary


def create_app(app, scratch, cache, plan, progress, source=None, transfer=None):
    (app/'source').mkdir(parents=True)
    drawables = app/'resources/drawables'
    drawables.mkdir(parents=True)
    for path in (ROOT/'app/source').glob('*.mc'):
        if path.name not in ('MapCatalog.mc','MapData.mc','MapLayers.mc'):
            shutil.copyfile(path, app/'source'/path.name)
    shutil.copyfile(ROOT/'app/manifest.xml', app/'manifest.xml')
    shutil.copyfile(ROOT/'app/monkey.jungle', app/'monkey.jungle')
    shutil.copyfile(ROOT/'app/resources/drawables/launcher.png', drawables/'launcher.png')
    (app/'resources/strings').mkdir()
    (app/'resources/strings/strings.xml').write_text('<strings><string id="AppName">离线地图</string></strings>', encoding='utf-8')
    route_dir = app/'resources/routes'
    route_dir.mkdir()
    route_xml = ET.Element('jsonDataResources')
    xml = ET.Element('drawables')
    ET.SubElement(xml, 'bitmap', id='LauncherIcon', filename='launcher.png')
    records = []
    for i,(region,layers,routes) in enumerate(plan):
        part = scratch/f'part_{i}'
        tag = f'r{i}_'
        progress(f"制作 {region['name']} 底图")
        generate(part, scratch/'tiles', cache, region['lat'], region['lon'], region['km'],
                 tag, progress, source=source,transfer=transfer)
        for item in ET.parse(part/'resources/drawables/drawables.xml').getroot():
            if item.get('id') != 'LauncherIcon':
                name = item.get('filename')
                shutil.copyfile(part/'resources/drawables'/name, drawables/name)
                xml.append(item)
        if i == 0:
            for name in ('MapData.mc','MapLayers.mc'):
                shutil.copyfile(part/'source'/name, app/'source'/name)
            layer_expr = 'MapLayers.ALL'
        else:
            desc = []
            for layer in layers:
                z, cols, rows = layer['zoom'], layer['cols'], layer['rows']
                ids = [f'Rez.Drawables.Tile_{tag}z{z}_{r}_{c}' for r in range(rows) for c in range(cols)]
                desc.append(f"[{z},{float(layer['scale'])},{layer['origin_x']},{layer['origin_y']},{cols},{rows},["+','.join(ids)+']]')
            layer_expr = '['+','.join(desc)+']'
        route_desc = []
        for j,(route,points) in enumerate(routes):
            rid = f'Route_{i}_{j}'
            filename = rid+'.json'
            (route_dir/filename).write_text(json.dumps(points), encoding='utf-8')
            ET.SubElement(route_xml,'jsonData',id=rid,filename=filename)
            route_desc.append(f'["{route["id"]}","{route["name"]}",Rez.JsonData.{rid}]')
        marker_resource = 'null'
        markers = []
        for item in validate_waypoints(region.get('waypoints',[])):
            if item['sync']:
                x,y = project_point(item['lat'],item['lon'])
                markers.append([x,y,item['name'],item['kind'],item['description'][:160]])
        if markers:
            rid = f'Waypoints_{i}'
            filename = rid+'.json'
            (route_dir/filename).write_text(json.dumps(markers,ensure_ascii=False),encoding='utf-8')
            ET.SubElement(route_xml,'jsonData',id=rid,filename=filename)
            marker_resource = f'Rez.JsonData.{rid}'
        records.append(f'["{region["id"]}","{region["name"]}",{float(region["lat"]):.7f},{float(region["lon"]):.7f},{layer_expr},['+','.join(route_desc)+'],'+marker_resource+']')
    ET.ElementTree(xml).write(drawables/'drawables.xml', encoding='utf-8')
    if len(route_xml):
        ET.ElementTree(route_xml).write(route_dir/'routes.xml', encoding='utf-8')
    (app/'source/MapCatalog.mc').write_text('module MapCatalog { var REGIONS = ['+',\n'.join(records)+']; }\n', encoding='utf-8')
    configure_source(app, source)


def project_budget(project, folder, cache):
    plan = prepare(project, folder, editing=True)
    source = project_source(project)
    coordinates = set()
    images = 0
    for _, layers, _ in plan:
        for layer in layers:
            images += layer['cols'] * layer['rows']
            for x in range(layer['origin_x']//256, layer['origin_x']//256 + layer['cols']*2):
                for y in range(layer['origin_y']//256, layer['origin_y']//256 + layer['rows']*2):
                    coordinates.add((layer['zoom'], x, y))
    cached = 0
    for z, x, y in coordinates:
        path = source.cache_path(cache, z, x, y) if source else Path(cache)/str(z)/str(x)/f'{y}.png'
        cached += path.is_file()
    # Uncompressed indexed pixels give a transparent estimate, not a PRG size prediction.
    return dict(images=images, max_images=MAX_IMAGES, source_tiles=len(coordinates),
                cached_tiles=cached, download_tiles=len(coordinates)-cached,
                bitmap_bytes=images*512*512, palette_colors=16 if source else 64,
                max_prg_bytes=MAX_BYTES, zoom_levels=[13, 15],
                source=source.metadata() if source else None)


def garmin_data_roots():
    if sys.platform == 'win32':
        roaming = os.environ.get('APPDATA')
        fallback = Path.home()/'AppData/Roaming'
        parents = [Path(roaming), fallback] if roaming else [fallback]
        return list(dict.fromkeys(p/'Garmin/ConnectIQ' for p in parents))
    if sys.platform == 'darwin':
        return [Path.home()/'Library/Application Support/Garmin/ConnectIQ']
    return [Path.home()/'.Garmin/ConnectIQ']


def fr255_profile(explicit=None):
    """Return the validated profile folder used for this compiler invocation."""
    locations = []
    if explicit:
        p = Path(explicit).expanduser()
        locations = [p, p/'fr255', p/'Devices/fr255']
    else:
        for root in garmin_data_roots():
            redirect = root/'sdkmanager-download-location.cfg'
            if redirect.is_file():
                try:
                    lines = redirect.read_text(encoding='utf-8-sig').splitlines()
                except (OSError, UnicodeError):
                    lines = []
                if lines and lines[0].strip():
                    locations.append(Path(lines[0].strip())/'Devices/fr255')
            locations.append(root/'Devices/fr255')
    checked = []
    for folder in dict.fromkeys(locations):
        checked.append(str(folder))
        try:
            config = json.loads((folder/'compiler.json').read_text(encoding='utf-8-sig'))
            if (isinstance(config, dict) and config.get('deviceId') == 'fr255'
                    and (folder/'fr255.bin').stat().st_size > 0):
                return folder.resolve()
        except (OSError, UnicodeError, ValueError):
            continue
    raise ValueError('未找到完整的普通 Forerunner 255 设备配置。请在 Garmin SDK Manager 的 Devices 中安装或更新 Forerunner 255，'
                     '或在「制包设置」中选择已有的 Devices/fr255 目录。已检查：\n'+'\n'.join(checked))


def run_tool(args, cwd, progress):
    with subprocess.Popen([str(v) for v in args], cwd=cwd, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace',
            creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0)) as process:
        tail = []
        first_error = None
        for line in process.stdout:
            tail = (tail+[line.rstrip()])[-12:]
            if first_error is None and line.lstrip().startswith('ERROR:'):
                first_error = line.strip()
            progress(line.rstrip())
        if process.wait():
            raise ValueError('Garmin 工具执行失败\n'+(first_error or '\n'.join(tail)))


def build(project, folder, output, sdk, java, key, cache, progress=print, test=False, devices=None, transfer=None):
    plan = prepare(project, folder)
    source = project_source(project)
    if source is not None:
        source.require_offline()
    jar = Path(sdk).resolve()/'bin/monkeybrains.jar'
    key = Path(key).resolve()
    java = str(Path(shutil.which(str(java)) or java).resolve())
    for dep in (jar, key, Path(java)):
        if not dep.is_file():
            raise ValueError(f"缺少制包工具或签名文件：{dep}")
    profile = fr255_profile(devices)
    progress(f"FR255 设备配置：{profile}")
    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='atlas-',dir=output.parent) as private:
        scratch = Path(private)
        app = scratch/'app'
        create_app(app,scratch,Path(cache).resolve(),plan,progress,source=source,transfer=transfer)
        online=online_config(project)
        configure_network(app,online)
        prg = scratch/'weinan-fr255.prg'  # Same filename as earlier sideloads.
        args = [java,'-Xmx2g','-Dfile.encoding=UTF-8','-jar',jar,'-f','monkey.jungle',
                '--override-devices-json',profile,'-d','fr255','-y',key,'-o',prg]
        if test:
            shutil.copytree(ROOT/'tests/monkeyc',app/'tests')
            with (app/'monkey.jungle').open('a',encoding='utf-8') as f:
                f.write('\nbase.sourcePath = source;tests\n')
            args.append('-t')
        progress("正在编译 FR255 应用")
        if transfer is not None:
            transfer.set_stage('正在编译 FR255 应用')
        run_tool(args,app,progress)
        if not prg.is_file() or prg.stat().st_size > MAX_BYTES:
            raise ValueError("PRG 超过 15 MB 预算，请缩小地区")
        meta = dict(version=VERSION, device='fr255', bytes=prg.stat().st_size,
                    sha256=hashlib.sha256(prg.read_bytes()).hexdigest(),
                    coordinate_system='WGS84', source=source.credit if source else 'OpenStreetMap France HOT',
                    attribution=source.attribution if source else HOT_ATTRIBUTION,
                    map_source=source.metadata() if source else None,
                    budget=project_budget(project,folder,cache),
                    online_source=online['credit'] if online else None,
                    regions=[dict(name=r['name'], id=r['id'], center=[r['lat'],r['lon']], km=r['km'],
                                  waypoints=sum(item.get('sync',True) for item in r.get('waypoints',[])),
                                  routes=[dict(name=t['name'], points=sum(v is not None for v in pts)//2) for t,pts in routes]) for r,_,routes in plan])
        archive = scratch/'install.zip'
        with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
            z.write(prg,prg.name)
            z.writestr('atlas.json',json.dumps(meta,ensure_ascii=False,indent=2))
            z.write(ROOT/'docs/INSTALL-V05.md','INSTALL.md')
            z.write(ROOT/'LICENSE','LICENSE')
            z.writestr('MAP-LICENSE.txt', meta['attribution'])
        with zipfile.ZipFile(archive) as z:
            if z.testzip() or hashlib.sha256(z.read(prg.name)).hexdigest() != meta['sha256']:
                raise ValueError('安装包校验失败')
        os.replace(archive,output)
        return meta


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('project',type=Path)
    parser.add_argument('--check',action='store_true')
    parser.add_argument('--output',type=Path,default=Path('fr255-atlas.zip'))
    parser.add_argument('--sdk',default=os.environ.get('CIQ_SDK',''))
    parser.add_argument('--java',default=os.environ.get('CIQ_JAVA','java'))
    parser.add_argument('--key',default=os.environ.get('CIQ_KEY','developer_key.der'))
    parser.add_argument('--devices',default=os.environ.get('CIQ_DEVICES'),help='Garmin Devices 或 fr255 配置目录（默认自动查找）')
    parser.add_argument('--cache',type=Path,default=Path('maps/cache/hot'))
    parser.add_argument('--direct',action='store_true')
    parser.add_argument('--tests',action='store_true',help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.direct:
        urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))
    project = json.loads(args.project.read_text(encoding='utf-8-sig'))
    folder = args.project.resolve().parent
    if args.check:
        for region,layers,routes in prepare(project,folder):
            print(region['name'], sum(l['cols']*l['rows'] for l in layers), 'tiles,',len(routes),'routes')
        return
    build(project,folder,args.output,args.sdk,args.java,args.key,args.cache,test=args.tests,devices=args.devices)


if __name__ == '__main__':
    main()
