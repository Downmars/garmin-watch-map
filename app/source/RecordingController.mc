using Toybox.Activity;
using Toybox.ActivityRecording;
using Toybox.System;

class RecordingController {
    const IDLE = 0;
    const RUNNING = 1;
    const PAUSED = 2;
    const SAVED = 3;
    const DISCARDED = 4;
    const INTERRUPTED = 5;
    const HISTORY = 6;
    var state = IDLE;
    var session = null;
    var error = null;
    var totalMs = 0;
    var startedAt = 0;

    function initialize() {}
    function now() { return System.getTimer(); }
    function createSession(sport) {
        return ActivityRecording.createSession({:name => "Weinan Map", :sport => sport});
    }
    function hasSession() { return session != null; }
    function canAccumulate() { return state == IDLE || state == RUNNING; }
    function elapsedMs() {
        var delta = (state == RUNNING) ? now() - startedAt : 0;
        return totalMs + ((delta < 0) ? 0 : delta);
    }
    function start(sport) {
        error = null;
        if (session != null) { error = "请先处理当前运动"; return false; }
        try {
            session = createSession(sport);
            if (session == null) { error = "无法创建运动"; return false; }
            if (session.isRecording()) { session = null; error = "请先结束已有运动"; return false; }
            state = PAUSED; totalMs = 0;
            return resume();
        } catch (e) { error = "开始失败，请重试"; return false; }
    }
    function pause() {
        error = null;
        if (session == null || state != RUNNING) { return false; }
        try {
            if (!session.stop()) { error = "暂停失败，请重试"; return false; }
            totalMs = elapsedMs(); state = PAUSED; return true;
        } catch (e) { error = "暂停失败，请重试"; return false; }
    }
    function resume() {
        error = null;
        if (session == null || state != PAUSED) { return false; }
        try {
            if (!session.start()) { error = "开始失败，请重试"; return false; }
            startedAt = now(); state = RUNNING; return true;
        } catch (e) { error = "开始失败，请重试"; return false; }
    }
    function finish(keep) {
        error = null;
        if (session == null) { return false; }
        if (state == RUNNING && !pause()) { return false; }
        try {
            var ok = keep ? session.save() : session.discard();
            if (!ok) { error = keep ? "保存失败，请重试" : "丢弃失败，请重试"; return false; }
            session = null; state = keep ? SAVED : DISCARDED; return true;
        } catch (e) { error = keep ? "保存失败，请重试" : "丢弃失败，请重试"; return false; }
    }
    function label() {
        if (state == RUNNING) { return "记录中"; }
        if (state == PAUSED) { return "已暂停"; }
        if (state == SAVED) { return "FIT已保存"; }
        if (state == DISCARDED) { return "已丢弃"; }
        if (state == HISTORY) { return "历史轨迹"; }
        return "未记录";
    }
}
