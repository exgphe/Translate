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
    const TRACK_LABEL = "Live translation";
    const VIDEO_ATTRIBUTE = "data-translate-live-captions";
    const PLAYER_ATTRIBUTE = "data-translate-native-captions";

    const state = { video: null, player: null, track: null, cue: null, text: "", session: null };
    let fullscreenVideo = null;
    let latestCaption = null;

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
            state.cue.endTime = Math.max(state.cue.endTime, now + CUE_SECONDS);
            return;
        }
        clearCue();
        const cue = new VTTCue(Math.max(0, now - 0.05), now + CUE_SECONDS, text);
        track.addCue(cue);
        state.cue = cue;
        state.text = text;
    }

    async function poll() {
        let reply = null;
        try {
            reply = await browser.runtime.sendMessage({ type: "captions" });
        } catch (_) {
            reply = null;
        }
        if (!reply || !reply.active) {
            latestCaption = null;
            if (state.session !== null) { detach(); state.session = null; }
            return IDLE_POLL_MS;
        }
        if (reply.session !== state.session) {
            clearCue();
            state.session = reply.session;
        }
        latestCaption = { text: reply.text || "", language: reply.language };
        show(latestCaption.text, latestCaption.language);
        return ACTIVE_POLL_MS;
    }

    async function loop() {
        let delay = ACTIVE_POLL_MS;
        try {
            delay = await poll();
        } catch (error) {
            // A player can replace its media or tracks while we are updating them. Retry
            // instead of losing the polling loop for the rest of the page's lifetime.
            console.warn("Translate Live Captions: could not update the subtitle track", error);
        } finally {
            const watchingFullscreen = fullscreenVideo || state.video?.webkitDisplayingFullscreen || state.video?.webkitPresentationMode === "fullscreen";
            setTimeout(loop, document.hidden && !watchingFullscreen ? IDLE_POLL_MS : delay);
        }
    }

    function refresh() {
        if (!latestCaption) return;
        try { show(latestCaption.text, latestCaption.language); } catch (_) { /* next poll retries */ }
    }

    document.addEventListener("webkitbeginfullscreen", (event) => {
        if (event.target.tagName !== "VIDEO") return;
        fullscreenVideo = event.target;
        refresh();
    }, true);
    document.addEventListener("webkitendfullscreen", (event) => {
        if (event.target === fullscreenVideo) fullscreenVideo = null;
        refresh();
    }, true);
    for (const event of ["fullscreenchange", "webkitfullscreenchange", "webkitpresentationmodechanged", "loadedmetadata", "seeked", "play"]) {
        document.addEventListener(event, refresh, true);
    }

    // Frames without a video stay quiet until one appears.
    function waitForVideo() {
        if (document.querySelector("video")) loop();
        else setTimeout(waitForVideo, NO_VIDEO_RECHECK_MS);
    }

    if (globalThis.__translateCaptionsTestHooks) {
        globalThis.__translateCaptionsTestHooks({ show, pickVideo, poll, state });
    } else {
        waitForVideo();
    }
})();
