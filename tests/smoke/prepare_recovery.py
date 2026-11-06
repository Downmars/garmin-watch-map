"""Prepare an isolated FR255 simulator harness using production sources/resources.

Usage: python tests/smoke/prepare_recovery.py <scratch-directory>
Then compile the printed jungle with the local SDK/key and run without /t.
Never install this synthetic-data harness on a physical watch.
"""
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

repo = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
(out / 'resources').mkdir(exist_ok=True)
ns = 'http://www.garmin.com/xml/connectiq'
ET.register_namespace('iq', ns)
manifest = ET.parse(repo / 'app/manifest.xml')
app = manifest.getroot().find('{' + ns + '}application')
app.set('id', 'be8ea42c5c014da8a7b16109495f0313')
app.set('entry', 'RecoverySmokeApp')
manifest.write(out / 'manifest.xml', encoding='utf-8', xml_declaration=True)
records = []
for seq in (2, 1):
    points = []
    for i in range(800):
        points.extend([None, None] if i == 399 else [3450000 + i, 10950000])
    record = [1, seq, 123456, 7200, 3, 1793960000, points, 0]
    checksum = 17
    for value in record[:6]:
        checksum = (checksum * 97 + value % 1000003) % 1000003
    for value in points:
        checksum = (checksum * 97 + (18000001 if value is None else value) + 18000001) % 1000003
    record[7] = checksum
    records.append(record)
(out / 'resources/legacy.json').write_text(json.dumps(records), encoding='utf-8')
(out / 'resources/legacy.xml').write_text('<jsonDataResources><jsonData id="LegacyRecovery" filename="legacy.json" /></jsonDataResources>', encoding='utf-8')
jungle = out / 'monkey.jungle'
jungle.write_text(f'project.manifest = manifest.xml\nbase.sourcePath = {repo.as_posix()}/app/source;{repo.as_posix()}/tests/smoke\nbase.resourcePath = {repo.as_posix()}/app/resources;resources\n', encoding='utf-8')
print(jungle)
