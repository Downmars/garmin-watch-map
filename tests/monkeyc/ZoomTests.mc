using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Test;

function prepareTestTiles(view) {
    view.queueMapTiles();
    var steps = 0;
    while (view.tiles.pending() && steps < 4) { view.tiles.step(); steps++; }
    Test.assert(!view.tiles.pending()); Test.assert(!view.tiles.error);
}

class FakeMapTileCache extends MapTileCache {
    var failLoads = false;
    function initialize() { MapTileCache.initialize(); }
    function loadResource(id) {
        if (failLoads) { throw new Lang.InvalidValueException("injected tile failure"); }
        return id;
    }
}
class FakeTileDc {
    var draws=[];
    function initialize() {}
    function drawBitmap(x,y,resource) {draws.add([x,y,resource]);}
}

(:test)
function tileDrawingSnapsPixelsWithoutOpeningSeams(logger as Test.Logger) as Lang.Boolean {
    var cache=new FakeMapTileCache(); var dc=new FakeTileDc();
    cache.prepare(0,[15,1.0,0,0,2,1,[10,11]],400.25,0.25,260,260);
    cache.step(); cache.step(); cache.draw(dc,400.25,0.25);
    Test.assertEqual(dc.draws.size(),2);
    Test.assertEqual(dc.draws[0][0],-401); Test.assertEqual(dc.draws[1][0],111);
    Test.assertEqual(dc.draws[0][1],-1); Test.assertEqual(dc.draws[1][1],-1);
    Test.assertEqual(dc.draws[1][0]-dc.draws[0][0],512);
    return true;
}

(:test)
function visibleTilesMatchBruteForceAtEdgesAndOutside(logger as Test.Logger) as Lang.Boolean {
    var layer = [15,1.0,0,0,11,11,[]];
    var offsets = [-600,-512,-260,-1,0,252,256,511,512,513,5500,5632,6000];
    for (var a = 0; a < offsets.size(); a++) {
        for (var b = 0; b < offsets.size(); b++) {
            var found = MapTiles.visible(layer, offsets[a], offsets[b], 260, 260);
            var expected = [];
            for (var row = 0; row < 11; row++) {
                for (var col = 0; col < 11; col++) {
                    var x = col * 512 - offsets[a]; var y = row * 512 - offsets[b];
                    if (x > -512 && x < 260 && y > -512 && y < 260) { expected.add(row * 11 + col); }
                }
            }
            Test.assertEqual(found.size(), expected.size()); Test.assert(found.size() <= 4);
            for (var n = 0; n < found.size(); n++) { Test.assertEqual(found[n], expected[n]); }
        }
    }
    return true;
}

(:test)
function tileQueueLoadsOncePerStepAndCancelsObsoleteLevel(logger as Test.Logger) as Lang.Boolean {
    var ids = [10,11,12,13]; var layer = [15,1.0,0,0,2,2,ids];
    var cache = new FakeMapTileCache(); cache.prepare(0,layer,400,400,260,260);
    Test.assertEqual(cache.wanted.size(),4); Test.assertEqual(cache.loads,0);
    cache.step(); Test.assertEqual(cache.loads,1); Test.assertEqual(cache.entries.size(),1);
    cache.prepare(1,[13,0.25,0,0,2,2,[20,21,22,23]],0,0,260,260);
    Test.assertEqual(cache.entries.size(),0); cache.step();
    Test.assertEqual(cache.loads,2); Test.assert(!cache.pending()); Test.assertEqual(cache.bitmap(0),20);
    cache.prepare(1,[13,0.25,0,0,2,2,[20,21,22,23]],20,20,260,260);
    Test.assert(!cache.pending()); Test.assertEqual(cache.loads,2);
    return true;
}

(:test)
function tileFailureStopsRetryLoopAndNewViewCanRecover(logger as Test.Logger) as Lang.Boolean {
    var layer = [15,1.0,0,0,2,2,[10,11,12,13]];
    var cache = new FakeMapTileCache(); cache.failLoads = true;
    cache.prepare(0,layer,0,0,260,260); cache.step(); cache.draw(new FakeTileDc(),0,0);
    Test.assert(cache.error); Test.assert(!cache.pending()); Test.assertEqual(cache.loads,1);
    cache.prepare(0,layer,10,10,260,260); cache.step(); Test.assertEqual(cache.loads,1);
    cache.failLoads = false; cache.prepare(0,layer,512,0,260,260); cache.step(); cache.draw(new FakeTileDc(),512,0);
    Test.assert(!cache.error); Test.assert(!cache.pending()); Test.assertEqual(cache.bitmap(1),11);
    return true;
}

(:test)
function zoomPreservesCenterTrackAndBrowseAcrossHundredSwitches(logger as Test.Logger) as Lang.Boolean {
    var view = new MapView(); view.track = new CountingProjectionTrack();
    view.track.append([34.5,109.5]); view.track.append([34.5001,109.5]);
    view.panBy(40,40); var x = view.centerGX; var y = view.centerGY;
    var rev = view.track.revision;
    for (var i = 0; i < 100; i++) { view.zoomTo(i % 2); }
    Test.assertEqual(view.centerGX,x); Test.assertEqual(view.centerGY,y);
    Test.assertEqual(view.track.revision,rev); Test.assertEqual(view.track.projections,2);
    Test.assert(!view.browse.following); Test.assert(!view.recorder.hasSession());
    view.zoomTo(1); view.panBy(40,0); Test.assertEqual(view.centerGX,x+160);
    view.zoomTo(0); x=view.centerGX; view.panBy(40,0); Test.assertEqual(view.centerGX,x+40);
    return true;
}

(:test)
function zoomKeyModeBoundsAndGpsFollowRemainDistinct(logger as Test.Logger) as Lang.Boolean {
    var view = new MapView(); view.onStart(); view.onStart();
    Test.assertEqual(view.browse.axis,2); view.onDown(); Test.assertEqual(view.levelIndex,1);
    view.onDown(); Test.assertEqual(view.levelIndex,1); Test.assert(view.browse.following);
    view.followPosition(34.51,109.51); Test.assertEqual(view.centerGX,MapProjection.x(109.51));
    view.panBy(40,0); var x=view.centerGX; var y=view.centerGY;
    view.followPosition(34.52,109.52); Test.assertEqual(view.centerGX,x); Test.assertEqual(view.centerGY,y);
    view.onUp(); view.onUp(); Test.assertEqual(view.levelIndex,0);
    view.onStart(); Test.assertEqual(view.browse.axis,0);
    Test.assert(!view.browse.following);
    return true;
}

(:test)
function zoomAndPanDoNotStopOrReplaceActiveFit(logger as Test.Logger) as Lang.Boolean {
    var view = new MapView(); var recorder = new TestRecorder();
    view.recorder = recorder; Test.assert(recorder.start(Toybox.Activity.SPORT_WALKING));
    view.track.accept(34.5,109.5,true); var revision=view.track.revision;
    recorder.clock=10000;
    for(var i=0;i<20;i++) { view.zoomTo(i%2); view.panBy(40,0); }
    Test.assertEqual(recorder.state,recorder.RUNNING); Test.assert(recorder.fake.active);
    Test.assertEqual(recorder.creates,1); Test.assertEqual(recorder.fake.saves,0);
    Test.assertEqual(recorder.fake.discards,0); Test.assertEqual(recorder.elapsedMs(),10000);
    Test.assertEqual(view.track.revision,revision);
    Test.assert(recorder.pause()); recorder.clock=20000;
    view.zoomTo(0); view.panBy(-40,0); view.onBack();
    Test.assertEqual(recorder.state,recorder.PAUSED); Test.assertEqual(recorder.elapsedMs(),10000);
    Test.assert(recorder.hasSession()); Test.assert(!recorder.fake.active);
    return true;
}

(:test)
function zoomedTrackUsesSameTransformAndKeepsCrossings(logger as Test.Logger) as Lang.Boolean {
    var dc = new CountingTrackDc();
    var t = new TestProjectedTrack([[100,200],[1100,200],null,[500,0],[500,1300]]);
    Test.assertEqual(TrackRenderer.drawScaled(dc,t,100,100,260,260,0.25),2);
    Test.assertEqual(dc.lastLine[0],100.0); Test.assertEqual(dc.lastLine[1],-25.0);
    Test.assertEqual(dc.lastLine[2],100.0); Test.assertEqual(dc.lastLine[3],300.0);
    Test.assertEqual(dc.pen,1);
    return true;
}

(:test)
function scaleBarMatchesBothWeinanLevelsAndNativeMapDraws(logger as Test.Logger) as Lang.Boolean {
    var street=MapTiles.scaleBar(MapProjection.y(34.5),1.0);
    var overview=MapTiles.scaleBar(MapProjection.y(34.5),0.25);
    Test.assertEqual(street[0],200); Test.assert(street[1]>50 && street[1]<52);
    Test.assertEqual(overview[0],1000); Test.assert(overview[1]>63 && overview[1]<65);
    var view=new MapView(); var bitmap=Graphics.createBufferedBitmap({:width=>260,:height=>260}).get();
    for(var i=0;i<2;i++) {
        view.zoomTo(i); prepareTestTiles(view); view.onUpdate(bitmap.getDc());
        Test.assert(view.tiles.entries.size()<=4); Test.assert(!view.tiles.error);
        // Exercise clipping and resource indexing at all map corners on the real Dc.
        var corners=[[-100000,-100000],[100000,-100000],[100000,100000],[-100000,100000]];
        for(var n=0;n<corners.size();n++) {
            view.panBy(corners[n][0],corners[n][1]); prepareTestTiles(view);
            view.onUpdate(bitmap.getDc()); Test.assert(!view.tiles.error);
        }
        view.centerGX=MapProjection.x(MapData.CENTER_LON); view.centerGY=MapProjection.y(MapData.CENTER_LAT);
        view.queueMapTiles();
    }
    return true;
}
