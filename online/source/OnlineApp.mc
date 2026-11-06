using Toybox.Application;
using Toybox.Communications;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Math;
using Toybox.Position;
using Toybox.Sensor;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi;

const TILE_PX = 256.0;
// 每块瓦片按 173px 绘制：260px 屏幕能看到约 385 世界像素（视野放大 1.48 倍），
// 单块位图从 64KB 降到约 29KB，省出的内存用来铺外圈预取
const DISP = 173;   // 基准值；实际按屏幕在 initialize 里调（见 dispPx）

// 瓦片源：true = 高德（国内快 5 倍、中文地名，需 GCJ-02 纠偏）
//         false = OSM fr/hot（WGS84，无偏移，但跨国慢）
const USE_AMAP = true;
const TILE_HOST = "https://a.tile.openstreetmap.fr/hot/";
const AMAP_BASE = ".is.autonavi.com/appmaptile?lang=zh_cn&size=1&scl=1&style=7&x=";
const AMAP_HOSTS = ["wprd01", "wprd02", "wprd03", "wprd04"];
const MAX_CH = 3;
const STALE_MS = 20000;
const ZMIN = 3;   // z2 高德返回 1 色空白图；z3 才是中国全图（省界/国界/东海/南海）
const ZMAX = 18;
// MAX_TILES 只是"最多留几块"，能不能留下由 MEM_FLOOR 实时守门（见 pruneCache / handle）。
// 173px 一块约 29KB，12 块约 350KB，仍在 512KB 堆内
const MAX_TILES = 12;
const MEM_FLOOR = 120000;  // 剩余堆低于此值先丢外圈，视口内的永不丢
const RECENTER_MS = 8000;  // 手动平移/缩放后，运动中空闲这么久就把视口挪回实际位置（不动缩放级别）
const MOVE_SPEED = 0.7;    // 米/秒。低于此值视为静止：不自动回中，让你安心翻地图（借鉴高德）
const LONG_MS = 700;

// 20 色，按"拉开明暗层次"重排：近白只留 2 档（原来 5 档近白把画面压成一片灰），
// 中性灰保留 4 档做建筑/底色分层，深灰压文字与路缘，绿地/水域/道路各 3 档
const MAP_PALETTE = [
    0x000000, 0xFFFFFF,
    0xF7F2E6, 0xE6E0D2, 0xD3CBB8, 0xB4AC99,
    0x7D7668, 0x4A453C,
    0xE3F0CE, 0xB9DC8E, 0x86BE63,
    0xB8DDF2, 0x74B3DE, 0x3F7FB5,
    0xF7D05A, 0xF2A93B, 0xE0705F,
    0xEDE7DA, 0xC9C2B2, 0x9C9484
];

// 取图优先级：中心块最先，其次是四邻，最后四角，让屏幕中间先出图
const ORDER = [
    [0, 0],
    [0, -1],
    [0, 1],
    [-1, 0],
    [1, 0],
    [-1, -1],
    [1, -1],
    [-1, 1],
    [1, 1]
];

class OnlineApp extends Application.AppBase {
    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() {
        var view = new OnlineView();
        return [view, new OnlineDelegate(view)];
    }
}

class OnlineDelegate extends WatchUi.InputDelegate {
    var view;
    var pressAt = {};

    function initialize(v) {
        InputDelegate.initialize();
        view = v;
    }

    function isOurs(k) {
        return (k == WatchUi.KEY_UP || k == WatchUi.KEY_DOWN || k == WatchUi.KEY_START || k == 4);
    }

    function onKeyPressed(evt) {
        var k = evt.getKey();
        if (isOurs(k)) {
            pressAt[k] = System.getTimer();
        }
        return false;
    }

    function onKeyReleased(evt) {
        var k = evt.getKey();
        if (!isOurs(k)) {
            return false;
        }
        var t0 = pressAt.get(k);
        if (t0 != null) {
            pressAt.remove(k);
            if (System.getTimer() - t0 >= LONG_MS) {
                view.longPress(k);
            } else {
                view.shortPress(k);
            }
        }
        return true;
    }

    function onKey(evt) {
        var k = evt.getKey();
        if (!isOurs(k)) {
            // BACK / LIGHT 等不属于本应用，必须交还系统，否则会吞掉退出键
            return false;
        }
        var t0 = pressAt.get(k);
        if (t0 != null && System.getTimer() - t0 < 500) {
            return true;
        }
        view.shortPress(k);
        return true;
    }
}

class OnlineView extends WatchUi.View {
    // 屏幕尺寸相关的量全部运行时取，不再写死 260（fr255=260，Venu4 41mm=390，45mm=454）
    var W = 260;
    var H = 260;
    var cx = 130.0;        // 屏幕中心 x
    var cy = 130.0;        // 屏幕中心 y
    var scale = 0.6757813; // = dispPx / TILE_PX
    // 每块瓦片的显示尺寸：fr255(260px,8bpp) 与 390px(16bpp) 都用 173；
    // 454px(16bpp) 降到 160，否则最坏情况 4x4 块 × 2 字节/像素会超过 768KB 堆
    var dispPx = DISP;
    var zoom = 15;
    var mode = 1; // 0=缩放 1=上下 2=左右
    var fracX = 0.5;
    var fracY = 0.5;
    var loc = null;
    var trail = [];
    var showTrail = true;   // 长按 UP 切换；关掉只是不画，数据还在
    var heading = 0.0;
    var prevLat = null;
    var prevLon = null;
    var lastFixAt = 0;
    var curSpeed = 0.0;
    var compassHeading = null; // 电子罗盘方位（FR255 有三轴电子罗盘）
    var lastPan = 0;
    var tiles = {};
    var tileUse = {};
    var visKeys = {};   // 当前视口内的瓦片 key，供 handle() 判断"这是外圈还是视口"
    var inflight = {};
    var inflightAt = {};
    var inflightGen = {};
    var generation = 0;
    var queue = [];
    var qHead = 0;
    var ringCursor = 0;
    var pumping = false;
    var failUntil = {};
    var hintUntil = 0;
    var hintTimer = null;
    var toastMsg = "";
    var toastUntil = 0;
    var didCenter = false;  // 首次拿到定位后把视口挪到当前位置（只做一次）
    var shownAt = 0;        // onShow 时刻：区分"还在搜星"和"根本收不到定位回调"
    var arw = 1.0;          // 箭头尺寸系数，大屏按比例放大，260px 上保持原样

    function initialize() {
        View.initialize();
        var ds = System.getDeviceSettings();
        if (ds != null && ds.screenWidth != null && ds.screenHeight != null) {
            W = ds.screenWidth;
            H = ds.screenHeight;
        }
        cx = W / 2.0;
        cy = H / 2.0;
        if (W > 420) {
            dispPx = 160;
        }
        // 屏幕越大，同一块瓦片显示得越"远"，箭头按屏放大才看得清；
        // fr255(260) 保持 1.0，与 b38 完全一致
        if (W >= 420) {
            arw = 1.6;
        } else if (W >= 320) {
            arw = 1.25;
        }
        scale = dispPx / TILE_PX;
        var c = toMapCoords(36.1054, 120.4513);
        fracX = lonToFracX(c[1]);
        fracY = latToFracY(c[0]);
    }

    // ---------- 坐标 ----------

    function worldPx() {
        return TILE_PX * Math.pow(2.0, zoom);
    }

    function centerGX() {
        return fracX * worldPx();
    }

    function centerGY() {
        return fracY * worldPx();
    }

    function lonToFracX(lon) {
        return (lon + 180.0) / 360.0;
    }

    function latToFracY(lat) {
        var rad = lat * Math.PI / 180.0;
        return (1.0 - Math.log(Math.tan(rad) + 1.0 / Math.cos(rad), 2.718281828459045) / Math.PI) / 2.0;
    }

    function keyOf(tx, ty) {
        return zoom.toString() + "_" + tx.toString() + "_" + ty.toString();
    }

    // ---------- GCJ-02 纠偏（高德瓦片用火星坐标） ----------

    // 只用已验证存在的原语：pow / sin / cos / floor / log
    // Math.abs 和 Math.sqrt 在设备固件上不存在（实测 Symbol Not Found）
    function fabs(x) {
        if (x < 0.0) {
            return -x;
        }
        return x;
    }

    function fsqrt(x) {
        if (x <= 0.0) {
            return 0.0;
        }
        return Math.pow(x, 0.5);
    }

    function outOfChina(lat, lon) {
        return (lon < 72.004 || lon > 137.8347 || lat < 0.8293 || lat > 55.8271);
    }

    function transformLat(x, y) {
        var r = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * fsqrt(fabs(x));
        r = r + (20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0 / 3.0;
        r = r + (20.0 * Math.sin(y * Math.PI) + 40.0 * Math.sin(y / 3.0 * Math.PI)) * 2.0 / 3.0;
        r = r + (160.0 * Math.sin(y / 12.0 * Math.PI) + 320.0 * Math.sin(y * Math.PI / 30.0)) * 2.0 / 3.0;
        return r;
    }

    function transformLon(x, y) {
        var r = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * fsqrt(fabs(x));
        r = r + (20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0 / 3.0;
        r = r + (20.0 * Math.sin(x * Math.PI) + 40.0 * Math.sin(x / 3.0 * Math.PI)) * 2.0 / 3.0;
        r = r + (150.0 * Math.sin(x / 12.0 * Math.PI) + 300.0 * Math.sin(x / 30.0 * Math.PI)) * 2.0 / 3.0;
        return r;
    }

    function wgs2gcj(lat, lon) {
        if (outOfChina(lat, lon)) {
            return [lat, lon];
        }
        var a = 6378245.0;
        var ee = 0.00669342162296594323;
        var dLat = transformLat(lon - 105.0, lat - 35.0);
        var dLon = transformLon(lon - 105.0, lat - 35.0);
        var radLat = lat / 180.0 * Math.PI;
        var magic = Math.sin(radLat);
        magic = 1.0 - ee * magic * magic;
        var sqrtMagic = fsqrt(magic);
        dLat = (dLat * 180.0) / ((a * (1.0 - ee)) / (magic * sqrtMagic) * Math.PI);
        dLon = (dLon * 180.0) / (a / sqrtMagic * Math.cos(radLat) * Math.PI);
        return [lat + dLat, lon + dLon];
    }

    // 经纬度 -> 该瓦片源使用的坐标系
    function toMapCoords(lat, lon) {
        if (USE_AMAP) {
            return wgs2gcj(lat, lon);
        }
        return [lat, lon];
    }

    function tileUrl(tx, ty) {
        if (USE_AMAP) {
            var h = AMAP_HOSTS[(fabs(tx) + fabs(ty)) % 4];
            return "https://" + h + AMAP_BASE + tx.toString() + "&y=" + ty.toString() + "&z=" + zoom.toString();
        }
        return TILE_HOST + zoom.toString() + "/" + tx.toString() + "/" + ty.toString() + ".png";
    }

    // ---------- 生命周期 ----------

    function onShow() {
        var now = System.getTimer();
        shownAt = now;
        hintUntil = now + 5000;
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
        // 常驻 2 秒节拍：让提示能自动消失，也用来刷新"信号丢失"状态
        if (hintTimer == null) {
            hintTimer = new Timer.Timer();
            hintTimer.start(method(:onTick), 2000, true);
        }
        refresh();
    }

    function onHide() {
        if (hintTimer != null) {
            hintTimer.stop();
            hintTimer = null;
        }
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
    }

    function onPosition(info as Position.Info) as Void {
        var p = info.position;
        if (p == null) {
            return;
        }
        loc = p;
        var deg = p.toDegrees();
        readCompass();

        // 速度：用来判断"在动还是静止"（回中、朝向都要用），取不到就按 0 处理
        try {
            curSpeed = info.speed;
        } catch (e) {
            curSpeed = 0.0;
        }

        // 方位角：以"上一个参考点"为基准，走过 8 米才更新一次。
        // 之前是跟"上一次定位"比，步行 1 秒才移动 1–2 米，永远够不到 2.5 米阈值，
        // 所以箭头一直指北 —— 这是方向不变的根因。
        if (prevLat == null) {
            prevLat = deg[0];
            prevLon = deg[1];
        } else {
            var dLat = (deg[0] - prevLat) * Math.PI / 180.0;
            var dLon = (deg[1] - prevLon) * Math.PI / 180.0;
            var mPerDeg = 6371000.0 * Math.PI / 180.0;
            var dyy = dLat * mPerDeg;
            var dxx = dLon * mPerDeg * Math.cos(deg[0] * Math.PI / 180.0);
            if (dyy * dyy + dxx * dxx > 64.0) {
                var yy = Math.sin(dLon) * Math.cos(deg[0] * Math.PI / 180.0);
                var xx = Math.cos(prevLat * Math.PI / 180.0) * Math.sin(deg[0] * Math.PI / 180.0) -
                    Math.sin(prevLat * Math.PI / 180.0) * Math.cos(deg[0] * Math.PI / 180.0) * Math.cos(dLon);
                var nh = Math.atan2(yy, xx) * 180.0 / Math.PI;
                var diff = nh - heading;
                while (diff > 180.0) {
                    diff -= 360.0;
                }
                while (diff < -180.0) {
                    diff += 360.0;
                }
                heading = heading + diff * 0.6;
                prevLat = deg[0];
                prevLon = deg[1];
            }
        }
        lastFixAt = System.getTimer();

        // 首次定位：把视口挪到当前位置。
        // 之前只有两条回中路径 —— 运动中空闲 8 秒自动跟随、长按 START 手动回中。
        // 静止用户打开应用时，视口还停在初始中心（青岛），地图能正常显示（显示的是青岛的图），
        // 但自己的位置箭头永远在屏幕外 —— 这就是"定位之后看不到定位"。
        // 只在第一次拿到定位时挪一次，之后绝不抢用户的手动平移。
        if (!didCenter) {
            didCenter = true;
            var c0 = toMapCoords(deg[0], deg[1]);
            fracX = lonToFracX(c0[1]);
            fracY = latToFracY(c0[0]);
            lastPan = System.getTimer();
            refresh();
        }

        // 轨迹点：存已纠偏的坐标。
        // 抽稀阈值分两档：走动时 4 米（走几步就有线、弯道更顺），
        // 静止时 12 米（GPS 漂移不会在原地糊成一团）。满了滑动窗口而不是整条清空
        var tc = toMapCoords(deg[0], deg[1]);
        var addP = true;
        var minD = (curSpeed >= MOVE_SPEED) ? 4.0 : 12.0;
        if (trail.size() > 0) {
            var lp = trail[trail.size() - 1];
            var tdLat = (tc[0] - lp[0]) * Math.PI / 180.0;
            var tdLon = (tc[1] - lp[1]) * Math.PI / 180.0;
            var tmd = 6371000.0 * Math.PI / 180.0;
            var tey = tdLat * tmd;
            var tex = tdLon * tmd * Math.cos(tc[0] * Math.PI / 180.0);
            if (tey * tey + tex * tex < minD * minD) {
                addP = false;
            }
        }
        if (addP) {
            trail.add([tc[0], tc[1]]);
            if (trail.size() > 800) {
                var ntrail = [];
                for (var tq = 100; tq < trail.size(); tq++) {
                    ntrail.add(trail[tq]);
                }
                trail = ntrail;
            }
        }

        // 走动/静止时跟随当前位置（只挪视口，不动 zoom）
        recenterIfIdle(deg);
        WatchUi.requestUpdate();
    }

    // 把视口挪回实际位置：只改 fracX/fracY，绝不改 zoom（比例尺保持不变）。
    // 借鉴高德的导航模式：
    //   运动时（speed >= MOVE_SPEED）—— 空闲 8 秒后自动跟随回中
    //   静止时 —— 不动，你翻到哪儿就停在哪儿（翻地图看周边是常见需求）
    function recenterIfIdle(deg) as Void {
        if (deg == null) {
            return;
        }
        if (System.getTimer() - lastPan < RECENTER_MS) {
            return;
        }
        if (curSpeed < MOVE_SPEED) {
            return;
        }
        var c = toMapCoords(deg[0], deg[1]);
        var nx = lonToFracX(c[1]);
        var ny = latToFracY(c[0]);
        // 已经基本对准就别动，免得每 2 秒触发一次 refresh 白取瓦片
        var wp = worldPx();
        if (fabs((nx - fracX) * wp) < 0.6 && fabs((ny - fracY) * wp) < 0.6) {
            return;
        }
        fracX = nx;
        fracY = ny;
        refresh();
    }

    // ---------- 按键 ----------

    function shortPress(key) {
        startHint();
        if (key == WatchUi.KEY_UP) {
            up();
        } else if (key == WatchUi.KEY_DOWN) {
            down();
        } else if (key == WatchUi.KEY_START || key == 4) {
            nextMode();
        }
        WatchUi.requestUpdate();
    }

    // 提示 5 秒后必须自己消失 —— 需要有定时器触发重绘，否则屏幕停在旧内容
    function startHint() {
        hintUntil = System.getTimer() + 5000;
    }

    // 常驻节拍：触发重绘 + 读罗盘。
    // 回中也在这里查一次，但 recenterIfIdle 内部有速度门 —— 静止时不会把你翻到的位置拉走；
    // 只在"运动中又没有新定位回调"的间隙补一次跟随。
    function onTick() as Void {
        readCompass();
        if (loc != null) {
            recenterIfIdle(loc.toDegrees());
        }
        WatchUi.requestUpdate();
    }

    // 读电子罗盘方位：Sensor.Info.heading 是弧度、真北参考
    function readCompass() as Void {
        try {
            var si = Sensor.getInfo();
            if (si != null && si.heading != null) {
                compassHeading = si.heading * 180.0 / Math.PI;
            } else {
                compassHeading = null;
            }
        } catch (e) {
            compassHeading = null;
        }
    }

    // 长按 START = 立即回中（相当于高德的"回到我的位置"按钮）
    // 长按 UP   = 轨迹显示 开/关
    // DOWN 不占用：系统用来跳音乐控制
    function longPress(key) {
        if (key == WatchUi.KEY_START || key == 4) {
            forceRecenter();
        } else if (key == WatchUi.KEY_UP) {
            toggleTrail();
        }
    }

    // 轨迹开关：只控制显示，不清数据 —— 关掉再打开，之前的轨迹还在
    function toggleTrail() as Void {
        showTrail = !showTrail;
        showToast(showTrail ? "轨迹开" : "轨迹关");
        WatchUi.requestUpdate();
    }

    // 立即回中：不受 8 秒等待和速度门限制，静止时按一下也能回到自己位置。
    // 只改 fracX/fracY，级别（比例尺）保持不变
    function forceRecenter() as Void {
        if (loc == null) {
            showToast("暂无定位");
            WatchUi.requestUpdate();
            return;
        }
        var deg = loc.toDegrees();
        var c = toMapCoords(deg[0], deg[1]);
        fracX = lonToFracX(c[1]);
        fracY = latToFracY(c[0]);
        lastPan = System.getTimer();
        refresh();
        showToast("已回中");
        WatchUi.requestUpdate();
    }

    // 提示条：停留 3 秒后自动消失（靠 onTick 的 2 秒节拍重绘把它擦掉）
    function showToast(msg) as Void {
        toastMsg = msg;
        toastUntil = System.getTimer() + 3000;
    }

    function up() {
        if (mode == 0) {
            setZoom(zoom + 1);
        } else if (mode == 1) {
            panPixels(0.0, -128.0);
        } else {
            panPixels(-128.0, 0.0);
        }
    }

    function down() {
        if (mode == 0) {
            setZoom(zoom - 1);
        } else if (mode == 1) {
            panPixels(0.0, 128.0);
        } else {
            panPixels(128.0, 0.0);
        }
    }

    function nextMode() {
        mode = mode + 1;
        if (mode > 2) {
            mode = 0;
        }
        WatchUi.requestUpdate();
    }

    function panPixels(dx, dy) {
        var w = worldPx();
        fracX = fracX + (dx / scale) / w;
        fracY = fracY + (dy / scale) / w;
        lastPan = System.getTimer();
        refresh();
        WatchUi.requestUpdate();
    }

    function setZoom(z) {
        if (z < ZMIN) {
            z = ZMIN;
        }
        if (z > ZMAX) {
            z = ZMAX;
        }
        if (z == zoom) {
            return;
        }
        zoom = z;
        generation = generation + 1;
        // 关键：不要清 inflight。通道上还挂着旧级别的请求，一旦清空，
        // 新请求会立刻复用同样的通道号（0/1/2），旧响应回来时 inflight[ch]
        // 已经指向另一块瓦片，旧图就被错记到新 key 上 —— 缩放时瓦片错乱的根因。
        // 旧响应返回后由 generation 判断丢弃，然后才释放通道。
        // 旧级别的位图对新级别没用，直接清掉腾堆（256px ≈ 64KB/块，512KB 堆经不起跨级堆积）
        tiles = {};
        tileUse = {};
        queue = [];
        qHead = 0;
        lastPan = System.getTimer();
        refresh();
        WatchUi.requestUpdate();
    }

    // ---------- 取图 ----------

    function refresh() {
        var gx = centerGX();
        var gy = centerGY();
        var now = System.getTimer();
        var tx0 = Math.floor(gx / TILE_PX).toNumber();
        var ty0 = Math.floor(gy / TILE_PX).toNumber();
        // 视口半宽换算成世界像素：scale<1 时一屏覆盖的世界范围更大
        var half = (W / 2.0) / scale;
        var x0 = Math.floor((gx - half) / TILE_PX).toNumber();
        var x1 = Math.floor((gx + half) / TILE_PX).toNumber();
        var y0 = Math.floor((gy - half) / TILE_PX).toNumber();
        var y1 = Math.floor((gy + half) / TILE_PX).toNumber();
        var needed = {};

        // 只请求真正覆盖屏幕的那几块（1:1 显示时是 2×2～3×3，不是固定 9 块）
        addNeed(needed, tx0, ty0, now);
        for (var tx = x0; tx <= x1; tx++) {
            for (var ty = y0; ty <= y1; ty++) {
                if (tx == tx0 && ty == ty0) {
                    continue;
                }
                addNeed(needed, tx, ty, now);
            }
        }

        // 视口内 = 一定要保留；外圈 = 尽量保留（受总上限约束）
        var vis = {};
        var nk = needed.keys();
        for (var i = 0; i < nk.size(); i++) {
            vis[nk[i]] = true;
        }
        visKeys = vis;
        var ring = {};
        var rk = ringKeys(x0, x1, y0, y1);
        for (var r = 0; r < rk.size(); r++) {
            ring[keyOf(rk[r][0], rk[r][1])] = true;
        }

        pruneCache(vis, ring);
        pump();
    }

    // 视口外一圈的瓦片坐标（8 个方向各取外沿）
    function ringKeys(x0, x1, y0, y1) {
        var out = [];
        for (var tx = x0 - 1; tx <= x1 + 1; tx++) {
            out.add([tx, y0 - 1]);
            out.add([tx, y1 + 1]);
        }
        for (var ty = y0; ty <= y1; ty++) {
            out.add([x0 - 1, ty]);
            out.add([x1 + 1, ty]);
        }
        return out;
    }

    function addNeed(needed, tx, ty, now) {
        var k = keyOf(tx, ty);
        needed[k] = [tx, ty];
        if (tiles.get(k) != null) {
            tileUse[k] = now;
        } else if (!containsKey(inflight, k) && !inQueue(tx, ty) && !inBackoff(k, now)) {
            queue.add([tx, ty]);
        }
    }

    // 视口空闲时补外圈 4 块，平移过去就已就绪
    function prefetchEdges() {
        var gx = centerGX();
        var gy = centerGY();
        var now = System.getTimer();
        // 视口半宽换算成世界像素：scale<1 时一屏覆盖的世界范围更大
        var half = (W / 2.0) / scale;
        var x0 = Math.floor((gx - half) / TILE_PX).toNumber();
        var x1 = Math.floor((gx + half) / TILE_PX).toNumber();
        var y0 = Math.floor((gy - half) / TILE_PX).toNumber();
        var y1 = Math.floor((gy + half) / TILE_PX).toNumber();
        var cand = ringKeys(x0, x1, y0, y1);
        var n = cand.size();
        if (n == 0) {
            return;
        }
        // 每次补 4 块，游标轮转 —— 外圈能留多少由 MEM_FLOOR 守门，
        // 内存够就逐步把整圈铺满，不够就只留视口
        var added = 0;
        for (var step = 0; step < n && added < 4; step++) {
            var idx = (ringCursor + step) % n;
            var tx = cand[idx][0];
            var ty = cand[idx][1];
            var k = keyOf(tx, ty);
            if (tiles.get(k) != null || containsKey(inflight, k) || inQueue(tx, ty) || inBackoff(k, now)) {
                continue;
            }
            queue.add([tx, ty]);
            added = added + 1;
        }
        ringCursor = (ringCursor + 4) % n;
    }

    // 剩余堆字节数（64 色设备位图约 1 字节/像素，256px 一块 ≈ 64KB）
    function freeBytes() {
        try {
            var st = System.getSystemStats();
            if (st != null && st.freeMemory != null) {
                return st.freeMemory;
            }
        } catch (e) {
            return 0;
        }
        return 0;
    }

    // 严格窗口缓存：只留屏幕上和外圈一圈，其余立刻清掉；
    // 若外圈本身超出上限，按最久未用淘汰（视口内的永不淘汰）
    function pruneCache(vis, ring) {
        var keys = tiles.keys();
        for (var i = 0; i < keys.size(); i++) {
            var k = keys[i];
            if (vis.get(k) == null && ring.get(k) == null) {
                tiles.remove(k);
                tileUse.remove(k);
            }
        }
        while (tiles.keys().size() > MAX_TILES) {
            keys = tiles.keys();
            var victim = null;
            var oldest = 0;
            for (var j = 0; j < keys.size(); j++) {
                var kk = keys[j];
                if (vis.get(kk) != null || ring.get(kk) == null) {
                    continue;
                }
                var t = 0;
                if (tileUse.get(kk) != null) {
                    t = tileUse[kk];
                }
                if (victim == null || t < oldest) {
                    victim = kk;
                    oldest = t;
                }
            }
            if (victim == null) {
                return;
            }
            tiles.remove(victim);
            tileUse.remove(victim);
            ring.remove(victim);
        }

        // 内存守门：堆快见底时继续丢外圈（视口内的一块都不丢）。
        // 这样"外圈能留几块就留几块"，不会因为想多预取而把堆顶穿。
        var guard = 0;
        while (guard < 40) {
            guard = guard + 1;
            if (freeBytes() >= MEM_FLOOR) {
                break;
            }
            keys = tiles.keys();
            var ringVictim = null;
            var ringOldest = 0;
            for (var m = 0; m < keys.size(); m++) {
                var kr = keys[m];
                if (vis.get(kr) != null || ring.get(kr) == null) {
                    continue;
                }
                var tr = 0;
                if (tileUse.get(kr) != null) {
                    tr = tileUse[kr];
                }
                if (ringVictim == null || tr < ringOldest) {
                    ringVictim = kr;
                    ringOldest = tr;
                }
            }
            if (ringVictim == null) {
                break;   // 只剩视口内的了，不能再丢
            }
            tiles.remove(ringVictim);
            tileUse.remove(ringVictim);
            ring.remove(ringVictim);
        }
    }

    function containsKey(dict, k) {
        var ks = dict.keys();
        for (var i = 0; i < ks.size(); i++) {
            if (ks[i] == k) {
                return true;
            }
        }
        return false;
    }

    function inQueue(tx, ty) {
        for (var i = qHead; i < queue.size(); i++) {
            var e = queue[i];
            if (e[0] == tx && e[1] == ty) {
                return true;
            }
        }
        return false;
    }

    function inBackoff(k, now) {
        var until = failUntil.get(k);
        if (until == null) {
            return false;
        }
        return now < until;
    }

    function freeChannel() {
        var now = System.getTimer();
        for (var c = 0; c < MAX_CH; c++) {
            if (!containsKey(inflight, c)) {
                return c;
            }
            var at = 0;
            if (inflightAt.get(c) != null) {
                at = inflightAt[c];
            }
            if (now - at > STALE_MS) {
                inflight.remove(c);
                inflightAt.remove(c);
                inflightGen.remove(c);
                return c;
            }
        }
        return -1;
    }

    function pump() {
        if (pumping) {
            return;
        }
        pumping = true;
        while (qHead < queue.size()) {
            var ch = freeChannel();
            if (ch < 0) {
                break;
            }
            var ent = queue[qHead];
            qHead = qHead + 1;
            if (qHead >= queue.size()) {
                queue = [];
                qHead = 0;
            }
            var tx = ent[0];
            var ty = ent[1];
            var k = keyOf(tx, ty);
            inflight[ch] = k;
            inflightAt[ch] = System.getTimer();
            inflightGen[ch] = generation;
            var url = tileUrl(tx, ty);
            var opts = {
                :maxWidth => dispPx,
                :maxHeight => dispPx,
                :palette => MAP_PALETTE,
                // 关闭抖动：地图是大块纯色，FS 抖动会在水面/绿地/底色上留下麻点，
                // 64 色 MIP 上看起来就是"脏 + 对比度低"；真机对比 NONE 明显更干净
                :dithering => Communications.IMAGE_DITHERING_NONE
            };
            try {
                if (ch == 0) {
                    Communications.makeImageRequest(url, null, opts, method(:onCh0));
                } else if (ch == 1) {
                    Communications.makeImageRequest(url, null, opts, method(:onCh1));
                } else if (ch == 2) {
                    Communications.makeImageRequest(url, null, opts, method(:onCh2));
                } else if (ch == 3) {
                    Communications.makeImageRequest(url, null, opts, method(:onCh3));
                } else {
                    Communications.makeImageRequest(url, null, opts, method(:onCh4));
                }
            } catch (e) {
                System.println("req failed: " + e.toString());
                inflight.remove(ch);
                inflightAt.remove(ch);
                inflightGen.remove(ch);
            }
        }
        pumping = false;
    }

    function onCh0(code as Lang.Number, data as Graphics.BitmapReference or WatchUi.BitmapResource or Null) as Void {
        handle(0, code, data);
    }

    function onCh1(code as Lang.Number, data as Graphics.BitmapReference or WatchUi.BitmapResource or Null) as Void {
        handle(1, code, data);
    }

    function onCh2(code as Lang.Number, data as Graphics.BitmapReference or WatchUi.BitmapResource or Null) as Void {
        handle(2, code, data);
    }

    function onCh3(code as Lang.Number, data as Graphics.BitmapReference or WatchUi.BitmapResource or Null) as Void {
        handle(3, code, data);
    }

    function onCh4(code as Lang.Number, data as Graphics.BitmapReference or WatchUi.BitmapResource or Null) as Void {
        handle(4, code, data);
    }

    function handle(ch, code, data) {
        var k = inflight.get(ch);
        if (k == null) {
            return;
        }
        var gen = 0;
        if (inflightGen.get(ch) != null) {
            gen = inflightGen[ch];
        }
        inflight.remove(ch);
        inflightAt.remove(ch);
        inflightGen.remove(ch);

        if (gen != generation) {
            pump();
            return;
        }

        if (data != null) {
            // 只是外圈瓦片、而且内存已经不够了，就别留（退避 30 秒，避免反复重取）
            if (visKeys.get(k) == null && freeBytes() < MEM_FLOOR) {
                failUntil[k] = System.getTimer() + 30000;
            } else {
                tiles[k] = data;
                tileUse[k] = System.getTimer();
                failUntil.remove(k);
            }
        } else {
            // 失败退避，避免对同一个失败请求死循环重试
            failUntil[k] = System.getTimer() + 15000;
            System.println("tile fail " + k + " code=" + code.toString());
        }
        pump();
        if (qHead >= queue.size()) {
            prefetchEdges();
            pump();
        }
        WatchUi.requestUpdate();
    }

    // ---------- 绘制 ----------

    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var gx = centerGX();
        var gy = centerGY();
        // 视口半宽换算成世界像素：scale<1 时一屏覆盖的世界范围更大
        var half = (W / 2.0) / scale;
        var x0 = Math.floor((gx - half) / TILE_PX).toNumber();
        var x1 = Math.floor((gx + half) / TILE_PX).toNumber();
        var y0 = Math.floor((gy - half) / TILE_PX).toNumber();
        var y1 = Math.floor((gy + half) / TILE_PX).toNumber();

        for (var tx = x0; tx <= x1; tx++) {
            for (var ty = y0; ty <= y1; ty++) {
                var bmp = tiles.get(keyOf(tx, ty));
                if (bmp == null) {
                    continue;
                }
                var sx = cx + (tx * TILE_PX - gx) * scale;
                var sy = cy + (ty * TILE_PX - gy) * scale;
                try {
                    dc.drawBitmap(sx.toNumber(), sy.toNumber(), bmp);
                } catch (e) {
                    System.println("draw ex: " + e.toString());
                }
            }
        }

        // 轨迹：深红，4 条偏移线模拟 2px 宽（与离线版一致）；长按 UP 可关掉显示
        if (showTrail && trail.size() > 1) {
            var wp = worldPx();
            dc.setColor(0x8B0000, Graphics.COLOR_TRANSPARENT);
            for (var k = 1; k < trail.size(); k++) {
                var ax = cx + (lonToFracX(trail[k - 1][1]) * wp - gx) * scale;
                var ay = cy + (latToFracY(trail[k - 1][0]) * wp - gy) * scale;
                var bx = cx + (lonToFracX(trail[k][1]) * wp - gx) * scale;
                var by = cy + (latToFracY(trail[k][0]) * wp - gy) * scale;
                if ((ax < -20.0 && bx < -20.0) || (ax > W + 20.0 && bx > W + 20.0) ||
                    (ay < -20.0 && by < -20.0) || (ay > W + 20.0 && by > W + 20.0)) {
                    continue;
                }
                var iax = ax.toNumber();
                var iay = ay.toNumber();
                var ibx = bx.toNumber();
                var iby = by.toNumber();
                dc.drawLine(iax, iay, ibx, iby);
                dc.drawLine(iax + 1, iay, ibx + 1, iby);
                dc.drawLine(iax, iay + 1, ibx, iby + 1);
                dc.drawLine(iax + 1, iay + 1, ibx + 1, iby + 1);
            }
        }

        // 箭头方向：走动时用 GPS 航迹方位（与轨迹必然一致），
        // 静止时才用电子罗盘 —— 罗盘有磁干扰和校准误差，走动时会和轨迹打架
        var drawH = heading;
        if (curSpeed < 0.7 && compassHeading != null) {
            drawH = compassHeading;
        }

        // 位置箭头：GPS 实际位置 + 行进朝向
        if (loc != null) {
            var d = loc.toDegrees();
            var cc = toMapCoords(d[0], d[1]);
            var lx = lonToFracX(cc[1]) * worldPx();
            var ly = latToFracY(cc[0]) * worldPx();
            var ax = cx + (lx - gx) * scale;
            var ay = cy + (ly - gy) * scale;
            if (ax >= -12.0 && ax <= W + 12.0 && ay >= -12.0 && ay <= H + 12.0) {
                drawArrow(dc, ax, ay, drawH * Math.PI / 180.0);
            }
        }

        // 定位状态提示（纯黑透明底，与离线版一致）
        var nowT = System.getTimer();
        if (loc == null) {
            // 分两档：25 秒内是"还在搜星"；超过 25 秒仍没有任何定位回调，
            // 说明根本没收到 GPS 数据，换红字 —— 现场一眼就能区分，不用再猜
            var late = (shownAt > 0 && nowT - shownAt > 25000);
            dc.setColor(late ? Graphics.COLOR_RED : Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, H - 72, Graphics.FONT_XTINY, late ? "无定位" : "定位中", Graphics.TEXT_JUSTIFY_CENTER);
        } else if (nowT - lastFixAt > 20000) {
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, H - 72, Graphics.FONT_XTINY, "信号丢失", Graphics.TEXT_JUSTIFY_CENTER);
        }

        // 顶部：时钟 HH:MM（常驻）。y 取 10 是为了避开 FR255 圆形屏幕的上边缘裁切；
        // 刷新靠 onTick 的 2 秒节拍，分钟变化最多延迟 2 秒
        var ck = System.getClockTime();
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 10, Graphics.FONT_XTINY, ck.hour.format("%02d") + ":" + ck.min.format("%02d"), Graphics.TEXT_JUSTIFY_CENTER);

        // 顶部提示行：toast 优先（如"已回中"），其次才是模式提示；都在时钟下方避免压字
        var nowHint = System.getTimer();
        if (nowHint < toastUntil) {
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, 32, Graphics.FONT_XTINY, toastMsg, Graphics.TEXT_JUSTIFY_CENTER);
        } else if (nowHint < hintUntil) {
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, 32, Graphics.FONT_XTINY, hintText(), Graphics.TEXT_JUSTIFY_CENTER);
        }

        // 底部：比例尺（灰底白字）
        drawScale(dc);
    }

    function drawArrow(dc, sx, sy, rad) {
        var dx = Math.sin(rad);
        var dy = -Math.cos(rad);
        // 一律 toNumber()：几何运算的结果是 Double，直接塞给 fillPolygon 的
        // 嵌套数组在部分固件上会出问题，转成整数最稳
        var tipX = (sx + dx * 13.0 * arw).toNumber();
        var tipY = (sy + dy * 13.0 * arw).toNumber();
        var leftX = (sx - dx * 7.0 * arw - dy * 7.0 * arw).toNumber();
        var leftY = (sy - dy * 7.0 * arw + dx * 7.0 * arw).toNumber();
        var rightX = (sx - dx * 7.0 * arw + dy * 7.0 * arw).toNumber();
        var rightY = (sy - dy * 7.0 * arw - dx * 7.0 * arw).toNumber();
        dc.setColor(0xFF0000, Graphics.COLOR_TRANSPARENT);
        try {
            dc.fillPolygon([[tipX, tipY], [leftX, leftY], [rightX, rightY]]);
        } catch (e) {
            // 兜底：万一某些 16bpp 固件对嵌套数组多边形不买账，退化成实心圆，
            // 至少能看清"自己在哪"，而不是整块屏幕没有任何位置标记
            dc.fillCircle(sx.toNumber(), sy.toNumber(), (9.0 * arw).toNumber());
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(sx.toNumber(), sy.toNumber(), (2.0 * arw).toNumber());
    }

    function latFromFracY(fy) {
        var n = Math.PI * (1.0 - 2.0 * fy);
        var e = Math.pow(2.718281828459045, n);
        var einv = Math.pow(2.718281828459045, -n);
        var sh = (e - einv) / 2.0;
        return Math.atan2(sh, 1.0) * 180.0 / Math.PI;
    }

    // 比例尺：顶部一条带刻度的横线 + 距离标注
    function drawScale(dc) {
        var lat = latFromFracY(fracY);
        var mppWorld = 156543.03392 * Math.cos(lat * Math.PI / 180.0) / Math.pow(2.0, zoom);
        var mppScreen = mppWorld / scale;
        // 刻度候选（米）：从 2km 一路扩到 2000km，低级别才画得出刻度线
        var cand = [2000000, 1000000, 500000, 200000, 100000, 50000, 20000,
                    10000, 5000, 2000, 1000, 500, 200, 100, 50, 20, 10];
        var pick = 10;
        for (var i = 0; i < cand.size(); i++) {
            if (cand[i] / mppScreen <= W * 0.42) {
                pick = cand[i];
                break;
            }
        }
        var px = pick / mppScreen;
        var yBar = H - 34;
        var x0 = cx - px / 2.0;
        var x1 = cx + px / 2.0;

        // 纯黑刻度线，无底色（与离线版一致的样式）
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(x0.toNumber(), yBar, x1.toNumber(), yBar);
        dc.drawLine(x0.toNumber(), yBar - 4, x0.toNumber(), yBar + 4);
        dc.drawLine(x1.toNumber(), yBar - 4, x1.toNumber(), yBar + 4);

        var label;
        if (pick >= 1000) {
            label = (pick / 1000).toString() + "km";
        } else {
            label = pick.toString() + "m";
        }
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, H - 52, Graphics.FONT_XTINY, label, Graphics.TEXT_JUSTIFY_CENTER);
    }

    function hintText() {
        if (mode == 0) {
            return "缩放";
        }
        if (mode == 1) {
            return "上下";
        }
        return "左右";
    }
}
