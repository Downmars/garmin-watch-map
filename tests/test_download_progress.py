import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

from PIL import Image

sys.path.insert(0,str(Path(__file__).parents[1]/'tools'))
import atlas
from download_progress import DownloadCancelled, DownloadProgress, read_tile
from make_city_pack import fetch_tile
from map_source import project_source


def image_bytes():
    stream = io.BytesIO()
    Image.new('RGB',(256,256),'green').save(stream,'PNG')
    return stream.getvalue()


def project():
    return dict(version=1,regions=[dict(id='area',name='测试地区',lat=34.5,lon=109.5,km=1,routes=[])],
                map_source=dict(provider='custom',style='测试',credit='TEST',attribution='Synthetic test',
                                url='https://example.invalid/{z}/{x}/{y}.png',offline_allowed=True))


class DownloadTests(unittest.TestCase):
    def test_switching_view_stops_old_request_retries_for_both_sources(self):
        with tempfile.TemporaryDirectory() as folder,patch('map_source.time.sleep'):
            source = project_source(project())
            for loader in (
                lambda transfer:source.fetch(15,1,2,{},folder,preview=True,transfer=transfer),
                lambda transfer:fetch_tile(15,1,2,{},cache_dir=folder,transfer=transfer,timeout=10),
            ):
                transfer = DownloadProgress(1)
                def cancelled_request(*args,**kwargs):
                    transfer.cancel()
                    raise TimeoutError('superseded request')
                with patch('urllib.request.urlopen',side_effect=cancelled_request) as request:
                    with self.assertRaises(DownloadCancelled):loader(transfer)
                self.assertEqual(request.call_count,1)
                self.assertEqual(transfer.snapshot()['failures'],0)

    def test_speed_decays_to_zero_during_wait_and_cache_is_not_network_traffic(self):
        now = [0.0]
        transfer = DownloadProgress(3,clock=lambda:now[0])
        transfer.complete((15,1,1),cached=True)
        transfer.request()
        now[0] = 1
        transfer.add_bytes(2048)
        transfer.complete((15,1,2))
        transfer.complete((15,1,2),cached=True)
        self.assertEqual(transfer.snapshot()['speed'],2048)
        now[0] = 2
        transfer.retry()
        transfer.request()
        self.assertEqual(transfer.snapshot()['speed'],1024)
        now[0] = 4.1
        info = transfer.snapshot()
        self.assertEqual(info['speed'],0)
        self.assertEqual((info['received'],info['completed'],info['cached'],info['failures']),(2048,2,1,1))
        self.assertIn('等待服务器响应',transfer.text())
        self.assertIn('2/3',transfer.text())

    def test_stream_reports_partial_bytes_before_completion_and_enforces_size_limit(self):
        transfer = DownloadProgress(1)
        sizes = []
        class Response(io.BytesIO):
            def read1(self, size):
                sizes.append(transfer.snapshot()['received'])
                return super().read(min(size,1024))
        payload = b'01234567'*1024
        self.assertEqual(read_tile(Response(payload),transfer),payload)
        self.assertEqual(sizes[1],1024)
        self.assertEqual(transfer.snapshot()['received'],len(payload))
        with self.assertRaisesRegex(ValueError,'4 MB'):
            read_tile(io.BytesIO(b'x'*(4*1024*1024+1)))

    def test_both_sources_count_actual_download_retry_and_cache_hits(self):
        payload = image_bytes()
        source = project_source(project())
        with tempfile.TemporaryDirectory() as folder,patch('map_source.time.sleep'):
            for loader in (
                lambda transfer:source.fetch(15,1,2,{},folder,transfer=transfer),
                lambda transfer:fetch_tile(15,1,2,{},cache_dir=folder,transfer=transfer),
            ):
                transfer = DownloadProgress(1)
                with patch('urllib.request.urlopen',side_effect=[urllib.error.URLError('temporary'),io.BytesIO(payload)]):
                    self.assertEqual(loader(transfer).size,(256,256))
                info = transfer.snapshot()
                self.assertEqual((info['received'],info['completed'],info['cached'],info['failures']),(len(payload),1,0,1))
                cached = DownloadProgress(1)
                with patch('urllib.request.urlopen',side_effect=AssertionError('unexpected network')):
                    loader(cached)
                info = cached.snapshot()
                self.assertEqual((info['received'],info['completed'],info['cached']),(0,1,1))

    def test_normal_installer_build_reports_all_tiles_and_compile_stage(self):
        payload = image_bytes()
        obj = project()
        with tempfile.TemporaryDirectory() as folder,patch('map_source.time.sleep'):
            root = Path(folder)
            profile = root/'devices/fr255'; profile.mkdir(parents=True)
            (profile/'compiler.json').write_text('{"deviceId":"fr255"}')
            (profile/'fr255.bin').write_bytes(b'test')
            (root/'sdk/bin').mkdir(parents=True)
            (root/'sdk/bin/monkeybrains.jar').touch()
            key = root/'test.der'; key.touch()
            total = atlas.project_budget(obj,root,root/'cache')['source_tiles']
            transfer = DownloadProgress(total)
            def compile_app(args,app,progress):
                self.assertEqual(transfer.snapshot()['stage'],'正在编译 FR255 应用')
                Path(args[args.index('-o')+1]).write_bytes(b'test program')
            with patch('urllib.request.urlopen',side_effect=lambda *args,**kwargs:io.BytesIO(payload)) as request:
                with patch.object(atlas,'run_tool',side_effect=compile_app):
                    atlas.build(obj,root,root/'install.zip',root/'sdk',sys.executable,key,root/'cache',
                                progress=lambda message:None,devices=profile,transfer=transfer)
            info = transfer.snapshot()
            self.assertEqual((info['completed'],info['cached']),(total,0))
            self.assertEqual(info['received'],request.call_count*len(payload))
            self.assertEqual(request.call_count,total)
