using Toybox.Application.Storage;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi;

// Simulator-only entry point. Separate app ID and synthetic Storage keys.
class RecoverySmokeApp extends MapApp {
    function initialize() { MapApp.initialize(); }
    function getInitialView() {
        var records = WatchUi.loadResource(Rez.JsonData.LegacyRecovery);
        Storage.setValue("weinan.smoke.recovery.0", records[0]);
        Storage.setValue("weinan.smoke.recovery.1", records[1]);
        mainView = new RecoverySmokeView();
        return [mainView, new MapDelegate(mainView)];
    }
    function onStop(state) {
        MapApp.onStop(state);
        Storage.deleteValue("weinan.smoke.recovery.0");
        Storage.deleteValue("weinan.smoke.recovery.1");
        System.println("RECOVERY_SMOKE_STOPPED");
    }
}

class RecoverySmokeView extends MapView {
    var ticks = 0;
    var maxTickMs = 0;
    var begun = 0;
    var exitTimer = null;
    function initialize() {
        MapView.initialize();
        snapshots = new SnapshotStore("weinan.smoke.recovery.");
    }
    function onShow() {
        begun = System.getTimer();
        MapView.onShow();
        System.println("RECOVERY_SMOKE_STARTED");
    }
    function onRecoveryTick() as Void {
        ticks++;
        var start = System.getTimer();
        MapView.onRecoveryTick();
        var duration = System.getTimer() - start;
        if (duration > maxTickMs) { maxTickMs = duration; }
        if (!recovering) {
            System.println("RECOVERY_SMOKE_DONE ticks=" + ticks + " elapsed_ms=" + (System.getTimer() - begun) +
                " max_tick_ms=" + maxTickMs + " points=" + track.size() + " phase=" + recorder.state);
        }
    }
    function onUpdate(dc) {
        MapView.onUpdate(dc);
        if (restored && exitTimer == null) {
            var ok = track.size() == 800 && track.point(399) == null && track.projectedPoint(399) == null &&
                     recorder.state == recorder.HISTORY && snapshots.sequence == 2 && !recorder.hasSession();
            System.println(ok ? "RECOVERY_SMOKE_RENDER_PASS" : "RECOVERY_SMOKE_RENDER_FAIL");
            System.println("RECOVERY_SMOKE_MEMORY=" + System.getSystemStats().usedMemory);
            exitTimer = new Timer.Timer(); exitTimer.start(method(:finishSmoke), 200, false);
        }
    }
    function finishSmoke() as Void {
        checkpoint(true);
        System.println(snapshots.error == null ? "RECOVERY_SMOKE_SAVE_PASS" : "RECOVERY_SMOKE_SAVE_FAIL");
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
}
