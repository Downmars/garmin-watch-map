using Toybox.Application;
using Toybox.Lang;
using Toybox.Graphics;
using Toybox.Math;
using Toybox.WatchUi;
using Toybox.Activity;

class MapDataField extends WatchUi.DataField {
    var trail = [];
    var mapBmp = null;
    var act = null;

    function initialize() {
        DataField.initialize();
    }

    function onLayout(dc) {
        mapBmp = WatchUi.loadResource(Rez.Drawables.MapWide);
    }

    function compute(info) {
        if (info == null) {
            return;
        }
        act = info;
        var loc = info.currentLocation;
        if (loc != null) {
            var deg = loc.toDegrees();
            trail.add([deg[0], deg[1]]);
            if (trail.size() > 240) {
                trail = [[deg[0], deg[1]]];
            }
        }
    }

    function mercator(lat) {
        var rad = lat * Math.PI / 180.0;
        return Math.log(Math.tan(Math.PI / 4.0 + rad / 2.0), 2.718281828459045);
    }

    function project(lat, lon) {
        if (lat < MapData.WIDE_LAT_MIN || lat > MapData.WIDE_LAT_MAX ||
            lon < MapData.WIDE_LON_MIN || lon > MapData.WIDE_LON_MAX) {
            return null;
        }
        var x = (lon - MapData.WIDE_LON_MIN) / (MapData.WIDE_LON_MAX - MapData.WIDE_LON_MIN) * MapData.W;
        var mTop = mercator(MapData.WIDE_LAT_MAX);
        var mBottom = mercator(MapData.WIDE_LAT_MIN);
        var y = (mTop - mercator(lat)) / (mTop - mBottom) * MapData.H;
        return [x, y];
    }

    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        if (mapBmp != null) {
            dc.drawBitmap(0, 0, mapBmp);
        }

        if (trail.size() > 1) {
            dc.setColor(0xFF2D95, Graphics.COLOR_TRANSPARENT);
            for (var i = 1; i < trail.size(); i++) {
                var a = project(trail[i - 1][0], trail[i - 1][1]);
                var b = project(trail[i][0], trail[i][1]);
                if (a != null && b != null) {
                    dc.drawLine(a[0], a[1], b[0], b[1]);
                }
            }
        }

        if (act != null) {
            var loc = act.currentLocation;
            if (loc != null) {
                var deg = loc.toDegrees();
                var xy = project(deg[0], deg[1]);
                if (xy != null) {
                    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                    dc.fillCircle(xy[0], xy[1], 6);
                    dc.setColor(0xFF2D95, Graphics.COLOR_TRANSPARENT);
                    dc.fillCircle(xy[0], xy[1], 4);
                }
            }

            if (act.elapsedTime != null) {
                var secs = act.elapsedTime;
                var mm = secs / 60;
                var ss = secs % 60;
                var timeText = mm.toString() + ":" + ((ss < 10) ? "0" : "") + ss.toString();
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(8, 8, Graphics.FONT_XTINY, timeText, Graphics.TEXT_JUSTIFY_LEFT);
            }
        } else {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(8, 8, Graphics.FONT_XTINY, "WAIT GPS", Graphics.TEXT_JUSTIFY_LEFT);
        }

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(MapData.W - 6, MapData.H - 14, Graphics.FONT_XTINY, "OSM", Graphics.TEXT_JUSTIFY_RIGHT);
    }
}
