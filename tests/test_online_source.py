import sys
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from atlas import online_config, configure_network
from atlas_studio import load_project, save_project, EXAMPLE

class OnlineSourceTests(unittest.TestCase):
    def test_generated_url_and_permission_survive_project_roundtrip(self):
        project=load_project(EXAMPLE)
        project['online']={'url':'https://tiles.example.invalid/{z}/{x}/{y}.png?k=client', 'credit':'测试图源'}
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp); path=folder/'project.json'
            save_project(project,path)
            restored=online_config(load_project(path))
            self.assertEqual(restored,project['online'])
            (folder/'source').mkdir()
            (folder/'manifest.xml').write_bytes((EXAMPLE.parents[1]/'app/manifest.xml').read_bytes())
            configure_network(folder,restored)
            src=(folder/'source/OnlineSource.mc').read_text(encoding='utf-8')
            self.assertIn('z.toString() + "/" + x.toString() + "/" + y.toString()',src)
            perms=ET.parse(folder/'manifest.xml').findall('.//{*}uses-permission')
            self.assertIn('Communications',[item.get('id') for item in perms])

    def test_unconfigured_and_invalid_sources(self):
        self.assertIsNone(online_config(load_project(EXAMPLE)))
        for url in ('http://site/{z}/{x}/{y}','https://u:p@site/{z}/{x}/{y}',
                    'https://site/{z}/{y}','https://{x}.site/{z}/{y}','https://site/{z}/{x}/{y}/{s}'):
            with self.subTest(url=url),self.assertRaises(ValueError):
                online_config({'online':{'url':url,'credit':'Map'}})
        with self.assertRaises(ValueError):
            online_config({'online':{'url':'https://site/{z}/{x}/{y}','credit':''}})
