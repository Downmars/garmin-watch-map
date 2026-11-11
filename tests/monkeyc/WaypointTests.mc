using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Test;

(:test)
function waypointLayerClipsAndBoundsLabel(logger as Test.Logger) as Lang.Boolean {
    var layer = new WaypointLayer();
    layer.items = [[100,100,"测试补给地点名称很长",1,"饮水"], [9000,9000,"远处",3,""]];
    layer.selected = 0;
    var bitmap = Graphics.createBufferedBitmap({:width=>260,:height=>260}).get();
    layer.draw(bitmap.getDc(),0,0,1.0,260,260);
    Test.assertEqual(layer.visibleCount,1);
    Test.assert(layer.shortName(0).length() <= 10);
    layer.draw(bitmap.getDc(),9000,9000,1.0,260,260);
    Test.assertEqual(layer.visibleCount,1);
    Test.assert(layer.load(null)); Test.assertEqual(layer.items.size(),0);
    return true;
}

(:test)
function waypointMenuJumpKeepsTrackAndRecording(logger as Test.Logger) as Lang.Boolean {
    var view = new MapView();
    view.atlas.waypoints.items = [[view.centerGX,view.centerGY,"补给",1,"饮水点"]];
    view.track.accept(34.5,109.5,true);
    var revision = view.track.revision;
    var state = view.recorder.state;
    view.openMenu(); view.performAction("waypoints");
    Test.assertEqual(view.menuRows.size(),2);
    view.onDown(); view.onStart();
    Test.assertEqual(view.atlas.waypoints.selected,0);
    Test.assert(view.menuTitle.equals("补给"));
    view.onStart();
    Test.assert(!view.menuOpen); Test.assert(!view.browse.following);
    Test.assertEqual(view.track.revision,revision); Test.assertEqual(view.recorder.state,state);
    return true;
}

(:test)
function waypointResourceLoadsOnlyCurrentRegion(logger as Test.Logger) as Lang.Boolean {
    var atlas = new OfflineAtlas();
    Test.assert(atlas.waypoints.items.size()<=32);
    if (MapCatalog.REGIONS.size()>1) {
        atlas.waypoints.selected = 0;
        atlas.chooseRegion(1);
        Test.assertEqual(atlas.waypoints.selected,-1);
        Test.assert(atlas.waypoints.items.size()<=32);
    }
    return true;
}
