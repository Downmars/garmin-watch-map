using Toybox.Application.Storage;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Position;
using Toybox.System;
using Toybox.Test;

class RecoveryStoreSpy extends MemorySnapshots {
    var reads = 0;
    var writes = 0;
    var readFail = false;
    function initialize() { MemorySnapshots.initialize(); }
    function readValue(key) {
        reads++;
        if (readFail) { throw new Lang.InvalidValueException("injected read failure"); }
        return MemorySnapshots.readValue(key);
    }
    function writeValue(key, value) { writes++; MemorySnapshots.writeValue(key, value); }
}
class RecoveryTimerSpy {
    var starts = 0;
    var stops = 0;
    var interval = 0;
    var repeating = false;
    function initialize() {}
    function start(callback, ms, repeat) { starts++; interval = ms; repeating = repeat; }
    function stop() { stops++; }
}
class RecoveryViewSpy extends MapView {
    var liveStarts = 0;
    function initialize() { MapView.initialize(); }
    function createRecoveryTimer() { return new RecoveryTimerSpy(); }
    function startLiveUpdates() { liveStarts++; }
}

function legacyRecoveryRecord(store, seq, count) {
    var points = [];
    for (var i = 0; i < count; i++) {
        if (i == 399) { points.add(null); points.add(null); }
        else { points.add(3450000 + i); points.add(10950000); }
    }
    var record = [1, seq, 123456, 7200, 3, 1793960000, points, 0];
    // The unchanged alpha.1 checksum provides the compatibility reference.
    record[7] = store.checksum(record);
    return record;
}

function driveRecovery(view) {
    var ticks = 0;
    while (view.recovering && ticks < 100) {
        var previousSize = view.track.size();
        var loader = view.recovery;
        var candidate = loader == null ? null : loader.candidate;
        var cursor = loader == null ? 0 : loader.cursor;
        var started = System.getTimer();
        view.onRecoveryTick(); ticks++;
        Test.assert(view.track.size() - previousSize <= 32);
        if (loader != null && candidate != null && loader.candidate == candidate) {
            Test.assert(loader.cursor - cursor <= 64);
        }
        Test.assert(System.getTimer() - started < 1000);
    }
    Test.assert(view.restored); Test.assert(!view.recovering);
    return ticks;
}

(:test)
function startupDefersStorageAndBoundsFullTrackCallbacks(logger as Test.Logger) as Lang.Boolean {
    var store = new RecoveryStoreSpy();
    store.data.put("test.0", legacyRecoveryRecord(store, 2, 800));
    store.data.put("test.1", legacyRecoveryRecord(store, 1, 800));
    var view = new RecoveryViewSpy(); view.snapshots = store;
    view.onShow(); var timer = view.recoveryTimer;
    Test.assert(!view.restored); Test.assert(view.recovering);
    Test.assertEqual(store.reads, 0); Test.assertEqual(view.track.size(), 0);
    Test.assertEqual(timer.interval, 100); Test.assert(timer.repeating);
    view.onShow(); Test.assertEqual(timer.starts, 1); Test.assertEqual(view.liveStarts, 0);
    var ticks = driveRecovery(view);
    Test.assertEqual(ticks, 78); Test.assertEqual(store.reads, 2); Test.assertEqual(store.writes, 0);
    Test.assertEqual(timer.stops, 1); Test.assertEqual(view.liveStarts, 1);
    view.onRecoveryTick(); Test.assertEqual(view.liveStarts, 1);
    Test.assertEqual(view.track.size(), 800); Test.assert(view.track.point(399) == null);
    Test.assert(view.track.projectedPoint(399) == null); Test.assertEqual(store.sequence, 2);
    Test.assertEqual(view.recorder.elapsedMs(), 7200000); Test.assertEqual(view.track.distance, 1234.56);
    Test.assertEqual(view.recorder.state, view.recorder.HISTORY); Test.assert(view.loc == null);
    Test.assertEqual(view.savedRevision, view.track.revision);
    logger.debug("RECOVERY_CALLBACKS=" + ticks);
    return true;
}

(:test)
function recoveryFallsBackWhenNewestChecksumFailsAtLastPoint(logger as Test.Logger) as Lang.Boolean {
    var store = new RecoveryStoreSpy();
    var latest = legacyRecoveryRecord(store, 2, 800); latest[6][1598] += 1;
    store.data.put("test.0", latest); store.data.put("test.1", legacyRecoveryRecord(store, 1, 800));
    var view = new RecoveryViewSpy(); view.snapshots = store; view.onShow();
    driveRecovery(view);
    Test.assertEqual(store.sequence, 1); Test.assertEqual(view.track.size(), 800);
    Test.assert(view.notice.equals("部分轨迹无法恢复")); Test.assertEqual(store.writes, 0);
    return true;
}

(:test)
function recoveryRejectsPartialNullAndMalformedHeaders(logger as Test.Logger) as Lang.Boolean {
    var store = new RecoveryStoreSpy();
    var broken = legacyRecoveryRecord(store, 2, 800); broken[6][1598] = null;
    broken[7] = store.checksum(broken);
    store.data.put("test.0", broken); store.data.put("test.1", [1, 2]);
    var view = new RecoveryViewSpy(); view.snapshots = store; view.onShow(); driveRecovery(view);
    Test.assertEqual(view.track.size(), 0); Test.assertEqual(view.recorder.state, view.recorder.IDLE);
    Test.assert(view.notice != null); Test.assertEqual(store.writes, 0);
    return true;
}

(:test)
function partialRecoveryCannotStartRecordOrOverwriteSavedData(logger as Test.Logger) as Lang.Boolean {
    var store = new RecoveryStoreSpy(); var saved = legacyRecoveryRecord(store, 1, 800);
    store.data.put("test.1", saved);
    var view = new RecoveryViewSpy(); view.snapshots = store; view.recorder = new TestRecorder();
    view.onShow();
    for (var i = 0; i < 29; i++) { view.onRecoveryTick(); }
    Test.assert(view.track.size() > 0 && view.track.size() < 800);
    var size = view.track.size();
    view.fix.accept(34.5, 109.5, Position.QUALITY_GOOD, 100, System.getTimer());
    view.performAction("walk"); view.checkpoint(true); view.onHeadingTick(); view.openMenu();
    Test.assertEqual(view.recorder.creates, 0); Test.assert(!view.menuOpen);
    Test.assertEqual(view.track.size(), size); Test.assertEqual(store.writes, 0);
    var bitmap = Graphics.createBufferedBitmap({:width=>260, :height=>260}).get();
    view.onUpdate(bitmap.getDc());
    view.shutdown(); Test.assertEqual(store.writes, 0);
    Test.assertEqual(store.checksum(saved), saved[7]); Test.assertEqual(saved[6].size(), 1600);
    return true;
}

(:test)
function hidingRecoveryStopsTimerAndShowingResumesSameLoader(logger as Test.Logger) as Lang.Boolean {
    var store = new RecoveryStoreSpy(); store.data.put("test.0", legacyRecoveryRecord(store, 2, 800));
    var view = new RecoveryViewSpy(); view.snapshots = store; view.onShow();
    view.onRecoveryTick(); view.onRecoveryTick();
    var timer = view.recoveryTimer; var loader = view.recovery; var cursor = loader.cursor;
    view.onHide(); Test.assertEqual(timer.stops, 1); Test.assert(view.recoveryTimer == null);
    view.onShow(); Test.assert(view.recovery == loader); Test.assertEqual(loader.cursor, cursor);
    Test.assertEqual(store.reads, 1); driveRecovery(view);
    Test.assertEqual(store.reads, 2); Test.assertEqual(view.track.size(), 800);
    return true;
}

(:test)
function emptyAndUnreadableRecoveryFinishWithoutWriting(logger as Test.Logger) as Lang.Boolean {
    var store = new RecoveryStoreSpy(); var view = new RecoveryViewSpy(); view.snapshots = store;
    view.onShow(); Test.assertEqual(driveRecovery(view), 3);
    Test.assert(view.notice == null); Test.assertEqual(view.liveStarts, 1); Test.assertEqual(store.writes, 0);
    store = new RecoveryStoreSpy(); store.readFail = true;
    view = new RecoveryViewSpy(); view.snapshots = store; view.onShow(); driveRecovery(view);
    Test.assert(view.notice.equals("轨迹读取失败")); Test.assertEqual(store.writes, 0);
    return true;
}

(:test)
function legacyDoubleSlotStorageRestoresThroughStartupCallbacks(logger as Test.Logger) as Lang.Boolean {
    var prefix = "weinan.unit.recovery.";
    var store = new SnapshotStore(prefix);
    store.writeValue(prefix + "0", legacyRecoveryRecord(store, 2, 800));
    store.writeValue(prefix + "1", legacyRecoveryRecord(store, 1, 800));
    var view = new RecoveryViewSpy(); view.snapshots = store; view.onShow(); driveRecovery(view);
    Test.assertEqual(view.track.size(), 800); Test.assert(!view.recorder.hasSession());
    var bitmap = Graphics.createBufferedBitmap({:width=>260, :height=>260}).get();
    view.onUpdate(bitmap.getDc());
    logger.debug("RESTORED_MAP_USED_MEMORY=" + System.getSystemStats().usedMemory);
    Test.assert(System.getSystemStats().usedMemory < 350 * 1024);
    Storage.deleteValue(prefix + "0"); Storage.deleteValue(prefix + "1");
    return true;
}

(:test)
function snapshotSaveHashesOnceAndRejectsInvalidTrack(logger as Test.Logger) as Lang.Boolean {
    var store = new RecoveryStoreSpy(); var track = new TrackModel();
    var legacy = legacyRecoveryRecord(store, 2, 800);
    Test.assertEqual(store.checkedChecksum(legacy), store.checksum(legacy));
    track.restore(legacy[6], legacy[2]);
    Test.assert(store.save(track, 7200000, 3));
    var record = store.data.get("test.1"); Test.assertEqual(record[7], store.checksum(record));
    track.clear(); track.append([91.0, 109.5]);
    Test.assert(!store.save(track, 0, 0)); Test.assertEqual(store.writes, 1);
    return true;
}

(:test)
function shutdownWritesFinalFitStateOnceAndSkipsUnchangedSnapshot(logger as Test.Logger) as Lang.Boolean {
    var store = new RecoveryStoreSpy(); var view = new MapView(); var r = new TestRecorder();
    view.snapshots = store; view.recorder = r; view.restored = true;
    view.track.accept(34.5, 109.5, true); r.start(Toybox.Activity.SPORT_WALKING);
    view.shutdown();
    Test.assertEqual(store.writes, 1); Test.assertEqual(store.load()[4], r.SAVED);
    Test.assertEqual(r.fake.saves, 1);
    view.shutdown(); Test.assertEqual(store.writes, 1); Test.assertEqual(r.fake.saves, 1);
    view.track.accept(34.5001, 109.5, true); view.checkpoint(true);
    Test.assertEqual(store.writes, 2); view.shutdown(); Test.assertEqual(store.writes, 2);
    return true;
}
