using Toybox.Graphics;

module TrackRenderer {
    function draw(dc, track, left, top, width, height) {
        var count = track.size();
        if (count < 2) { return 0; }
        var minX = left - 2; var maxX = left + width + 2;
        var minY = top - 2; var maxY = top + height + 2;
        var previous = track.projectedPoint(0);
        var drawn = 0;
        dc.setColor(0x8B0000, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        for (var i = 1; i < count; i++) {
            var current = track.projectedPoint(i);
            if (previous != null && current != null) {
                // Reject only segments wholly beyond the same viewport edge.
                // A crossing line remains visible even when both endpoints are outside.
                if (!((previous[0] < minX && current[0] < minX) ||
                      (previous[0] > maxX && current[0] > maxX) ||
                      (previous[1] < minY && current[1] < minY) ||
                      (previous[1] > maxY && current[1] > maxY))) {
                    dc.drawLine(previous[0] - left, previous[1] - top, current[0] - left, current[1] - top);
                    drawn++;
                }
            }
            previous = current;
        }
        // Other map overlays still use their original one-pixel pen.
        dc.setPenWidth(1);
        return drawn;
    }
}
