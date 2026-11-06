using Toybox.Application.Storage;
using Toybox.Lang;
using Toybox.Time;

// Two bounded, versioned records. No persistent Symbols or live Session objects.
class SnapshotStore {
    var prefix;
    var sequence = 0;
    var error = null;
    function initialize(keyPrefix) { prefix = keyPrefix; }
    function readValue(key) { return Storage.getValue(key); }
    function writeValue(key, value) { Storage.setValue(key, value); }
    function checksum(record) {
        var hash = 17;
        for (var i = 0; i < 6; i++) { hash = (hash * 97 + record[i] % 1000003) % 1000003; }
        var data = record[6];
        for (var j = 0; j < data.size(); j++) {
            var n = data[j] == null ? 18000001 : data[j];
            hash = (hash * 97 + n + 18000001) % 1000003;
        }
        return hash;
    }
    function headerValid(r) {
        if (!(r instanceof Lang.Array) || r.size() != 8) { return false; }
        for (var i = 0; i < 6; i++) {
            if (!(r[i] instanceof Lang.Number) || r[i] < 0) { return false; }
        }
        if (r[0] != 1 || r[4] > 6 || !(r[7] instanceof Lang.Number)) { return false; }
        var data = r[6];
        if (!(data instanceof Lang.Array) || data.size() > 1600 || data.size() % 2 != 0) { return false; }
        return true;
    }
    function checkedChecksum(r) {
        if (!headerValid(r)) { return null; }
        var hash = 17;
        for (var i = 0; i < 6; i++) { hash = (hash * 97 + r[i] % 1000003) % 1000003; }
        var data = r[6];
        for (var j = 0; j < data.size(); j += 2) {
            var lat = data[j]; var lon = data[j + 1];
            if (lat == null && lon == null) { lat = 18000001; lon = 18000001; }
            else if (!(lat instanceof Lang.Number) || !(lon instanceof Lang.Number) ||
                     lat < -9000000 || lat > 9000000 || lon < -18000000 || lon > 18000000) { return null; }
            hash = (hash * 97 + lat + 18000001) % 1000003;
            hash = (hash * 97 + lon + 18000001) % 1000003;
        }
        return hash;
    }
    function valid(r) { var hash = checkedChecksum(r); return hash != null && hash == r[7]; }
    function save(track, elapsedMs, phase) {
        error = null;
        var next = sequence + 1;
        var r = [1, next, (track.distance * 100.0).toNumber(), (elapsedMs / 1000).toNumber(), phase,
            Time.now().value(), track.exportPoints(), 0];
        // Validate and hash in one traversal; never hash a generated record twice.
        var hash = checkedChecksum(r);
        if (hash == null) { error = "轨迹摘要无效"; return false; }
        r[7] = hash;
        try {
            writeValue(prefix + (next % 2).toString(), r);
            sequence = next; return true;
        } catch (e) { error = "轨迹保存失败"; return false; }
    }
}
