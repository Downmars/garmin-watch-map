import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import xml.etree.ElementTree as ET

from PIL import Image
sys.path.insert(0,str(Path(__file__).parents[1]/'tools'))
import atlas
from atlas_studio import EXAMPLE, Studio, load_project, save_project
from map_canvas import Viewport, world_point
from map_source import project_source
from route_editor import RouteEditor
from route_document import DraftStore, EditorHistory, RouteDocument, atomic_write, merge_waypoints, waypoint


class EditorTests(unittest.TestCase):
    def test_zoom_anchor_pan_and_roundtrip_keep_subpixel_position(self):
        viewport = Viewport(34.5,109.5)
        for zoom in (8,13,15,18,19,12):
            original = viewport.location(431,127)
            viewport.zoom_at(zoom,431,127)
            self.assertAlmostEqual(viewport.location(431,127)[0],original[0],places=10)
            self.assertAlmostEqual(viewport.location(431,127)[1],original[1],places=10)
            x,y = viewport.screen(*original)
            self.assertAlmostEqual(x,431,places=7)
            self.assertAlmostEqual(y,127,places=7)
        before = viewport.center
        viewport.move(50,-30)
        self.assertAlmostEqual(viewport.center[0],before[0]-50/viewport.scale)
        self.assertAlmostEqual(viewport.center[1],before[1]+30/viewport.scale)

    def test_fit_route_and_tile_requests_stay_in_world(self):
        viewport = Viewport()
        points = [(34.4991,109.4822),(34.5017,109.5234)]
        viewport.fit(points)
        for point in points:
            x,y = viewport.screen(*point)
            self.assertTrue(0<=x<=viewport.width and 0<=y<=viewport.height)
        viewport.center = (0,0)
        _,_,tiles = viewport.tiles()
        self.assertLessEqual(len(tiles),16)
        self.assertTrue(all(x>=0 and y>=0 for _,x,y in tiles))

    def test_gpx_precision_segments_and_waypoints_roundtrip(self):
        document = RouteDocument('精确路线',[
            [(34.5000001234,109.5000009876),(34.5000201234,109.5000309876)],
            [(34.501,109.501),(34.502,109.502)]],
            [waypoint(34.5000001111,109.5000002222,'补给',1,'带备注',False,'water')])
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder)/'source.gpx'
            source.write_bytes(document.export())
            original = source.read_bytes()
            restored = RouteDocument.load(source)
            self.assertEqual(restored.segments,document.segments)
            self.assertEqual(restored.waypoints,document.waypoints)
            restored.segments[0][0] = (34.4999999999,109.4999999999)
            atomic_write(Path(folder)/'edited.gpx',restored.export())
            self.assertEqual(source.read_bytes(),original)
            self.assertEqual(len(RouteDocument.load(Path(folder)/'edited.gpx').segments),2)

    def test_waypoint_only_import_and_merge_avoid_duplicate_marks(self):
        document = RouteDocument(waypoints=[waypoint(34.5,109.5,'停车',2)])
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'places.gpx'; path.write_bytes(document.export())
            restored = RouteDocument.load(path)
            self.assertFalse(restored.segments)
            self.assertEqual(len(merge_waypoints(restored.waypoints,restored.waypoints)),1)

    def test_undo_redo_keeps_geometry_marker_properties_and_clears_redo_after_edit(self):
        document = RouteDocument('路线',[[(34.5,109.5),(34.501,109.501)]])
        history = EditorHistory(document)
        before = document.snapshot()
        document.segments[0].insert(1,(34.50012,109.50013))
        history.commit(before)
        before = document.snapshot()
        document.waypoints.append(waypoint(34.5,109.5,'危险路口',3,'慢行',False))
        history.commit(before)
        self.assertTrue(history.undo()); self.assertFalse(document.waypoints)
        self.assertTrue(history.redo()); self.assertFalse(document.waypoints[0]['sync'])
        self.assertTrue(history.undo())
        before = document.snapshot(); del document.segments[0][1]; history.commit(before)
        self.assertFalse(history.redo())
        self.assertAlmostEqual(document.distance(),144,delta=4)

    def test_draft_recovers_partial_route_and_failed_write_preserves_previous(self):
        document = RouteDocument('未完成',[[(34.50000012,109.50000034)]],
                                 [waypoint(34.5,109.5,'备注',description='草稿')])
        with tempfile.TemporaryDirectory() as folder:
            draft = DraftStore(folder,'project/region/route')
            draft.save(document)
            original = draft.path.read_bytes()
            restored = draft.load()
            self.assertEqual(restored.snapshot(),document.snapshot())
            with patch('route_document.os.replace',side_effect=OSError('injected')):
                with self.assertRaises(OSError):draft.save(RouteDocument('新内容'))
            self.assertEqual(draft.path.read_bytes(),original)
            draft.clear(); self.assertIsNone(draft.load())

    def test_complex_route_can_be_opened_and_edited_before_watch_simplification(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            points = [(34.5+(index%2)*.001,109.5+index*.000006) for index in range(700)]
            path = root/'complex.gpx'; path.write_bytes(RouteDocument('复杂',[points]).export())
            project = dict(version=1,regions=[dict(id='area',name='区域',lat=34.5,lon=109.5,km=3,
                routes=[dict(id='route',name='复杂',gpx=str(path))])])
            save_project(project,root/'project.json')
            restored = load_project(root/'project.json')
            atlas.prepare(restored,root,editing=True)
            with self.assertRaisesRegex(ValueError,'复杂'):
                atlas.prepare(restored,root)

    def test_reopening_route_keeps_changed_and_deleted_region_waypoints(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original = waypoint(34.5,109.5,'原地点',identity='place')
            deleted = waypoint(34.501,109.501,'已删除',identity='removed')
            document = RouteDocument('路线',[[(34.5,109.5),(34.501,109.501)]],[original,deleted])
            path = root/'route.gpx'; path.write_bytes(document.export())
            studio = Studio.__new__(Studio)
            studio.root = None
            studio.path = root/'project.json'
            studio.settings = dict(cache=folder)
            studio.index = lambda:0
            studio.routes = Mock()
            studio.routes.curselection.return_value = (0,)
            changed = waypoint(34.5002,109.5003,'改名地点',identity='place')
            region = dict(id='area',name='地区',lat=34.5,lon=109.5,km=3,
                          routes=[dict(id='route',name='路线',gpx=str(path))],waypoints=[changed])
            studio.project = dict(version=1,regions=[region])
            with patch('atlas_studio.RouteEditor') as editor:
                studio.edit_map(existing=True)
                self.assertEqual(editor.call_args.args[1].waypoints,[changed])
                region['waypoints'] = []
                studio.edit_map(existing=True)
                self.assertEqual(editor.call_args.args[1].waypoints,[])
                del region['waypoints']
                studio.edit_map(existing=True)
                self.assertEqual(editor.call_args.args[1].waypoints,[original,deleted])

    def test_invalid_draft_is_backed_up_before_new_edits_are_saved(self):
        with tempfile.TemporaryDirectory() as folder:
            draft = DraftStore(folder,'damaged')
            draft.path.parent.mkdir(parents=True)
            original = b'{partial'
            draft.path.write_bytes(original)
            with self.assertRaises(ValueError):draft.load()
            draft.save(RouteDocument('新草稿'))
            self.assertEqual(next(draft.path.parent.glob('*.invalid')).read_bytes(),original)
            self.assertEqual(draft.load().name,'新草稿')

    def test_place_mode_selects_marker_at_route_vertex_without_creating_duplicate(self):
        editor = RouteEditor.__new__(RouteEditor)
        editor.document = RouteDocument('路线',[[(34.5,109.5),(34.501,109.501)]],
                                        [waypoint(34.5,109.5,'路口')])
        editor.mode = Mock()
        editor.map = Mock()
        editor.map.viewport = Viewport(34.5,109.5)
        x,y = editor.map.viewport.screen(34.5,109.5)
        editor.mode.get.return_value = '地点'
        self.assertEqual(editor.nearest(x,y),('waypoint',0))
        editor.mode.get.return_value = '编辑节点'
        self.assertEqual(editor.nearest(x,y),('point',0,0))

    def test_waypoint_package_filters_sync_and_checks_watch_bounds_before_build(self):
        project = load_project(EXAMPLE)
        region = project['regions'][0]
        region['waypoints'] = [waypoint(34.5,109.5,'补给',1,'长备注'*100),
                               waypoint(1,1,'仅电脑',sync=False)]
        plan = atlas.prepare(project,Path.cwd())
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def generate(app,out,cache,lat,lon,km,tag,progress,source=None):
                (app/'resources/drawables').mkdir(parents=True)
                (app/'source').mkdir()
                (app/'source/MapData.mc').write_text('module MapData {}')
                (app/'source/MapLayers.mc').write_text('module MapLayers {}')
                (app/'resources/drawables/drawables.xml').write_text('<drawables/>')
            with patch.object(atlas,'generate',side_effect=generate):
                atlas.create_app(root/'app',root,root/'cache',plan,lambda message:None)
            values = json.loads((root/'app/resources/routes/Waypoints_0.json').read_text(encoding='utf-8'))
            self.assertEqual(len(values),1)
            self.assertEqual(len(values[0][4]),160)
            self.assertIn('Rez.JsonData.Waypoints_0',(root/'app/source/MapCatalog.mc').read_text(encoding='utf-8'))
        region['waypoints'][1]['sync'] = True
        with self.assertRaisesRegex(ValueError,'超出'):
            atlas.prepare(project,Path.cwd())
        region['waypoints'] = [waypoint(34.5,109.5,f'点{i}') for i in range(33)]
        atlas.prepare(project,Path.cwd(),editing=True)
        with self.assertRaisesRegex(ValueError,'32'):
            atlas.prepare(project,Path.cwd())

    def test_interactive_preview_works_without_offline_permission_and_honors_no_store(self):
        source = project_source(dict(map_source=dict(provider='maptiler',style='streets-v4',key='TEST')))
        class Response(io.BytesIO):
            headers = {'Cache-Control':'no-store'}
        stream = Response(); Image.new('RGB',(256,256),'blue').save(stream,'PNG'); stream.seek(0)
        with tempfile.TemporaryDirectory() as folder,patch('map_source.time.sleep'):
            with patch('map_source.urllib.request.urlopen',return_value=stream):
                image = source.fetch(15,1,1,{},folder,preview=True)
            self.assertEqual(image.size,(256,256))
            self.assertFalse(list(Path(folder).rglob('*.png')))
            with self.assertRaisesRegex(ValueError,'授权'):
                source.fetch(15,1,1,{},folder)
