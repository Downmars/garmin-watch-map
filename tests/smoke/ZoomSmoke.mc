using Toybox.Application.Storage;
using Toybox.Lang;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi;

// Run twice without /t. The production MapView receives native drawing events
// directly; this app controller only injects keys and observes final state.
class ZoomSmokeApp extends MapApp {
    var stage=0;
    var controller=null;
    var actions=0;
    var begun=0;
    var ready=false;
    function initialize() {MapApp.initialize();}
    function onStart(state) {
        controller=new Timer.Timer(); controller.start(method(:tick),100,true);
    }
    function getInitialView() {
        var marker=Storage.getValue("weinan.zoom.stage");
        if(marker instanceof Lang.String && marker.equals("composed-native-verified")) {stage=1;}
        if(stage==0) {
            var records=WatchUi.loadResource(Rez.JsonData.LegacyRecovery);
            Storage.setValue("weinan.zoom.0",records[0]); Storage.setValue("weinan.zoom.1",records[1]);
        }
        mainView=new MapView(); mainView.snapshots=new SnapshotStore("weinan.zoom.");
        return [mainView,new MapDelegate(mainView)];
    }
    function press(key) {
        var input=new MapDelegate(mainView); input.onKey(new ZoomSmokeKey(key));
    }
    function tick() as Void {
        var view=mainView;
        if(view==null || !view.restored || view.tiles.pending()) {return;}
        if(view.tiles.error) {throw new Lang.InvalidValueException("native map resource failure");}
        if(!ready) {
            if(view.track.size()!=800 || view.track.point(399)!=null || view.recorder.state!=view.recorder.HISTORY) {
                throw new Lang.InvalidValueException("legacy recovery mismatch");
            }
            if(stage==1 && view.snapshots.sequence<3) {throw new Lang.InvalidValueException("did not reopen saved snapshot");}
            ready=true; begun=System.getTimer();
            System.println(stage==0 ? "ZOOM_START_PASS" : "ZOOM_REOPEN_PASS");
        }
        if(stage==1 || actions==100) {
            controller.stop();
            var used=System.getSystemStats().usedMemory;
            if(used>=350*1024) {throw new Lang.InvalidValueException("heap sample over budget");}
            System.println("ZOOM_ACTIONS_PASS actions="+actions+" queue_prepares="+view.tiles.loads+
                " end_memory="+used+" elapsed_ms="+(System.getTimer()-begun));
            view.performAction("exit"); return;
        }
        var part=actions%5;
        if(part==0) {
            while(view.browse.axis!=2) {press(WatchUi.KEY_START);}
            press(WatchUi.KEY_DOWN);
        } else if(part==1) {
            press(WatchUi.KEY_START); press(WatchUi.KEY_DOWN);
        } else if(part==2) {
            press(WatchUi.KEY_START); press(WatchUi.KEY_DOWN);
        } else if(part==3) {
            press(WatchUi.KEY_START); press(WatchUi.KEY_UP);
        } else {
            var x=view.centerGX; var y=view.centerGY;
            view.followPosition(34.51,109.51);
            if(x!=view.centerGX || y!=view.centerGY) {throw new Lang.InvalidValueException("GPS moved browsing center");}
            press(WatchUi.KEY_ESC);
        }
        if(view.tiles.entries.size()>4 || view.track.size()!=800 || view.recorder.hasSession()) {
            throw new Lang.InvalidValueException("state changed during browsing");
        }
        actions++;
        if(actions%25==0) {System.println("ZOOM_PROGRESS actions="+actions);}
    }
    function onStop(state) {
        if(controller!=null) {controller.stop();}
        MapApp.onStop(state);
        if(mainView.snapshots.error!=null) {throw new Lang.InvalidValueException("snapshot save failed");}
        if(stage==0 && actions==100) {Storage.setValue("weinan.zoom.stage","composed-native-verified");}
        else {
            Storage.deleteValue("weinan.zoom.0"); Storage.deleteValue("weinan.zoom.1");
            Storage.deleteValue("weinan.zoom.stage");
        }
        System.println("ZOOM_STOP_PASS stage="+stage);
    }
}

class ZoomSmokeKey {
    var key;
    function initialize(value) {key=value;}
    function getKey() {return key;}
}
