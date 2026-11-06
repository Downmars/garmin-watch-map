import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from xml.etree import ElementTree

from PIL import Image

spec = importlib.util.spec_from_file_location("city", Path(__file__).parents[1] / "tools/make_city_pack.py")
city = importlib.util.module_from_spec(spec)
spec.loader.exec_module(city)


class CityPackTests(unittest.TestCase):
    def test_download_failure_does_not_create_blank_tile(self):
        with patch.object(city.urllib.request, "urlopen", side_effect=OSError("offline")), patch.object(city.time, "sleep"):
            with self.assertRaisesRegex(RuntimeError, "Tile download failed"):
                city.fetch_tile(15, 1, 1, {}, retries=1)

    def test_disk_cache_resumes_without_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            tile = Path(tmp) / "15/1/2.png"
            tile.parent.mkdir(parents=True)
            Image.new("RGB", (256, 256), (100, 120, 140)).save(tile)
            with patch.object(city.urllib.request, "urlopen", side_effect=AssertionError("unexpected network")):
                result = city.fetch_tile(15, 1, 2, {}, cache_dir=tmp)
            self.assertEqual(result.getpixel((0, 0)), (100, 120, 140))

    def test_weinan_grid_contains_centered_twenty_km_square(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(city, "fetch_tile", return_value=Image.new("RGB", (256, 256))):
            x, y, cols, rows, names, mpp = city.build_tiles(34.5, 109.5, 20, 15, tmp, {})
            cx, cy = city.lon_to_x(109.5, 15), city.lat_to_y(34.5, 15)
            half = 10000 / mpp
            self.assertLessEqual(x, cx - half)
            self.assertLessEqual(y, cy - half)
            self.assertGreaterEqual(x + cols * 512, cx + half)
            self.assertGreaterEqual(y + rows * 512, cy + half)
            self.assertEqual(len(names), cols * rows)

    def test_resource_ids_do_not_collide_for_large_grids(self):
        with tempfile.TemporaryDirectory() as tmp:
            city.emit_sources(tmp, 0, 0, 12, 12, [], 4, tmp, 256 << 15, 34.5, 109.5)
            root = ElementTree.parse(Path(tmp) / "resources/drawables/drawables.xml").getroot()
            ids = [node.attrib["id"] for node in root]
            self.assertEqual(len(ids), len(set(ids)))
            self.assertEqual(len(ids), 145)


if __name__ == "__main__":
    unittest.main()
