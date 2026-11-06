using Toybox.Graphics;
using Toybox.Lang;
using Toybox.System;
using Toybox.Test;

// Full-view panning workload; simulator CPU samples are not watch key latency.
function runPanBenchmark(logger, label, count, spread) {
    var view = new MapView();
    for (var i = 0; i < count; i++) {
        view.track.append([MapData.CENTER_LAT + (spread ? i * 0.0001 : (i % 20) * 0.00001), MapData.CENTER_LON]);
    }
    var bitmap = Graphics.createBufferedBitmap({:width=>260, :height=>260}).get();
    var dc = bitmap.getDc();
    prepareTestTiles(view);
    // Warm the resource path once, then measure 20 complete view updates during panning.
    view.onUpdate(dc);
    for (var frame = 0; frame < 20; frame++) {
        view.panBy(frame < 10 ? 40 : -40, 0);
        // Include synchronous tile preparation, but not production timer scheduling waits.
        var begin = System.getTimer();
        prepareTestTiles(view);
        view.onUpdate(dc);
        var elapsed = System.getTimer() - begin;
        logger.debug("PAN_SAMPLE," + label + "," + elapsed + "," + System.getSystemStats().usedMemory);
    }
}

(:test)
function benchmarkEmptyAndLongTrackPanning(logger as Test.Logger) as Lang.Boolean {
    runPanBenchmark(logger, "empty", 0, false);
    runPanBenchmark(logger, "dense800", 800, false);
    runPanBenchmark(logger, "spread800", 800, true);
    return true;
}
