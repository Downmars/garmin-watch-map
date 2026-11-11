using Toybox.Graphics;
using Toybox.Lang;
using Toybox.WatchUi;

class WaypointLayer {
    var items = [];
    var selected = -1;
    var visibleCount = 0;
    var kinds = ["地点", "补给", "停车", "危险", "休息", "观景"];

    function initialize() {}

    function load(resource) {
        items = []; selected = -1;
        if (resource == null) { return true; }
        try {
            var data = WatchUi.loadResource(resource);
            if (!(data instanceof Lang.Array) || data.size() > 32) { return false; }
            items = data;
            return true;
        } catch(e) { return false; }
    }

    function shortName(index) {
        var name = items[index][2];
        return name.length() > 10 ? name.substring(0, 10) : name;
    }

    function draw(dc, left, top, scale, width, height) {
        visibleCount = 0;
        for (var i = 0; i < items.size(); i++) {
            var item = items[i];
            var x = ((item[0] - left) * scale).toNumber();
            var y = ((item[1] - top) * scale).toNumber();
            if (x < -8 || x > width+8 || y < -8 || y > height+8) { continue; }
            visibleCount++;
            dc.setColor(item[3] == 3 ? 0xBB3300 : 0x006633, Graphics.COLOR_TRANSPARENT);
            if (item[3] == 3) {
                dc.drawLine(x, y-6, x-6, y+5);
                dc.drawLine(x-6, y+5, x+6, y+5);
                dc.drawLine(x+6, y+5, x, y-6);
            } else {
                dc.fillCircle(x, y, 4);
            }
            if (i == selected) {
                dc.drawCircle(x, y, 7);
                var text = shortName(i);
                var textWidth = dc.getTextWidthInPixels(text, Graphics.FONT_XTINY);
                var labelX = x+9;
                if (labelX+textWidth > width-8) { labelX = width-textWidth-8; }
                if (labelX < 8) { labelX = 8; }
                var labelY = y-18;
                if (labelY < 80) { labelY = 80; }
                if (labelY > height-110) { labelY = height-110; }
                dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
                dc.drawText(labelX, labelY, Graphics.FONT_XTINY, text, Graphics.TEXT_JUSTIFY_LEFT);
            }
        }
    }
}
