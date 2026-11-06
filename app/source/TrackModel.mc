using Toybox.Lang;
using Toybox.Math;

class TrackModel {
    const CAPACITY = 800;
    var points;
    var projected;
    var head = 0;
    var count = 0;
    var distance = 0.0;
    var previous = null;
    var pendingBreak = true;
    var revision = 0;

    function initialize() { points = new [CAPACITY]; projected = new [CAPACITY]; }
    function clear() {
        points = new [CAPACITY]; projected = new [CAPACITY]; head = 0; count = 0; distance = 0.0;
        previous = null; pendingBreak = true; revision++;
    }
    function size() { return count; }
    function point(index) { return points[(head + index) % CAPACITY]; }
    function projectedPoint(index) { return projected[(head + index) % CAPACITY]; }
    function project(value) { return MapProjection.point(value[0], value[1]); }
    function append(value) {
        var slot = (head + count) % CAPACITY;
        if (count < CAPACITY) { count++; }
        else { head = (head + 1) % CAPACITY; }
        points[slot] = value;
        // Fixed-capacity render cache; raw coordinates and persistence stay unchanged.
        projected[slot] = value == null ? null : project(value);
        revision++;
    }
    function breakSegment() { previous = null; pendingBreak = true; }
    function meters(a, b) {
        var y = (b[0] - a[0]) * Math.PI / 180.0 * 6371000.0;
        var x = (b[1] - a[1]) * Math.PI / 180.0 * 6371000.0 * Math.cos(b[0] * Math.PI / 180.0);
        return Math.sqrt(x*x + y*y);
    }
    function accept(lat, lon, newSegment) {
        if (newSegment) { breakSegment(); }
        var p = [lat, lon];
        if (previous != null) {
            var segment = meters(previous, p);
            if (segment < 50.0) { distance += segment; revision++; }
            else { pendingBreak = true; }
        }
        previous = p;
        if (pendingBreak) {
            if (count > 0 && point(count - 1) != null) { append(null); }
            append(p); pendingBreak = false;
        } else if (count == 0 || meters(point(count - 1), p) >= 8.0) { append(p); }
    }
    function exportPoints() {
        var data = [];
        for (var i = 0; i < count; i++) {
            var p = point(i);
            data.add(p == null ? null : (p[0] * 100000.0).toNumber());
            data.add(p == null ? null : (p[1] * 100000.0).toNumber());
        }
        return data;
    }
    function restore(data, distanceCm) {
        clear();
        for (var i = 0; i < data.size(); i += 2) {
            append(data[i] == null ? null : [data[i] / 100000.0, data[i + 1] / 100000.0]);
        }
        distance = distanceCm / 100.0;
        breakSegment();
    }
}
