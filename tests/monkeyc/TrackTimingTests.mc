using Toybox.Lang;
using Toybox.Position;
using Toybox.Test;

function assertContinuousTrack(track, expectedPoints) {
    Test.assertEqual(track.size(), expectedPoints);
    for (var i=0; i<track.size(); i++) { Test.assert(track.point(i)!=null); }
}

(:test)
function drivingAndCyclingDoNotBreakAtFiftyMeters(logger as Test.Logger) as Lang.Boolean {
    var car=new TrackModel();
    for (var i=0; i<6; i++) {
        // About 61m per three seconds, consistent with ordinary road travel.
        car.acceptSample(34.5+i*0.00055,109.5,i==0,100+i*3,1000+i*3000,20.4);
    }
    assertContinuousTrack(car,6); Test.assert(car.distance>300 && car.distance<315);
    var bike=new TrackModel();
    bike.acceptSample(34.5,109.5,true,100,1000,8.5);
    bike.acceptSample(34.5006,109.5,false,108,9000,8.5);
    assertContinuousTrack(bike,2); Test.assert(bike.distance>65 && bike.distance<68);
    return true;
}

(:test)
function trackUsesSampleTimeWhenCallbacksAreBatched(logger as Test.Logger) as Lang.Boolean {
    var t=new TrackModel();
    t.acceptSample(34.5,109.5,true,100,1000,25.0);
    t.acceptSample(34.501,109.5,false,105,1000,25.0);
    assertContinuousTrack(t,2); Test.assert(t.distance>110);
    return true;
}

(:test)
function trackReceptionGapAndUntimedDuplicateStayDisconnected(logger as Test.Logger) as Lang.Boolean {
    var t=new TrackModel();
    t.acceptSample(34.5,109.5,true,100,1000,20.0);
    t.acceptSample(34.5001,109.5,false,101,12000,20.0);
    Test.assertEqual(t.distance,0.0); Test.assert(t.point(1)==null);
    t.clear();
    t.acceptSample(34.5,109.5,true,null,1000,20.0);
    t.acceptSample(34.5001,109.5,false,null,1000,20.0);
    Test.assertEqual(t.distance,0.0); Test.assert(t.point(1)==null);
    return true;
}

(:test)
function trackMissingSpeedOrSourceStillHandlesMovingSamples(logger as Test.Logger) as Lang.Boolean {
    var t=new TrackModel();
    t.acceptSample(34.5,109.5,true,null,1000,null);
    t.acceptSample(34.501,109.5,false,null,4000,null);
    assertContinuousTrack(t,2); Test.assert(t.distance>110);
    t.acceptSample(34.5016,109.5,false,null,7000,-1.0);
    assertContinuousTrack(t,3);
    return true;
}

(:test)
function trackRejectsRealJumpsWithoutInflatingDistance(logger as Test.Logger) as Lang.Boolean {
    var t=new TrackModel();
    t.acceptSample(34.5,109.5,true,100,1000,1.0);
    t.acceptSample(34.5001,109.5,false,101,2000,1.0);
    var before=t.distance;
    t.acceptSample(34.501,109.5,false,102,3000,1.0);
    Test.assertEqual(t.distance,before); Test.assert(t.point(2)==null);
    t.acceptSample(34.52,109.5,false,103,4000,60.0);
    Test.assertEqual(t.distance,before); Test.assert(t.point(4)==null);
    return true;
}

(:test)
function trackClockGapsPauseAndRestoreStillBreak(logger as Test.Logger) as Lang.Boolean {
    var t=new TrackModel();
    t.acceptSample(34.5,109.5,true,100,1000,20.0);
    t.acceptSample(34.5001,109.5,false,111,2000,20.0);
    Test.assertEqual(t.distance,0.0); Test.assert(t.point(1)==null);
    t.acceptSample(34.5002,109.5,false,112,500,20.0);
    Test.assertEqual(t.distance,0.0); Test.assert(t.point(3)==null);
    t.breakSegment();
    t.acceptSample(34.501,109.5,false,113,1500,20.0);
    Test.assertEqual(t.distance,0.0); Test.assert(t.point(5)==null);
    var restored=new TrackModel(); restored.restore(t.exportPoints(),0);
    restored.acceptSample(34.502,109.5,false,114,2500,20.0);
    Test.assertEqual(restored.distance,0.0);
    Test.assert(restored.point(restored.size()-2)==null);
    return true;
}

(:test)
function weakFixStillBreaksTimedDrivingTrack(logger as Test.Logger) as Lang.Boolean {
    var fix=new FixState(), t=new TrackModel();
    Test.assert(fix.accept(34.5,109.5,Position.QUALITY_GOOD,100,1000));
    t.acceptSample(fix.latitude,fix.longitude,fix.startsSegment,100,1000,20.0);
    Test.assert(!fix.accept(34.5005,109.5,Position.QUALITY_POOR,103,4000));
    Test.assert(fix.accept(34.501,109.5,Position.QUALITY_GOOD,106,7000));
    t.acceptSample(fix.latitude,fix.longitude,fix.startsSegment,106,7000,20.0);
    Test.assertEqual(t.distance,0.0); Test.assert(t.point(1)==null);
    return true;
}
