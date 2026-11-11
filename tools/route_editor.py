"""Route and waypoint editing window, sharing the geographic map canvas."""
import copy
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from map_canvas import MapCanvas, world_point
from route_document import KINDS, MAX_EDIT_POINTS, EditorHistory, atomic_write, coordinate, waypoint


class RouteEditor:
    def __init__(self, parent, document, cache, source, coverage, draft, apply, background=None, mode='画路线'):
        self.root = tk.Toplevel(parent)
        self.root.title('路线与地点编辑器')
        self.root.geometry('1120x760')
        self.root.minsize(880,620)
        self.root.transient(parent)
        self.root.grab_set()
        self.document = copy.deepcopy(document)
        self.draft = draft
        self.apply = apply
        self.coverage = coverage
        self.background = background or []
        self.selected = None
        self.before_drag = None
        self.active_segment = max(0,len(document.segments)-1)
        self.draft_job = None
        try:
            recovered = draft.load()
            if recovered and messagebox.askyesno('恢复草稿','发现未完成的编辑，是否恢复？',parent=self.root):
                self.document = recovered
        except Exception as exc:
            messagebox.showinfo('草稿读取失败',str(exc),parent=self.root)
        self.history = EditorHistory(self.document)
        self.name = tk.StringVar(self.root,value=self.document.name)
        toolbar = ttk.Frame(self.root,padding=8)
        toolbar.pack(fill='x')
        name_entry = ttk.Entry(toolbar,textvariable=self.name,width=22)
        name_entry.pack(side='left',padx=(0,8))
        name_entry.bind('<FocusOut>',lambda event:self.rename())
        name_entry.bind('<Return>',lambda event:self.rename())
        self.mode = tk.StringVar(self.root,value=mode)
        for label in ('浏览','画路线','编辑节点','地点'):
            ttk.Radiobutton(toolbar,text=label,variable=self.mode,value=label,command=self.refresh).pack(side='left',padx=3)
        for label,command in [('撤销',self.undo),('重做',self.redo),('新分段',self.new_segment),('删除选中',self.delete)]:
            ttk.Button(toolbar,text=label,command=lambda fn=command:self.guard(fn)).pack(side='left',padx=2)
        body = ttk.Frame(self.root,padding=(8,0,8,8))
        body.pack(fill='both',expand=True)
        self.map = MapCanvas(body,cache,source,on_pointer=self.pointer)
        self.map.pack(side='left',fill='both',expand=True)
        side = ttk.Frame(body,width=230,padding=(10,0))
        side.pack(side='right',fill='y')
        ttk.Label(side,text='地点列表').pack(anchor='w')
        self.places = tk.Listbox(side,width=25,height=8,exportselection=False)
        self.places.pack(fill='x',pady=5)
        self.places.bind('<<ListboxSelect>>',self.select_place)
        self.fields = {}
        self.entries = {}
        for field,label in [('name','名称'),('lat','纬度'),('lon','经度'),('description','备注')]:
            ttk.Label(side,text=label).pack(anchor='w',pady=(7,0))
            self.fields[field] = tk.StringVar(self.root)
            self.entries[field] = ttk.Entry(side,textvariable=self.fields[field],width=25)
            self.entries[field].pack(fill='x')
        ttk.Label(side,text='类别').pack(anchor='w',pady=(7,0))
        self.kind = tk.StringVar(self.root,value=KINDS[0])
        self.kind_entry = ttk.Combobox(side,textvariable=self.kind,values=KINDS,state='readonly',width=22)
        self.kind_entry.pack(fill='x')
        self.sync = tk.BooleanVar(self.root,value=True)
        self.sync_entry = ttk.Checkbutton(side,text='同步到手表',variable=self.sync)
        self.sync_entry.pack(anchor='w',pady=8)
        ttk.Button(side,text='应用属性',command=lambda:self.guard(self.apply_properties)).pack(fill='x')
        ttk.Label(side,text='编辑节点时点击线段可插点。\n右键拖动地图，滚轮缩放。',wraplength=215).pack(anchor='w',pady=12)
        ttk.Button(side,text='定位经纬度…',command=self.locate).pack(fill='x')
        self.watch = tk.BooleanVar(self.root,value=False)
        ttk.Checkbutton(side,text='手表配色与简化线预览',variable=self.watch,command=self.refresh).pack(anchor='w',pady=8)
        footer = ttk.Frame(self.root,padding=8)
        footer.pack(fill='x')
        self.status = ttk.Label(footer)
        self.status.pack(side='left')
        ttk.Button(footer,text='应用到项目',command=lambda:self.guard(self.finish)).pack(side='right')
        ttk.Button(footer,text='导出 GPX…',command=lambda:self.guard(self.export)).pack(side='right',padx=6)
        self.root.protocol('WM_DELETE_WINDOW',self.close)
        for key,command in [('<Control-z>',self.undo),('<Control-y>',self.redo),('<Delete>',self.delete)]:
            self.root.bind(key,lambda event,fn=command:self.shortcut(event,fn))
        self.root.bind('<Escape>',self.clear_selection)
        self.refresh(fit=True)

    def guard(self, command):
        try:
            command()
        except Exception as exc:
            messagebox.showerror('编辑未完成',str(exc),parent=self.root)

    def shortcut(self, event, command):
        if event.widget.winfo_class() not in ('Entry','TEntry','Text','TCombobox'):
            self.guard(command)
            return 'break'

    def clear_selection(self, event=None):
        self.selected = None
        self.refresh()

    def refresh(self, fit=False):
        self.map.mode = '浏览' if self.watch.get() else self.mode.get()
        self.map.nodes = not self.watch.get() and self.mode.get() == '编辑节点' and bool(self.document.segments)
        self.map.selected = self.selected
        self.map.watch_colors = self.watch.get()
        routes = self.document.segments or self.background
        if self.watch.get() and self.document.segments:
            from gpx_route import project, simplify
            from map_canvas import geographic
            try:
                packed = simplify([[project(*point) for point in segment] for segment in self.document.segments if len(segment)>1])
                routes = [[]]
                for index in range(0,len(packed),2):
                    if packed[index] is None:
                        routes.append([])
                    else:
                        routes[-1].append(geographic(packed[index],packed[index+1]))
            except ValueError as exc:
                self.status.config(text=str(exc))
                self.watch.set(False)
                return
        self.map.scene(routes,self.document.waypoints,self.coverage,fit)
        self.places.delete(0,'end')
        for item in self.document.waypoints:
            self.places.insert('end',('● ' if item['sync'] else '○ ')+item['name'])
        if self.selected and self.selected[0]=='waypoint':
            self.places.selection_set(self.selected[1])
        count = sum(len(segment) for segment in self.document.segments)
        self.status.config(text=f'{self.document.distance()/1000:.2f} km · {count} 个节点 · {len(self.document.waypoints)} 个地点')

    def changed(self, before):
        if self.history.commit(before):
            if self.draft_job:
                self.root.after_cancel(self.draft_job)
            self.draft_job = self.root.after(700,self.persist)
        self.refresh()

    def rename(self):
        before = self.document.snapshot()
        self.document.name = self.name.get().strip()
        self.changed(before)

    def persist(self):
        self.draft_job = None
        self.document.name = self.name.get().strip()
        try:
            self.draft.save(self.document)
            self.status.config(text=f'草稿已保存 · {self.document.distance()/1000:.2f} km')
            return True
        except Exception as exc:
            self.status.config(text='草稿保存失败 '+str(exc))
            return False

    def nearest(self, x, y):
        candidates = []
        for segment_index,segment in enumerate(self.document.segments):
            for index,point in enumerate(segment):
                px,py = self.map.viewport.screen(*point)
                candidates.append(((px-x)**2+(py-y)**2,('point',segment_index,index)))
        for index,item in enumerate(self.document.waypoints):
            px,py = self.map.viewport.screen(item['lat'],item['lon'])
            candidates.append(((px-x)**2+(py-y)**2,('waypoint',index)))
        if candidates:
            distance,selected = min(candidates,key=lambda value:value[0])
            if distance <= 144:
                return selected
        return None

    def pointer(self, phase, x, y):
        self.guard(lambda:self.edit_pointer(phase,x,y))

    def edit_pointer(self, phase, x, y):
        lat,lon = coordinate(*self.map.viewport.location(x,y))
        if phase == 'press':
            before = self.document.snapshot()
            if self.mode.get() == '画路线':
                self.selected = None
                self.before_drag = None
                if sum(map(len,self.document.segments))>=MAX_EDIT_POINTS:
                    raise ValueError('路线最多编辑 20000 个节点')
                if not self.document.segments:
                    self.document.segments.append([])
                self.active_segment = min(self.active_segment,len(self.document.segments)-1)
                self.document.segments[self.active_segment].append((lat,lon))
                self.changed(before)
                return
            self.selected = self.nearest(x,y)
            if self.mode.get() == '地点' and (not self.selected or self.selected[0]!='waypoint'):
                if len(self.document.waypoints)>=256:
                    raise ValueError('每个地区最多编辑 256 个地点')
                self.document.waypoints.append(waypoint(lat,lon,f'地点{len(self.document.waypoints)+1}'))
                self.selected = ('waypoint',len(self.document.waypoints)-1)
                self.changed(before)
            elif self.mode.get() == '编辑节点' and self.selected is None:
                best = None
                for segment_index,segment in enumerate(self.document.segments):
                    for index,(a,b) in enumerate(zip(segment,segment[1:])):
                        ax,ay = self.map.viewport.screen(*a)
                        bx,by = self.map.viewport.screen(*b)
                        length = (bx-ax)**2+(by-ay)**2
                        ratio = min(1,max(0,((x-ax)*(bx-ax)+(y-ay)*(by-ay))/length)) if length else 0
                        distance = (x-ax-ratio*(bx-ax))**2+(y-ay-ratio*(by-ay))**2
                        if best is None or distance<best[0]:
                            best = (distance,segment_index,index+1)
                if best and best[0]<=144:
                    if sum(map(len,self.document.segments))>=MAX_EDIT_POINTS:
                        raise ValueError('路线最多编辑 20000 个节点')
                    self.document.segments[best[1]].insert(best[2],(lat,lon))
                    self.selected = ('point',best[1],best[2])
                    self.changed(before)
            self.before_drag = self.document.snapshot()
            self.show_properties()
            self.refresh()
        elif phase == 'drag' and self.selected and self.before_drag:
            if self.selected[0]=='point':
                self.document.segments[self.selected[1]][self.selected[2]] = (lat,lon)
            else:
                self.document.waypoints[self.selected[1]].update(lat=lat,lon=lon)
            self.refresh()
        elif phase == 'release' and self.before_drag:
            self.changed(self.before_drag)
            self.before_drag = None
            self.show_properties()

    def show_properties(self):
        if not self.selected:
            return
        is_place = self.selected[0]=='waypoint'
        if is_place:
            item = self.document.waypoints[self.selected[1]]
            lat,lon = item['lat'],item['lon']
            self.fields['name'].set(item['name'])
            self.fields['description'].set(item['description'])
            self.kind.set(KINDS[item['kind']])
            self.sync.set(item['sync'])
        else:
            lat,lon = self.document.segments[self.selected[1]][self.selected[2]]
            self.fields['name'].set('路线节点')
            self.fields['description'].set('')
        self.fields['lat'].set(f'{lat:.8f}')
        self.fields['lon'].set(f'{lon:.8f}')
        for name in ('name','description'):
            self.entries[name].config(state='normal' if is_place else 'disabled')
        self.kind_entry.config(state='readonly' if is_place else 'disabled')
        self.sync_entry.config(state='normal' if is_place else 'disabled')

    def select_place(self, event=None):
        selection = self.places.curselection()
        if selection:
            self.selected = ('waypoint',selection[0])
            point = self.document.waypoints[selection[0]]
            self.map.viewport.center = world_point(point['lat'],point['lon'])
            self.show_properties()
            self.refresh()

    def apply_properties(self):
        if not self.selected:
            return
        before = self.document.snapshot()
        lat,lon = coordinate(self.fields['lat'].get(),self.fields['lon'].get())
        if self.selected[0]=='point':
            self.document.segments[self.selected[1]][self.selected[2]] = (lat,lon)
        else:
            old = self.document.waypoints[self.selected[1]]
            self.document.waypoints[self.selected[1]] = waypoint(lat,lon,self.fields['name'].get(),
                KINDS.index(self.kind.get()),self.fields['description'].get(),self.sync.get(),old['id'])
        self.changed(before)

    def delete(self):
        if not self.selected:
            return
        before = self.document.snapshot()
        if self.selected[0]=='point':
            segment = self.document.segments[self.selected[1]]
            del segment[self.selected[2]]
            if not segment:
                del self.document.segments[self.selected[1]]
        else:
            del self.document.waypoints[self.selected[1]]
        self.selected = None
        self.changed(before)

    def undo(self):
        if self.history.undo():
            self.selected = None
            self.name.set(self.document.name)
            self.persist()
            self.refresh()

    def redo(self):
        if self.history.redo():
            self.selected = None
            self.name.set(self.document.name)
            self.persist()
            self.refresh()

    def new_segment(self):
        if self.document.segments and not self.document.segments[-1]:
            return
        before = self.document.snapshot()
        self.document.segments.append([])
        self.active_segment = len(self.document.segments)-1
        self.mode.set('画路线')
        self.changed(before)

    def locate(self):
        dialog = tk.Toplevel(self.root)
        dialog.title('定位经纬度')
        dialog.transient(self.root)
        dialog.grab_set()
        ttk.Label(dialog,text='纬度, 经度（WGS84）').pack(padx=14,pady=8)
        entry = ttk.Entry(dialog,width=36)
        entry.pack(padx=14,pady=8)
        def accept():
            try:
                lat,lon = coordinate(*entry.get().replace('，',',').split(','))
                self.map.viewport.center = world_point(lat,lon)
                self.map.viewport.zoom = max(16,self.map.viewport.zoom)
                self.map.redraw()
                dialog.destroy()
                self.root.grab_set()
            except Exception as exc:
                messagebox.showerror('经纬度无效',str(exc),parent=dialog)
        ttk.Button(dialog,text='定位',command=accept).pack(pady=8)

    def export(self):
        self.document.name = self.name.get().strip()
        data = self.document.export()
        path = filedialog.asksaveasfilename(parent=self.root,initialfile=self.document.name+'-编辑.gpx',
            defaultextension='.gpx',filetypes=[('GPX 路线和地点','*.gpx')])
        if path:
            atomic_write(path,data)
            self.status.config(text='GPX 已导出')

    def finish(self):
        self.document.name = self.name.get().strip()
        if self.document.segments or self.document.waypoints:
            self.document.export()
        if self.apply(self.document,self.root):
            try:
                self.draft.clear()
            except OSError:
                pass
            if self.draft_job:
                self.root.after_cancel(self.draft_job)
            self.root.destroy()

    def close(self):
        if self.persist():
            if self.draft_job:
                self.root.after_cancel(self.draft_job)
            self.root.destroy()
