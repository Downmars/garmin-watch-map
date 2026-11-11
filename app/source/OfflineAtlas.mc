using Toybox.Application.Storage;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.WatchUi;

class OfflineAtlas {
    var region;
    var routeIndex = -1;
    var points = null;
    var restoredSelection = false;
    var waypoints;

    function initialize() {
        region = MapCatalog.REGIONS[0];
        waypoints = new WaypointLayer();
        loadWaypoints();
    }

    function loadWaypoints() {
        return waypoints.load(region.size() > 6 ? region[6] : null);
    }

    function restoreChoice() {
        try {
            var saved = Storage.getValue("atlas.selection.v1");
            if (!(saved instanceof Lang.Array) || saved.size() != 2) { return; }
            for (var n = 0; n < MapCatalog.REGIONS.size(); n++) {
                var r = MapCatalog.REGIONS[n];
                if (r[0].equals(saved[0])) {
                    region = r;
                    loadWaypoints();
                    restoredSelection = true;
                    for (var i = 0; i < r[5].size(); i++) {
                        if (r[5][i][0].equals(saved[1])) { chooseRoute(i); break; }
                    }
                    break;
                }
            }
        } catch (e) { points = null; routeIndex = -1; }
    }

    function remember() {
        var routeId = routeIndex < 0 ? "" : region[5][routeIndex][0];
        try { Storage.setValue("atlas.selection.v1", [region[0], routeId]); return true; }
        catch (e) { return false; }
    }

    function chooseRegion(index) {
        if (region != MapCatalog.REGIONS[index]) {
            region = MapCatalog.REGIONS[index];
            points = null;
            routeIndex = -1;
            loadWaypoints();
        }
    }

    function chooseRoute(index) {
        var next = null;
        if (index >= 0) {
            try { next = WatchUi.loadResource(region[5][index][2]); }
            catch (e) { return false; }
            if (!(next instanceof Lang.Array) || next.size() < 4) { return false; }
        }
        points = next;
        routeIndex = index;
        return true;
    }

    function draw(dc, left, top, scale, w, h) {
        if (points == null) { return; }
        dc.setColor(0x0050BB, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(3);
        var lastX = 0.0; var lastY = 0.0; var havePrevious = false;
        for (var i = 0; i < points.size(); i += 2) {
            if (points[i] == null) { havePrevious = false; continue; }
            var x = (points[i] - left) * scale;
            var y = (points[i+1] - top) * scale;
            if (havePrevious && !((x < -3 && lastX < -3) || (x > w+3 && lastX > w+3) ||
                    (y < -3 && lastY < -3) || (y > h+3 && lastY > h+3))) {
                dc.drawLine(lastX, lastY, x, y);
            }
            lastX = x; lastY = y; havePrevious = true;
        }
        dc.setPenWidth(1);
    }
}
