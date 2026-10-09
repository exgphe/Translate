// Shows the Translate app's live captions as a subtitle track on the page's main video.
//
// Safari renders the TextTrack, including its native fullscreen caption layer. Custom players
// such as Plyr hide WebKit's caption container, so captions.css restores it only while our
// track is showing. The app decides the text; this script keeps one current cue.

(() => {
    "use strict";

    const ACTIVE_POLL_MS = 350;
    const IDLE_POLL_MS = 3000;
    const NO_VIDEO_RECHECK_MS = 2000;
    const CUE_SECONDS = 6;
    const CUE_REFRESH_SECONDS = 3;
    const REQUEST_TIMEOUT_MS = 4000;
    const REPLY_GRACE_MS = 8000;
    const TRACK_LABEL = "Live translation";
    const VIDEO_ATTRIBUTE = "data-translate-live-captions";
    const PLAYER_ATTRIBUTE = "data-translate-native-captions";

    const state = { video: null, player: null, track: null, cue: null, text: "", session: null };
    let fullscreenVideo = null;
    let latestCaption = null;
    let pollingEnabled = false;
    let timer = null;
    let pending = null;
    let nextPollAt = 0;
    let failures = 0;
    let lastReportAt = 0;
    const progress = { status: "idle", requests: 0, responses: 0, timeouts: 0, lastReplyAt: null, mediaEvents: 0, lastMediaEventAt: null, source: null };

    function diagnostics() {
        return {
            ...progress, pending: Boolean(pending), nextPollAt, failures,
            reportedAt: Date.now(), replyAge: progress.lastReplyAt === null ? null : (Date.now() - progress.lastReplyAt) / 1000,
            hidden: document.hidden,
            fullscreen: Boolean(fullscreenVideo || state.video?.webkitDisplayingFullscreen || state.video?.webkitPresentationMode === "fullscreen"),
            mediaTime: state.video?.currentTime ?? null,
            trackMode: state.track?.mode ?? null,
            cues: state.track?.cues?.length ?? 0,
            activeCues: state.track?.activeCues?.length ?? 0,
        };
    }

    function report() {
        // Metadata only: a remote Safari inspector can diagnose stalls without logging text.
        document.documentElement?.setAttribute("data-translate-caption-status", JSON.stringify(diagnostics()));
        lastReportAt = Date.now();
    }

    function area(video) {
        const rect = video.getBoundingClientRect();
        return Math.max(0, rect.width) * Math.max(0, rect.height);
    }

    // Native video fullscreen doesn't necessarily set document.fullscreenElement.
    function pickVideo(root = document) {
        const videos = Array.from(root.querySelectorAll("video"));
        if (videos.length === 0) return null;
        const native = videos.find((v) => v === fullscreenVideo || v.webkitDisplayingFullscreen || v.webkitPresentationMode === "fullscreen");
        if (native) return native;
        const fullscreen = document.fullscreenElement || document.webkitFullscreenElement;
        const inFullscreen = fullscreen && videos.filter((v) => fullscreen === v || fullscreen.contains(v));
        const visible = videos.filter((v) => area(v) > 0);
        const candidates = inFullscreen?.length ? inFullscreen : visible;
        if (candidates.length === 0) return null;
        // Small autoplay advertisements shouldn't win over the main player. Prefer audible
        // playback, otherwise use size (including a paused main video).
        const audible = candidates.filter((v) => !v.paused && !v.ended && v.readyState > 1 && !v.muted && v.volume > 0);
        const pool = audible.length > 0 ? audible : candidates;
        return pool.reduce((best, video) => (area(video) > area(best) ? video : best));
    }

    function nativeRendering(enabled) {
        if (state.video) state.video.toggleAttribute(VIDEO_ATTRIBUTE, enabled);
        const player = enabled ? state.video?.closest(".plyr") : null;
        if (state.player && state.player !== player) state.player.removeAttribute(PLAYER_ATTRIBUTE);
        if (player) player.setAttribute(PLAYER_ATTRIBUTE, "");
        state.player = player;
    }

    function clearCue() {
        if (state.track && state.cue) {
            try { state.track.removeCue(state.cue); } catch (_) { /* already gone */ }
        }
        state.cue = null;
        state.text = "";
    }

    function detach() {
        clearCue();
        nativeRendering(false);
        if (state.track) state.track.mode = "disabled";
        state.video = null;
        state.track = null;
    }

    function trackFor(video, language) {
        if (state.video === video && state.track && Array.from(video.textTracks).includes(state.track)) return state.track;
        detach();
        // Reuse our track if this video already has one (for example after a page script reset).
        let track = Array.from(video.textTracks).find((t) => t.label === TRACK_LABEL);
        if (!track) track = video.addTextTrack("subtitles", TRACK_LABEL, language || "");
        state.video = video;
        state.track = track;
        return track;
    }

    /// Puts `text` on the main video. Empty text removes the caption.
    function show(text, language) {
        if (!text) {
            clearCue();
            nativeRendering(false);
            if (state.track) state.track.mode = "disabled";
            return;
        }
        const video = pickVideo();
        if (!video) { detach(); return; }
        const track = trackFor(video, language);
        if (track.mode !== "showing") track.mode = "showing"; // players sometimes switch tracks off
        nativeRendering(true);

        const now = video.currentTime;
        if (!Number.isFinite(now)) return;
        if (state.cue && text === state.text && state.cue.startTime <= now && now < state.cue.endTime && Array.from(track.cues || []).includes(state.cue)) {
            // Changing endTime removes/re-adds the active cue in WebKit. Avoid rebuilding
            // the native caption layer on every poll when the text has not changed.
            if (state.cue.endTime - now <= CUE_REFRESH_SECONDS) state.cue.endTime = now + CUE_SECONDS;
            return;
        }
        clearCue();
        const cue = new VTTCue(Math.max(0, now - 0.05), now + CUE_SECONDS, text);
        track.addCue(cue);
        state.cue = cue;
        state.text = text;
    }

    function refresh() {
        if (!latestCaption) return;
        if (Date.now() >= latestCaption.expiresAt) {
            latestCaption = null;
            show("", "");
            return;
        }
        try { show(latestCaption.text, latestCaption.language); } catch (_) { /* next poll retries */ }
    }

    function failedRequest(timedOut) {
        failures += 1;
        if (timedOut) progress.timeouts += 1;
        progress.status = timedOut ? "timeout" : "transport-error";
        refresh();
        report();
        return Math.min(30_000, 1000 * 2 ** Math.min(failures - 1, 5));
    }

    function accept(reply) {
        // A bridge failure is different from a feed that explicitly stopped. Keep the last
        // reply only for a bounded grace period, while retrying with backoff.
        if (!reply || typeof reply.active !== "boolean" || reply.status === "transport-error") return failedRequest(false);
        failures = 0;
        progress.responses += 1;
        progress.lastReplyAt = Date.now();
        progress.status = reply.status || (reply.active ? "active" : "inactive");
        progress.source = reply.diagnostics || null;
        if (!reply.active) {
            latestCaption = null;
            detach();
            state.session = null;
            report();
            return IDLE_POLL_MS;
        }
        if (reply.session !== state.session) { clearCue(); state.session = reply.session; }
        latestCaption = {
            text: reply.text || "", language: reply.language,
            expiresAt: Math.min(Date.now() + REPLY_GRACE_MS, Number.isFinite(reply.expiresAt) ? reply.expiresAt * 1000 : Infinity),
        };
        refresh();
        report();
        return ACTIVE_POLL_MS;
    }

    // Each request has a deadline independent of the Promise returned by Safari. Media
    // events also check it, so a throttled DOM timeout cannot hold the loop indefinitely.
    function poll() {
        if (pending) return pending.promise;
        let resolve;
        const promise = new Promise((done) => { resolve = done; });
        const request = { promise, deadline: Date.now() + REQUEST_TIMEOUT_MS, timeout: null, expire: null };
        pending = request;
        progress.requests += 1;
        const finish = (reply, timedOut = false, transportError = false) => {
            if (pending !== request) return; // a late reply must not overwrite newer captions
            clearTimeout(request.timeout);
            pending = null;
            let delay;
            try { delay = timedOut || transportError ? failedRequest(timedOut) : accept(reply); }
            catch (_) { delay = failedRequest(false); }
            nextPollAt = Date.now() + delay;
            resolve(delay);
            if (pollingEnabled) schedule();
        };
        request.expire = () => finish(null, true);
        request.timeout = setTimeout(request.expire, REQUEST_TIMEOUT_MS);
        try {
            Promise.resolve(browser.runtime.sendMessage({ type: "captions" })).then(
                (reply) => finish(reply), () => finish(null, false, true)
            );
        } catch (_) { finish(null, false, true); }
        report();
        return promise;
    }

    function schedule() {
        clearTimeout(timer);
        const fullscreen = fullscreenVideo || state.video?.webkitDisplayingFullscreen || state.video?.webkitPresentationMode === "fullscreen";
        const delay = Math.max(0, nextPollAt - Date.now());
        timer = setTimeout(wake, document.hidden && !fullscreen ? Math.max(IDLE_POLL_MS, delay) : delay);
    }

    function wake(force = false) {
        if (!pollingEnabled) return;
        refresh();
        if (pending && Date.now() >= pending.deadline) pending.expire();
        if (!pending && (Date.now() >= nextPollAt || (force && failures === 0))) {
            clearTimeout(timer);
            void poll();
        }
        if (Date.now() - lastReportAt >= 1000) report();
    }

    function start() { pollingEnabled = true; nextPollAt = 0; wake(); }
    function stop() {
        pollingEnabled = false;
        clearTimeout(timer);
        if (pending) { pending.expire(); }
        latestCaption = null;
        detach();
    }

    document.addEventListener("webkitbeginfullscreen", (event) => {
        if (event.target.tagName !== "VIDEO") return;
        fullscreenVideo = event.target;
        refresh();
        wake(true);
    }, true);
    document.addEventListener("webkitendfullscreen", (event) => {
        if (event.target === fullscreenVideo) fullscreenVideo = null;
        refresh();
        wake(true);
    }, true);
    for (const event of ["fullscreenchange", "webkitfullscreenchange", "webkitpresentationmodechanged", "loadedmetadata", "seeked", "play", "playing", "visibilitychange"]) {
        document.addEventListener(event, () => { refresh(); wake(true); }, true);
    }
    document.addEventListener("timeupdate", (event) => {
        // A first request can stall before there is a track, and an inactive feed detaches
        // it. The video being played must still be able to wake polling in those states.
        if (event.target === state.video || event.target === fullscreenVideo || event.target === pickVideo()) {
            progress.mediaEvents += 1;
            progress.lastMediaEventAt = Date.now();
            wake();
        }
    }, true);
    window.addEventListener("pageshow", () => wake(true));
    window.addEventListener("focus", () => wake(true));

    // Frames without a video stay quiet until one appears.
    function waitForVideo() {
        if (document.querySelector("video")) start();
        else setTimeout(waitForVideo, NO_VIDEO_RECHECK_MS);
    }

    if (globalThis.__translateCaptionsTestHooks) {
        globalThis.__translateCaptionsTestHooks({ show, pickVideo, poll, state, start, stop, wake, diagnostics });
    } else {
        waitForVideo();
    }
})();
