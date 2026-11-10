using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Position;
using Toybox.System;
using Toybox.Test;

class MemoryActivityPreference extends ActivityPreference {
    var data;
    var fail=false;
    function initialize(values) { data=values; ActivityPreference.initialize(); }
    function readValue() { return data.get(KEY); }
    function writeValue(value) {
        if (fail) { throw new Lang.InvalidValueException("injected"); }
        data.put(KEY,value);
    }
}

(:test)
function activityChoiceSurvivesRestartAndInvalidValues(logger as Test.Logger) as Lang.Boolean {
    var data={}, pref=new MemoryActivityPreference(data);
    Test.assertEqual(pref.selected,0);
    for (var i=0;i<pref.choices.size();i++) {
        Test.assert(pref.choose(i));
        var restored=new MemoryActivityPreference(data);
        Test.assertEqual(restored.sport(),pref.choices[i][2]);
        Test.assertEqual(restored.selected,i);
    }
    data.put(pref.KEY,"unknown"); Test.assertEqual(new MemoryActivityPreference(data).selected,0);
    data.put(pref.KEY,99); Test.assertEqual(new MemoryActivityPreference(data).selected,0);
    Test.assert(!pref.choose(99));
    return true;
}

(:test)
function activityWriteFailureKeepsChoiceForCurrentSession(logger as Test.Logger) as Lang.Boolean {
    var data={}, pref=new MemoryActivityPreference(data);
    Test.assert(pref.choose(1)); pref.fail=true;
    Test.assert(!pref.choose(2)); Test.assertEqual(pref.selected,2);
    Test.assertEqual(new MemoryActivityPreference(data).selected,1);
    return true;
}

(:test)
function singleStartUsesSelectedSportForAllTypes(logger as Test.Logger) as Lang.Boolean {
    for (var i=0;i<4;i++) {
        var view=new MapView(), r=new TestRecorder(), pref=new MemoryActivityPreference({});
        view.recorder=r; view.snapshots=new MemorySnapshots(); view.activityPreference=pref;
        pref.choose(i); view.openMenu();
        var start=-1, starts=0;
        for (var n=0;n<view.menuRows.size();n++) {
            if (view.menuRows[n][1].equals("start_record")) { start=n; starts++; }
            Test.assert(!view.menuRows[n][1].equals("walk") && !view.menuRows[n][1].equals("run"));
        }
        Test.assertEqual(starts,1);
        view.menuIndex=start; view.onStart(); Test.assertEqual(r.creates,0);
        view.fix.accept(34.5,109.5,Position.QUALITY_GOOD,100,System.getTimer());
        view.menuIndex=start; view.onStart();
        Test.assertEqual(r.creates,1); Test.assertEqual(r.lastSport,pref.sport());
        Test.assert(!view.menuOpen);
    }
    return true;
}

(:test)
function activitySettingsNavigationAndActiveSessionGuard(logger as Test.Logger) as Lang.Boolean {
    var view=new MapView(), pref=new MemoryActivityPreference({}), r=new TestRecorder();
    view.activityPreference=pref; view.recorder=r; view.snapshots=new MemorySnapshots();
    var bitmap=Graphics.createBufferedBitmap({:width=>260,:height=>260}).get();
    view.openMenu(); view.performAction("settings"); view.onUpdate(bitmap.getDc());
    Test.assert(view.menuTitle.equals("设置"));
    view.onStart(); view.onUpdate(bitmap.getDc()); Test.assert(view.menuTitle.equals("活动类型"));
    view.menuIndex=2; view.onStart();
    Test.assertEqual(pref.selected,2); Test.assert(view.menuTitle.equals("设置"));
    view.onStart(); view.onBack(); Test.assert(view.menuTitle.equals("设置"));
    view.onBack(); Test.assert(view.menuTitle.equals("地图菜单"));
    r.start(pref.sport()); view.performAction("activity_types");
    Test.assert(view.menuTitle.equals("地图菜单")); Test.assert(view.notice!=null);
    Test.assertEqual(pref.selected,2); Test.assertEqual(r.creates,1);
    return true;
}
