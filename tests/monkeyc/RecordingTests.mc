using Toybox.Activity;
using Toybox.Application.Storage;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Position;
using Toybox.System;
using Toybox.Test;

class FakeFitSession {
    var active = false;
    var startOK = true;
    var stopOK = true;
    var saveOK = true;
    var discardOK = true;
    var saves = 0;
    var discards = 0;
    function initialize() {}
    function isRecording() { return active; }
    function start() { if (startOK) { active = true; } return startOK; }
    function stop() { if (stopOK) { active = false; } return stopOK; }
    function save() { saves++; return saveOK; }
    function discard() { discards++; return discardOK; }
}
class TestRecorder extends RecordingController {
    var fake;
    var clock = 0;
    var creates = 0;
    function initialize() { RecordingController.initialize(); fake = new FakeFitSession(); }
    function now() { return clock; }
    function createSession(sport) { creates++; return fake; }
}
class MemorySnapshots extends SnapshotStore {
    var data = {};
    var writeFail = false;
    function initialize() { SnapshotStore.initialize("test."); }
    function readValue(key) { return data.get(key); }
    function writeValue(key, value) {
        if (writeFail) { throw new Lang.InvalidValueException("injected storage failure"); }
        data.put(key, value);
    }
}

(:test)
function recordingPauseResumePreservesSessionAndActiveTime(logger as Test.Logger) as Lang.Boolean {
    var r = new TestRecorder();
    Test.assert(r.start(Activity.SPORT_WALKING));
    r.clock = 30000; Test.assert(r.pause());
    Test.assert(!r.canAccumulate());
    r.clock = 90000; Test.assertEqual(r.elapsedMs(), 30000);
    Test.assert(r.resume()); r.clock = 100000;
    Test.assertEqual(r.elapsedMs(), 40000);
    Test.assert(r.finish(true)); Test.assertEqual(r.creates, 1);
    Test.assertEqual(r.fake.saves, 1); Test.assert(!r.hasSession());
    return true;
}

(:test)
function failedSaveRetainsPausedSessionForRetry(logger as Test.Logger) as Lang.Boolean {
    var r = new TestRecorder(); r.start(Activity.SPORT_RUNNING); r.fake.saveOK = false;
    Test.assert(!r.finish(true)); Test.assert(r.hasSession());
    Test.assertEqual(r.state, r.PAUSED); Test.assert(r.error != null);
    Test.assert(!r.start(Activity.SPORT_WALKING)); Test.assertEqual(r.creates, 1);
    r.fake.saveOK = true; Test.assert(r.finish(true)); Test.assertEqual(r.fake.saves, 2);
    return true;
}

(:test)
function failedStopNeverSavesOrDiscardsActiveSession(logger as Test.Logger) as Lang.Boolean {
    var r = new TestRecorder(); r.start(Activity.SPORT_WALKING); r.fake.stopOK = false;
    Test.assert(!r.finish(true)); Test.assert(!r.finish(false));
    Test.assertEqual(r.fake.saves, 0); Test.assertEqual(r.fake.discards, 0);
    Test.assertEqual(r.state, r.RUNNING);
    return true;
}

(:test)
function failedStartAndDiscardCanBeRetried(logger as Test.Logger) as Lang.Boolean {
    var r = new TestRecorder(); r.fake.startOK = false;
    Test.assert(!r.start(Activity.SPORT_WALKING)); Test.assert(r.hasSession());
    r.fake.startOK = true; Test.assert(r.resume());
    r.fake.discardOK = false; Test.assert(!r.finish(false)); Test.assert(r.hasSession());
    r.fake.discardOK = true; Test.assert(r.finish(false)); Test.assert(!r.hasSession());
    Test.assertEqual(r.fake.saves, 0);
    return true;
}

(:test)
function existingActiveSessionIsNotModified(logger as Test.Logger) as Lang.Boolean {
    var r = new TestRecorder(); r.fake.active = true;
    Test.assert(!r.start(Activity.SPORT_WALKING)); Test.assert(!r.hasSession());
    Test.assert(r.fake.active); Test.assertEqual(r.fake.discards, 0); Test.assertEqual(r.fake.saves, 0);
    return true;
}

(:test)
function ringBufferKeepsNewestPointsAndStaysBounded(logger as Test.Logger) as Lang.Boolean {
    var t = new TrackModel();
    for (var i = 0; i < 4000; i++) { t.append([34.5 + i * 0.00001, 109.5]); }
    Test.assertEqual(t.size(), 800);
    Test.assert(t.point(0)[0] > 34.5319 && t.point(0)[0] < 34.5321);
    t.append(null); t.append([34.6, 109.5]);
    Test.assert(t.point(798) == null); Test.assertEqual(t.size(), 800);
    return true;
}

(:test)
function trackPauseAndJumpDoNotBridgeDistance(logger as Test.Logger) as Lang.Boolean {
    var t = new TrackModel();
    t.accept(34.5, 109.5, true); t.accept(34.5001, 109.5, false);
    var before = t.distance; Test.assert(before > 10 && before < 12);
    t.breakSegment(); t.accept(34.6, 109.5, false);
    Test.assertEqual(t.distance, before); Test.assert(t.point(2) == null);
    t.accept(35.0, 109.5, false); Test.assertEqual(t.distance, before);
    Test.assert(t.point(4) == null);
    return true;
}

(:test)
function snapshotCorruptionFallsBackAndWritesFailSafely(logger as Test.Logger) as Lang.Boolean {
    var store = new MemorySnapshots(); var t = new TrackModel();
    t.accept(34.5, 109.5, true); Test.assert(store.save(t, 1000, 1));
    t.accept(34.5001, 109.5, false); Test.assert(store.save(t, 2000, 2));
    store.data.get("test.0")[7] = -1;
    var recovered = store.load(); Test.assertEqual(recovered[1], 1);
    store.writeFail = true; Test.assert(!store.save(t, 3000, 3));
    Test.assertEqual(store.sequence, 1); Test.assert(store.error != null);
    Test.assertEqual(store.load()[1], 1);
    return true;
}

(:test)
function snapshotRejectsInvalidSchemaAndCoordinates(logger as Test.Logger) as Lang.Boolean {
    var store = new MemorySnapshots(); var t = new TrackModel();
    t.accept(34.5, 109.5, true); store.save(t, 1000, 1);
    var record = store.load(); record[0] = 99;
    Test.assert(!store.valid(record)); record[0] = 1; record[6][0] = 9100000;
    record[7] = store.checksum(record); Test.assert(!store.valid(record));
    Test.assert(!store.valid([1, 2])); Test.assert(!store.valid("corrupt"));
    return true;
}

(:test)
function fullTrackFitsRealDoubleSlotStorage(logger as Test.Logger) as Lang.Boolean {
    var key = "weinan.unit.v03.";
    Storage.deleteValue(key + "0"); Storage.deleteValue(key + "1");
    var store = new SnapshotStore(key); var t = new TrackModel();
    for (var i = 0; i < 800; i++) { t.append([34.5 + i * 0.00001, 109.5]); }
    Test.assert(store.save(t, 7200000, 2)); Test.assert(store.save(t, 7200000, 3));
    var restored = new TrackModel(); var data = new SnapshotStore(key).load();
    Test.assert(data != null); restored.restore(data[6], data[2]);
    Test.assertEqual(restored.size(), 800); Test.assertEqual(data[3], 7200);
    logger.debug("MODEL_STORAGE_USED_MEMORY=" + System.getSystemStats().usedMemory);
    Storage.deleteValue(key + "0"); Storage.deleteValue(key + "1");
    return true;
}

(:test)
function menuRequiresConfirmationBeforeDiscard(logger as Test.Logger) as Lang.Boolean {
    var view = new MapView(); var r = new TestRecorder(); view.recorder = r;
    r.start(Activity.SPORT_WALKING); view.track.accept(34.5, 109.5, true);
    view.openMenu(); view.performAction("discard");
    Test.assertEqual(r.fake.discards, 0); view.performAction("cancel");
    view.performAction("discard_yes"); Test.assertEqual(r.fake.discards, 0);
    Test.assertEqual(r.fake.discards, 0); view.performAction("discard"); view.performAction("discard_yes");
    Test.assertEqual(r.fake.discards, 1); Test.assertEqual(view.track.size(), 0);
    return true;
}

(:test)
function menuStartRequiresFreshFixAndPauseKeepsTrack(logger as Test.Logger) as Lang.Boolean {
    var view = new MapView(); var r = new TestRecorder(); view.recorder = r;
    view.performAction("walk"); Test.assertEqual(r.creates, 0);
    view.fix.accept(34.5, 109.5, Position.QUALITY_GOOD, 100, System.getTimer());
    view.performAction("walk"); Test.assertEqual(r.creates, 1);
    view.track.accept(34.5, 109.5, true); view.performAction("toggle");
    Test.assertEqual(r.state, r.PAUSED); Test.assertEqual(view.track.size(), 1);
    view.performAction("toggle"); Test.assertEqual(view.track.size(), 1);
    return true;
}

(:test)
function menuRenderingUsesSupportedGraphics(logger as Test.Logger) as Lang.Boolean {
    var view = new MapView(); var bitmap = Graphics.createBufferedBitmap({:width=>260, :height=>260}).get();
    Test.assert(bitmap.getDc().getFontHeight(Graphics.FONT_XTINY) <= 26);
    view.openMenu(); view.onUpdate(bitmap.getDc());
    view.recorder = new TestRecorder(); view.recorder.start(Activity.SPORT_WALKING);
    view.openMenu(); view.onDown(); view.onUpdate(bitmap.getDc());
    view.performAction("discard"); view.onUpdate(bitmap.getDc());
    return true;
}

(:test)
function nativeFitSessionStartPauseResumeSave(logger as Test.Logger) as Lang.Boolean {
    var r = new RecordingController();
    Test.assert(r.start(Activity.SPORT_WALKING)); Test.assert(r.pause());
    Test.assert(r.resume()); Test.assert(r.finish(true));
    Test.assert(!r.hasSession()); logger.debug("NATIVE_FIT_SAVE_SUCCEEDED");
    return true;
}

(:test)
function savedFitDoesNotHideSnapshotFailure(logger as Test.Logger) as Lang.Boolean {
    var view = new MapView(); var r = new TestRecorder(); var store = new MemorySnapshots();
    view.recorder = r; view.snapshots = store; view.restored = true;
    r.start(Activity.SPORT_WALKING); store.writeFail = true; view.performAction("save");
    Test.assertEqual(r.state, r.SAVED); Test.assert(view.notice.equals("轨迹保存失败"));
    return true;
}

(:test)
function discardReplacesBothRecoverySlotsWithEmptyTrack(logger as Test.Logger) as Lang.Boolean {
    var view = new MapView(); var r = new TestRecorder(); var store = new MemorySnapshots();
    view.recorder = r; view.snapshots = store; view.restored = true;
    view.track.accept(34.5, 109.5, true); view.checkpoint(true); view.checkpoint(true);
    r.start(Activity.SPORT_WALKING); view.performAction("discard"); view.performAction("discard_yes");
    Test.assertEqual(store.load()[6].size(), 0);
    store.data.get("test." + (store.sequence % 2).toString())[7] = -1;
    Test.assertEqual(store.load()[6].size(), 0);
    return true;
}

(:test)
function restoredTrackDoesNotPretendToResumeFit(logger as Test.Logger) as Lang.Boolean {
    var store = new MemorySnapshots(); var track = new TrackModel();
    track.accept(34.5, 109.5, true); store.save(track, 65000, 1);
    var view = new MapView(); view.snapshots = store; view.restoreSnapshot();
    Test.assertEqual(view.track.size(), 1); Test.assertEqual(view.recorder.state, view.recorder.HISTORY);
    Test.assert(!view.recorder.hasSession()); Test.assert(!view.recorder.canAccumulate());
    Test.assert(view.loc == null); Test.assertEqual(view.recorder.elapsedMs(), 65000);
    return true;
}

(:test)
function fullMapAndLongTrackRenderWithinDeviceBudget(logger as Test.Logger) as Lang.Boolean {
    var view = new MapView();
    for (var i = 0; i < 800; i++) { view.track.append([34.5 + (i % 20) * 0.00001, 109.5]); }
    var bitmap = Graphics.createBufferedBitmap({:width=>260, :height=>260}).get();
    view.onUpdate(bitmap.getDc());
    logger.debug("MAP_RENDER_USED_MEMORY=" + System.getSystemStats().usedMemory);
    Test.assert(System.getSystemStats().usedMemory < 350 * 1024);
    return true;
}
