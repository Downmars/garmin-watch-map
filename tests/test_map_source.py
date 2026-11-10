import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import zipfile

from PIL import Image

sys.path.insert(0, str(Path(__file__).parents[1]/'tools'))
import atlas
from atlas_studio import EXAMPLE, load_project, preview_image, save_project
from map_source import PALETTE, project_source


def configured_project():
    project = load_project(EXAMPLE)
    project['regions'] = project['regions'][1:]
    project['map_source'] = dict(provider='custom',style='道路',
        url='https://tiles.example.invalid/roads/{z}/{x}/{y}.png?key=PRIVATE_TEST',
        credit='测试道路',attribution='Test tiles, test license',online=True,offline_allowed=True)
    return project


def png(color):
    buffer = io.BytesIO()
    Image.new('RGB',(256,256),color).save(buffer,'PNG')
    buffer.seek(0)
    return buffer


class SourceTests(unittest.TestCase):
    def test_presets_and_unsupported_coordinate_contract(self):
        for style in ('streets-v4','outdoor-v4'):
            project = {'map_source':dict(provider='maptiler',style=style,key='client_key')}
            source = project_source(project)
            self.assertIn(f'/{style}/256/{{z}}/{{x}}/{{y}}.png',source.url)
            self.assertFalse(source.offline_allowed)
            self.assertNotIn('client_key',json.dumps(source.metadata()))
        for field,value in [('coordinates','GCJ02'),('coordinates','BD09'),('scheme','TMS'),
                            ('tile_size',512),('projection','EPSG:4326')]:
            project = configured_project()
            project['map_source'][field] = value
            with self.subTest(field=field,value=value),self.assertRaises(ValueError):
                project_source(project)

    def test_legacy_project_roundtrip_and_new_source_save(self):
        legacy = load_project(EXAMPLE)
        legacy['online'] = dict(url='https://legacy.invalid/{z}/{x}/{y}.png',credit='Legacy')
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'project.json'
            for project in (legacy,configured_project()):
                save_project(project,path)
                restored = load_project(path)
                self.assertEqual(atlas.online_config(restored),atlas.online_config(project))
                self.assertEqual(restored.get('map_source'),project.get('map_source'))
            self.assertIsNone(project_source(legacy))

    def test_cache_isolates_styles_and_never_uses_legacy_tile(self):
        roads = project_source(configured_project())
        project = configured_project()
        project['map_source'].update(style='户外',url='https://tiles.example.invalid/outdoor/{z}/{x}/{y}.png')
        outdoor = project_source(project)
        self.assertNotEqual(roads.fingerprint,outdoor.fingerprint)
        with tempfile.TemporaryDirectory() as folder,patch('map_source.time.sleep'):
            legacy = Path(folder)/'15/1/2.png'
            legacy.parent.mkdir(parents=True)
            Image.new('RGB',(256,256),'green').save(legacy)
            memory = {}
            with patch('map_source.urllib.request.urlopen',side_effect=[png('red'),png('blue')]) as request:
                self.assertEqual(roads.fetch(15,1,2,memory,folder).getpixel((0,0)),(255,0,0))
                self.assertEqual(outdoor.fetch(15,1,2,memory,folder).getpixel((0,0)),(0,0,255))
                self.assertEqual(request.call_count,2)
            with patch('map_source.urllib.request.urlopen',side_effect=AssertionError('network')):
                self.assertEqual(roads.fetch(15,1,2,{},folder).getpixel((0,0)),(255,0,0))
            self.assertNotIn('PRIVATE_TEST',str(roads.cache_path(folder,15,1,2)))

    def test_failed_or_wrong_size_download_keeps_previous_cache_and_redacts_url(self):
        source = project_source(configured_project())
        with tempfile.TemporaryDirectory() as folder,patch('map_source.time.sleep'):
            path = source.cache_path(folder,15,1,1)
            error = urllib.error.HTTPError(source.url,403,'Denied',{},None)
            with patch('map_source.urllib.request.urlopen',side_effect=error):
                with self.assertRaises(ValueError) as caught:
                    source.fetch(15,1,1,{},folder)
            self.assertNotIn('PRIVATE_TEST',str(caught.exception))
            self.assertFalse(path.exists())
            invalid = io.BytesIO()
            Image.new('RGB',(512,512)).save(invalid,'PNG'); invalid.seek(0)
            with patch('map_source.urllib.request.urlopen',return_value=invalid):
                with self.assertRaisesRegex(ValueError,'256'):
                    source.fetch(15,1,1,{},folder)
            self.assertFalse(path.exists())

    def test_preview_and_offline_and_watch_share_pixels_source_palette_and_license(self):
        project = configured_project()
        source = project_source(project)
        with tempfile.TemporaryDirectory() as folder,patch('map_source.time.sleep'):
            root = Path(folder)
            with patch('map_source.urllib.request.urlopen',side_effect=lambda *a,**k:png('#fdfdc9')):
                preview,hits = preview_image(project['regions'][0],root/'cache',(512,512),True,source)
            self.assertGreater(hits,0)
            profile = root/'devices/fr255'; profile.mkdir(parents=True)
            (profile/'compiler.json').write_text('{"deviceId":"fr255"}')
            (profile/'fr255.bin').write_bytes(b'test')
            sdk = root/'sdk/bin'; sdk.mkdir(parents=True)
            (sdk/'monkeybrains.jar').touch()
            key = root/'private.der'; key.touch()
            inspected = []
            def compile_app(args,app,progress):
                network = (app/'source/OnlineSource.mc').read_text(encoding='utf-8')
                self.assertIn('/roads/',network)
                self.assertIn('测试道路',(app/'source/MapSource.mc').read_text(encoding='utf-8'))
                self.assertIn('MapSource.PALETTE',(app/'source/PhoneTileTransport.mc').read_text())
                for path in (app/'resources/drawables').glob('tile_*.png'):
                    with Image.open(path) as tile:
                        self.assertEqual(tile.mode,'P')
                        self.assertEqual(tile.convert('RGB').getpixel((0,0)),(255,255,204))
                        inspected.append(path.name)
                Path(args[args.index('-o')+1]).write_bytes(b'compiled-test')
            with patch.object(atlas,'run_tool',side_effect=compile_app),\
                    patch('map_source.urllib.request.urlopen',side_effect=lambda *a,**k:png('#fdfdc9')):
                meta = atlas.build(project,Path.cwd(),root/'pack.zip',sdk.parent,sys.executable,key,
                                   root/'cache',progress=lambda value:None,devices=profile)
            self.assertTrue(inspected)
            self.assertEqual(meta['map_source']['palette'],list(PALETTE))
            with zipfile.ZipFile(root/'pack.zip') as archive:
                public = archive.read('atlas.json').decode('utf-8')
                self.assertNotIn('PRIVATE_TEST',public)
                self.assertEqual(archive.read('MAP-LICENSE.txt').decode(),source.attribution)

    def test_permission_failure_precedes_fetch_and_preserves_existing_package(self):
        project = configured_project()
        project['map_source']['offline_allowed'] = False
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'pack.zip'; target.write_bytes(b'previous')
            with patch('map_source.urllib.request.urlopen',side_effect=AssertionError('network')):
                with self.assertRaisesRegex(ValueError,'授权'):
                    atlas.build(project,Path.cwd(),target,'','','',folder)
            self.assertEqual(target.read_bytes(),b'previous')

    def test_budget_counts_shared_tiles_and_cache_without_downloading(self):
        project = configured_project()
        duplicate = copy.deepcopy(project['regions'][0]); duplicate['id']='duplicate'
        project['regions'].append(duplicate)
        with tempfile.TemporaryDirectory() as folder:
            source = project_source(project)
            layer = atlas.prepare(project,Path.cwd())[0][1][0]
            path = source.cache_path(folder,15,layer['origin_x']//256,layer['origin_y']//256)
            path.parent.mkdir(parents=True); Image.new('RGB',(256,256)).save(path)
            budget = atlas.project_budget(project,Path.cwd(),folder)
            self.assertEqual(budget['cached_tiles'],1)
            self.assertEqual(budget['source_tiles'],budget['images']*2)
            self.assertEqual(budget['max_prg_bytes'],15_000_000)
            project['regions'] = [dict(id='large',name='大区',lat=34.5,lon=109.5,km=25,routes=[])]*2
            project['regions'][1] = {**project['regions'][1],'id':'large2'}
            with self.assertRaisesRegex(ValueError,'180'):
                atlas.project_budget(project,Path.cwd(),folder)
