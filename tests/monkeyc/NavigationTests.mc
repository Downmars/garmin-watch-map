using Toybox.Test;
using Toybox.Lang;
using Toybox.Position;

(:test)
function noFixAndNullCoordinates(logger as Test.Logger) as Lang.Boolean {
    var s = new FixState();
    Test.assertEqual(s.status(0), s.WAITING);
    Test.assert(!s.accept(null, null, Position.QUALITY_GOOD, 100, 0));
    Test.assert(s.latitude == null);
    Test.assert(!s.isCurrent(0));
    return true;
}

(:test)
function unusableQualityNeverBecomesLive(logger as Test.Logger) as Lang.Boolean {
    var s = new FixState();
    Test.assert(!s.accept(34.5, 109.5, null, 100, 0));
    Test.assert(!s.accept(34.5, 109.5, Position.QUALITY_LAST_KNOWN, 100, 0));
    Test.assert(!s.accept(34.5, 109.5, Position.QUALITY_POOR, 100, 0));
    Test.assertEqual(s.status(0), s.WEAK);
    Test.assert(s.latitude == null);
    return true;
}

(:test)
function staleFixExpiresWithoutCallback(logger as Test.Logger) as Lang.Boolean {
    var s = new FixState();
    Test.assert(s.accept(34.5, 109.5, Position.QUALITY_GOOD, 100, 1000));
    Test.assert(s.isCurrent(11000));
    Test.assertEqual(s.status(11001), s.STALE);
    Test.assertEqual(s.latitude, 34.5);
    return true;
}

(:test)
function duplicateAndBackwardSourceTimeCannotRefresh(logger as Test.Logger) as Lang.Boolean {
    var s = new FixState();
    s.accept(34.5, 109.5, Position.QUALITY_GOOD, 100, 1000);
    Test.assert(!s.accept(35.0, 110.0, Position.QUALITY_GOOD, 100, 9000));
    Test.assert(!s.accept(35.0, 110.0, Position.QUALITY_GOOD, 99, 10000));
    Test.assertEqual(s.latitude, 34.5);
    Test.assertEqual(s.status(11001), s.STALE);
    return true;
}

(:test)
function invalidQualityBreaksDistanceSegment(logger as Test.Logger) as Lang.Boolean {
    var s = new FixState();
    s.accept(34.5, 109.5, Position.QUALITY_GOOD, 100, 0);
    Test.assert(s.startsSegment);
    s.accept(34.5001, 109.5, Position.QUALITY_USABLE, 101, 1000);
    Test.assert(!s.startsSegment);
    s.accept(34.5001, 109.5, Position.QUALITY_LAST_KNOWN, 101, 2000);
    Test.assertEqual(s.status(2000), s.STALE);
    s.accept(34.51, 109.5, Position.QUALITY_GOOD, 104, 4000);
    Test.assert(s.startsSegment);
    Test.assert(s.isCurrent(4000));
    return true;
}

(:test)
function longGapAndClockWrapStartNewSegment(logger as Test.Logger) as Lang.Boolean {
    var s = new FixState();
    s.accept(34.5, 109.5, Position.QUALITY_GOOD, 100, 1000);
    s.accept(34.51, 109.5, Position.QUALITY_GOOD, 112, 13000);
    Test.assert(s.startsSegment);
    Test.assertEqual(s.status(500), s.STALE);
    s.accept(34.52, 109.5, Position.QUALITY_GOOD, 113, 500);
    Test.assert(s.startsSegment);
    return true;
}

(:test)
function coordinateRangesAreValidated(logger as Test.Logger) as Lang.Boolean {
    var s = new FixState();
    Test.assert(!s.accept(91.0, 109.5, Position.QUALITY_GOOD, 100, 0));
    Test.assert(!s.accept(34.5, 181.0, Position.QUALITY_GOOD, 101, 0));
    Test.assert(!s.accept(-91.0, 109.5, Position.QUALITY_GOOD, 102, 0));
    Test.assert(s.accept(34.5, 109.5, Position.QUALITY_GOOD, 103, 0));
    return true;
}

(:test)
function missingSourceTimeStillExpires(logger as Test.Logger) as Lang.Boolean {
    var s = new FixState();
    Test.assert(s.accept(34.5, 109.5, Position.QUALITY_GOOD, null, 0));
    Test.assertEqual(s.status(10001), s.STALE);
    return true;
}

(:test)
function weakSignalCannotKeepOldPositionFresh(logger as Test.Logger) as Lang.Boolean {
    var s = new FixState();
    s.accept(34.5, 109.5, Position.QUALITY_GOOD, 100, 0);
    s.accept(34.51, 109.5, Position.QUALITY_POOR, 105, 5000);
    Test.assertEqual(s.status(5000), s.WEAK);
    Test.assertEqual(s.status(10001), s.STALE);
    Test.assertEqual(s.latitude, 34.5);
    return true;
}

(:test)
function browserBackRecentersBeforeExit(logger as Test.Logger) as Lang.Boolean {
    var b = new BrowseState();
    Test.assert(b.following);
    Test.assert(!b.backToFollow());
    b.pan();
    b.toggleAxis();
    Test.assert(!b.following);
    Test.assertEqual(b.axis, 1);
    b.toggleAxis();
    Test.assert(!b.following);
    Test.assertEqual(b.axis, 2);
    b.toggleAxis();
    Test.assertEqual(b.axis, 0);
    Test.assert(b.backToFollow());
    Test.assert(b.following);
    Test.assert(!b.backToFollow());
    return true;
}
