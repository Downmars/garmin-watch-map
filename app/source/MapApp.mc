using Toybox.Application;
using Toybox.Lang;
using Toybox.Graphics;
using Toybox.Math;
using Toybox.Position;
using Toybox.Sensor;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi;

class MapApp extends Application.AppBase {
    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() {
        var view = new MapView();
        return [ view, new MapDelegate(view) ];
    }
}

class MapDelegate extends WatchUi.InputDelegate {
    var view;

    function initialize(v) {
        InputDelegate.initialize();
        view = v;
    }

    function onKey(evt) {
        var key = evt.getKey();
        if (key == WatchUi.KEY_UP) { view.onUp(); return true; }
        if (key == WatchUi.KEY_DOWN) { view.onDown(); return true; }
        if (key == WatchUi.KEY_START || key == 4) { view.onStart(); return true; }
        if (key == WatchUi.KEY_ESC && view.onBack()) { return true; }
        return false;
    }
}

class MapView extends WatchUi.View {
    var loc = null;
    var heading = 0.0;
    var compass = null;
    var prevLat = null;
    var prevLon = null;
    var trail = [];
    var browse;
    var fix;
    var lastUiStatus = null;
    var lastUiMinute = null;
    var centerGX = 0;
    var centerGY = 0;
    var W = 260;
    var H = 260;
    var headingTimer = null;
    var lastFixLat = null;
    var lastFixLon = null;
    var distM = 0.0;
    var currentSpeed = 0.0;

    function initialize() {
        View.initialize();
        browse = new BrowseState();
        fix = new FixState();
        var ds = System.getDeviceSettings();
        if (ds != null) {
            W = ds.screenWidth;
            H = ds.screenHeight;
        }
        // Center comes from the generated MapData.mc (set by build-city.bat),
        // so switching city needs no edit in this file.
        centerGX = lonToGX(MapData.CENTER_LON);
        centerGY = latToGY(MapData.CENTER_LAT);
    }

    function onLayout(dc) {
    }

    function onShow() {
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
        // 1 秒节拍：静止时也能靠罗盘实时转头，不必等 GPS 回调
        if (headingTimer == null) {
            headingTimer = new Timer.Timer();
            headingTimer.start(method(:onHeadingTick), 1000, true);
        }
    }

    function onHide() {
        if (headingTimer != null) {
            headingTimer.stop();
            headingTimer = null;
        }
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
    }

    function onHeadingTick() as Void {
        var nextStatus = fix.status(System.getTimer());
        var needsUpdate = nextStatus != lastUiStatus;
        lastUiStatus = nextStatus;
        var minute = System.getClockTime().min;
        if (minute != lastUiMinute) { needsUpdate = true; lastUiMinute = minute; }
        readCompass();
        if (compass != null && currentSpeed < 0.7 && fix.isCurrent(System.getTimer())) {
            var cd = compass - heading;
            while (cd > 180.0) { cd -= 360.0; }
            while (cd < -180.0) { cd += 360.0; }
            heading = heading + cd * 0.4;
            // Math.abs is a newer module API and is absent on the tested FR255.
            if (cd > 1.0 || cd < -1.0) { needsUpdate = true; }
        }
        if (needsUpdate) { WatchUi.requestUpdate(); }
    }

    function lonToGX(lon) {
        return (lon + 180.0) / 360.0 * MapData.WORLD;
    }

    function latToGY(lat) {
        if (lat > 85.05112878) { lat = 85.05112878; }
        if (lat < -85.05112878) { lat = -85.05112878; }
        var rad = lat * Math.PI / 180.0;
        return (1.0 - Math.log(Math.tan(rad) + 1.0 / Math.cos(rad), 2.718281828459045) / Math.PI) / 2.0 * MapData.WORLD;
    }

    function gxToLon(gx) {
        return gx / MapData.WORLD * 360.0 - 180.0;
    }

    function gyToLat(gy) {
        var n = Math.PI - 2.0 * Math.PI * gy / MapData.WORLD;
        return 180.0 / Math.PI * Math.atan(0.5 * (Math.pow(2.718281828459045, n) - Math.pow(2.718281828459045, -n)));
    }

    // 读电子罗盘方位：Sensor.Info.heading 是弧度、真北参考
    function readCompass() as Void {
        try {
            var si = Sensor.getInfo();
            if (si != null && si.heading != null) {
                compass = si.heading * 180.0 / Math.PI;
            } else {
                compass = null;
            }
        } catch (e) {
            compass = null;
        }
    }

    function onPosition(info as Position.Info) as Void {
        var p = info.position;
        var deg = (p == null) ? null : p.toDegrees();
        var stamp = (info.when == null) ? null : info.when.value();
        if (!fix.accept((deg == null) ? null : deg[0], (deg == null) ? null : deg[1],
                        info.accuracy, stamp, System.getTimer())) {
            if (!fix.isCurrent(System.getTimer())) { currentSpeed = 0.0; }
            WatchUi.requestUpdate();
            return;
        }
        if (p != null) {
            if (fix.startsSegment) {
                lastFixLat = null;
                lastFixLon = null;
                prevLat = null;
                prevLon = null;
                if (trail.size() > 0 && trail[trail.size() - 1] != null) {
                    trail.add(null);
                }
            }
            loc = p;
            readCompass();

            var spd = 0.0;
            try {
                if (info.speed != null) { spd = info.speed; }
            } catch (e) {
                spd = 0.0;
            }
            currentSpeed = spd;

            // 累计里程：相邻两点距离累加，单段超过 50 米视为跳点丢弃
            if (lastFixLat != null) {
                var sLat = (deg[0] - lastFixLat) * Math.PI / 180.0;
                var sLon = (deg[1] - lastFixLon) * Math.PI / 180.0;
                var mD = 6371000.0;
                var sy = sLat * mD;
                var sx = sLon * mD * Math.cos(deg[0] * Math.PI / 180.0);
                var seg = Math.pow(sy * sy + sx * sx, 0.5);
                if (seg < 50.0) {
                    distM = distM + seg;
                }
            }
            lastFixLat = deg[0];
            lastFixLon = deg[1];

            // 先按 8 米参考点算航迹方位（走动时用，和轨迹方向天然一致）
            if (prevLat == null) {
                prevLat = deg[0];
                prevLon = deg[1];
            } else {
                var dLat = (deg[0] - prevLat) * Math.PI / 180.0;
                var dLon = (deg[1] - prevLon) * Math.PI / 180.0;
                var mPerDeg = 6371000.0;
                var dy = dLat * mPerDeg;
                var dx = dLon * mPerDeg * Math.cos(deg[0] * Math.PI / 180.0);
                if (dy * dy + dx * dx > 64.0) {
                    var yy = Math.sin(dLon) * Math.cos(deg[0] * Math.PI / 180.0);
                    var xx = Math.cos(prevLat * Math.PI / 180.0) * Math.sin(deg[0] * Math.PI / 180.0) -
                             Math.sin(prevLat * Math.PI / 180.0) * Math.cos(deg[0] * Math.PI / 180.0) * Math.cos(dLon);
                    var nh = Math.atan2(yy, xx) * 180.0 / Math.PI;
                    var diff = nh - heading;
                    while (diff > 180.0) { diff -= 360.0; }
                    while (diff < -180.0) { diff += 360.0; }
                    heading = heading + diff * 0.6;
                    prevLat = deg[0];
                    prevLon = deg[1];
                }
            }

            // 静止时改用罗盘（此时 GPS 方位没意义）
            // 罗盘有磁干扰和校准误差，走动时不采用，否则会和轨迹方向打架
            if (spd < 0.7 && compass != null) {
                var cd = compass - heading;
                while (cd > 180.0) { cd -= 360.0; }
                while (cd < -180.0) { cd += 360.0; }
                heading = heading + cd * 0.4;
            }

            // 轨迹：按距离抽稀（8 米一个点），满了丢弃最早的一段而不是整条清空
            var addPoint = true;
            if (trail.size() > 0 && trail[trail.size() - 1] != null) {
                var lastP = trail[trail.size() - 1];
                var dLat0 = (deg[0] - lastP[0]) * Math.PI / 180.0;
                var dLon0 = (deg[1] - lastP[1]) * Math.PI / 180.0;
                var mD0 = 6371000.0;
                var ey = dLat0 * mD0;
                var ex = dLon0 * mD0 * Math.cos(deg[0] * Math.PI / 180.0);
                if (ey * ey + ex * ex < 64.0) {
                    addPoint = false;
                }
            }
            if (addPoint) {
                trail.add([deg[0], deg[1]]);
                if (trail.size() > 800) {
                    // 一次丢最早 100 点，保持滑动窗口，避免每点都重建数组
                    var nt = [];
                    for (var q = 100; q < trail.size(); q++) {
                        nt.add(trail[q]);
                    }
                    trail = nt;
                }
            }
            if (browse.following) {
                centerGX = lonToGX(deg[1]);
                centerGY = latToGY(deg[0]);
            }
            WatchUi.requestUpdate();
        }
    }

    function clampCenter() {
        var halfW = W / 2;
        var halfH = H / 2;
        var minX = MapData.ORIGIN_X + halfW;
        var maxX = MapData.ORIGIN_X + MapData.COLS * MapData.TILE - halfW;
        var minY = MapData.ORIGIN_Y + halfH;
        var maxY = MapData.ORIGIN_Y + MapData.ROWS * MapData.TILE - halfH;
        if (centerGX < minX) { centerGX = minX; }
        if (centerGX > maxX) { centerGX = maxX; }
        if (centerGY < minY) { centerGY = minY; }
        if (centerGY > maxY) { centerGY = maxY; }
    }

    function panBy(dx, dy) {
        centerGX += dx;
        centerGY += dy;
        clampCenter();
        browse.pan();
        WatchUi.requestUpdate();
    }

    function onUp() {
        if (browse.axis == 0) {
            panBy(0, -40);
        } else {
            panBy(-40, 0);
        }
    }

    function onDown() {
        if (browse.axis == 0) {
            panBy(0, 40);
        } else {
            panBy(40, 0);
        }
    }

    function onStart() {
        browse.toggleAxis();
        WatchUi.requestUpdate();
    }

    function onBack() {
        if (!browse.backToFollow()) { return false; }
        centerGX = lonToGX((loc == null) ? MapData.CENTER_LON : fix.longitude);
        centerGY = latToGY((loc == null) ? MapData.CENTER_LAT : fix.latitude);
        WatchUi.requestUpdate();
        return true;
    }

    function outsideMap() {
        if (loc == null) { return false; }
        var gx = lonToGX(fix.longitude);
        var gy = latToGY(fix.latitude);
        return gx < MapData.ORIGIN_X || gx >= MapData.ORIGIN_X + MapData.COLS * MapData.TILE ||
            gy < MapData.ORIGIN_Y || gy >= MapData.ORIGIN_Y + MapData.ROWS * MapData.TILE;
    }

    function statusText() {
        var s = fix.status(System.getTimer());
        if (s == fix.WAITING) { return "等待定位"; }
        if (s == fix.WEAK) { return "GPS 信号弱"; }
        if (s == fix.STALE) { return "定位已过期"; }
        if (outsideMap()) { return "超出地图范围"; }
        return "GPS 正常";
    }

    function drawArrow(dc, sx, sy, rad) {
        var dx = Math.sin(rad);
        var dy = -Math.cos(rad);
        var tipX = sx + dx * 13;
        var tipY = sy + dy * 13;
        var leftX = sx - dx * 7 - dy * 7;
        var leftY = sy - dy * 7 + dx * 7;
        var rightX = sx - dx * 7 + dy * 7;
        var rightY = sy - dy * 7 - dx * 7;
        dc.setColor(0xFF0000, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([[tipX, tipY], [leftX, leftY], [rightX, rightY]]);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(sx, sy, 2);
    }

    // 屏幕中左侧的小罗盘：地图固定上北下南，所以 N 恒在正上方，
    // 指针表示"表盘朝向"（即你面朝的方向）相对正北的夹角
    function drawCompass(dc) {
        var r = W / 13;
        var cx = r + 12;
        var cy = H / 2;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.fillCircle(cx, cy, r);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy, r);

        // 四向刻度
        dc.drawLine(cx, cy - r + 2, cx, cy - r + 6);
        dc.drawLine(cx, cy + r - 2, cx, cy + r - 6);
        dc.drawLine(cx - r + 2, cy, cx - r + 6, cy);
        dc.drawLine(cx + r - 2, cy, cx + r - 6, cy);

        // N 标记
        dc.drawText(cx, cy - r - 9, Graphics.FONT_XTINY, "N", Graphics.TEXT_JUSTIFY_CENTER);

        // 指针
        var rad = heading * Math.PI / 180.0;
        var dx = Math.sin(rad);
        var dy = -Math.cos(rad);
        dc.setColor(0xFF0000, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx, cy, (cx + dx * (r - 4)).toNumber(), (cy + dy * (r - 4)).toNumber());
        dc.drawLine(cx - 1, cy, (cx + dx * (r - 4) - 1).toNumber(), (cy + dy * (r - 4)).toNumber());
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx, cy, 2);
    }

    function onUpdate(dc) {
        clampCenter();
        var left = centerGX - W / 2.0;
        var top = centerGY - H / 2.0;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        for (var j = 0; j < MapData.ROWS; j++) {
            for (var i = 0; i < MapData.COLS; i++) {
                var x = MapData.ORIGIN_X + i * MapData.TILE - left;
                var y = MapData.ORIGIN_Y + j * MapData.TILE - top;
                if (x <= -MapData.TILE || x >= W || y <= -MapData.TILE || y >= H) {
                    continue;
                }
                var bmp = WatchUi.loadResource(MapData.ALL[j * MapData.COLS + i]);
                if (bmp != null) {
                    dc.drawBitmap(x, y, bmp);
                }
            }
        }

        if (trail.size() > 1) {
            dc.setColor(0x8B0000, Graphics.COLOR_TRANSPARENT);
            for (var k = 1; k < trail.size(); k++) {
                if (trail[k - 1] == null || trail[k] == null) { continue; }
                var ax = lonToGX(trail[k - 1][1]) - left;
                var ay = latToGY(trail[k - 1][0]) - top;
                var bx = lonToGX(trail[k][1]) - left;
                var by = latToGY(trail[k][0]) - top;
                dc.drawLine(ax, ay, bx, by);
                dc.drawLine(ax + 1, ay, bx + 1, by);
                dc.drawLine(ax, ay + 1, bx, by + 1);
                dc.drawLine(ax + 1, ay + 1, bx + 1, by + 1);
            }
        }

        if (loc != null) {
            var deg = loc.toDegrees();
            var sx = lonToGX(deg[1]) - left;
            var sy = latToGY(deg[0]) - top;
            if (sx >= -12 && sx <= W + 12 && sy >= -12 && sy <= H + 12) {
                if (fix.isCurrent(System.getTimer())) {
                    drawArrow(dc, sx, sy, heading * Math.PI / 180.0);
                } else {
                    // Historical position is intentionally not a live direction arrow.
                    dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
                    dc.drawCircle(sx, sy, 6);
                }
            }
        }

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.fillRectangle(30, 8, W - 60, 33);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(W / 2, 8, Graphics.FONT_XTINY, statusText(), Graphics.TEXT_JUSTIFY_CENTER);
        var modeText = (browse.following ? "跟随 " : "浏览 ") +
            ((browse.axis == 0) ? "上下" : "左右");
        dc.drawText(W / 2, 24, Graphics.FONT_XTINY, modeText, Graphics.TEXT_JUSTIFY_CENTER);


        // 小罗盘（屏幕中左侧）
        drawCompass(dc);

        // 地图来源署名保持可见。
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(W / 2, 44, Graphics.FONT_XTINY, "(c) OSM contributors", Graphics.TEXT_JUSTIFY_CENTER);

        // 累计里程
        var distText;
        if (distM >= 1000.0) {
            distText = (distM / 1000.0).format("%.2f") + " km";
        } else {
            distText = distM.toNumber().toString() + " m";
        }
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(W / 2, H - 52, Graphics.FONT_XTINY, distText, Graphics.TEXT_JUSTIFY_CENTER);

        var clock = System.getClockTime();
        var timeText = clock.hour.format("%02d") + ":" + clock.min.format("%02d");
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(W / 2, H - 34, Graphics.FONT_XTINY, timeText, Graphics.TEXT_JUSTIFY_CENTER);
    }
}
