using Toybox.Lang;
using Toybox.Test;
using Toybox.Graphics;

class TestPhoneTiles extends PhoneTiles {
    var phone=true; var clock=0; var memory=true;
    var sent=[]; var updates=0;
    function initialize() { PhoneTiles.initialize(); }
    function now() { return clock; }
    function isConnected() { return phone; }
    function hasMemory() { return memory; }
    function notify() { updates++; }
    function send(request) { sent.add(request); }
}
class PhoneTestImage {
    var width=256;
    function initialize() {}
    function getWidth() { return width; }
    function getHeight() { return 256; }
}

(:test)
function phoneSuccessDisconnectAndReconnect(logger as Test.Logger) as Lang.Boolean {
    var p=new TestPhoneTiles(); p.prepare(15,400.25,400.25,260,260);
    var image=new PhoneTestImage();
    p.phone=false; p.tick(); Test.assertEqual(p.sent.size(),0);
    p.phone=true; p.tick(); p.tick(); Test.assertEqual(p.sent.size(),1);
    p.received(p.sent[0],200,image); Test.assertEqual(p.ready.size(),1);
    var dc=new FakeTileDc(); p.draw(dc,400.25,400.25);
    Test.assertEqual(dc.draws.size(),1);
    var tile=p.sent[0].xyz;
    Test.assertEqual(dc.draws[0][0],tile[0]*256-401);
    p.tick(); var stale=p.current;
    p.phone=false; p.tick(); Test.assertEqual(p.ready.size(),0);
    p.phone=true; p.tick(); p.received(stale,200,image);
    Test.assertEqual(p.ready.size(),0);
    p.received(p.current,200,image); Test.assertEqual(p.ready.size(),1);
    return true;
}

(:test)
function phoneTimeoutErrorsAndStaleReplies(logger as Test.Logger) as Lang.Boolean {
    var p=new TestPhoneTiles(); p.prepare(15,0,0,260,260); p.tick();
    var old=p.current; var image=new PhoneTestImage();
    p.prepare(13,600,600,260,260);
    p.received(old,200,image); Test.assertEqual(p.ready.size(),0);
    p.tick(); old=p.current;
    p.clock=15001; p.tick(); Test.assert(p.current==null);
    p.tick(); Test.assertEqual(p.sent.size(),2);
    p.clock+=30000; p.tick(); Test.assert(p.current!=null);
    p.received(old,200,image); Test.assertEqual(p.ready.size(),0);
    p.received(p.current,503,null); Test.assertEqual(p.ready.size(),0);
    p.clock+=30000; p.tick();
    image.width=128; p.received(p.current,200,image); Test.assertEqual(p.ready.size(),0);
    p.clock+=30000; p.memory=false; p.tick(); Test.assert(p.current==null);
    return true;
}

(:test)
function phoneKeepsFourTilesAndRejectsAfterHide(logger as Test.Logger) as Lang.Boolean {
    var p=new TestPhoneTiles(); p.prepare(15,255,255,260,260);
    Test.assertEqual(p.wanted.size(),4);
    for(var i=0;i<4;i++){ p.tick(); p.received(p.current,200,new PhoneTestImage()); }
    p.tick(); Test.assertEqual(p.ready.size(),4); Test.assertEqual(p.sent.size(),4);
    p.prepare(15,3000,3000,260,260); Test.assertEqual(p.ready.size(),0);
    p.tick(); var old=p.current; p.stop();
    p.received(old,200,new PhoneTestImage()); Test.assertEqual(p.ready.size(),0);
    return true;
}

(:test)
function mapSwitchesFallbackAtSameViewport(logger as Test.Logger) as Lang.Boolean {
    if (MapCatalog.REGIONS.size()<2) { return true; }
    var view=new MapView(), p=new TestPhoneTiles();
    view.phoneTiles=p;
    var other=MapCatalog.REGIONS[1];
    view.centerGX=MapProjection.x(other[3]); view.centerGY=MapProjection.y(other[2]);
    view.queueMapTiles(); prepareTestTiles(view);
    Test.assert(view.offlineRegion[0].equals(other[0]));
    var x=view.centerGX; var y=view.centerGY;
    var track=view.track; var rec=view.recorder;
    var bitmap=Graphics.createBufferedBitmap({:width=>260,:height=>260}).get();
    p.tick(); p.received(p.current,502,null); view.onUpdate(bitmap.getDc());
    Test.assert(!view.tiles.error); Test.assertEqual(view.centerGX,x); Test.assertEqual(view.centerGY,y);
    p.phone=false; p.tick(); Test.assert(view.recorder==rec && view.track==track);
    view.centerGX=MapProjection.x(-10); view.centerGY=MapProjection.y(20);
    view.clampCenter(); view.queueMapTiles(); view.onUpdate(bitmap.getDc());
    Test.assertEqual(view.centerGX,MapProjection.x(-10)); Test.assertEqual(view.tiles.wanted.size(),0);
    return true;
}
