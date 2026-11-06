using Toybox.Lang;
using Toybox.Test;

class CountingProjectionTrack extends TrackModel {
    var projections = 0;
    function initialize() { TrackModel.initialize(); }
    function project(value) { projections++; return TrackModel.project(value); }
}
class TestProjectedTrack {
    var data;
    function initialize(points) { data = points; }
    function size() { return data.size(); }
    function projectedPoint(i) { return data[i]; }
}
class CountingTrackDc {
    var lines = 0;
    var pen = 1;
    var lastLine = null;
    function initialize() {}
    function setColor(fg, bg) {}
    function setPenWidth(width) { pen = width; }
    function drawLine(ax, ay, bx, by) { lines++; lastLine = [ax, ay, bx, by]; }
}

(:test)
function panningNeverReprojectsUnchangedTrack(logger as Test.Logger) as Lang.Boolean {
    var t = new CountingProjectionTrack();
    t.append([34.5, 109.5]); t.append([34.5001, 109.5]);
    Test.assertEqual(t.projections, 2);
    var dc = new CountingTrackDc();
    for (var i = 0; i < 30; i++) {
        TrackRenderer.draw(dc, t, MapProjection.x(109.5) - 130 + i, MapProjection.y(34.5) - 130, 260, 260);
    }
    Test.assertEqual(t.projections, 2);
    Test.assertEqual(dc.lines, 30); Test.assertEqual(dc.pen, 1);
    t.append(null); Test.assertEqual(t.projections, 2);
    t.append([34.5002, 109.5]); Test.assertEqual(t.projections, 3);
    return true;
}

(:test)
function projectedRingRemainsAlignedAfterWrapAndClear(logger as Test.Logger) as Lang.Boolean {
    var t = new TrackModel();
    for (var i = 0; i < 1000; i++) { t.append([34.5 + i * 0.00001, 109.5]); }
    Test.assertEqual(t.size(), 800);
    for (var n = 0; n < t.size(); n++) {
        var p = t.point(n); var cached = t.projectedPoint(n);
        Test.assertEqual(cached[0], MapProjection.x(p[1]));
        Test.assertEqual(cached[1], MapProjection.y(p[0]));
    }
    t.append(null); Test.assert(t.projectedPoint(799) == null);
    t.clear(); Test.assertEqual(t.size(), 0);
    t.append([35.0, 110.0]); Test.assertEqual(t.projectedPoint(0)[0], MapProjection.x(110.0));
    return true;
}

(:test)
function rendererCullsEachOutsideEdgeButKeepsCrossings(logger as Test.Logger) as Lang.Boolean {
    var dc = new CountingTrackDc();
    var outside = [[[-10,10],[-5,30]], [[270,10],[280,30]], [[10,-5],[30,-10]], [[10,270],[30,280]]];
    for (var i = 0; i < outside.size(); i++) {
        Test.assertEqual(TrackRenderer.draw(dc, new TestProjectedTrack(outside[i]), 0, 0, 260, 260), 0);
    }
    Test.assertEqual(dc.lines, 0);
    Test.assertEqual(TrackRenderer.draw(dc, new TestProjectedTrack([[-10,130],[270,130]]), 0, 0, 260, 260), 1);
    Test.assertEqual(TrackRenderer.draw(dc, new TestProjectedTrack([[130,-10],[130,270]]), 0, 0, 260, 260), 1);
    Test.assertEqual(dc.lines, 2); Test.assertEqual(dc.pen, 1);
    return true;
}

(:test)
function rendererPreservesBreaksOffsetsAndEdgeThickness(logger as Test.Logger) as Lang.Boolean {
    var dc = new CountingTrackDc();
    var t = new TestProjectedTrack([[110,210],[150,250],null,[100,260],[200,260]]);
    Test.assertEqual(TrackRenderer.draw(dc, t, 100, 200, 260, 260), 2);
    Test.assertEqual(dc.lines, 2); Test.assertEqual(dc.lastLine[0], 0); Test.assertEqual(dc.lastLine[1], 60);
    Test.assertEqual(TrackRenderer.draw(dc, new TestProjectedTrack([[-1,10],[-1,20]]), 0, 0, 260, 260), 1);
    Test.assertEqual(TrackRenderer.draw(dc, new TestProjectedTrack([null,[10,10],null]), 0, 0, 260, 260), 0);
    return true;
}

(:test)
function restoredTrackRebuildsCacheWithoutChangingStorageFormat(logger as Test.Logger) as Lang.Boolean {
    var original = new TrackModel();
    original.accept(34.5, 109.5, true); original.accept(34.5001, 109.5, true);
    var data = original.exportPoints(); var restored = new TrackModel();
    restored.restore(data, 1234);
    Test.assertEqual(restored.size(), original.size()); Test.assertEqual(restored.distance, 12.34);
    var again = restored.exportPoints(); Test.assertEqual(again.size(), data.size());
    for (var i = 0; i < data.size(); i++) {
        if (data[i] == null) { Test.assert(again[i] == null); }
        else { Test.assertEqual(again[i], data[i]); }
    }
    for (var n = 0; n < restored.size(); n++) {
        var point = restored.point(n); var projected = restored.projectedPoint(n);
        if (point == null) { Test.assert(projected == null); }
        else { Test.assertEqual(projected[1], MapProjection.y(point[0])); }
    }
    return true;
}
