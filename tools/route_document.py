"""Full precision GPX editing data and recoverable, bounded undo history."""
import copy
from dataclasses import dataclass, field
import hashlib
import json
import math
import os
from pathlib import Path
import tempfile
import uuid
import xml.etree.ElementTree as ET

GPX_NS = 'http://www.topografix.com/GPX/1/1'
ATLAS_NS = 'https://github.com/Downmars/garmin-watch-map/waypoints/1'
KINDS = ['地点', '补给', '停车', '危险', '休息', '观景']
MAX_EDIT_POINTS = 20000


def coordinate(lat, lon):
    lat, lon = float(lat), float(lon)
    if not (math.isfinite(lat) and math.isfinite(lon) and -85 < lat < 85 and -180 <= lon < 180):
        raise ValueError('经纬度超出 WGS84 地图范围')
    return lat, lon


def atomic_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def waypoint(lat, lon, name='地点', kind=0, description='', sync=True, identity=None):
    lat, lon = coordinate(lat, lon)
    if not isinstance(name, str) or not name.strip() or len(name) > 32 or not name.isprintable():
        raise ValueError('地点名称需为 1–32 个可显示字符')
    if not isinstance(kind, int) or not 0 <= kind < len(KINDS):
        raise ValueError('地点类别无效')
    if not isinstance(description, str) or len(description) > 500:
        raise ValueError('地点备注最多 500 个字符')
    if not isinstance(sync, bool):
        raise ValueError('同步开关无效')
    if identity is not None and (not isinstance(identity,str) or not identity or len(identity)>64):
        raise ValueError('地点标识无效')
    return dict(id=identity or 'w'+uuid.uuid4().hex[:12],lat=lat,lon=lon,name=name.strip(),
                kind=kind,description=description,sync=sync)


def validate_waypoints(values):
    if not isinstance(values, list) or len(values) > 256:
        raise ValueError('每个地区最多编辑 256 个地点')
    validated = []
    identities = set()
    for value in values:
        item = waypoint(value['lat'],value['lon'],value['name'],value.get('kind',0),
                        value.get('description',''),value.get('sync',True),value.get('id'))
        if item['id'] in identities:
            raise ValueError('地点标识重复')
        identities.add(item['id'])
        validated.append(item)
    return validated


def merge_waypoints(current, imported):
    result = copy.deepcopy(current)
    known = {(round(p['lat'],8),round(p['lon'],8),p['name']) for p in result}
    for item in imported:
        key = (round(item['lat'],8),round(item['lon'],8),item['name'])
        if key not in known:
            result.append(copy.deepcopy(item))
            known.add(key)
    return validate_waypoints(result)


@dataclass
class RouteDocument:
    name: str = '新路线'
    segments: list = field(default_factory=list)
    waypoints: list = field(default_factory=list)
    metadata: str = ''

    @classmethod
    def load(cls, path):
        path = Path(path)
        if path.stat().st_size > 4_000_000:
            raise ValueError('GPX 超过 4 MB，请先裁剪')
        data = path.read_bytes()
        if b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper() or b'\x00' in data:
            raise ValueError('GPX 需使用 UTF-8，不能包含 DTD')
        root = ET.fromstring(data)
        namespace = root.tag[:-3] if root.tag.endswith('gpx') else None
        if namespace not in ('','{http://www.topografix.com/GPX/1/0}','{'+GPX_NS+'}'):
            raise ValueError('请选择 GPX 1.0/1.1 文件')
        result = cls(name=path.stem)
        count = 0
        for element in root:
            if element.tag == namespace+'metadata':
                result.metadata = ET.tostring(element,encoding='unicode')
            if element.tag == namespace+'wpt':
                if len(result.waypoints)>=256:
                    raise ValueError('每个地区最多编辑 256 个地点')
                kind_name = element.findtext(namespace+'type','地点')
                extension = element.find('.//{'+ATLAS_NS+'}waypoint')
                sync = extension is None or extension.get('sync','true') != 'false'
                identity = extension.get('id') if extension is not None else None
                result.waypoints.append(waypoint(element.get('lat'),element.get('lon'),
                    element.findtext(namespace+'name','地点'),
                    KINDS.index(kind_name) if kind_name in KINDS else 0,
                    element.findtext(namespace+'desc','')[:500],sync,identity))
            groups = []
            if element.tag == namespace+'trk':
                groups = [g.findall(namespace+'trkpt') for g in element.findall(namespace+'trkseg')]
            elif element.tag == namespace+'rte':
                groups = [element.findall(namespace+'rtept')]
            if groups:
                result.name = element.findtext(namespace+'name',result.name)
            for group in groups:
                segment = []
                for point in group:
                    count += 1
                    if count > MAX_EDIT_POINTS:
                        raise ValueError('GPX 超过 20000 点，请先裁剪')
                    try:
                        position = coordinate(point.attrib['lat'],point.attrib['lon'])
                    except (ValueError,KeyError,TypeError):
                        raise ValueError('GPX 包含无效经纬度') from None
                    if not segment or position != segment[-1]:
                        segment.append(position)
                if segment:
                    result.segments.append(segment)
        result.waypoints = validate_waypoints(result.waypoints)
        if not result.segments and not result.waypoints:
            raise ValueError('GPX 中没有路线或地点')
        return result

    def export(self):
        ET.register_namespace('',GPX_NS)
        ET.register_namespace('atlas',ATLAS_NS)
        root = ET.Element('{'+GPX_NS+'}gpx',version='1.1',creator='FR255 Atlas Studio')
        if self.metadata:
            root.append(ET.fromstring(self.metadata))
        for item in validate_waypoints(self.waypoints):
            node = ET.SubElement(root,'{'+GPX_NS+'}wpt',lat=f"{item['lat']:.10f}",lon=f"{item['lon']:.10f}")
            for tag,text in [('name',item['name']),('desc',item['description']),('type',KINDS[item['kind']])]:
                ET.SubElement(node,'{'+GPX_NS+'}'+tag).text = text
            extension = ET.SubElement(node,'{'+GPX_NS+'}extensions')
            ET.SubElement(extension,'{'+ATLAS_NS+'}waypoint',id=item['id'],sync=str(item['sync']).lower())
        if self.segments:
            track = ET.SubElement(root,'{'+GPX_NS+'}trk')
            ET.SubElement(track,'{'+GPX_NS+'}name').text = self.name
            for segment in self.segments:
                if len(segment) < 2:
                    raise ValueError('每个路线分段至少需要两个点，请补点或删除此分段')
                node = ET.SubElement(track,'{'+GPX_NS+'}trkseg')
                for lat,lon in segment:
                    coordinate(lat,lon)
                    ET.SubElement(node,'{'+GPX_NS+'}trkpt',lat=f'{lat:.10f}',lon=f'{lon:.10f}')
        if not self.segments and not self.waypoints:
            raise ValueError('请先绘制路线或添加地点')
        return ET.tostring(root,encoding='utf-8',xml_declaration=True)

    def snapshot(self):
        return copy.deepcopy(self.__dict__)

    def distance(self):
        meters = 0.0
        for segment in self.segments:
            for a,b in zip(segment,segment[1:]):
                lat1,lat2 = math.radians(a[0]),math.radians(b[0])
                dlat,dlon = lat2-lat1,math.radians(b[1]-a[1])
                value = math.sin(dlat/2)**2 + math.cos(lat1)*math.cos(lat2)*math.sin(dlon/2)**2
                meters += 12742000*math.asin(min(1,math.sqrt(value)))
        return meters


class EditorHistory:
    def __init__(self, document):
        self.document = document
        self.undo_stack = []
        self.redo_stack = []

    def commit(self, before):
        if before == self.document.snapshot():
            return False
        self.undo_stack.append(before)
        self.undo_stack = self.undo_stack[-50:]
        self.redo_stack.clear()
        return True

    def restore(self, source, destination):
        if not source:
            return False
        destination.append(self.document.snapshot())
        self.document.__dict__.update(copy.deepcopy(source.pop()))
        return True

    def undo(self):
        return self.restore(self.undo_stack,self.redo_stack)

    def redo(self):
        return self.restore(self.redo_stack,self.undo_stack)


class DraftStore:
    def __init__(self, folder, identity):
        digest = hashlib.sha256(identity.encode('utf-8')).hexdigest()[:24]
        self.path = Path(folder)/'editor-drafts'/f'{digest}.json'
        self.invalid = False

    def save(self, document):
        if self.invalid and self.path.exists():
            original = self.path.read_bytes()
            digest = hashlib.sha256(original).hexdigest()[:12]
            atomic_write(self.path.with_suffix('.'+digest+'.invalid'),original)
        data = dict(version=1,document=document.snapshot())
        atomic_write(self.path,json.dumps(data,ensure_ascii=False).encode('utf-8'))
        self.invalid = False

    def load(self):
        if not self.path.exists():
            return None
        self.invalid = True
        if self.path.stat().st_size > 8_000_000:
            raise ValueError('草稿文件过大，已保留原文件')
        payload = json.loads(self.path.read_text(encoding='utf-8'))
        if payload.get('version') != 1:
            raise ValueError('草稿版本无效，已保留原文件')
        data = payload['document']
        segments = [[coordinate(*point) for point in segment] for segment in data['segments']]
        if sum(len(segment) for segment in segments) > MAX_EDIT_POINTS:
            raise ValueError('草稿路线点过多')
        result = RouteDocument(data['name'],segments,validate_waypoints(data['waypoints']),data.get('metadata',''))
        self.invalid = False
        return result

    def clear(self):
        self.path.unlink(missing_ok=True)
