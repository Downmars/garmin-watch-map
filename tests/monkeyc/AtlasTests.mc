using Toybox.Application.Storage;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Test;

(:test)
function atlasSwitchViaMenuAndRestore(logger as Test.Logger) as Lang.Boolean {
    Storage.deleteValue("atlas.selection.v1");
    if (MapCatalog.REGIONS.size() < 2 || MapCatalog.REGIONS[1][5].size() == 0) {
        // The single-region fallback still works in legacy source-only builds.
        return true;
    }
    var view = new MapView();
    view.track.accept(34.5,109.5,true);
    var revision = view.track.revision;
    view.openMenu(); view.onDown(); view.onStart(); view.onDown(); view.onStart();
    Test.assert(view.atlas.region[0].equals(MapCatalog.REGIONS[1][0]));
    Test.assert(!view.browse.following);
    view.openMenu(); view.onDown(); view.onDown(); view.onStart(); view.onDown(); view.onStart();
    Test.assertEqual(view.atlas.routeIndex,0); Test.assert(view.atlas.points != null);
    Test.assertEqual(view.centerGX,view.atlas.points[0]);
    var bitmap=Graphics.createBufferedBitmap({:width=>260,:height=>260}).get();
    view.zoomTo(1); prepareTestTiles(view); view.onUpdate(bitmap.getDc());
    Test.assert(!view.tiles.error);
    var reopened = new MapView();
    Test.assert(reopened.atlas.region[0].equals(view.atlas.region[0]));
    Test.assertEqual(reopened.atlas.routeIndex,0);
    view.openMenu(); view.onDown(); view.onStart(); view.onUp(); view.onStart();
    Test.assertEqual(view.atlas.routeIndex,-1); Test.assert(view.atlas.points==null);
    if (view.atlas.region[5].size() > 1) {
        view.openMenu(); view.performAction("routes"); view.onDown(); view.onStart();
        var first = view.atlas.points;
        view.openMenu(); view.performAction("routes"); view.onDown(); view.onStart();
        Test.assertEqual(view.atlas.routeIndex,1); Test.assert(first != view.atlas.points);
        prepareTestTiles(view); view.onUpdate(bitmap.getDc());
        view.openMenu(); view.performAction("routes"); view.onDown(); view.onStart();
        Test.assertEqual(view.atlas.routeIndex,-1); Test.assert(view.atlas.points == null);
    }
    Test.assertEqual(view.track.revision,revision);
    Storage.deleteValue("atlas.selection.v1");
    logger.debug("ATLAS_SWITCH_RENDER_REOPEN_PASS");
    return true;
}
