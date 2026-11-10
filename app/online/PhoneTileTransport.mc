using Toybox.Communications;

module PhoneTileTransport {
    function send(request) {
        var url = OnlineSource.url(request.zoom, request.xyz[0], request.xyz[1]);
        Communications.makeImageRequest(url, null, {
            :maxWidth => 256, :maxHeight => 256,
            :dithering => Communications.IMAGE_DITHERING_NONE,
            :palette => MapSource.PALETTE
        }, request.method(:receive));
    }
}
