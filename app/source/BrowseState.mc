class BrowseState {
    var following = true;
    var axis = 0;

    function initialize() {}
    function pan() { following = false; }
    function toggleAxis() { axis = (axis + 1) % 3; }
    // First BACK leaves browsing; another BACK can exit the app normally.
    function backToFollow() {
        if (following) { return false; }
        following = true;
        return true;
    }
}
