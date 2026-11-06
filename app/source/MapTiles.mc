using Toybox.Math;
using Toybox.System;
using Toybox.WatchUi;

module MapTiles {
    // Layer: [zoom, canonical scale, origin X, origin Y, columns, rows, resources].
    function visible(layer, left, top, width, height) {
        var c0 = Math.floor((left - layer[2]) / 512.0).toNumber();
        var r0 = Math.floor((top - layer[3]) / 512.0).toNumber();
        var c1 = Math.ceil((left + width - layer[2]) / 512.0).toNumber() - 1;
        var r1 = Math.ceil((top + height - layer[3]) / 512.0).toNumber() - 1;
        if (c0 < 0) { c0 = 0; } if (r0 < 0) { r0 = 0; }
        if (c1 >= layer[4]) { c1 = layer[4] - 1; }
        if (r1 >= layer[5]) { r1 = layer[5] - 1; }
        var result = [];
        for (var r = r0; r <= r1; r++) {
            for (var c = c0; c <= c1; c++) { result.add(r * layer[4] + c); }
        }
        return result;
    }
    function scaleBar(centerY, scale) {
        var n = Math.PI - 2.0 * Math.PI * centerY / MapData.WORLD;
        var lat = Math.atan(0.5 * (Math.pow(2.718281828459045, n) - Math.pow(2.718281828459045, -n)));
        var mpp = 40075016.6856 * Math.cos(lat) / MapData.WORLD / scale;
        var values = [1,2,5,10,20,50,100,200,500,1000,2000,5000,10000,20000];
        var best = 1; var error = 1000000.0;
        for (var i = 0; i < values.size(); i++) {
            var difference = values[i] / mpp - 60;
            if (difference < 0) { difference = -difference; }
            if (difference < error) { best = values[i]; error = difference; }
        }
        return [best, best / mpp, best >= 1000 ? (best / 1000).toNumber().toString() + " km" : best.toString() + " m"];
    }
}

// Retains only current visible resource IDs (at most four on FR255).
// Bitmap objects stay local to a callback; the platform manages image caching.
class MapTileCache {
    var level = -1;
    var layer = null;
    var wanted = [];
    var entries = [];
    var failed = [];
    var error = false;
    var loads = 0;
    function initialize() {}
    function bitmap(index) {
        for (var i = 0; i < entries.size(); i++) {
            if (entries[i][0] == index) { return entries[i][1]; }
        }
        return null;
    }
    function isFailed(index) {
        for (var i = 0; i < failed.size(); i++) { if (failed[i] == index) { return true; } }
        return false;
    }
    function prepare(nextLevel, nextLayer, left, top, width, height) {
        var next = MapTiles.visible(nextLayer, left, top, width, height);
        var changed = level != nextLevel || next.size() != wanted.size();
        if (!changed) {
            for (var i = 0; i < next.size(); i++) { if (next[i] != wanted[i]) { changed = true; } }
        }
        if (!changed) { return; }
        var kept = [];
        if (level == nextLevel) {
            for (var j = 0; j < next.size(); j++) {
                var resource = bitmap(next[j]);
                if (resource != null) { kept.add([next[j], resource]); }
            }
        }
        level = nextLevel; layer = nextLayer; wanted = next; entries = kept;
        failed = []; error = false;
    }
    function pending() {
        for (var i = 0; i < wanted.size(); i++) {
            if (bitmap(wanted[i]) == null && !isFailed(wanted[i])) { return true; }
        }
        return false;
    }
    function loadResource(id) {
        // Do not force decoding here or retain this object across callbacks.
        return WatchUi.loadResource(id);
    }
    function fail(index) {
        if (!isFailed(index)) { failed.add(index); }
        error = true;
    }
    // One call enables at most one new visible ID. Resource resolution is confined
    // to onUpdate via draw; this is not a decode-per-frame limit.
    function step() {
        for (var i = 0; i < wanted.size(); i++) {
            var index = wanted[i];
            if (bitmap(index) == null && !isFailed(index)) {
                loads++;
                entries.add([index, layer[6][index]]);
                return;
            }
        }
    }
    function draw(dc, left, top) {
        if (layer == null) { return; }
        for (var i = 0; i < wanted.size(); i++) {
            var index = wanted[i]; var resource = bitmap(index);
            if (resource == null || isFailed(index)) { continue; }
            var x = layer[2] + (index % layer[4]) * 512 - left;
            var y = layer[3] + (index / layer[4]).toNumber() * 512 - top;
            try { dc.drawBitmap(Math.floor(x).toNumber(), Math.floor(y).toNumber(), loadResource(resource)); }
            catch (e) { fail(index); System.println("MAP_TILE_DRAW_FAILED"); }
        }
    }
}
