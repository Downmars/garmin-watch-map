using Toybox.Activity;
using Toybox.Application.Storage;

class ActivityPreference {
    const KEY = "weinan.activity.v1";
    var choices = [["步行", "walk", Activity.SPORT_WALKING],
        ["跑步", "run", Activity.SPORT_RUNNING],
        ["骑行", "cycle", Activity.SPORT_CYCLING],
        ["通用轨迹", "generic", Activity.SPORT_GENERIC]];
    var selected = 0;
    function initialize() {
        try {
            var saved = readValue();
            for (var i=0; i<choices.size(); i++) {
                if (choices[i][1].equals(saved)) { selected=i; break; }
            }
        } catch(e) {}
    }
    function readValue() { return Storage.getValue(KEY); }
    function writeValue(value) { Storage.setValue(KEY,value); }
    function label() { return choices[selected][0]; }
    function sport() { return choices[selected][2]; }
    function choose(index) {
        if (index<0 || index>=choices.size()) { return false; }
        selected=index;
        try { writeValue(choices[index][1]); return true; }
        catch(e) { return false; }
    }
}
