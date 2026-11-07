import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import atlas
from gpx_route import read_gpx, simplify
from atlas_studio import EXAMPLE, load_project, save_project, region_from_gpx


class AtlasTests(unittest.TestCase):
    def test_device_lookup_honors_sdk_manager_relocation_and_exact_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)/'original'
            root.mkdir()
            relocated=Path(tmp)/'elsewhere'
            profile=relocated/'Devices/fr255'
            profile.mkdir(parents=True)
            (root/'sdkmanager-download-location.cfg').write_text(str(relocated),encoding='utf-8')
            (profile/'compiler.json').write_text('{"deviceId":"fr255"}',encoding='utf-8')
            (profile/'fr255.bin').write_bytes(b'test')
            with patch.object(atlas,'garmin_data_roots',return_value=[root]):
                self.assertEqual(atlas.fr255_profile(),profile.resolve())
            self.assertEqual(atlas.fr255_profile(relocated/'Devices'),profile.resolve())
            (profile/'compiler.json').write_text('{"deviceId":"fr255s"}',encoding='utf-8')
            with self.assertRaisesRegex(ValueError,'Forerunner 255'):
                atlas.fr255_profile(profile)

    def test_missing_profile_rejected_before_tile_work_and_zip_replacement(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)
            (folder/'bin').mkdir()
            (folder/'bin/monkeybrains.jar').touch()
            key=folder/'example.der'; key.touch()
            out=folder/'previous.zip'; out.write_bytes(b'previous')
            with patch.object(atlas,'create_app',side_effect=AssertionError('generated tiles')):
                with self.assertRaisesRegex(ValueError,'设备配置'):
                    atlas.build(load_project(EXAMPLE),folder,out,folder,sys.executable,key,folder,
                                devices=folder/'absent')
            self.assertEqual(out.read_bytes(),b'previous')

    def test_example_project_is_portable_and_keeps_segment_breaks(self):
        with tempfile.TemporaryDirectory() as tmp:
            saved = Path(tmp)/'另一个目录'/'渭南西安.json'
            saved.parent.mkdir()
            obj=load_project(EXAMPLE)
            save_project(obj,saved)
            text=saved.read_text(encoding='utf-8')
            self.assertNotIn(str(atlas.ROOT),text)
            plan=atlas.prepare(load_project(saved),saved.parent)
            self.assertEqual([len(routes) for _,_,routes in plan],[2,1])
            self.assertIn(None,plan[0][2][1][1])
            moved=Path(tmp)/'moved'
            saved.parent.rename(moved)
            self.assertEqual(len(load_project(moved/saved.name)['regions']),2)

    def test_outside_route_is_rejected_before_fetch_or_output_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)/'old.zip'; out.write_bytes(b'old')
            obj=load_project(EXAMPLE)
            obj['regions'][0]['lat']=20
            with patch('make_city_pack.fetch_tile', side_effect=AssertionError('unexpected network')):
                with self.assertRaisesRegex(ValueError,'超出'):
                    atlas.build(obj,Path.cwd(),out,'','','',tmp)
            self.assertEqual(out.read_bytes(),b'old')

    def test_bad_coordinates_and_single_waypoint(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'bad.gpx'
            for t in ('<rte><rtept lat="NaN" lon="1"/></rte>','<wpt lat="34" lon="108"/>'):
                p.write_text('<gpx>'+t+'</gpx>',encoding='utf-8')
                with self.assertRaises(ValueError): read_gpx(p)

    def test_bounds_budget_and_fit_route(self):
        obj=load_project(EXAMPLE)
        for km in (float('nan'),100):
            obj['regions'][0]['km']=km
            with self.assertRaises(ValueError): atlas.prepare(obj,Path.cwd())
        route=Path(obj['regions'][0]['routes'][0]['gpx'])
        lat,lon,km=region_from_gpx(route)
        self.assertTrue(34.49<lat<34.51 and 109.49<lon<109.51 and 1<=km<=25)
        region=obj['regions'][0]; region.update(lat=lat,lon=lon,km=km,routes=region['routes'][:1])
        atlas.prepare(obj,Path.cwd())
        paths=[[(i,0) for i in range(500)],[(500,500),(501,510)]]
        self.assertEqual(simplify(paths),[0,0,499,0,None,None,500,500,501,510])
