"""Interactive geographic canvas with viewport-only background tile loading."""
from collections import OrderedDict
import math
from pathlib import Path
import queue
import threading
import tkinter as tk
from tkinter import ttk

from PIL import Image, ImageTk
from make_city_pack import fetch_tile
from map_source import quantize

WORLD = 256 << 15


def world_point(lat, lon):
    return ((lon+180)/360*WORLD,
            (1-math.asinh(math.tan(math.radians(lat)))/math.pi)/2*WORLD)


def geographic(x, y):
    return math.degrees(math.atan(math.sinh(math.pi*(1-2*y/WORLD)))), x/WORLD*360-180


class Viewport:
    def __init__(self, lat=34.5, lon=109.5, zoom=13):
        self.center = world_point(lat,lon)
        self.zoom = zoom
        self.width, self.height = 640,420

    @property
    def scale(self):
        return 2**(self.zoom-15)

    def screen(self, lat, lon):
        x,y = world_point(lat,lon)
        return ((x-self.center[0])*self.scale+self.width/2,
                (y-self.center[1])*self.scale+self.height/2)

    def location(self, x, y):
        return geographic(self.center[0]+(x-self.width/2)/self.scale,
                          self.center[1]+(y-self.height/2)/self.scale)

    def move(self, dx, dy):
        self.center = (min(WORLD-1,max(0,self.center[0]-dx/self.scale)),
                       min(WORLD-1,max(0,self.center[1]-dy/self.scale)))

    def zoom_at(self, zoom, x, y):
        position = world_point(*self.location(x,y))
        self.zoom = min(19,max(8,zoom))
        self.center = (position[0]-(x-self.width/2)/self.scale,
                       position[1]-(y-self.height/2)/self.scale)
        self.move(0,0)

    def fit(self, coordinates):
        points = [world_point(*point) for point in coordinates]
        if not points:
            return
        xs,ys = zip(*points)
        self.center = ((min(xs)+max(xs))/2,(min(ys)+max(ys))/2)
        ratio = max((max(xs)-min(xs))/max(100,self.width-40),
                    (max(ys)-min(ys))/max(100,self.height-40),1/16)
        self.zoom = min(19,max(8,math.floor(15-math.log2(ratio))))

    def tiles(self):
        scale = self.scale
        left = self.center[0]*scale-self.width/2
        top = self.center[1]*scale-self.height/2
        limit = (1 << self.zoom)-1
        keys = [(self.zoom,x,y) for y in range(max(0,math.floor(top/256)),min(limit,math.floor((top+self.height)/256))+1)
                for x in range(max(0,math.floor(left/256)),min(limit,math.floor((left+self.width)/256))+1)]
        keys.sort(key=lambda key:(key[1]*256+128-left-self.width/2)**2+(key[2]*256+128-top-self.height/2)**2)
        return left,top,keys


class MapCanvas(ttk.Frame):
    def __init__(self, parent, cache, source=None, on_pointer=None):
        super().__init__(parent)
        self.cache, self.source = Path(cache),source
        self.viewport = Viewport()
        self.routes, self.waypoints = [],[]
        self.coverage = None
        self.selected = None
        self.nodes = False
        self.watch_colors = False
        self.auto_load = True
        self.scene_ready = False
        self.resized = False
        self.on_pointer = on_pointer
        self.mode = '浏览'
        self.images = OrderedDict()
        self.tk_images = {}
        self.last_error = None
        self.photos = []
        self.results = queue.Queue()
        self.requests = queue.Queue(maxsize=1)
        self.generation = 0
        self.requested = None
        self.closed = False
        self.pan_start = None
        self.redraw_job = None
        self.fit_coordinates = []
        controls = ttk.Frame(self)
        controls.pack(fill='x')
        for label,command in [('＋',lambda:self.zoom(1)),('－',lambda:self.zoom(-1)),
                              ('查看全部',self.fit_all),('载入当前视野',self.load_view)]:
            ttk.Button(controls,text=label,command=command).pack(side='left',padx=2)
        self.message = ttk.Label(controls,text='滚轮缩放 · 拖动平移',width=42)
        self.message.pack(side='left',padx=8)
        self.canvas = tk.Canvas(self,bg='#e5eae5',highlightthickness=0,width=640,height=420)
        self.canvas.pack(fill='both',expand=True)
        self.canvas.bind('<Configure>',self.resize)
        self.canvas.bind('<MouseWheel>',self.wheel)
        self.canvas.bind('<ButtonPress-1>',self.press)
        self.canvas.bind('<B1-Motion>',self.drag)
        self.canvas.bind('<ButtonRelease-1>',self.release)
        self.canvas.bind('<ButtonPress-2>',self.start_pan)
        self.canvas.bind('<ButtonPress-3>',self.start_pan)
        self.canvas.bind('<B2-Motion>',self.pan)
        self.canvas.bind('<B3-Motion>',self.pan)
        self.canvas.bind('<ButtonRelease-2>',lambda event:setattr(self,'pan_start',None))
        self.canvas.bind('<ButtonRelease-3>',lambda event:setattr(self,'pan_start',None))
        self.bind('<Destroy>',self.destroyed)
        threading.Thread(target=self.worker,daemon=True).start()
        self.poll_job = self.after(80,self.poll)

    def destroyed(self, event):
        if event.widget == self:
            self.closed = True
            self.generation += 1
            self.after_cancel(self.poll_job)
            if self.redraw_job:
                self.after_cancel(self.redraw_job)

    def set_source(self, source):
        identity = source.fingerprint if source else None
        previous = self.source.fingerprint if self.source else None
        self.source = source
        if identity != previous:
            self.images.clear()
            self.tk_images.clear()
            self.requested = None
            self.generation += 1

    def scene(self, routes, waypoints, coverage=None, fit=False):
        self.scene_ready = True
        self.routes, self.waypoints, self.coverage = routes,waypoints,coverage
        self.fit_coordinates = [point for segment in routes for point in segment]
        self.fit_coordinates += [(point['lat'],point['lon']) for point in waypoints]
        if not self.fit_coordinates and coverage:
            self.fit_coordinates = [geographic(coverage[0],coverage[1]),geographic(coverage[2],coverage[3])]
        if fit:
            self.viewport.fit(self.fit_coordinates)
        self.redraw()

    def fit_all(self):
        self.viewport.fit(self.fit_coordinates)
        self.redraw()

    def load_view(self):
        self.auto_load = True
        self.requested = None
        self.redraw()

    def resize(self, event):
        self.viewport.width,self.viewport.height = max(100,event.width),max(100,event.height)
        if not self.resized:
            self.viewport.fit(self.fit_coordinates)
            self.resized = True
        if self.redraw_job:
            self.after_cancel(self.redraw_job)
        self.redraw_job = self.after(80,self.redraw)

    def zoom(self, step):
        self.viewport.zoom_at(self.viewport.zoom+step,self.viewport.width/2,self.viewport.height/2)
        self.redraw()

    def wheel(self, event):
        self.viewport.zoom_at(self.viewport.zoom+(1 if event.delta>0 else -1),event.x,event.y)
        self.redraw()
        return 'break'

    def start_pan(self, event):
        self.pan_start = (event.x,event.y)

    def pan(self, event):
        if self.pan_start:
            self.viewport.move(event.x-self.pan_start[0],event.y-self.pan_start[1])
            self.pan_start = (event.x,event.y)
            self.redraw()

    def press(self, event):
        self.canvas.focus_set()
        if self.mode == '浏览' or self.on_pointer is None:
            self.start_pan(event)
        else:
            self.on_pointer('press',event.x,event.y)

    def drag(self, event):
        if self.pan_start:
            self.pan(event)
        elif self.on_pointer:
            self.on_pointer('drag',event.x,event.y)

    def release(self, event):
        if self.pan_start:
            self.pan_start = None
        elif self.on_pointer:
            self.on_pointer('release',event.x,event.y)

    def worker(self):
        while not self.closed:
            try:
                generation,keys,source,download,zoom = self.requests.get(timeout=.5)
            except queue.Empty:
                continue
            memory = {}
            for key in keys:
                if self.closed or generation != self.generation:
                    break
                try:
                    fetch = download and key[0] == zoom
                    if source:
                        image = source.fetch(*key,memory,self.cache,allow_download=fetch,preview=True)
                    else:
                        path = self.cache/str(key[0])/str(key[1])/f'{key[2]}.png'
                        image = fetch_tile(*key,memory,cache_dir=str(self.cache)) if fetch or path.exists() else None
                    self.results.put((generation,key,image,None))
                except Exception as exc:
                    self.results.put((generation,key,None,str(exc)))
                    if download:
                        break

    def poll(self):
        changed = False
        error = None
        while not self.results.empty():
            generation,key,image,message = self.results.get_nowait()
            if generation != self.generation:
                continue
            if image is not None:
                self.images[key] = image
                self.tk_images.pop((key,False),None)
                self.tk_images.pop((key,True),None)
                self.images.move_to_end(key)
                while len(self.images)>96:
                    removed,_ = self.images.popitem(last=False)
                    self.tk_images.pop((removed,False),None)
                    self.tk_images.pop((removed,True),None)
                changed = True
            if message:
                error = message
        if error:
            self.last_error = error
        if changed or error:
            self.redraw()
        if not self.closed:
            self.poll_job = self.after(80,self.poll)

    def redraw(self):
        self.redraw_job = None
        if self.closed or not self.scene_ready:
            return
        canvas = self.canvas
        canvas.delete('all')
        self.photos = []
        left,top,keys = self.viewport.tiles()
        missing = [key for key in keys if key not in self.images]
        signature = (tuple(keys),self.auto_load,self.source.fingerprint if self.source else None)
        if signature != self.requested:
            self.last_error = None
            self.requested = signature
            self.generation += 1
            try:
                self.requests.get_nowait()
            except queue.Empty:
                pass
            parents = set()
            for z,x,y in missing:
                for parent_z in (13,15):
                    if parent_z<z:
                        factor = 1 << (z-parent_z)
                        parent_key = (parent_z,x//factor,y//factor)
                        if parent_key not in self.images:
                            parents.add(parent_key)
            self.requests.put_nowait((self.generation,sorted(parents)+missing,self.source,self.auto_load,self.viewport.zoom))
        for key in keys:
            z,x,y = key
            image = self.images.get(key)
            exact = image is not None
            if image is None:
                for parent_z in range(z-1,max(7,z-5),-1):
                    factor = 1 << (z-parent_z)
                    parent = self.images.get((parent_z,x//factor,y//factor))
                    if parent is not None:
                        size = 256/factor
                        image = parent.crop((int(x%factor*size),int(y%factor*size),
                                             int((x%factor+1)*size),int((y%factor+1)*size))).resize((256,256))
                        break
            px,py = x*256-left,y*256-top
            if image is not None:
                photo_key = (key,self.watch_colors)
                photo = self.tk_images.get(photo_key) if exact else None
                if photo is None:
                    photo = ImageTk.PhotoImage(quantize(image) if self.watch_colors else image,master=canvas)
                    if exact:
                        self.tk_images[photo_key] = photo
                self.photos.append(photo)
                canvas.create_image(px,py,image=photo,anchor='nw')
            else:
                canvas.create_rectangle(px,py,px+256,py+256,outline='#ccd4cd')
        if self.coverage:
            x1,y1,x2,y2 = self.coverage
            lat1,lon1 = geographic(x1,y1)
            lat2,lon2 = geographic(x2,y2)
            canvas.create_rectangle(*self.viewport.screen(lat1,lon1),*self.viewport.screen(lat2,lon2),
                                    outline='#c16b24',width=2,dash=(7,4))
        for segment_index,segment in enumerate(self.routes):
            points = [self.viewport.screen(*point) for point in segment]
            if len(points)>1:
                canvas.create_line(*[value for point in points for value in point],fill='#1859b5',width=3)
            for index,(x,y) in enumerate(points):
                if self.nodes and -5<x<self.viewport.width+5 and -5<y<self.viewport.height+5:
                    selected = self.selected == ('point',segment_index,index)
                    radius = 6 if selected else 3
                    canvas.create_oval(x-radius,y-radius,x+radius,y+radius,fill='#e86724' if selected else 'white',outline='#1859b5')
            for index,label in [(0,'起'),(len(points)-1,'终')]:
                if points:
                    x,y = points[index]
                    canvas.create_text(x,y-11,text=label,fill='#1859b5')
        for index,item in enumerate(self.waypoints):
            x,y = self.viewport.screen(item['lat'],item['lon'])
            if -10<x<self.viewport.width+10 and -10<y<self.viewport.height+10:
                selected = self.selected == ('waypoint',index)
                color = '#c64222' if item['kind']==3 else '#176853'
                canvas.create_oval(x-6,y-6,x+6,y+6,fill=color,outline='#f39a36' if selected else 'white',width=2)
                canvas.create_text(x+9,y-8,text=item['name'],anchor='w',fill=color)
        if self.watch_colors:
            cx,cy = self.viewport.width/2,self.viewport.height/2
            canvas.create_oval(cx-130,cy-130,cx+130,cy+130,outline='#202d25',width=2)
        lat,_ = geographic(*self.viewport.center)
        meters_per_pixel = 156543.03392*math.cos(math.radians(lat))/(2**self.viewport.zoom)
        candidates = [10,20,50,100,200,500,1000,2000,5000,10000,20000,50000]
        distance = min(candidates,key=lambda value:abs(value/meters_per_pixel-90))
        length = distance/meters_per_pixel
        y = self.viewport.height-22
        canvas.create_line(16,y,16+length,y,fill='#202d25',width=3)
        canvas.create_text(16,y-10,text=f'{distance:g} m',anchor='w',fill='#202d25')
        status = f'z{self.viewport.zoom} · 当前视野缓存 {len(keys)-len(missing)}/{len(keys)} 张'
        if self.last_error:
            status += ' · 加载失败，点载入重试'
        self.message.config(text=status)
