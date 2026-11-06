using Toybox.Lang;

// One step per event-loop callback. Never drain this loader inside onShow.
class SnapshotLoader {
    const BATCH_PAIRS = 32;
    var store;
    var slot = 0;
    var candidate = null;
    var best = null;
    var cursor = 0;
    var hash = 17;
    var done = false;
    function initialize(source) { store = source; store.error = null; }
    function reject() { store.error = "部分轨迹无法恢复"; candidate = null; }
    function step() {
        if (done) { return true; }
        if (candidate == null) {
            if (slot == 2) {
                if (best != null) { store.sequence = best[1]; }
                done = true; return true;
            }
            var key = store.prefix + slot.toString(); slot++;
            try { candidate = store.readValue(key); }
            catch (e) { store.error = "轨迹读取失败"; candidate = null; }
            if (candidate == null) { return false; }
            if (!store.headerValid(candidate)) { reject(); return false; }
            hash = 17; cursor = 0;
            for (var i = 0; i < 6; i++) { hash = (hash * 97 + candidate[i] % 1000003) % 1000003; }
            // Reading a storage slot and validating its points use separate callbacks.
            return false;
        }
        var data = candidate[6];
        for (var count = 0; count < BATCH_PAIRS && cursor < data.size(); count++) {
            var lat = data[cursor]; var lon = data[cursor + 1];
            if (lat == null && lon == null) { lat = 18000001; lon = 18000001; }
            else if (!(lat instanceof Lang.Number) || !(lon instanceof Lang.Number) ||
                     lat < -9000000 || lat > 9000000 || lon < -18000000 || lon > 18000000) {
                reject(); return false;
            }
            // Keep the v1 checksum arithmetic, including the null sentinel, unchanged.
            hash = (hash * 97 + lat + 18000001) % 1000003;
            hash = (hash * 97 + lon + 18000001) % 1000003;
            cursor += 2;
        }
        if (cursor == data.size()) {
            if (hash != candidate[7]) { reject(); }
            else {
                if (best == null || candidate[1] > best[1]) { best = candidate; }
                candidate = null;
            }
        }
        return false;
    }
    function takeResult() { var result = best; best = null; return result; }
}
