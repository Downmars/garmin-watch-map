"""Windows desktop editor for shareable Garmin FR255 offline map installers."""
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import shutil
import sys
import threading
import tempfile
import xml.etree.ElementTree as ET
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
import uuid

from PIL import Image, ImageDraw, ImageTk
from atlas import ROOT, VERSION, build, online_config, prepare, project_budget, run_tool, validate_label
from map_source import HOT_CREDIT, project_source, quantize
from gpx_route import read_gpx
from make_city_pack import fetch_tile, lon_to_x, lat_to_y
from make_multilevel_pack import layer_grids
from map_canvas import MapCanvas, geographic
from route_document import DraftStore, RouteDocument, atomic_write, merge_waypoints
from route_editor import RouteEditor
from download_progress import DownloadProgress

EXAMPLE = ROOT/'examples/atlas.json'


def app_data():
    return Path(os.environ.get('ATLAS_STUDIO_HOME') or os.environ.get('LOCALAPPDATA') or Path.home())/'FR255AtlasStudio'


def new_id(prefix):
    return prefix + uuid.uuid4().hex[:10]


def load_project(path):
    obj = json.loads(Path(path).read_text(encoding='utf-8-sig'))
    if obj.get('version') != 1 or not isinstance(obj.get('regions'), list):
        raise ValueError('不支持的项目文件')
    for region in obj['regions']:
        for route in region.get('routes', []):
            route['gpx'] = str((Path(path).parent/route['gpx']).resolve())
    prepare(obj, Path.cwd(),editing=True) if obj['regions'] else None
    return obj


def save_project(obj, path):
    path = Path(path).resolve()
    copy_obj = copy.deepcopy(obj)
    for region in copy_obj['regions']:
        for route in region.get('routes', []):
            data = Path(route['gpx']).read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            asset = path.parent/(path.stem+'-routes')/(digest+'.gpx')
            asset.parent.mkdir(exist_ok=True)
            if not asset.exists():
                asset.write_bytes(data)
            if hashlib.sha256(asset.read_bytes()).hexdigest() != digest:
                raise ValueError('项目内的 GPX 副本校验失败')
            route['gpx'] = asset.relative_to(path.parent).as_posix()
    tmp = path.with_name(path.name+'.tmp')
    tmp.write_text(json.dumps(copy_obj,ensure_ascii=False,indent=2),encoding='utf-8')
    os.replace(tmp,path)


def region_from_gpx(path):
    document = RouteDocument.load(path)
    points = [(lon_to_x(lon,15),lat_to_y(lat,15)) for segment in document.segments for lat,lon in segment]
    points.extend((lon_to_x(p['lon'],15),lat_to_y(p['lat'],15)) for p in document.waypoints)
    xs, ys = zip(*points)
    x = (min(xs)+max(xs))/2
    y = (min(ys)+max(ys))/2
    world = 256 << 15
    lon = x/world*360-180
    lat = math.degrees(math.atan(math.sinh(math.pi*(1-2*y/world))))
    meters = 40075016.6856*math.cos(math.radians(lat))/world
    km = max(1,math.ceil(max(max(xs)-min(xs),max(ys)-min(ys))*meters*1.2/100)/10)
    if km > 25:
        raise ValueError('这条路线跨度超过 25 km，请先在 GPX 工具中分段')
    return lat,lon,km


def canvas_location(region, x, y, width, height):
    base = layer_grids(region['lat'],region['lon'],region['km'])[0]
    px = base['origin_x'] + x * base['cols'] * 512 / width
    py = base['origin_y'] + y * base['rows'] * 512 / height
    world = 256 << 15
    return math.degrees(math.atan(math.sinh(math.pi*(1-2*py/world)))), px/world*360-180


def write_route(path,name,coordinates):
    if len(set(coordinates)) < 2:
        raise ValueError('至少点选两个不同的位置')
    root=ET.Element('gpx',version='1.1',creator='FR255 Atlas Studio',xmlns='http://www.topografix.com/GPX/1/1')
    track=ET.SubElement(root,'trk')
    ET.SubElement(track,'name').text=name
    segment=ET.SubElement(track,'trkseg')
    for lat,lon in coordinates:
        ET.SubElement(segment,'trkpt',lat=f'{lat:.7f}',lon=f'{lon:.7f}')
    ET.ElementTree(root).write(path,encoding='utf-8',xml_declaration=True)


def settings_defaults():
    home = app_data()
    sdk = os.environ.get('CIQ_SDK','')
    cfg = Path(os.environ.get('APPDATA',''))/'Garmin/ConnectIQ/current-sdk.cfg'
    if not sdk and cfg.is_file():
        sdk = cfg.read_text(encoding='utf-8-sig').strip()
    java = os.environ.get('CIQ_JAVA') or shutil.which('java') or ''
    values = dict(sdk=sdk,java=java,key=os.environ.get('CIQ_KEY',str(home/'developer_key.der')),
                  cache=os.environ.get('ATLAS_TILE_CACHE',str(home/'tiles')),devices=os.environ.get('CIQ_DEVICES',''))
    try:
        stored = json.loads((home/'studio.json').read_text(encoding='utf-8'))
        values.update({k:v for k,v in stored.items() if k in values and isinstance(v,str)})
    except (FileNotFoundError,ValueError):
        pass
    return values


def preview_image(region, cache, size, online=False, source=None):
    layers = layer_grids(region['lat'],region['lon'],region['km'])
    base = layers[0]
    level = 15 if max(base['cols'],base['rows']) <= 3 else 13
    factor = 2**(level-15)
    left,top = int(base['origin_x']*factor),int(base['origin_y']*factor)
    width,height = int(base['cols']*512*factor),int(base['rows']*512*factor)
    image = Image.new('RGB',(width,height),'#e3e9e3')
    pen = ImageDraw.Draw(image)
    hits = 0
    memory = {}
    for tx in range(left//256,(left+width-1)//256+1):
        for ty in range(top//256,(top+height-1)//256+1):
            xy = (tx*256-left,ty*256-top)
            path = source.cache_path(cache,level,tx,ty) if source else Path(cache)/str(level)/str(tx)/(str(ty)+'.png')
            if online or path.exists():
                if source is None:
                    tile = fetch_tile(level,tx,ty,memory,cache_dir=str(cache))
                else:
                    tile = source.fetch(level,tx,ty,memory,cache,allow_download=online)
                image.paste(tile,xy)
                hits += 1
            else:
                pen.rectangle([xy,(xy[0]+255,xy[1]+255)],outline='#c6d0c8')
    if source is not None:
        image = quantize(image).convert('RGB')
    image.thumbnail(size,Image.Resampling.LANCZOS)
    sx,sy=image.width/width,image.height/height
    pen=ImageDraw.Draw(image)
    for route in region.get('routes',[]):
        for line in read_gpx(route['gpx']):
            pts=[((x*factor-left)*sx,(y*factor-top)*sy) for x,y in line]
            pen.line(pts, fill='#145bc2',width=3)
            x,y=pts[0]
            pen.ellipse([x-3,y-3,x+3,y+3],fill='#176045')
    return image,hits


class Studio:
    def __init__(self, root):
        self.root = root
        root.title('离线地图制包器 · FR255 · '+VERSION)
        root.geometry('960x680')
        root.minsize(820,600)
        self.project = load_project(EXAMPLE)
        self.path = None
        self.settings = settings_defaults()
        self.dirty = False
        self.busy = False
        self.build_transfer = None
        self.events = queue.Queue()
        self.photo = None
        self.preview_region = None
        self.autosave_job = None
        self.recovery_path = app_data()/'v08-project-draft.json'
        root.protocol('WM_DELETE_WINDOW',self.close)
        style = ttk.Style(root)
        style.configure('Title.TLabel',font=('Microsoft YaHei UI',16,'bold'))
        style.configure('Section.TLabel',font=('Microsoft YaHei UI',11,'bold'))
        style.configure('Build.TButton',font=('Microsoft YaHei UI',10,'bold'))
        shell = ttk.Frame(root,padding=15)
        shell.pack(fill='both',expand=True)
        bar=ttk.Frame(shell); bar.pack(fill='x',pady=(0,12))
        ttk.Label(bar,text='离线地图制包器',style='Title.TLabel').pack(side='left')
        for label,fn in [('制包设置',self.configure),('地图图源',self.edit_source),('保存项目',self.save),('打开项目',self.open),('新项目',self.new)]:
            ttk.Button(bar,text=label,command=lambda f=fn:self.guard(f)).pack(side='right',padx=2)
        middle=ttk.Frame(shell); middle.pack(fill='both',expand=True)
        left=ttk.Frame(middle); left.pack(side='left',fill='y',padx=(0,14))
        ttk.Label(left,text='地图地区',style='Section.TLabel').pack(anchor='w')
        self.regions=tk.Listbox(left,width=24,height=7,exportselection=False)
        self.regions.pack(fill='both',expand=True,pady=5)
        self.regions.bind('<<ListboxSelect>>',lambda e:self.guard(self.refresh_detail))
        self.buttons(left,[('添加',lambda:self.edit_region(True)),('编辑',lambda:self.edit_region(False)),('移除',self.remove_region)])
        ttk.Button(left,text='从 GPX 建立地区',command=lambda:self.guard(self.from_gpx)).pack(fill='x',pady=5)
        ttk.Label(left,text='该地区的路线',style='Section.TLabel').pack(anchor='w',pady=(9,0))
        self.routes=tk.Listbox(left,width=24,height=5,exportselection=False)
        self.routes.pack(fill='both',expand=True,pady=5)
        self.buttons(left,[('导入 GPX',self.import_routes),('新建路线',self.draw_route),('移除',self.remove_route)])
        self.buttons(left,[('编辑所选',lambda:self.edit_map(True)),('地点标注',lambda:self.edit_map(False,'地点'))])
        self.routes.bind('<Double-Button-1>',lambda event:self.guard(lambda:self.edit_map(True)))
        right=ttk.Frame(middle); right.pack(side='left',fill='both',expand=True)
        top=ttk.Frame(right); top.pack(fill='x')
        self.map_title=ttk.Label(top,text='覆盖范围',style='Section.TLabel'); self.map_title.pack(side='left')
        ttk.Button(top,text='载入预览底图',command=lambda:self.guard(self.fetch_preview)).pack(side='right')
        self.preview=MapCanvas(right,self.settings['cache'],project_source(self.project))
        self.preview.pack(fill='both',expand=True,pady=(5,4))
        self.detail=ttk.Label(right,wraplength=540); self.detail.pack(anchor='w')
        self.budget_label=ttk.Label(right,wraplength=540); self.budget_label.pack(anchor='w',pady=(4,0))
        self.download_status=ttk.Label(shell,wraplength=780)
        self.download_status.pack(fill='x',pady=(4,0))
        self.log=tk.Text(shell,height=4,wrap='word',state='disabled')
        self.log.pack(fill='x',pady=(9,5))
        footer=ttk.Frame(shell); footer.pack(fill='x')
        self.status=ttk.Label(footer,text='就绪'); self.status.pack(side='left')
        ttk.Button(footer,text='生成手表安装包…',style='Build.TButton',command=lambda:self.guard(self.start_build)).pack(side='right')
        root.after_idle(self.startup)
        root.after(120,self.poll)

    def guard(self,fn):
        if self.busy: return
        try: fn()
        except Exception as exc: messagebox.showerror('操作未完成',str(exc),parent=self.root)

    def buttons(self,parent,items):
        row=ttk.Frame(parent); row.pack(fill='x')
        for name,fn in items:
            ttk.Button(row,text=name,width=7,command=lambda f=fn:self.guard(f)).pack(side='left',expand=True,fill='x')

    def index(self):
        sel=self.regions.curselection()
        if not sel: raise ValueError('请先选择地区')
        return sel[0]

    def refresh(self,idx=0):
        self.regions.delete(0,'end')
        for r in self.project['regions']: self.regions.insert('end',r['name'])
        if self.project['regions']:
            self.regions.selection_set(min(idx,len(self.project['regions'])-1))
        self.refresh_detail()

    def refresh_detail(self):
        self.routes.delete(0,'end')
        if not self.regions.curselection():
            self.detail.config(text='添加地区或从 GPX 建立地区'); self.map_title.config(text='覆盖范围')
            self.budget_label.config(text='FR255 预算 180 张底图 / 15 MB 安装文件')
            self.preview.scene([],[])
            return
        r=self.project['regions'][self.index()]
        for t in r['routes']: self.routes.insert('end',t['name'])
        self.map_title.config(text=r['name'])
        source = project_source(self.project)
        routes = [segment for route in r['routes'] for segment in RouteDocument.load(route['gpx']).segments]
        base = layer_grids(r['lat'],r['lon'],r['km'])[0]
        coverage = (base['origin_x'],base['origin_y'],base['origin_x']+base['cols']*512,base['origin_y']+base['rows']*512)
        self.preview.set_source(source)
        changed_region = self.preview_region!=r['id']
        self.preview.scene(routes,r.get('waypoints',[]),coverage)
        self.preview.fit_coordinates = [geographic(coverage[0],coverage[1]),geographic(coverage[2],coverage[3])]
        if changed_region:
            self.preview.fit_all()
        self.preview_region = r['id']
        credit = source.credit if source else HOT_CREDIT
        pairing = '预览 / 离线 / 在线共用图源' if source else '旧项目配置，离线为 HOT'
        self.detail.config(text=f"{r['lat']:.4f}°, {r['lon']:.4f}°   ·   {r['km']:g} km · {len(r.get('waypoints',[]))} 个地点\n{credit} · {pairing}")
        budget = project_budget(self.project,Path.cwd(),self.settings['cache'])
        self.budget_label.config(text=f"手表地图资源 {budget['images']}/180 张 · 完整离线包还需下载 {budget['download_tiles']} 张瓦片\n"
                                f"底图未压缩总量约 {budget['bitmap_bytes']/1024/1024:.1f} MiB · 安装文件限 15 MB（编译后核验）")

    def changed(self):
        self.dirty=True
        self.status.config(text='项目有未保存的修改')
        if self.autosave_job:
            self.root.after_cancel(self.autosave_job)
        self.autosave_job = self.root.after(1200,self.autosave)

    def startup(self):
        try:
            if self.recovery_path.exists() and messagebox.askyesno('恢复项目','恢复上次未保存的地图项目？',parent=self.root):
                self.project = load_project(self.recovery_path)
                original = self.project.pop('_studio_path','')
                self.path = Path(original) if original else None
                self.dirty = True
                self.status.config(text='已恢复项目草稿，请保存项目')
        except Exception as exc:
            messagebox.showinfo('项目草稿',str(exc),parent=self.root)
        self.refresh(0)

    def autosave(self):
        self.autosave_job = None
        snapshot = copy.deepcopy(self.project)
        snapshot['_studio_path'] = str(self.path or '')
        try:
            self.recovery_path.parent.mkdir(parents=True,exist_ok=True)
            save_project(snapshot,self.recovery_path)
            self.status.config(text='项目草稿已保存')
            return True
        except Exception as exc:
            self.status.config(text='项目草稿保存失败 '+str(exc))
            return False

    def clear_autosave(self):
        if self.autosave_job:
            self.root.after_cancel(self.autosave_job)
            self.autosave_job = None
        self.recovery_path.unlink(missing_ok=True)

    def can_replace(self):
        accepted = not self.dirty or messagebox.askyesno('项目尚未保存','放弃当前项目的修改？',parent=self.root)
        if accepted:
            self.clear_autosave()
        return accepted

    def new(self):
        if self.can_replace():
            self.project={'version':1,'regions':[]}; self.path=None; self.dirty=False
            self.preview_region=None; self.refresh(); self.status.config(text='新项目')

    def open(self):
        path=filedialog.askopenfilename(filetypes=[('地图项目','*.json')])
        if path and self.can_replace():
            obj=load_project(path)
            self.project=obj; self.path=Path(path); self.dirty=False
            self.preview_region=None; self.refresh(); self.status.config(text=self.path.name)

    def save(self):
        path=filedialog.asksaveasfilename(initialfile=self.path.name if self.path else '地图项目.json',
            defaultextension='.json',filetypes=[('地图项目','*.json')])
        if path:
            save_project(self.project,path)
            self.path=Path(path); self.dirty=False; self.status.config(text='已保存 '+self.path.name)
            self.clear_autosave()

    def close(self):
        if self.busy: messagebox.showinfo('正在处理','请等待当前任务结束',parent=self.root); return
        if not self.dirty or self.autosave(): self.root.destroy()

    def form(self,title,fields,apply):
        dlg=tk.Toplevel(self.root); dlg.title(title); dlg.transient(self.root); dlg.grab_set()
        area=ttk.Frame(dlg,padding=16); area.pack(fill='both',expand=True)
        values={}
        for n,(key,label,initial,kind) in enumerate(fields):
            ttk.Label(area,text=label).grid(column=0,row=n,sticky='w',padx=(0,8),pady=4)
            v=tk.StringVar(dlg,value=str(initial)); values[key]=v
            ttk.Entry(area,textvariable=v,width=45).grid(column=1,row=n,sticky='ew')
            if kind:
                def pick(var=v,mode=kind):
                    value=filedialog.askdirectory(parent=dlg) if mode=='dir' else filedialog.askopenfilename(parent=dlg)
                    if value: var.set(value)
                ttk.Button(area,text='选择',width=6,command=pick).grid(column=2,row=n)
        def submit():
            try: apply({k:v.get().strip() for k,v in values.items()})
            except Exception as exc: messagebox.showerror(title,str(exc),parent=dlg); return
            dlg.destroy()
        ttk.Button(area,text='确定',command=submit).grid(column=1,row=len(fields),sticky='e',pady=(10,0))
        return dlg,area,values

    def edit_region(self,new,seed=None):
        regions=self.project['regions']
        if new and len(regions)>=8: raise ValueError('每个项目最多 8 个地区')
        region=seed or (dict(id=new_id('m'),name='新地区',lat=34.5,lon=109.5,km=3,routes=[]) if new else copy.deepcopy(regions[self.index()]))
        def accept(values):
            updated={**region,'name':values['name'],'lat':float(values['lat']),'lon':float(values['lon']),'km':float(values['km'])}
            target=len(regions) if new else self.index()
            proposed=list(regions)
            if new: proposed.append(updated)
            else: proposed[target]=updated
            prepare({**self.project,'regions':proposed},Path.cwd(),editing=True)
            self.project['regions']=proposed; self.changed(); self.refresh(target)
        self.form('地图地区',[(k,l,region[k],None) for k,l in
                  [('name','名称'),('lat','中心纬度 WGS84'),('lon','中心经度 WGS84'),('km','区域边长（公里）')]],accept)

    def from_gpx(self):
        path=filedialog.askopenfilename(filetypes=[('GPX 路线','*.gpx')])
        if not path: return
        lat,lon,km=region_from_gpx(path)
        document=RouteDocument.load(path)
        route=self.make_route(path)
        self.edit_region(True,dict(id=new_id('m'),name=route['name'],lat=round(lat,6),lon=round(lon,6),km=km,
                                  routes=[route] if document.segments else [],waypoints=document.waypoints))

    @staticmethod
    def make_route(path):
        name=''.join(c for c in Path(path).stem if c.isalnum() or c in ' -_')[:18].strip() or '路线'
        return dict(id=new_id('t'),name=name,gpx=str(Path(path).resolve()))

    def import_routes(self):
        index=self.index()
        paths=filedialog.askopenfilenames(filetypes=[('GPX 路线','*.gpx')])
        if not paths: return
        proposed=copy.deepcopy(self.project)
        region=proposed['regions'][index]
        for path in paths:
            document=RouteDocument.load(path)
            if document.segments:
                region['routes'].append(self.make_route(path))
            region['waypoints']=merge_waypoints(region.get('waypoints',[]),document.waypoints)
        prepare(proposed,Path.cwd(),editing=True)
        self.project=proposed; self.changed(); self.refresh(index)

    def draw_route(self):
        self.edit_map(False)

    def edit_map(self, existing=False, mode='画路线'):
        index = self.index()
        region = self.project['regions'][index]
        selection = self.routes.curselection()
        route_index = selection[0] if existing and selection else None
        if existing and route_index is None:
            raise ValueError('请先选择要编辑的路线')
        route = region['routes'][route_index] if route_index is not None else None
        document = RouteDocument.load(route['gpx']) if route else RouteDocument()
        document.name = route['name'] if route else '新路线'
        if 'waypoints' in region:
            document.waypoints = copy.deepcopy(region['waypoints'])
        identity = str(self.path or 'unsaved')+'/'+region['id']+'/'+(route['id'] if route else 'new')
        draft = DraftStore(app_data(),identity)
        base = layer_grids(region['lat'],region['lon'],region['km'])[0]
        coverage = (base['origin_x'],base['origin_y'],base['origin_x']+base['cols']*512,base['origin_y']+base['rows']*512)
        background = [segment for item in region['routes'] for segment in RouteDocument.load(item['gpx']).segments]

        def apply(edited, window):
            proposed = copy.deepcopy(self.project)
            target_region = proposed['regions'][index]
            target_region['waypoints'] = copy.deepcopy(edited.waypoints)
            if not edited.segments:
                if route_index is not None:
                    del target_region['routes'][route_index]
            else:
                updated = dict(route) if route else dict(id=new_id('t'))
                updated['name'] = edited.name
                validate_label(updated)
                data = edited.export()
                with tempfile.TemporaryDirectory() as folder:
                    scratch = Path(folder)/'edited.gpx'
                    scratch.write_bytes(data)
                    updated['gpx'] = str(scratch)
                    if route_index is None:
                        target_region['routes'].append(updated)
                    else:
                        target_region['routes'][route_index] = updated
                    prepare(proposed,Path.cwd(),editing=True)
                    destination = filedialog.asksaveasfilename(parent=window,
                        initialfile=edited.name+'-编辑.gpx',defaultextension='.gpx',
                        filetypes=[('GPX 路线和地点','*.gpx')])
                    if not destination:
                        return False
                    atomic_write(destination,data)
                    updated['gpx'] = str(Path(destination).resolve())
            self.project = proposed
            self.changed()
            self.refresh(index)
            return True

        RouteEditor(self.root,document,self.settings['cache'],project_source(self.project),
                    coverage,draft,apply,background,mode='编辑节点' if existing else mode)

    def remove_region(self):
        n=self.index()
        if messagebox.askyesno('移除地区','从本项目移除所选地区和其中的路线？'):
            del self.project['regions'][n]; self.changed(); self.refresh(max(0,n-1))

    def remove_route(self):
        idx=self.index(); sel=self.routes.curselection()
        if sel:
            del self.project['regions'][idx]['routes'][sel[0]]
            self.changed(); self.refresh(idx)

    def edit_source(self):
        current = self.project.get('map_source') or {}
        legacy = self.project.get('online') or {}
        options = ['保留旧项目配置', 'MapTiler 街道', 'MapTiler 户外', '自定义 XYZ']
        selection = options[0]
        if current.get('provider') == 'maptiler':
            selection = options[2] if current.get('style') == 'outdoor-v4' else options[1]
        elif current:
            selection = options[3]
        dialog = tk.Toplevel(self.root)
        dialog.title('地图图源')
        dialog.transient(self.root)
        dialog.grab_set()
        area = ttk.Frame(dialog,padding=16)
        area.pack(fill='both',expand=True)
        selected = tk.StringVar(dialog,value=selection)
        ttk.Label(area,text='图源方案').grid(row=0,column=0,sticky='w')
        picker = ttk.Combobox(area,textvariable=selected,values=options,state='readonly',width=48)
        picker.grid(row=0,column=1,sticky='ew',pady=4)
        fields = {}
        entries = {}
        for row,(name,label) in enumerate([
                ('style','地图样式'),('key','访问密钥'),('url','HTTPS 瓦片模板'),
                ('credit','手表简短署名'),('attribution','完整署名与许可')],1):
            value = current.get(name,legacy.get(name,''))
            fields[name] = tk.StringVar(dialog,value=value)
            ttk.Label(area,text=label).grid(row=row,column=0,sticky='w',padx=(0,10),pady=4)
            entries[name] = ttk.Entry(area,textvariable=fields[name],width=56,show='*' if name=='key' else '')
            entries[name].grid(row=row,column=1,sticky='ew')
        online = tk.BooleanVar(dialog,value=current.get('online',True) if current else bool(legacy))
        offline = tk.BooleanVar(dialog,value=current.get('offline_allowed',False))
        online_button = ttk.Checkbutton(area,text='连接手机时使用该在线图源',variable=online)
        online_button.grid(row=6,column=1,sticky='w',pady=4)
        offline_button = ttk.Checkbutton(area,text='已确认允许区域下载、离线使用及所需分发',variable=offline)
        offline_button.grid(row=7,column=1,sticky='w',pady=4)
        explanation = ttk.Label(area,wraplength=510)
        explanation.grid(row=8,column=0,columnspan=2,sticky='w',pady=10)
        ttk.Label(area,text='新图源支持 WGS84 / Web Mercator / XYZ / 256px，使用街道 z15 和概览 z13。',
                  wraplength=570).grid(row=9,column=0,columnspan=2,sticky='w')

        def update_fields(event=None):
            chosen = selected.get()
            is_legacy = chosen == options[0]
            is_maptiler = chosen in options[1:3]
            for entry in entries.values():
                entry.config(state='normal')
            if is_maptiler:
                style = 'streets-v4' if chosen == options[1] else 'outdoor-v4'
                fields['style'].set(style)
                fields['url'].set('https://api.maptiler.com/maps/'+style+'/256/{z}/{x}/{y}.png')
                fields['credit'].set('©MapTiler ©OpenStreetMap')
                fields['attribution'].set('© MapTiler https://www.maptiler.com/copyright/; © OpenStreetMap contributors, ODbL https://www.openstreetmap.org/copyright')
                for name in ('style','url','credit','attribution'):
                    entries[name].config(state='readonly')
                explanation.config(text='预览、离线制包与手表在线使用同一地图。MapTiler API 批量下载需要 Custom 方案或对应授权。')
            elif is_legacy:
                fields['url'].set(legacy.get('url',''))
                fields['credit'].set(legacy.get('credit',''))
                for name in ('style','key','attribution'):
                    entries[name].config(state='disabled')
                explanation.config(text='保留旧版 HOT 离线底图和单独在线地址。在线地址留空时仅离线。选择其他方案后将统一三处图源。')
            else:
                if not fields['style'].get():
                    fields['style'].set('自定义地图')
                entries['key'].config(state='disabled')
                explanation.config(text='填写厂家提供的 HTTPS 图片模板和完整署名。需各含一个 {z}/{x}/{y}。GCJ-02、BD-09 或矢量 PBF 图源需要另行适配。')
            offline_button.config(state='disabled' if is_legacy else 'normal')
            online_button.config(state='disabled' if is_legacy else 'normal')
            if event is not None:
                offline.set(False)
                online.set(not is_legacy)

        def accept():
            try:
                proposed = copy.deepcopy(self.project)
                if selected.get() == options[0]:
                    proposed.pop('map_source',None)
                    url = fields['url'].get().strip()
                    if url:
                        proposed['online'] = online_config({'online':dict(url=url,credit=fields['credit'].get().strip())})
                    else:
                        proposed.pop('online',None)
                else:
                    config = {name:value.get().strip() for name,value in fields.items()}
                    config.update(provider='maptiler' if selected.get() in options[1:3] else 'custom',
                                  online=online.get(),offline_allowed=offline.get(),
                                  coordinates='WGS84',projection='EPSG:3857',scheme='XYZ',tile_size=256)
                    if config['provider'] == 'custom':
                        config.pop('key',None)
                    project_source({'map_source':config})
                    proposed['map_source'] = config
                    proposed.pop('online',None)
                self.project = proposed
                self.changed()
                dialog.destroy()
                self.refresh_detail()
            except Exception as exc:
                messagebox.showerror('地图图源',str(exc),parent=dialog)
        picker.bind('<<ComboboxSelected>>',update_fields)
        update_fields()
        ttk.Button(area,text='保存设置',command=accept).grid(row=10,column=1,sticky='e',pady=(12,0))

    def configure(self):
        def accept(v):
            path=app_data(); path.mkdir(parents=True,exist_ok=True)
            (path/'studio.json').write_text(json.dumps(v,ensure_ascii=False),encoding='utf-8')
            self.settings=v
        dlg,area,v=self.form('制包设置',[(k,l,self.settings[k],mode) for k,l,mode in [
            ('sdk','Garmin SDK 目录','dir'),('java','Java 17 程序','file'),('key','签名文件 .der','file'),
            ('cache','底图缓存目录','dir'),('devices','FR255 设备目录（留空自动查找）','dir')]],accept)
        def keygen():
            target=filedialog.asksaveasfilename(parent=dlg,defaultextension='.der',initialfile='developer_key.der')
            if not target: return
            try:
                if Path(target).exists(): raise ValueError('请选择新的文件名，已有签名不会覆盖')
                run_tool([v['java'].get(),ROOT/'tools/SigningKey.java',target],Path(target).parent,lambda msg:None)
                v['key'].set(target)
            except Exception as e: messagebox.showerror('生成签名失败',str(e),parent=dlg)
        ttk.Button(area,text='创建新签名…',command=keygen).grid(column=0,row=5,sticky='w')

    def job(self,title,fn):
        self.busy=True; self.status.config(text=title)
        def worker():
            try: self.events.put(('ok',fn()))
            except Exception as exc: self.events.put(('error',str(exc)))
        threading.Thread(target=worker,daemon=True).start()

    def fetch_preview(self):
        self.preview.load_view()

    def start_build(self):
        obj=copy.deepcopy(self.project)
        prepare(obj,Path.cwd())
        source=project_source(obj)
        if source is not None:
            source.require_offline()
        v=self.settings.copy()
        if not (Path(v['sdk'])/'bin/monkeybrains.jar').is_file() or not Path(v['key']).is_file() or not (Path(v['java']).is_file() or shutil.which(v['java'])):
            messagebox.showinfo('首次制包设置','请选择 Garmin SDK、Java 17 和签名文件。签名也可以在设置里创建。')
            self.configure(); return
        output=filedialog.asksaveasfilename(initialfile='FR255-离线地图.zip',defaultextension='.zip')
        if output:
            budget = project_budget(obj,Path.cwd(),v['cache'])
            self.build_transfer = DownloadProgress(budget['source_tiles'])
            def task():
                meta=build(obj,Path.cwd(),output,v['sdk'],v['java'],v['key'],v['cache'],
                           lambda s:self.events.put(('log',s)),devices=v['devices'],transfer=self.build_transfer)
                return f"已生成 {output}（{meta['bytes']:,} 字节）"
            self.job('正在生成安装包',task)

    def poll(self):
        try:
            while True:
                kind,value=self.events.get_nowait()
                if kind=='log':
                    self.log.config(state='normal'); self.log.insert('end',value+'\n'); self.log.see('end'); self.log.config(state='disabled')
                else:
                    self.busy=False; self.status.config(text=value if kind=='ok' else '操作未完成')
                    if self.build_transfer is not None:
                        self.build_transfer.set_stage('制包完成' if kind=='ok' else '制包失败')
                    if kind=='error': messagebox.showerror('操作未完成',value,parent=self.root)
                    else: self.guard(self.refresh_detail)
        except queue.Empty: pass
        if self.build_transfer is not None:
            self.download_status.config(text=self.build_transfer.text())
        self.root.after(120,self.poll)


def main():
    if len(sys.argv)>1 and sys.argv[1]=='--build':
        from atlas import main as cli
        del sys.argv[1]
        cli(); return
    root=tk.Tk()
    Studio(root); root.mainloop()


if __name__=='__main__':
    main()
