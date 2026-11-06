using Toybox.Graphics;

module TrackRenderer {
    function draw(dc, track, left, top, width, height) {
        return drawScaled(dc, track, left, top, width, height, 1.0);
    }
    function drawScaled(dc, track, left, top, width, height, scale) {
        var count = track.size();
        if (count < 2) { return 0; }
        var minX = left - 2 / scale; var maxX = left + (width + 2) / scale;
        var minY = top - 2 / scale; var maxY = top + (height + 2) / scale;
        var previousX = track.projectedX(0); var previousY = track.projectedY(0);
        var drawn = 0;
        dc.setColor(0x8B0000, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        for (var i = 1; i < count; i++) {
            var currentX = track.projectedX(i); var currentY = track.projectedY(i);
            if (previousX != null && currentX != null) {
                // Reject only segments wholly beyond the same viewport edge.
                // A crossing line remains visible even when both endpoints are outside.
                if (!((previousX < minX && currentX < minX) ||
                      (previousX > maxX && currentX > maxX) ||
                      (previousY < minY && currentY < minY) ||
                      (previousY > maxY && currentY > maxY))) {
                    dc.drawLine((previousX - left) * scale, (previousY - top) * scale,
                        (currentX - left) * scale, (currentY - top) * scale);
                    drawn++;
                }
            }
            previousX = currentX; previousY = currentY;
        }
        // Other map overlays still use their original one-pixel pen.
        dc.setPenWidth(1);
        return drawn;
    }
}
