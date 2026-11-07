// The generic atlas builder replaces this single-region fallback in its scratch copy.
// Region: [id, name, center lat/lon, layers, routes]. Route: [id, name, JSON resource].
module MapCatalog {
    var REGIONS = [["weinan", "渭南", MapData.CENTER_LAT, MapData.CENTER_LON, MapLayers.ALL, []]];
}
