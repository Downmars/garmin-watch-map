import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from xml.etree import ElementTree

from PIL import Image
sys.path.insert(0, str(Path(__file__).parents[1] / 'tools'))
import make_multilevel_pack as multi


class MultiLevelTests(unittest.TestCase):
    def test_overview_covers_exact_existing_street_extent(self):
        street, overview = multi.layer_grids(34.5, 109.5, 20)
        self.assertEqual((street['cols'], street['rows']), (11, 11))
        self.assertEqual((overview['cols'], overview['rows']), (4, 3))
        for axis, count in [('x', 'cols'), ('y', 'rows')]:
            start = street['origin_' + axis] / 4
            end = (street['origin_' + axis] + street[count] * 512) / 4
            self.assertLessEqual(overview['origin_' + axis], start)
            self.assertGreaterEqual(overview['origin_' + axis] + overview[count] * 512, end)

    def test_failed_overview_download_keeps_active_resources(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            root = Path(tmp); app = root / 'app'
            (app / 'source').mkdir(parents=True); (app / 'resources/drawables').mkdir(parents=True)
            source = app / 'source/MapData.mc'; xml = app / 'resources/drawables/drawables.xml'
            source.write_text('old source'); xml.write_text('old resources')
            def tile(z, *args, **kwargs):
                if z == 13: raise OSError('injected overview failure')
                return Image.new('RGB', (256, 256))
            with patch.object(multi.city, 'fetch_tile', side_effect=tile):
                with self.assertRaises(OSError): multi.generate(app, root / 'maps', root / 'cache', 34.5, 109.5, 1)
            self.assertEqual(source.read_text(), 'old source'); self.assertEqual(xml.read_text(), 'old resources')
            self.assertFalse((app / 'source/MapLayers.mc').exists())

    def test_both_levels_have_unique_complete_compressed_resources(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            root = Path(tmp); app = root / 'app'
            with patch.object(multi.city, 'fetch_tile', return_value=Image.new('RGB', (256, 256), 'white')):
                meta = multi.generate(app, root / 'maps', root / 'cache', 34.5, 109.5, 1)
            xml = ElementTree.parse(app / 'resources/drawables/drawables.xml').getroot()
            ids = [e.attrib['id'] for e in xml]
            self.assertEqual(len(ids), len(set(ids))); self.assertEqual(len(ids), meta['image_count'] + 1)
            for element in list(xml)[:-1]:
                with Image.open(app / 'resources/drawables' / element.attrib['filename']) as image:
                    self.assertEqual(image.size, (512, 512))
                self.assertEqual(element.attrib['compress'], 'true')
            source = (app / 'source/MapLayers.mc').read_text()
            self.assertIn('[15, 1.0', source); self.assertIn('[13, 0.25', source)
            self.assertTrue((root / 'maps/multilevel-metadata.json').exists())


if __name__ == '__main__': unittest.main()
