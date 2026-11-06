using Toybox.Lang;
using Toybox.Position;
using Toybox.System;
using Toybox.Test;

// Exercise MapView's real timer callback with deterministic compass input.
class HeadingTimerTestView extends MapView {
    var injectedCompass = null;

    function initialize() {
        MapView.initialize();
    }

    function readCompass() as Void {
        compass = injectedCompass;
    }
}

(:test)
function stationaryHeadingTimerUpdatesInBothDirections(logger as Test.Logger) as Lang.Boolean {
    var view = new HeadingTimerTestView();
    view.fix.accept(34.5, 109.5, Position.QUALITY_GOOD, 100, System.getTimer());
    view.currentSpeed = 0.0;
    view.injectedCompass = 30.0;
    view.onHeadingTick();
    Test.assert(view.heading > 11.9 && view.heading < 12.1);
    view.injectedCompass = -30.0;
    view.onHeadingTick();
    Test.assert(view.heading > -4.9 && view.heading < -4.7);
    return true;
}

(:test)
function stationaryHeadingTimerHandlesWrapAndMissingCompass(logger as Test.Logger) as Lang.Boolean {
    var view = new HeadingTimerTestView();
    view.fix.accept(34.5, 109.5, Position.QUALITY_GOOD, 100, System.getTimer());
    view.heading = 359.0;
    view.injectedCompass = 1.0;
    view.onHeadingTick();
    Test.assert(view.heading > 359.7 && view.heading < 359.9);
    var previous = view.heading;
    view.injectedCompass = null;
    view.onHeadingTick();
    Test.assertEqual(view.heading, previous);
    return true;
}

(:test)
function headingTimerLeavesMovingAndStaleHeadingUnchanged(logger as Test.Logger) as Lang.Boolean {
    var view = new HeadingTimerTestView();
    view.fix.accept(34.5, 109.5, Position.QUALITY_GOOD, 100, System.getTimer());
    view.heading = 90.0;
    view.injectedCompass = 180.0;
    view.currentSpeed = 2.0;
    view.onHeadingTick();
    Test.assertEqual(view.heading, 90.0);
    view.currentSpeed = 0.0;
    view.fix.accept(null, null, Position.QUALITY_LAST_KNOWN, 100, System.getTimer());
    view.onHeadingTick();
    Test.assertEqual(view.heading, 90.0);
    return true;
}

(:test)
function stationaryHeadingTimerSurvivesRepeatedCallbacks(logger as Test.Logger) as Lang.Boolean {
    var view = new HeadingTimerTestView();
    view.fix.accept(34.5, 109.5, Position.QUALITY_GOOD, 100, System.getTimer());
    for (var n = 0; n < 120; n++) {
        view.injectedCompass = (n % 2 == 0) ? 0.0 : 30.0;
        view.onHeadingTick();
    }
    Test.assert(view.heading >= 0.0 && view.heading <= 30.0);
    return true;
}
