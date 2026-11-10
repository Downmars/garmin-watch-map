using Toybox.Lang;
using Toybox.Math;

class TrackModel {
    const CAPACITY = 800;
    const MAX_SAMPLE_GAP_SECONDS = 10;
    const MAX_TRAVEL_MPS = 60.0;
    var points;
    var projected;
    var head = 0;
    var count = 0;
    var distance = 0.0;
    var previous = null;
    var previousAt = null;
    var previousSource = null;
    var previousSpeed = null;
    var pendingBreak = true;
    var revision = 0;

    function initialize() { points = new [CAPACITY * 2]; projected = new [CAPACITY * 2]; }
    function clear() {
        points = new [CAPACITY * 2]; projected = new [CAPACITY * 2]; head = 0; count = 0; distance = 0.0;
        breakSegment(); revision++;
    }
    function size() { return count; }
    // Flat ring buffers avoid retaining two small Array objects for every entry.
    function point(index) {
        var offset = ((head + index) % CAPACITY) * 2;
        return points[offset] == null ? null : [points[offset], points[offset + 1]];
    }
    function projectedX(index) { return projected[((head + index) % CAPACITY) * 2]; }
    function projectedY(index) { return projected[((head + index) % CAPACITY) * 2 + 1]; }
    function projectedPoint(index) {
        var x = projectedX(index);
        return x == null ? null : [x, projectedY(index)];
    }
    function project(value) { return MapProjection.point(value[0], value[1]); }
    function append(value) {
        var slot = (head + count) % CAPACITY;
        if (count < CAPACITY) { count++; }
        else { head = (head + 1) % CAPACITY; }
        var offset = slot * 2;
        if (value == null) {
            points[offset] = null; points[offset + 1] = null;
            projected[offset] = null; projected[offset + 1] = null;
        } else {
            points[offset] = value[0]; points[offset + 1] = value[1];
            var p = project(value);
            projected[offset] = p[0]; projected[offset + 1] = p[1];
        }
        revision++;
    }
    function breakSegment() {
        previous = null; previousAt = null; previousSource = null; previousSpeed = null;
        pendingBreak = true;
    }
    function meters(a, b) {
        var y = (b[0] - a[0]) * Math.PI / 180.0 * 6371000.0;
        var x = (b[1] - a[1]) * Math.PI / 180.0 * 6371000.0 * Math.cos(b[0] * Math.PI / 180.0);
        return Math.sqrt(x*x + y*y);
    }
    function accept(lat, lon, newSegment) {
        // Untimed callers keep the conservative legacy distance limit.
        acceptSample(lat, lon, newSegment, null, null, null);
    }
    function usableSpeed(speed) {
        return speed != null && speed == speed && speed >= 0 && speed <= MAX_TRAVEL_MPS;
    }
    function acceptSample(lat, lon, newSegment, sourceSeconds, receivedMs, speed) {
        if (newSegment) { breakSegment(); }
        var p = [lat, lon];
        var sampleSpeed = usableSpeed(speed) ? speed : null;
        if (previous != null) {
            var segment = meters(previous, p);
            var seconds = null;
            var invalidTime = false;
            if (receivedMs != null && previousAt != null) {
                seconds = (receivedMs - previousAt) / 1000.0;
                invalidTime = seconds < 0 || seconds > MAX_SAMPLE_GAP_SECONDS;
            }
            if (sourceSeconds != null && previousSource != null) {
                seconds = sourceSeconds - previousSource;
                invalidTime = invalidTime || seconds <= 0 || seconds > MAX_SAMPLE_GAP_SECONDS;
            } else if (seconds != null && seconds <= 0) {
                invalidTime = true;
            }
            var allowed = 50.0;
            if (!invalidTime && seconds != null) {
                var travelSpeed = previousSpeed;
                if (sampleSpeed != null && (travelSpeed == null || sampleSpeed > travelSpeed)) { travelSpeed = sampleSpeed; }
                // Allow acceleration and GPS error without interpreting every >50m step as a jump.
                if (travelSpeed == null) { travelSpeed = MAX_TRAVEL_MPS; }
                else { travelSpeed += 10.0; }
                if (travelSpeed > MAX_TRAVEL_MPS) { travelSpeed = MAX_TRAVEL_MPS; }
                var timedLimit = 20.0 + travelSpeed * seconds;
                if (timedLimit > allowed) { allowed = timedLimit; }
            }
            if (!invalidTime && segment < allowed) { distance += segment; revision++; }
            else { pendingBreak = true; }
        }
        previous = p; previousAt = receivedMs; previousSource = sourceSeconds; previousSpeed = sampleSpeed;
        if (pendingBreak) {
            if (count > 0 && point(count - 1) != null) { append(null); }
            append(p); pendingBreak = false;
        } else if (count == 0 || meters(point(count - 1), p) >= 8.0) { append(p); }
    }
    function exportPoints() {
        var data = [];
        for (var i = 0; i < count; i++) {
            var offset = ((head + i) % CAPACITY) * 2;
            var lat = points[offset]; var lon = points[offset + 1];
            data.add(lat == null ? null : (lat * 100000.0).toNumber());
            data.add(lon == null ? null : (lon * 100000.0).toNumber());
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
