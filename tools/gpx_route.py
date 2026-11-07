"""Read GPX tracks/routes into bounded, disconnected z15 screen polylines."""
import heapq
import math
from pathlib import Path
import xml.etree.ElementTree as ET

from make_city_pack import lon_to_x, lat_to_y

MAX_POINTS = 192
MAX_INPUT = 20000
MAX_ERROR_PX = 6  # About 24 m at Weinan. Reject instead of silently distorting.


def project(lat, lon):
    if not (math.isfinite(lat) and -85 < lat < 85 and math.isfinite(lon) and -180 <= lon < 180):
        raise ValueError("GPX 坐标超出 WGS84 地图范围")
    return (round(lon_to_x(lon, 15)), round(lat_to_y(lat, 15)))


def read_gpx(path):
    path = Path(path)
    if path.stat().st_size > 4_000_000:
        raise ValueError("GPX 超过 4 MB，请先裁剪")
    data = path.read_bytes()
    if b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper() or b'\x00' in data:
        raise ValueError("GPX 需使用 UTF-8，不能包含 DTD")
    root = ET.fromstring(data)
    ns = root.tag[:-3] if root.tag.endswith('gpx') else None
    if ns not in ('', '{http://www.topografix.com/GPX/1/0}', '{http://www.topografix.com/GPX/1/1}'):
        raise ValueError("请选择 GPX 1.0/1.1 文件")
    segments = []
    count = 0
    for element in root:
        groups = []
        if element.tag == ns + 'trk':
            groups = [g.findall(ns + 'trkpt') for g in element.findall(ns + 'trkseg')]
        elif element.tag == ns + 'rte':
            groups = [element.findall(ns + 'rtept')]
        for points in groups:
            segment = []
            for p in points:
                count += 1
                if count > MAX_INPUT:
                    raise ValueError("GPX 超过 20000 点，请先裁剪")
                try:
                    xy = project(float(p.attrib['lat']), float(p.attrib['lon']))
                except (ValueError, KeyError) as exc:
                    raise ValueError("GPX 包含无效经纬度") from exc
                if not segment or segment[-1] != xy:
                    segment.append(xy)
            if len(segment) >= 2:
                segments.append(segment)
    if not segments:
        raise ValueError("GPX 没有可连成线的 trkseg/trkpt 或 rte/rtept")
    return segments


def simplify(segments):
    # Repeatedly split the worst chord. Endpoints of every segment are mandatory.
    selected = [{0, len(seg) - 1} for seg in segments]
    count = 2 * len(segments)
    if count > MAX_POINTS:
        raise ValueError("GPX 断段过多")
    queue = []

    def offer(n, a, b):
        line = segments[n]
        ax, ay = line[a]
        dx, dy = line[b][0] - ax, line[b][1] - ay
        length = dx * dx + dy * dy
        best, split = 0.0, a
        for i in range(a + 1, b):
            x, y = line[i][0] - ax, line[i][1] - ay
            t = min(1, max(0, (x * dx + y * dy) / length)) if length else 0
            error = (x - t * dx)**2 + (y - t * dy)**2
            if error > best:
                best, split = error, i
        if best > 1:
            heapq.heappush(queue, (-best, n, a, b, split))

    for n, seg in enumerate(segments):
        offer(n, 0, len(seg) - 1)
    while queue and count < MAX_POINTS:
        _, n, a, b, split = heapq.heappop(queue)
        selected[n].add(split)
        count += 1
        offer(n, a, split)
        offer(n, split, b)
    if queue and -queue[0][0] > MAX_ERROR_PX**2:
        raise ValueError("路线过于复杂，请拆分为多条 GPX")
    result = []
    for seg, indices in zip(segments, selected):
        if result:
            result.extend([None, None])
        for i in sorted(indices):
            result.extend(seg[i])
    return result
