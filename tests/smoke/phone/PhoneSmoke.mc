using Toybox.Application;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi;

// Simulator fixture supplies phone connectivity; send(), callback and rendering are production code.
class SmokePhoneTiles extends PhoneTiles {
    var link=true;
    var draws=0;
    function initialize() { PhoneTiles.initialize(); }
    function isConnected() { return link; }
    function send(request) {
        System.println("NATIVE_SEND "+request.xyz[2]+" heap="+System.getSystemStats().freeMemory);
        PhoneTiles.send(request);
    }
    function received(request,code,image) {
        System.println("NATIVE_RESPONSE code="+code+" image="+(image!=null));
        PhoneTiles.received(request,code,image);
    }
    function draw(dc,left,top) {
        PhoneTiles.draw(dc,left,top);
        if (ready.size()>0) { draws++; }
    }
}

class PhoneSmokeApp extends MapApp {
    var timer;
    var elapsed=0;
    var stage=0;
    var beforeX;
    var beforeY;
    function initialize() { MapApp.initialize(); }
    function getInitialView() {
        mainView=new MapView();
        mainView.phoneTiles=new SmokePhoneTiles();
        mainView.queueMapTiles();
        return [mainView,new MapDelegate(mainView)];
    }
    function onStart(state) {
        timer=new Timer.Timer();
        timer.start(method(:inspect),250,true);
    }
    function inspect() as Void {
        elapsed++;
        if (mainView==null || !mainView.restored) { return; }
        var p=mainView.phoneTiles;
        if (stage==0 && p.draws>0 && p.ready.size()==4) {
            System.println("NATIVE_HTTP_FOUR_BITMAPS_DRAWN");
            beforeX=mainView.centerGX; beforeY=mainView.centerGY;
            p.link=false; stage=1;
        } else if (stage==1 && !p.connected && p.ready.size()==0 && !mainView.tiles.pending() && !mainView.tiles.error) {
            System.println("LOCAL_FALLBACK_DRAW_READY");
            p.link=true; p.draws=0; stage=2;
        } else if (stage==2 && p.draws>0 && p.ready.size()==4 && mainView.centerGX==beforeX && mainView.centerGY==beforeY) {
            System.println("NATIVE_RECONNECT_PASS heap="+System.getSystemStats().usedMemory);
            timer.stop(); mainView.performAction("exit"); return;
        }
        if (elapsed>=180) {
            System.println("NATIVE_HTTP_TEST_TIMEOUT stage="+stage+" connected="+p.connected+
                " ready="+p.ready.size()+" wanted="+p.wanted.size()+" heap="+System.getSystemStats().freeMemory);
            timer.stop(); mainView.performAction("exit");
        }
    }
}
