// Regressions for Safari caption updates when extension messages or DOM timers stall.
// A deterministic clock drives the real scripts; the DOM only models media/track APIs.
// Rendering remains covered by ContentScriptTests.swift in actual WebKit.
//
//   node Tools/CaptionPollingTests.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const contentSource = readFileSync(new URL("../TranslateCaptions/content.js", import.meta.url), "utf8");
const backgroundSource = readFileSync(new URL("../TranslateCaptions/background.js", import.meta.url), "utf8");
const HOLD = Symbol("pending response");
const active = (text, session = "A", extra = {}) => ({ active: true, session, language: "zh-Hans", text, ...extra });

// Drain nested async continuations (runtime message, poll, scheduler). No real-time sleeps.
async function flush() {
    for (let i = 0; i < 20; ++i) await Promise.resolve();
}

function observe(promise) {
    const result = { settled: false };
    Promise.resolve(promise).then(
        (value) => Object.assign(result, { settled: true, value }),
        (error) => Object.assign(result, { settled: true, error }),
    );
    return result;
}

class Clock {
    now = 1_000_000;
    nextID = 1;
    timers = new Map();
    videos = [];

    setTimeout = (callback, delay = 0, ...args) => {
        const id = this.nextID++;
        this.timers.set(id, { at: this.now + Math.max(0, Number(delay) || 0), callback, args });
        return id;
    };

    clearTimeout = (id) => { this.timers.delete(id); };

    moveTo(time) {
        const elapsed = (time - this.now) / 1000;
        for (const video of this.videos) {
            if (!video.paused && !video.ended) video.currentTime += elapsed;
        }
        this.now = time;
    }

    async advance(milliseconds, { runTimers = true } = {}) {
        const end = this.now + milliseconds;
        if (runTimers) {
            for (let iterations = 0; ; ++iterations) {
                assert.ok(iterations < 10_000, "scheduler created an unbounded timer loop");
                const next = [...this.timers.entries()]
                    .filter(([, timer]) => timer.at <= end)
                    .sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
                if (!next) break;
                const [id, timer] = next;
                this.timers.delete(id);
                this.moveTo(Math.max(this.now, timer.at));
                timer.callback(...timer.args);
                await flush();
            }
        }
        this.moveTo(end);
        await flush();
    }

    globals() {
        const clock = this;
        return {
            Date: class extends Date {
                constructor(...args) { super(...(args.length ? args : [clock.now])); }
                static now() { return clock.now; }
            },
            performance: { now: () => clock.now },
            setTimeout: this.setTimeout,
            clearTimeout: this.clearTimeout,
        };
    }
}

class Events {
    listeners = new Map();

    addEventListener(type, callback, options = {}) {
        const entries = this.listeners.get(type) || [];
        entries.push({ callback, once: typeof options === "object" && options.once });
        this.listeners.set(type, entries);
    }

    removeEventListener(type, callback) {
        this.listeners.set(type, (this.listeners.get(type) || []).filter((entry) => entry.callback !== callback));
    }

    emit(type, target = this) {
        for (const entry of [...(this.listeners.get(type) || [])]) {
            if (entry.once) this.removeEventListener(type, entry.callback);
            entry.callback({ type, target });
        }
    }
}

class Element extends Events {
    attributes = new Map();
    setAttribute(name, value) { this.attributes.set(name, String(value)); }
    removeAttribute(name) { this.attributes.delete(name); }
    hasAttribute(name) { return this.attributes.has(name); }
    toggleAttribute(name, force = !this.hasAttribute(name)) {
        if (force) this.setAttribute(name, "");
        else this.removeAttribute(name);
        return force;
    }
}

class Cue {
    endTimeWrites = 0;
    constructor(startTime, endTime, text) {
        this.startTime = startTime;
        this._endTime = endTime;
        this.text = text;
    }
    get endTime() { return this._endTime; }
    set endTime(value) { this._endTime = value; this.endTimeWrites++; }
}

class Track {
    mode = "disabled";
    cues = [];
    constructor(kind, label, language, video) {
        Object.assign(this, { kind, label, language, video });
    }
    addCue(cue) { this.cues.push(cue); }
    removeCue(cue) {
        const index = this.cues.indexOf(cue);
        if (index < 0) throw new Error("Cue is not in the track");
        this.cues.splice(index, 1);
    }
    get activeCues() {
        if (this.mode === "disabled") return [];
        return this.cues.filter((cue) => cue.startTime <= this.video.currentTime && this.video.currentTime < cue.endTime);
    }
}

class Video extends Element {
    tagName = "VIDEO";
    currentTime = 10;
    paused = false;
    ended = false;
    muted = false;
    volume = 1;
    readyState = 4;
    isConnected = true;
    textTracks = [];
    player = new Element();
    getBoundingClientRect() { return { width: 640, height: 360 }; }
    closest(selector) { return selector === ".plyr" ? this.player : null; }
    addTextTrack(kind, label, language) {
        const track = new Track(kind, label, language, this);
        this.textTracks.push(track);
        return track;
    }
}

function contentHarness(replyForCall = () => HOLD) {
    const clock = new Clock();
    const video = new Video();
    clock.videos.push(video);
    const document = new Events();
    Object.assign(document, {
        hidden: false,
        visibilityState: "visible",
        fullscreenElement: null,
        webkitFullscreenElement: null,
        documentElement: new Element(),
        querySelector: (selector) => selector === "video" ? video : null,
        querySelectorAll: (selector) => selector === "video" ? [video] : [],
    });
    const window = new Events();
    const requests = [];
    const harness = { clock, document, window, video, requests, replyForCall };
    const runtime = {
        sendMessage(message) {
            const request = { message, at: clock.now, settled: false };
            requests.push(request);
            const promise = new Promise((resolve, reject) => {
                request.resolve = (reply) => { request.settled = true; resolve(reply); };
                request.reject = (error) => { request.settled = true; reject(error); };
            });
            const reply = harness.replyForCall(requests.length - 1);
            if (reply !== HOLD) Promise.resolve().then(() => {
                if (reply instanceof Error) request.reject(reply);
                else request.resolve(reply);
            });
            return promise;
        },
    };
    const globals = {
        ...clock.globals(),
        document,
        window,
        browser: { runtime },
        VTTCue: Cue,
        console,
        __translateCaptionsTestHooks: (hooks) => { harness.hooks = hooks; },
        addEventListener: window.addEventListener.bind(window),
        removeEventListener: window.removeEventListener.bind(window),
    };
    vm.runInNewContext(contentSource, globals, { filename: "content.js" });
    harness.text = () => video.textTracks.flatMap((track) => track.mode === "showing" ? track.activeCues : []).map((cue) => cue.text).join("\n");
    harness.event = async (type, target = video) => {
        document.emit(type, target);
        await flush();
    };
    return harness;
}

function backgroundHarness(replyForCall = () => HOLD) {
    const clock = new Clock();
    const requests = [];
    const harness = { clock, requests, replyForCall };
    const runtime = {
        onMessage: { addListener: (listener) => { harness.receive = listener; } },
        sendNativeMessage(applicationID, message) {
            const request = { applicationID, message, at: clock.now, settled: false };
            requests.push(request);
            const promise = new Promise((resolve, reject) => {
                request.resolve = (reply) => { request.settled = true; resolve(reply); };
                request.reject = (error) => { request.settled = true; reject(error); };
            });
            const reply = harness.replyForCall(requests.length - 1);
            if (reply !== HOLD) Promise.resolve().then(() => {
                if (reply instanceof Error) request.reject(reply);
                else request.resolve(reply);
            });
            return promise;
        },
    };
    vm.runInNewContext(backgroundSource, { ...clock.globals(), browser: { runtime }, console }, { filename: "background.js" });
    harness.read = () => harness.receive({ type: "captions" });
    return harness;
}

const tests = [];
function test(name, callback) { tests.push({ name, callback }); }

test("a hung caption message times out and live updates resume without seeking", async () => {
    const h = contentHarness((index) => index === 0 ? active("First caption") : index === 1 ? HOLD : active("Recovered caption"));
    h.hooks.start();
    await flush();
    assert.equal(h.text(), "First caption");
    await h.clock.advance(350);
    assert.equal(h.requests.length, 2);
    await h.clock.advance(6000);
    assert.ok(h.requests.length >= 3, "the hung request must release the polling loop");
    assert.equal(h.requests[1].settled, false, "recovery must not depend on the original promise settling");
    assert.equal(h.text(), "Recovered caption");
    h.hooks.stop();
});

test("a late reply from a timed-out request cannot replace a newer caption", async () => {
    const h = contentHarness((index) => index === 0 ? HOLD : active("Current caption", "B"));
    h.hooks.start();
    await h.clock.advance(6000);
    assert.equal(h.text(), "Current caption");
    h.requests[0].resolve(active("Late obsolete caption", "A"));
    await flush();
    assert.equal(h.text(), "Current caption");
    assert.equal(h.hooks.state.session, "B");
    h.hooks.stop();
});

test("media timeupdate recovers both a suspended DOM timer and an overdue request", async () => {
    const h = contentHarness((index) => index === 0 ? active("Before suspension") : index === 1 ? HOLD : active("After suspension"));
    h.hooks.start();
    await flush();
    await h.clock.advance(350);
    assert.equal(h.requests.length, 2);
    await h.clock.advance(12_000, { runTimers: false });
    assert.equal(h.text(), "", "the finite cue must expire while DOM timers are suspended");
    await h.event("timeupdate");
    await h.clock.advance(1500);
    assert.ok(h.requests.length >= 3, "media progress must restart the overdue request");
    assert.equal(h.text(), "After suspension");
    h.hooks.stop();
});

test("media progress recovers an initial hung request before a caption track was attached", async () => {
    const h = contentHarness((index) => index === 0 ? HOLD : active("First recovered caption"));
    h.hooks.start();
    await flush();
    assert.equal(h.hooks.state.video, null);
    assert.equal(h.video.textTracks.length, 0);
    await h.clock.advance(12_000, { runTimers: false });
    await h.event("timeupdate");
    assert.equal(h.requests.length, 1, "the timeout still observes retry backoff");
    await h.clock.advance(1500, { runTimers: false });
    await h.event("timeupdate");
    assert.equal(h.requests.length, 2, "the watched video must wake polling before a track exists");
    assert.equal(h.requests[0].settled, false);
    assert.equal(h.text(), "First recovered caption");
    h.hooks.stop();
});

test("media progress resumes an inactive detached feed while DOM timers remain suspended", async () => {
    const h = contentHarness((index) => index === 0 ? active("Before inactive feed") : index === 1 ? { active: false } : active("Newly active feed", "B"));
    h.hooks.start();
    await flush();
    assert.equal(h.text(), "Before inactive feed");
    await h.clock.advance(350);
    assert.equal(h.requests.length, 2);
    assert.equal(h.hooks.state.video, null, "the inactive reply detaches the previous video");
    assert.equal(h.text(), "");
    await h.clock.advance(3500, { runTimers: false });
    await h.event("timeupdate");
    assert.equal(h.requests.length, 3, "the watched video must wake the detached feed after its idle interval");
    assert.equal(h.text(), "Newly active feed");
    h.hooks.stop();
});

test("playing, seeked, visibility, pageshow, and focus wake suspended polling", async () => {
    for (const type of ["playing", "seeked", "visibilitychange", "pageshow", "focus"]) {
        const h = contentHarness((index) => active(index === 0 ? "Before wake" : `After ${type}`));
        h.hooks.start();
        await flush();
        await h.clock.advance(9000, { runTimers: false });
        if (type === "pageshow" || type === "focus") {
            h.window.emit(type);
            await flush();
        } else await h.event(type, type === "visibilitychange" ? h.document : h.video);
        await h.clock.advance(500);
        assert.equal(h.text(), `After ${type}`, `${type} must resume polling`);
        h.hooks.stop();
    }
});

test("frequent media events do not launch parallel caption requests", async () => {
    const h = contentHarness();
    h.hooks.start();
    await flush();
    for (let i = 0; i < 100; ++i) {
        await h.event("timeupdate");
        await h.event("playing");
        await h.clock.advance(10);
    }
    assert.equal(h.requests.length, 1);
    h.requests[0].resolve(active("One request"));
    await flush();
    assert.equal(h.text(), "One request");
    h.hooks.stop();
});

test("repeated transport failures back off despite frequent media wake events", async () => {
    const h = contentHarness(() => ({ status: "transport-error" }));
    h.hooks.start();
    await flush();
    for (let i = 0; i < 120; ++i) {
        await h.event("playing");
        await h.event("timeupdate");
        await h.clock.advance(250);
    }
    assert.ok(h.requests.length >= 4 && h.requests.length <= 6, `retry backoff made ${h.requests.length} requests in 30 seconds`);
    assert.equal(h.text(), "");
    h.hooks.stop();
});

test("same-text polling keeps one cue and avoids rewriting its endTime every poll", async () => {
    const h = contentHarness(() => active("Stable caption"));
    h.hooks.start();
    await flush();
    const cue = h.video.textTracks[0].cues[0];
    assert.equal(cue.endTime - h.video.currentTime, 6, "cue duration must remain bounded");
    await h.clock.advance(2500);
    assert.equal(cue.endTimeWrites, 0, "unchanged cues with ample remaining duration must stay untouched");
    await h.clock.advance(7500);
    assert.equal(h.video.textTracks[0].cues.length, 1);
    assert.equal(h.video.textTracks[0].cues[0], cue);
    assert.ok(cue.endTimeWrites > 0 && cue.endTimeWrites <= 3, `expected occasional renewal, got ${cue.endTimeWrites} writes`);
    assert.equal(h.text(), "Stable caption");
    h.hooks.stop();
});

test("temporary transport errors preserve captions but stale cache cannot revive after seeking", async () => {
    const h = contentHarness((index) => index === 0 ? active("Recent caption") : { status: "transport-error" });
    await h.hooks.poll();
    const cue = h.video.textTracks[0].cues[0];
    const delay = await h.hooks.poll();
    assert.ok(delay >= 350, "failed transport should back off instead of busy-looping");
    assert.equal(h.video.textTracks[0].cues[0], cue);
    assert.equal(h.text(), "Recent caption");
    await h.clock.advance(30_000, { runTimers: false });
    h.video.currentTime = 1;
    await h.event("seeked");
    await h.hooks.poll();
    assert.equal(h.text(), "");
    assert.equal(h.video.textTracks[0].cues.length, 0, "expired cached text must not produce a new cue after a seek");
    h.hooks.stop();
});

test("the native feed expiry limits cache freshness even when playback time barely moves", async () => {
    const h = contentHarness((index) => index === 0 ? active("Expiring caption", "A", { expiresAt: h.clock.now / 1000 + 1 }) : { status: "transport-error" });
    h.video.paused = true;
    await h.hooks.poll();
    assert.equal(h.text(), "Expiring caption");
    await h.clock.advance(1500, { runTimers: false });
    await h.event("seeked");
    await h.hooks.poll();
    assert.equal(h.text(), "", "wall-clock expiry must hide the caption on a paused media timeline");
    h.hooks.stop();
});

test("a delayed reply whose native feed already expired never appears as a new caption", async () => {
    const h = contentHarness(() => active("Already expired", "A", { expiresAt: h.clock.now / 1000 - 1 }));
    await h.hooks.poll();
    assert.equal(h.text(), "", "an expired native reply must be rejected before creating a visible cue");
    assert.equal(h.video.textTracks.reduce((count, track) => count + track.cues.length, 0), 0);
    h.hooks.stop();
});

test("an explicitly inactive feed immediately removes the caption and restores idle polling", async () => {
    const h = contentHarness((index) => index === 0 ? active("Stopped caption") : { active: false, status: "stopped" });
    await h.hooks.poll();
    assert.equal(h.text(), "Stopped caption");
    assert.equal(await h.hooks.poll(), 3000);
    assert.equal(h.video.textTracks[0].cues.length, 0);
    assert.equal(h.video.textTracks[0].mode, "disabled");
    assert.equal(h.video.hasAttribute("data-translate-live-captions"), false);
    assert.equal(h.video.player.hasAttribute("data-translate-native-captions"), false);
});

test("the background bridge shares one pending native read across page frames", async () => {
    const h = backgroundHarness();
    const replies = Array.from({ length: 20 }, () => h.read());
    await flush();
    assert.equal(h.requests.length, 1);
    h.requests[0].resolve(active("Shared caption"));
    const values = await Promise.all(replies);
    assert.ok(values.every((reply) => reply.text === "Shared caption"));
    const cached = observe(h.read());
    await flush();
    assert.equal(h.requests.length, 1, "an immediate follow-up can reuse the short native-read cache");
    assert.equal(cached.settled, true, "cached reads should complete without another native reply");
    await h.clock.advance(200);
    h.replyForCall = () => active("New native caption");
    assert.equal((await h.read()).text, "New native caption");
    assert.equal(h.requests.length, 2);
});

test("a native timeout returns a transport error, backs off, and permits a new native read", async () => {
    const h = backgroundHarness((index) => index === 0 ? HOLD : active("Recovered native caption"));
    const first = observe(h.read());
    await h.clock.advance(8500);
    assert.equal(first.settled, true, "a native timeout must settle its caller");
    assert.equal(first.value?.status, "transport-error");
    assert.equal(h.requests[0].settled, false);
    const before = h.requests.length;
    const cooled = Array.from({ length: 30 }, () => observe(h.read()));
    await flush();
    assert.equal(h.requests.length, before, "retry cooldown must absorb frame/event request bursts");
    assert.ok(cooled.every((result) => result.settled && result.value?.status === "transport-error"));
    await h.clock.advance(31_000);
    assert.equal((await h.read()).text, "Recovered native caption");
    h.requests[0].resolve(active("Late native caption"));
    await flush();
    assert.equal((await h.read()).text, "Recovered native caption", "a late native result must not poison the bridge cache");
});

test("unresolved native calls remain bounded and capacity returns after an old call finishes", async () => {
    const h = backgroundHarness();
    const first = observe(h.read());
    await h.clock.advance(8500);
    assert.equal(first.value?.status, "transport-error");
    await h.clock.advance(2500);
    const second = observe(h.read());
    await h.clock.advance(8500);
    assert.equal(second.value?.status, "transport-error");
    await h.clock.advance(40_000);
    const blocked = Array.from({ length: 40 }, () => observe(h.read()));
    await flush();
    assert.equal(h.requests.length, 2, "JS timeouts must not accumulate uncancelled native calls indefinitely");
    assert.ok(blocked.every((result) => result.settled && result.value?.status === "transport-error"));
    h.requests[0].resolve(active("Obsolete native result"));
    await flush();
    const recovered = observe(h.read());
    assert.equal(h.requests.length, 3, "finishing an old native call must free a request slot");
    h.requests[2].resolve(active("New native result"));
    await flush();
    assert.equal(recovered.value?.text, "New native result");
});

let failures = 0;
for (const { name, callback } of tests) {
    try {
        await callback();
        console.log(`PASS ${name}`);
    } catch (error) {
        failures++;
        console.error(`FAIL ${name}\n${error.stack || error}`);
    }
}
console.log(`${tests.length - failures}/${tests.length} caption polling regressions passed (${fileURLToPath(import.meta.url)})`);
process.exitCode = failures ? 1 : 0;
