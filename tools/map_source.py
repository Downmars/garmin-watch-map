"""Shared raster source contract for desktop previews, offline packs and the watch."""
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path
import re
import tempfile
import time
import urllib.request
from urllib.parse import quote, urlsplit

from PIL import Image


PALETTE = (0xFFFFFF, 0x000000, 0xEEEEEE, 0xCCCCCC, 0x999999, 0x666666,
           0xFFFFCC, 0xFFCC66, 0xCC9933, 0x99CC99, 0x669966, 0x336633,
           0x99CCFF, 0x6699CC, 0xFF9999, 0xCC6666)
MAPTILER_STYLES = {'streets-v4': '街道', 'outdoor-v4': '户外'}
HOT_CREDIT = '©OSM · OSM France'
HOT_ATTRIBUTION = ('Map data © OpenStreetMap contributors, ODbL; '
                   'tiles © OpenStreetMap France, CC BY-SA 2.0')
USER_AGENT = 'FR255-Atlas-Studio/0.7 (+https://github.com/Downmars/garmin-watch-map)'


def validate_template(url, credit):
    if (not isinstance(url, str) or not url.isascii() or len(url) > 512
            or any(ord(c) <= 32 or ord(c) > 126 or c in '"\\' for c in url)):
        raise ValueError('请输入有效 HTTPS 瓦片模板')
    parts = urlsplit(url)
    if (parts.scheme != 'https' or not parts.hostname or parts.username is not None
            or parts.password is not None or parts.fragment or '{' in parts.netloc):
        raise ValueError('底图需使用 HTTPS 地址，不能含账号密码或片段')
    if (sorted(re.findall(r'\{[^{}]*\}', url)) != ['{x}', '{y}', '{z}']
            or any(c in re.sub(r'\{[xyz]\}', '', url) for c in '{}')):
        raise ValueError('瓦片模板必须各含一个 {z}、{x} 和 {y}')
    if (not isinstance(credit, str) or not credit.strip() or len(credit) > 24
            or not credit.isprintable()):
        raise ValueError('请输入 1–24 个字符的图源署名，用于手表显示')
    return {'url': url, 'credit': credit.strip()}


def quantize(image):
    palette = Image.new('P', (1, 1))
    colors = [component for color in PALETTE for component in
              ((color >> 16) & 255, (color >> 8) & 255, color & 255)]
    # Repeating the 16 entries avoids introducing black as an extra palette color.
    palette.putpalette(colors * 16)
    return image.convert('RGB').quantize(palette=palette, dither=Image.Dither.NONE)


@dataclass(frozen=True)
class TileSource:
    provider: str
    style: str
    url: str
    credit: str
    attribution: str
    online: bool
    offline_allowed: bool

    @property
    def fingerprint(self):
        # Credentials never appear in directory names or public metadata.
        identity = [self.provider, self.style, self.url, 'WGS84', 'EPSG:3857',
                    'XYZ', 256, list(PALETTE)]
        return hashlib.sha256(json.dumps(identity).encode('utf-8')).hexdigest()[:24]

    def cache_path(self, root, z, x, y):
        return Path(root) / 'sources-v1' / self.fingerprint / str(z) / str(x) / f'{y}.png'

    def require_offline(self):
        if not self.offline_allowed:
            raise ValueError('此图源尚未确认离线使用授权。请在「地图图源」中核实并设置离线授权，或选择允许离线的图源。')

    def fetch(self, z, x, y, memory, cache_dir, allow_download=True):
        key = (self.fingerprint, z, x, y)
        if key in memory:
            return memory[key]
        path = self.cache_path(cache_dir, z, x, y)
        if path.is_file():
            try:
                with Image.open(path) as image:
                    image.load()
                    if image.size != (256, 256):
                        raise ValueError('缓存瓦片尺寸无效，请删除此图源缓存后重试')
                    memory[key] = image.convert('RGB')
                return memory[key]
            except OSError:
                raise ValueError('缓存瓦片损坏，请删除此图源缓存后重试') from None
        if not allow_download:
            return None
        self.require_offline()
        url = self.url.format(z=z, x=x, y=y)
        error = '网络错误'
        for attempt in range(3):
            try:
                request = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
                with urllib.request.urlopen(request, timeout=25) as response:
                    data = response.read(4 * 1024 * 1024 + 1)
                if len(data) > 4 * 1024 * 1024:
                    raise ValueError('瓦片超过 4 MB，请选择普通 256px 图片')
                with Image.open(io.BytesIO(data)) as image:
                    if image.size != (256, 256):
                        raise ValueError('图源必须返回 256×256 图片，请检查尺寸和缩放设置')
                    image.load()
                    result = image.convert('RGB')
                path.parent.mkdir(parents=True, exist_ok=True)
                with tempfile.NamedTemporaryFile(dir=path.parent, suffix='.png', delete=False) as temp:
                    temporary = Path(temp.name)
                try:
                    result.save(temporary, 'PNG')
                    os.replace(temporary, path)
                finally:
                    temporary.unlink(missing_ok=True)
                memory[key] = result
                time.sleep(0.25)
                return result
            except ValueError:
                raise
            except Exception as exc:
                # HTTP exceptions may contain a private key in their URL.
                code = getattr(exc, 'code', None)
                error = f'HTTP {code}' if code else type(exc).__name__
                if code in (401, 403, 404, 429):
                    break
                time.sleep(1 + attempt)
        raise ValueError(f'{self.credit} 瓦片 {z}/{x}/{y} 获取失败（{error}），已有缓存会保留') from None

    def metadata(self):
        return dict(provider=self.provider, style=self.style, credit=self.credit,
                    attribution=self.attribution, coordinate_system='WGS84',
                    projection='EPSG:3857', scheme='XYZ', tile_size=256,
                    palette=list(PALETTE), fingerprint=self.fingerprint)


def project_source(project):
    config = project.get('map_source')
    if config is None:
        return None  # v1 projects retain their original HOT offline / optional online pairing.
    if not isinstance(config, dict):
        raise ValueError('地图图源配置无效')
    for name, expected in (('coordinates', 'WGS84'), ('projection', 'EPSG:3857'),
                           ('scheme', 'XYZ'), ('tile_size', 256)):
        if config.get(name, expected) != expected:
            raise ValueError('当前支持 WGS84 / Web Mercator / XYZ / 256px 图源，其他坐标或切片方式需专门适配')
    for name in ('online', 'offline_allowed'):
        if not isinstance(config.get(name, False), bool):
            raise ValueError('图源开关必须为布尔值')
    provider = config.get('provider')
    style = config.get('style', '')
    if provider == 'maptiler':
        if style not in MAPTILER_STYLES:
            raise ValueError('请选择 MapTiler 街道或户外样式')
        key = config.get('key', '')
        if not isinstance(key, str) or not key.strip() or len(key) > 256:
            raise ValueError('请填写 MapTiler 访问密钥')
        url = f'https://api.maptiler.com/maps/{style}/256/{{z}}/{{x}}/{{y}}.png?key={quote(key.strip(), safe="")}'
        credit = '©MapTiler ©OpenStreetMap'
        attribution = ('© MapTiler https://www.maptiler.com/copyright/; '
                       '© OpenStreetMap contributors, ODbL https://www.openstreetmap.org/copyright')
    elif provider == 'custom':
        url = config.get('url')
        credit = config.get('credit')
        attribution = config.get('attribution', '')
        if not isinstance(style, str) or not style.strip() or len(style) > 48:
            raise ValueError('请填写 1–48 个字符的地图样式名称')
        if not isinstance(attribution, str) or not attribution.strip() or len(attribution) > 1000:
            raise ValueError('请填写图源要求的完整署名和许可信息')
    else:
        raise ValueError('不支持的图源厂家')
    validated = validate_template(url, credit)
    return TileSource(provider, style, validated['url'], validated['credit'], attribution,
                      config.get('online', True), config.get('offline_allowed', False))
