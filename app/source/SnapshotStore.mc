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
    function valid(r) {
        if (!(r instanceof Lang.Array) || r.size() != 8) { return false; }
        for (var i = 0; i < 6; i++) {
            if (!(r[i] instanceof Lang.Number) || r[i] < 0) { return false; }
        }
        if (r[0] != 1 || r[4] > 6 || !(r[7] instanceof Lang.Number)) { return false; }
        var data = r[6];
        if (!(data instanceof Lang.Array) || data.size() > 1600 || data.size() % 2 != 0) { return false; }
        for (var j = 0; j < data.size(); j += 2) {
            if (data[j] == null && data[j + 1] == null) { continue; }
            if (!(data[j] instanceof Lang.Number) || !(data[j + 1] instanceof Lang.Number)) { return false; }
            if (data[j] < -9000000 || data[j] > 9000000 || data[j + 1] < -18000000 || data[j + 1] > 18000000) { return false; }
        }
        return checksum(r) == r[7];
    }
    function load() {
        error = null;
        var best = null;
        for (var i = 0; i < 2; i++) {
            try {
                var r = readValue(prefix + i.toString());
                if (valid(r) && (best == null || r[1] > best[1])) { best = r; }
                else if (r != null && !valid(r)) { error = "部分轨迹无法恢复"; }
            } catch (e) { error = "轨迹读取失败"; }
        }
        if (best != null) { sequence = best[1]; }
        return best;
    }
    function save(track, elapsedMs, phase) {
        error = null;
        var next = sequence + 1;
        var r = [1, next, (track.distance * 100.0).toNumber(), (elapsedMs / 1000).toNumber(), phase,
            Time.now().value(), track.exportPoints(), 0];
        r[7] = checksum(r);
        if (!valid(r)) { error = "轨迹摘要无效"; return false; }
        try {
            writeValue(prefix + (next % 2).toString(), r);
            sequence = next; return true;
        } catch (e) { error = "轨迹保存失败"; return false; }
    }
}
