"""Build a self-contained Windows EXE; bundle an explicit, public template only."""
from pathlib import Path
import argparse
import sys
from PyInstaller.__main__ import run

root = Path(__file__).resolve().parents[1]
args = argparse.ArgumentParser()
args.add_argument('--out',type=Path,default=root/'dist')
args.add_argument('--work',type=Path,default=root/'temp/studio-freeze')
options = args.parse_args()
options.work.mkdir(parents=True,exist_ok=True)
files = ['app/manifest.xml','app/monkey.jungle','app/resources/drawables/launcher.png',
         'docs/INSTALL-V05.md','LICENSE','tools/SigningKey.java',
         'examples/atlas.json','examples/routes/weinan-demo.gpx','examples/routes/weinan-segments.gpx','examples/routes/xian-demo.gpx']
files += [str(p.relative_to(root)) for p in sorted((root/'app/source').glob('*.mc'))
          if p.name not in ('MapData.mc','MapLayers.mc')]
opts = ['--onefile','--windowed','--noconfirm','--name','FR255-Atlas-Studio',
        '--distpath',str(options.out.resolve()),'--workpath',str(options.work.resolve()/'build'),
        '--specpath',str(options.work.resolve())]
for name in files:
    opts.extend(['--add-data', f'{root/name}:{Path(name).parent.as_posix()}'])
run(opts+[str(root/'tools/atlas_studio.py')])
