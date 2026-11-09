using Toybox.Communications;

module PhoneTileTransport {
    function send(request) {
        var url = OnlineSource.url(request.zoom, request.xyz[0], request.xyz[1]);
        Communications.makeImageRequest(url, null, {
            :maxWidth => 256, :maxHeight => 256,
            :dithering => Communications.IMAGE_DITHERING_NONE,
            :palette => [0xFFFFFF, 0x000000, 0xEEEEEE, 0xCCCCCC, 0x999999, 0x666666, 0xFFFFCC, 0xFFCC66,
                         0xCC9933, 0x99CC99, 0x669966, 0x336633, 0x99CCFF, 0x6699CC, 0xFF9999, 0xCC6666]
        }, request.method(:receive));
    }
}
