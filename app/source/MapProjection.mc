using Toybox.Math;

module MapProjection {
    function x(lon) { return (lon + 180.0) / 360.0 * MapData.WORLD; }
    function y(lat) {
        if (lat > 85.05112878) { lat = 85.05112878; }
        if (lat < -85.05112878) { lat = -85.05112878; }
        var rad = lat * Math.PI / 180.0;
        return (1.0 - Math.log(Math.tan(rad) + 1.0 / Math.cos(rad), 2.718281828459045) / Math.PI) / 2.0 * MapData.WORLD;
    }
    function point(lat, lon) { return [x(lon), y(lat)]; }
}
