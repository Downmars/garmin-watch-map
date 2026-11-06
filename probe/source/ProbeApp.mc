using Toybox.Application;
using Toybox.Communications;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.System;
using Toybox.WatchUi;

// 青岛市南（香港中路/台湾路一带），z15 密集街区
const IMG_URL = "https://a.tile.openstreetmap.fr/hot/15/27343/12860.png";

// 按地图要素定制的 24 色调色板：8 级中性灰 + 关键地物色
const MAP_PALETTE = [
    0x000000, 0x2A2A2A, 0x555555, 0x808080, 0xA8A8A8, 0xC8C8C8, 0xE4E4E4, 0xFFFFFF,
    0xF2EFE9, 0xD9D0C9, 0xAAD3DF, 0x7FB6C6, 0xC8E6C9, 0xAED6A5, 0xFCD6A4, 0xE892A2,
    0xF7FABF, 0xF5E9C6, 0x9ACCC9, 0xBFBFBF, 0x6E6E6E, 0xDDD8D4, 0xB5B5A5, 0xF0EEE4
];

class ProbeApp extends Application.AppBase {
    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() {
        var view = new ProbeView();
        return [view, new ProbeDelegate(view)];
    }
}

class ProbeDelegate extends WatchUi.InputDelegate {
    var view;

    function initialize(v) {
        InputDelegate.initialize();
        view = v;
    }

    function onKey(evt) {
        if (evt.getKey() == WatchUi.KEY_UP) {
            view.runTest();
            return true;
        }
        return false;
    }
}

class ProbeView extends WatchUi.View {
    var imgA = null;
    var imgB = null;
    var codeA = 0;
    var codeB = 0;
    var msA = 0;
    var msB = 0;
    var t0 = 0;
    var note = "UP=retest";

    function initialize() {
        View.initialize();
    }

    function onShow() {
        runTest();
    }

    function runTest() {
        imgA = null;
        imgB = null;
        codeA = 0;
        codeB = 0;
        msA = 0;
        msB = 0;
        note = "waiting...";
        t0 = System.getTimer();
        WatchUi.requestUpdate();
        System.println("=== PALETTE TEST ===");

        // A：默认（不给调色板）
        try {
            Communications.makeImageRequest(IMG_URL, null, {
                :maxWidth => 128,
                :maxHeight => 128,
                :dithering => Communications.IMAGE_DITHERING_NONE
            }, method(:onA));
            System.println("A dispatched");
        } catch (e) {
            System.println("A EXCEPTION " + e.toString());
        }

        // B：定制地图调色板
        try {
            Communications.makeImageRequest(IMG_URL, null, {
                :maxWidth => 128,
                :maxHeight => 128,
                :palette => MAP_PALETTE,
                :dithering => Communications.IMAGE_DITHERING_NONE
            }, method(:onB));
            System.println("B dispatched");
        } catch (e) {
            System.println("B EXCEPTION " + e.toString());
        }
    }

    function onA(code as Lang.Number, data as Graphics.BitmapReference or WatchUi.BitmapResource or Null) as Void {
        codeA = code;
        msA = System.getTimer() - t0;
        if (data != null) {
            imgA = data;
            System.println("A ok code=" + code.toString() + " ms=" + msA.toString());
        } else {
            System.println("A null code=" + code.toString());
        }
        WatchUi.requestUpdate();
    }

    function onB(code as Lang.Number, data as Graphics.BitmapReference or WatchUi.BitmapResource or Null) as Void {
        codeB = code;
        msB = System.getTimer() - t0;
        if (data != null) {
            imgB = data;
            System.println("B ok code=" + code.toString() + " ms=" + msB.toString());
        } else {
            System.println("B null code=" + code.toString());
        }
        WatchUi.requestUpdate();
    }

    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        if (imgA != null) {
            try {
                dc.drawBitmap(0, 0, imgA);
            } catch (e) {
                System.println("drawA failed: " + e.toString());
            }
        }
        if (imgB != null) {
            try {
                dc.drawBitmap(132, 0, imgB);
            } catch (e) {
                System.println("drawB failed: " + e.toString());
            }
        }

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_YELLOW);
        dc.drawText(2, 2, Graphics.FONT_XTINY, "A " + codeA.toString() + " " + msA.toString() + "ms", Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_RED);
        dc.drawText(134, 2, Graphics.FONT_XTINY, "B " + codeB.toString() + " " + msB.toString() + "ms", Graphics.TEXT_JUSTIFY_LEFT);

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_YELLOW);
        dc.drawText(2, 244, Graphics.FONT_XTINY, "A=default   B=palette   UP=again", Graphics.TEXT_JUSTIFY_LEFT);
    }
}
