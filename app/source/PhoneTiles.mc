using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Math;
using Toybox.System;
using Toybox.WatchUi;

// Each asynchronous callback owns its original XYZ and its own request identity.
class PhoneTileRequest {
    var owner;
    var xyz;
    var zoom;
    function initialize(manager, level, item) { owner = manager; zoom = level; xyz = item; }
    function receive(code as Lang.Number, image as WatchUi.BitmapResource or Graphics.BitmapReference or Null) as Void {
        owner.received(self, code, image);
    }
}

class PhoneTiles {
    const CACHE_LIMIT = 4;
    const TIMEOUT = 15000;
    const BACKOFF = 30000;
    var level = -1;
    var wanted = [];
    var ready = {};
    var current = null;
    var started = 0;
    var failedAt = null;
    var connected = false;

    function initialize() {}
    function now() { return System.getTimer(); }
    function isConnected() { return System.getDeviceSettings().phoneConnected; }
    function hasMemory() { return System.getSystemStats().freeMemory >= 100 * 1024; }
    function notify() { WatchUi.requestUpdate(); }

    function prepare(z, left, top, w, h) {
        var limit = (1 << z) - 1;
        var x0 = Math.floor(left / 256.0).toNumber(), y0 = Math.floor(top / 256.0).toNumber();
        var x1 = Math.ceil((left+w) / 256.0).toNumber()-1, y1 = Math.ceil((top+h) / 256.0).toNumber()-1;
        var cx = left+w/2.0, cy = top+h/2.0;
        var next = [];
        for (var y=y0; y<=y1; y++) {
            for (var x=x0; x<=x1; x++) {
                if (x<0 || y<0 || x>limit || y>limit) { continue; }
                var dx=x*256+128-cx, dy=y*256+128-cy;
                var score=dx*dx+dy*dy;
                var key=z.toString()+"/"+x.toString()+"/"+y.toString();
                next.add([x,y,key,score]);
                var i=next.size()-1;
                while (i>0 && next[i-1][3]>score) {
                    var item=next[i]; next[i]=next[i-1]; next[i-1]=item; i--;
                }
            }
        }
        // Only the four nearest visible tiles may occupy the graphics pool.
        if (next.size()>CACHE_LIMIT) { next=next.slice(0,CACHE_LIMIT); }
        var kept={};
        for (var n=0;n<next.size();n++) {
            var k=next[n][2];
            if (ready.hasKey(k)) { kept[k]=ready[k]; }
        }
        level=z; wanted=next; ready=kept;
    }
    function stop() {
        current=null; ready={}; connected=false; failedAt=null;
    }
    function fail(stamp) {
        current=null; ready={}; failedAt=stamp;
        notify();
    }
    function tick() {
        if (!isConnected()) {
            if (connected || current!=null || ready.size()>0) { stop(); notify(); }
            return;
        }
        connected=true;
        var stamp=now();
        if (current!=null) {
            var age=stamp-started;
            if (age<0 || age>=TIMEOUT) { fail(stamp); }
            return;
        }
        if (failedAt!=null) {
            var elapsed=stamp-failedAt;
            if (elapsed>=0 && elapsed<BACKOFF) { return; }
            failedAt=null;
        }
        for (var i=0;i<wanted.size();i++) {
            if (!ready.hasKey(wanted[i][2])) {
                if (!hasMemory()) { fail(stamp); return; }
                current=new PhoneTileRequest(self,level,wanted[i]);
                started=stamp;
                try { send(current); } catch(e) { fail(stamp); }
                return;
            }
        }
    }
    function send(request) {
        PhoneTileTransport.send(request);
    }
    function received(request,code,image) {
        if (current!=request) { return; }
        current=null;
        if (!isConnected()) { stop(); notify(); return; }
        var relevant=false;
        for (var i=0;i<wanted.size();i++) {
            if (request.xyz[2].equals(wanted[i][2])) { relevant=true; break; }
        }
        if (!relevant) { return; }
        if (code!=200 || image==null) { fail(now()); return; }
        try {
            if (image.getWidth()!=256 || image.getHeight()!=256) { fail(now()); return; }
            ready[request.xyz[2]]=image;
        } catch(e) { fail(now()); return; }
        notify();
    }
    function draw(dc,left,top) {
        for (var i=0;i<wanted.size();i++) {
            var item=wanted[i];
            var image=ready.get(item[2]);
            if (image!=null) {
                try { dc.drawBitmap(Math.floor(item[0]*256-left).toNumber(), Math.floor(item[1]*256-top).toNumber(),image); }
                catch(e) { fail(now()); return; }
            }
        }
    }
}
