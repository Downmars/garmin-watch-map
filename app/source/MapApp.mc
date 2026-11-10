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
    var mainView = null;
    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() {
        mainView = new MapView();
        return [ mainView, new MapDelegate(mainView) ];
    }

    function onStop(state) {
        if (mainView != null) { mainView.shutdown(); }
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
    var track;
    var recorder;
    var snapshots;
    var restored = false;
    var recovering = false;
    var recovery = null;
    var recoveryData = null;
    var recoveryIndex = 0;
    var recoveryTimer = null;
    var sessionStarted = false;
    var lastCheckpoint = 0;
    var savedRevision = -1;
    var savedPhase = -1;
    var savedElapsedSeconds = -1;
    var notice = null;
    var menuOpen = false;
    var menuTitle = "地图菜单";
    var atlas;
    var menuRows = [];
    var menuIndex = 0;
    var confirmDiscard = false;
    var browse;
    var fix;
    var lastUiStatus = null;
    var lastUiMinute = null;
    var centerGX = 0;
    var centerGY = 0;
    var W = 260;
    var H = 260;
    var headingTimer = null;
    var currentSpeed = 0.0;
    var levelIndex = 0;
    var tiles;
    var phoneTiles = null;
    var offlineRegion;
    var tileTimer = null;
    var active = false;
    var scaleBar;

    function initialize() {
        View.initialize();
        browse = new BrowseState();
        fix = new FixState();
        track = new TrackModel();
        recorder = new RecordingController();
        snapshots = new SnapshotStore("weinan.track.v1.");
        var ds = System.getDeviceSettings();
        if (ds != null) {
            W = ds.screenWidth;
            H = ds.screenHeight;
        }
        atlas = new OfflineAtlas();
        atlas.restoreChoice();
        centerGX = lonToGX(atlas.region[3]);
        centerGY = latToGY(atlas.region[2]);
        if (atlas.restoredSelection) {
            browse.pan();
            if (atlas.points != null) { centerGX = atlas.points[0]; centerGY = atlas.points[1]; }
        }
        tiles = new MapTileCache();
        if (OnlineSource.ENABLED) { phoneTiles = new PhoneTiles(); }
        queueMapTiles();
    }

    function onLayout(dc) {
    }

    function onShow() {
        active = true;
        if (!restored) {
            if (!recovering) { restoreSnapshot(); }
            if (recoveryTimer == null) {
                recoveryTimer = createRecoveryTimer();
                recoveryTimer.start(method(:onRecoveryTick), 100, true);
            }
            return;
        }
        startLiveUpdates();
    }

    function createRecoveryTimer() { return new Timer.Timer(); }

    function startLiveUpdates() {
        queueMapTiles();
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
        // 1 秒节拍：静止时也能靠罗盘实时转头，不必等 GPS 回调
        if (headingTimer == null) {
            headingTimer = new Timer.Timer();
            headingTimer.start(method(:onHeadingTick), 1000, true);
        }
    }

    function onHide() {
        active = false;
        if (phoneTiles != null) { phoneTiles.stop(); }
        if (tileTimer != null) { tileTimer.stop(); tileTimer = null; }
        if (recoveryTimer != null) { recoveryTimer.stop(); recoveryTimer = null; }
        if (headingTimer != null) {
            headingTimer.stop();
            headingTimer = null;
        }
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
    }

    function onHeadingTick() as Void {
        if (recovering) { return; }
        if (phoneTiles != null && active && !menuOpen) { phoneTiles.tick(); }
        var nextStatus = fix.status(System.getTimer());
        var needsUpdate = nextStatus != lastUiStatus || recorder.state == recorder.RUNNING;
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
        checkpoint(false);
        if (needsUpdate) { WatchUi.requestUpdate(); }
    }

    function lonToGX(lon) { return MapProjection.x(lon); }

    function latToGY(lat) { return MapProjection.y(lat); }

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
        if (recovering) { return; }
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
                track.breakSegment();
                prevLat = null;
                prevLon = null;
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

            if (recorder.canAccumulate()) {
                track.accept(deg[0], deg[1], fix.startsSegment);
            } else { track.breakSegment(); }
            followPosition(deg[0], deg[1]);
            WatchUi.requestUpdate();
        }
    }

    function clampCenter() {
        if (phoneTiles != null) {
            var dx = W/(2.0*mapScale()), dy = H/(2.0*mapScale());
            if (centerGX<dx) { centerGX=dx; } if (centerGX>MapData.WORLD-dx) { centerGX=MapData.WORLD-dx; }
            if (centerGY<dy) { centerGY=dy; } if (centerGY>MapData.WORLD-dy) { centerGY=MapData.WORLD-dy; }
            return;
        }
        var halfW = W / 2;
        var halfH = H / 2;
        var base = atlas.region[4][0];
        var minX = base[2] + halfW;
        var maxX = base[2] + base[4] * MapData.TILE - halfW;
        var minY = base[3] + halfH;
        var maxY = base[3] + base[5] * MapData.TILE - halfH;
        if (centerGX < minX) { centerGX = minX; }
        if (centerGX > maxX) { centerGX = maxX; }
        if (centerGY < minY) { centerGY = minY; }
        if (centerGY > maxY) { centerGY = maxY; }
    }

    function panBy(dx, dy) {
        centerGX += dx / mapScale();
        centerGY += dy / mapScale();
        clampCenter();
        browse.pan();
        queueMapTiles();
        WatchUi.requestUpdate();
    }

    function onUp() {
        if (recovering) { return; }
        if (menuOpen) { menuIndex = (menuIndex + menuRows.size() - 1) % menuRows.size(); WatchUi.requestUpdate(); return; }
        if (browse.axis == 2) { zoomTo(levelIndex - 1); return; }
        if (browse.axis == 0) {
            panBy(0, -40);
        } else {
            panBy(-40, 0);
        }
    }

    function onDown() {
        if (recovering) { return; }
        if (menuOpen) { menuIndex = (menuIndex + 1) % menuRows.size(); WatchUi.requestUpdate(); return; }
        if (browse.axis == 2) { zoomTo(levelIndex + 1); return; }
        if (browse.axis == 0) {
            panBy(0, 40);
        } else {
            panBy(40, 0);
        }
    }

    function onStart() {
        if (recovering) { return; }
        if (menuOpen) { performAction(menuRows[menuIndex][1]); return; }
        browse.toggleAxis();
        WatchUi.requestUpdate();
    }

    function onBack() {
        if (recovering) { WatchUi.popView(WatchUi.SLIDE_IMMEDIATE); return true; }
        if (menuOpen) {
            if (!menuTitle.equals("地图菜单")) { openMenu(); return true; }
            menuOpen = false; confirmDiscard = false; WatchUi.requestUpdate(); return true;
        }
        if (!browse.backToFollow()) { openMenu(); return true; }
        centerGX = lonToGX((loc == null) ? atlas.region[3] : fix.longitude);
        centerGY = latToGY((loc == null) ? atlas.region[2] : fix.latitude);
        clampCenter(); queueMapTiles();
        WatchUi.requestUpdate();
        return true;
    }

    function mapScale() { return atlas.region[4][levelIndex][1]; }

    function followPosition(lat, lon) {
        if (!browse.following) { return; }
        centerGX = lonToGX(lon); centerGY = latToGY(lat);
        clampCenter(); queueMapTiles();
    }

    function zoomTo(next) {
        if (next < 0) { next = 0; }
        if (next >= atlas.region[4].size()) { next = atlas.region[4].size() - 1; }
        if (next != levelIndex) { levelIndex = next; queueMapTiles(); }
        WatchUi.requestUpdate();
    }

    function queueMapTiles() {
        var scale = mapScale();
        offlineRegion = atlas.region;
        if (phoneTiles != null && !covers(offlineRegion,centerGX,centerGY)) {
            for (var i=0;i<MapCatalog.REGIONS.size();i++) {
                if (covers(MapCatalog.REGIONS[i],centerGX,centerGY)) { offlineRegion=MapCatalog.REGIONS[i]; break; }
            }
        }
        var layer = offlineRegion[4][levelIndex];
        var px = centerGX*scale-W/2.0, py = centerGY*scale-H/2.0;
        tiles.prepare(layer[6][0],layer,px,py,W,H);
        if (phoneTiles!=null) { phoneTiles.prepare(layer[0],px,py,W,H); }
        scaleBar = MapTiles.scaleBar(centerGY, scale);
        if (active && !recovering && tiles.pending() && tileTimer == null) {
            tileTimer = new Timer.Timer(); tileTimer.start(method(:onTileTick), 50, true);
        }
    }

    function onTileTick() as Void {
        if (!active || recovering) { return; }
        tiles.step();
        if (!tiles.pending() && tileTimer != null) { tileTimer.stop(); tileTimer = null; }
        WatchUi.requestUpdate();
    }

    function drawScaleBar(dc) {
        var cx = W - 60; var cy = H / 2;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - 23, Graphics.FONT_XTINY, scaleBar[2], Graphics.TEXT_JUSTIFY_CENTER);
        var x = cx - scaleBar[1] / 2;
        dc.drawLine(x, cy + 6, x + scaleBar[1], cy + 6);
        dc.drawLine(x, cy + 3, x, cy + 9);
        dc.drawLine(x + scaleBar[1], cy + 3, x + scaleBar[1], cy + 9);
    }


    function elapsedText() {
        var seconds = (recorder.elapsedMs() / 1000).toNumber();
        return (seconds / 60).toNumber().format("%02d") + ":" + (seconds % 60).format("%02d");
    }

    function restoreSnapshot() {
        if (restored || recovering) { return; }
        recovering = true;
        recovery = new SnapshotLoader(snapshots);
        recoveryData = null; recoveryIndex = 0;
        notice = "正在恢复轨迹";
    }

    function onRecoveryTick() as Void {
        if (!recovering) { return; }
        if (advanceRecovery()) {
            if (recoveryTimer != null) { recoveryTimer.stop(); recoveryTimer = null; }
            startLiveUpdates();
            WatchUi.requestUpdate();
        }
    }

    // Bounded independently of the saved track length: one load step OR 32 projections.
    function advanceRecovery() {
        if (!recovering) { return true; }
        if (recoveryData == null) {
            if (!recovery.step()) { return false; }
            recoveryData = recovery.takeResult(); recovery = null;
            if (recoveryData == null || recoveryData[6].size() == 0) {
                finishRecovery(); return true;
            }
            track.clear(); recoveryIndex = 0;
            return false;
        }
        var points = recoveryData[6];
        for (var n = 0; n < 32 && recoveryIndex < points.size(); n++) {
            var lat = points[recoveryIndex]; var lon = points[recoveryIndex + 1];
            track.append(lat == null ? null : [lat / 100000.0, lon / 100000.0]);
            recoveryIndex += 2;
        }
        if (recoveryIndex < points.size()) { return false; }
        track.distance = recoveryData[2] / 100.0;
        track.breakSegment();
        recorder.totalMs = recoveryData[3] * 1000;
        recorder.state = recorder.HISTORY;
        finishRecovery();
        return true;
    }

    function finishRecovery() {
        notice = null;
        if (recoveryData != null && recoveryData[6].size() > 0) {
            notice = recoveryData[4] == recorder.SAVED ? "上次FIT已保存" : "已恢复屏幕轨迹";
            // Restored points are historical: never create a live position arrow.
        }
        if (snapshots.error != null) { notice = snapshots.error; }
        savedPhase = recoveryData == null ? -1 : recoveryData[4];
        savedElapsedSeconds = recoveryData == null ? -1 : recoveryData[3];
        recovery = null; recoveryData = null;
        restored = true; recovering = false;
        lastCheckpoint = System.getTimer();
        savedRevision = track.revision;
    }

    function checkpoint(force) {
        if (!restored || recovering) { return; }
        var now = System.getTimer();
        if (!force && (now - lastCheckpoint < 60000 || track.revision == savedRevision)) { return; }
        lastCheckpoint = now;
        var elapsed = recorder.elapsedMs();
        if (snapshots.save(track, elapsed, recorder.state)) {
            savedRevision = track.revision; savedPhase = recorder.state;
            savedElapsedSeconds = (elapsed / 1000).toNumber();
        }
        else { notice = snapshots.error; }
    }

    function shutdown() {
        // Try to preserve FIT on system-driven exit; no promise of crash-proof FIT recovery.
        if (recorder.hasSession() && !recorder.finish(true)) {
            recorder.totalMs = recorder.elapsedMs(); recorder.state = recorder.INTERRUPTED;
        }
        // Save after FIT changes state, once; explicit save-and-exit already checkpointed it.
        if (track.revision != savedRevision || recorder.state != savedPhase ||
            (recorder.elapsedMs() / 1000).toNumber() != savedElapsedSeconds) { checkpoint(true); }
        onHide();
    }

    function openMenu() {
        if (recovering) { return; }
        menuTitle = "地图菜单";
        menuOpen = true; menuIndex = 0; confirmDiscard = false;
        menuRows = [["返回地图", "back"], ["地图地区", "regions"], ["GPX 路线", "routes"]];
        if (recorder.hasSession()) {
            menuRows.add([recorder.state == recorder.RUNNING ? "暂停运动" : "继续运动", "toggle"]);
            menuRows.add(["保存运动", "save"]);
            menuRows.add(["丢弃运动…", "discard"]);
            menuRows.add(["保存并退出", "save_exit"]);
        } else {
            menuRows.add(["开始新步行", "walk"]);
            menuRows.add(["开始新跑步", "run"]);
            menuRows.add(["退出地图", "exit"]);
        }
        WatchUi.requestUpdate();
    }

    function showLibrary(regions) {
        menuTitle = regions ? "地图地区" : "GPX 路线";
        menuIndex = 0;
        menuRows = [];
        if (regions) {
            for (var i = 0; i < MapCatalog.REGIONS.size(); i++) {
                menuRows.add([MapCatalog.REGIONS[i][1], "region", i]);
                if (atlas.region[0].equals(MapCatalog.REGIONS[i][0])) { menuIndex = i; }
            }
        } else {
            menuRows.add(["隐藏计划路线", "route", -1]);
            for (var j = 0; j < atlas.region[5].size(); j++) {
                menuRows.add([atlas.region[5][j][1], "route", j]);
            }
            menuIndex = atlas.routeIndex + 1;
        }
    }

    function selectLibraryItem(isRegion) {
        var index = menuRows[menuIndex][2];
        if (isRegion) {
            atlas.chooseRegion(index);
            tiles = new MapTileCache();
            centerGX = lonToGX(atlas.region[3]);
            centerGY = latToGY(atlas.region[2]);
            browse.pan();
        } else {
            if (!atlas.chooseRoute(index)) { notice = "路线读取失败"; return; }
            if (atlas.points != null) {
                centerGX = atlas.points[0]; centerGY = atlas.points[1];
                browse.pan();
            }
        }
        menuOpen = false;
        notice = atlas.remember() ? null : "本次已切换，未记住选择";
        clampCenter();
        queueMapTiles();
    }

    function performAction(action) {
        if (recovering) { return; }
        if (action.equals("discard_yes") && !confirmDiscard) { return; }
        if (action.equals("back")) { menuOpen = false; confirmDiscard = false; }
        else if (action.equals("regions") || action.equals("routes")) { showLibrary(action.equals("regions")); }
        else if (action.equals("region") || action.equals("route")) { selectLibraryItem(action.equals("region")); }
        else if (action.equals("discard")) {
            confirmDiscard = true; menuIndex = 0;
            menuRows = [["取消丢弃", "cancel"], ["确认丢弃运动", "discard_yes"]];
        } else if (action.equals("cancel")) { openMenu(); }
        else if (action.equals("walk") || action.equals("run")) {
            if (!fix.isCurrent(System.getTimer())) { notice = "请先等待GPS正常"; }
            else if (recorder.start(action.equals("walk") ? Toybox.Activity.SPORT_WALKING : Toybox.Activity.SPORT_RUNNING)) {
                track.clear(); sessionStarted = true; notice = null; checkpoint(true); menuOpen = false;
            } else { notice = recorder.error; openMenu(); }
        } else if (action.equals("toggle")) {
            var ok = recorder.state == recorder.RUNNING ? recorder.pause() : recorder.resume();
            if (ok) {
                if (!sessionStarted) { track.clear(); sessionStarted = true; }
                track.breakSegment(); notice = null; checkpoint(true); menuOpen = false;
            } else { notice = recorder.error; }
        } else if (action.equals("save") || action.equals("save_exit") || action.equals("discard_yes")) {
            if (recorder.finish(!action.equals("discard_yes"))) {
                notice = recorder.label();
                if (action.equals("discard_yes")) { track.clear(); checkpoint(true); }
                checkpoint(true); sessionStarted = false;
                if (action.equals("save_exit")) { WatchUi.popView(WatchUi.SLIDE_IMMEDIATE); return; }
                menuOpen = false; confirmDiscard = false;
            } else { notice = recorder.error; openMenu(); }
        } else if (action.equals("exit") && !recorder.hasSession()) {
            checkpoint(true); WatchUi.popView(WatchUi.SLIDE_IMMEDIATE); return;
        }
        WatchUi.requestUpdate();
    }

    function drawMenu(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_WHITE); dc.clear();
        dc.drawText(W / 2, 18, Graphics.FONT_XTINY, confirmDiscard ? "丢弃后无法恢复" : menuTitle, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(W / 2, 38, Graphics.FONT_XTINY, recorder.label() + " " + elapsedText(), Graphics.TEXT_JUSTIFY_CENTER);
        var first = menuIndex > 3 ? menuIndex - 3 : 0;
        for (var n = first; n < menuRows.size() && n < first + 5; n++) {
            var y = 64 + (n - first) * 27;
            dc.setColor(n == menuIndex ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(24, y, W - 48, 26);
            dc.setColor(n == menuIndex ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(W / 2, y + 2, Graphics.FONT_XTINY, menuRows[n][0], Graphics.TEXT_JUSTIFY_CENTER);
        }
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_WHITE);
        dc.drawText(W / 2, 204, Graphics.FONT_XTINY, notice == null ? "UP/DOWN选择" : notice, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(W / 2, 224, Graphics.FONT_XTINY, "START确认 BACK返回", Graphics.TEXT_JUSTIFY_CENTER);
    }

    function outsideMap() {
        if (loc == null) { return false; }
        var gx = lonToGX(fix.longitude);
        var gy = latToGY(fix.latitude);
        return !covers(offlineRegion,gx,gy);
    }

    function covers(region,x,y) {
        var base=region[4][0];
        return x>=base[2] && x<base[2]+base[4]*MapData.TILE &&
            y>=base[3] && y<base[3]+base[5]*MapData.TILE;
    }

    function statusText() {
        var s = fix.status(System.getTimer());
        if (s == fix.WAITING) { return "等待定位"; }
        if (s == fix.WEAK) { return "GPS 信号弱"; }
        if (s == fix.STALE) { return "定位已过期"; }
        if (phoneTiles == null && outsideMap()) { return "超出地图范围"; }
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
        if (recovering) {
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_WHITE); dc.clear();
            dc.drawText(W / 2, 92, Graphics.FONT_XTINY, "正在恢复轨迹", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(W / 2, 122, Graphics.FONT_XTINY, "请稍候", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(W / 2, 182, Graphics.FONT_XTINY, "BACK退出", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }
        if (menuOpen) { drawMenu(dc); return; }
        clampCenter();
        var scale = mapScale();
        var left = centerGX - W / (2.0 * scale);
        var top = centerGY - H / (2.0 * scale);

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_LT_GRAY);
        dc.clear();

        var base = offlineRegion[4][0];
        var clipX = (base[2] - left) * scale;
        var clipY = (base[3] - top) * scale;
        var clipRight = clipX + base[4] * 512 * scale;
        var clipBottom = clipY + base[5] * 512 * scale;
        if (clipX < 0) { clipX = 0; } if (clipY < 0) { clipY = 0; }
        if (clipRight > W) { clipRight = W; } if (clipBottom > H) { clipBottom = H; }
        if (clipRight>clipX && clipBottom>clipY) {
            dc.setClip(clipX, clipY, clipRight - clipX, clipBottom - clipY);
            tiles.draw(dc, left * scale, top * scale);
            dc.clearClip();
        }
        if (phoneTiles!=null) { phoneTiles.draw(dc,left*scale,top*scale); }
        atlas.draw(dc, left, top, scale, W, H);
        TrackRenderer.drawScaled(dc, track, left, top, W, H, scale);

        if (loc != null) {
            var deg = loc.toDegrees();
            var sx = (lonToGX(deg[1]) - left) * scale;
            var sy = (latToGY(deg[0]) - top) * scale;
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

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(W / 2, 8, Graphics.FONT_XTINY, statusText(), Graphics.TEXT_JUSTIFY_CENTER);
        var modeText = (browse.following ? "跟随 " : "浏览 ") +
            ((browse.axis == 0) ? "上下" : (browse.axis == 1 ? "左右" : "缩放")) +
            (levelIndex == 0 ? "·街道" : "·概览");
        dc.drawText(W / 2, 24, Graphics.FONT_XTINY, modeText, Graphics.TEXT_JUSTIFY_CENTER);


        // 小罗盘（屏幕中左侧）
        drawCompass(dc);
        drawScaleBar(dc);

        // 地图来源署名保持可见。
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(W / 2, 44, Graphics.FONT_XTINY, "©OSM · OSM France", Graphics.TEXT_JUSTIFY_CENTER);
        if (phoneTiles!=null) {
            var sourceText=phoneTiles.ready.size()>0 ? "在线 "+OnlineSource.CREDIT :
                (covers(offlineRegion,centerGX,centerGY) ? "离线" : "无离线覆盖");
            dc.drawText(W/2,62,Graphics.FONT_XTINY,sourceText,Graphics.TEXT_JUSTIFY_CENTER);
        } else if (tiles.pending() || tiles.error) {
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(W / 2, 65, Graphics.FONT_XTINY, tiles.error ? "底图暂不可用" : "载入底图", Graphics.TEXT_JUSTIFY_CENTER);
        }

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        if (notice != null) {
            dc.drawText(W / 2, H - 88, Graphics.FONT_XTINY, notice, Graphics.TEXT_JUSTIFY_CENTER);
        }
        dc.drawText(W / 2, H - 70, Graphics.FONT_XTINY, recorder.label() + " " + elapsedText(), Graphics.TEXT_JUSTIFY_CENTER);

        // 累计里程
        var distText;
        if (track.distance >= 1000.0) {
            distText = (track.distance / 1000.0).format("%.2f") + " km";
        } else {
            distText = track.distance.toNumber().toString() + " m";
        }
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(W / 2, H - 52, Graphics.FONT_XTINY, distText, Graphics.TEXT_JUSTIFY_CENTER);

        var clock = System.getClockTime();
        var timeText = clock.hour.format("%02d") + ":" + clock.min.format("%02d");
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(W / 2, H - 34, Graphics.FONT_XTINY, timeText, Graphics.TEXT_JUSTIFY_CENTER);
    }
}
