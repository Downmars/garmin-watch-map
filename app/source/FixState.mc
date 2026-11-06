using Toybox.Position;

// Receipt time is monotonic milliseconds. Source time is GPS seconds or null.
// Keep this independent of sensors and UI so the real Monkey C logic is testable.
class FixState {
    const WAITING = 0;
    const CURRENT = 1;
    const WEAK = 2;
    const STALE = 3;
    const MAX_AGE_MS = 10000;

    var latitude = null;
    var longitude = null;
    var acceptedAt = null;
    var sourceTime = null;
    var state = WAITING;
    var breakPending = true;
    var startsSegment = true;

    function initialize() {}

    function status(now) {
        if (acceptedAt != null) {
            var age = now - acceptedAt;
            if (age < 0 || age > MAX_AGE_MS) { return STALE; }
        }
        return state;
    }

    function isCurrent(now) { return status(now) == CURRENT; }

    function accept(lat, lon, quality, timestamp, now) {
        startsSegment = false;
        var validCoordinates = lat != null && lon != null;
        if (validCoordinates) {
            // NaN is unequal to itself; range checks also reject infinities.
            validCoordinates = lat == lat && lon == lon &&
                lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;
        }
        if (!validCoordinates ||
            (quality != Position.QUALITY_USABLE && quality != Position.QUALITY_GOOD)) {
            state = (quality == Position.QUALITY_POOR) ? WEAK :
                ((acceptedAt == null) ? WAITING : STALE);
            breakPending = true;
            return false;
        }
        // Duplicate/cached GPS callbacks must not extend the freshness timer.
        if (timestamp != null && sourceTime != null && timestamp <= sourceTime) {
            return false;
        }
        startsSegment = breakPending || !isCurrent(now);
        latitude = lat;
        longitude = lon;
        acceptedAt = now;
        if (timestamp != null) { sourceTime = timestamp; }
        state = CURRENT;
        breakPending = false;
        return true;
    }
}
