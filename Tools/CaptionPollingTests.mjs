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

    emit(type, target = this, properties = {}) {
        for (const entry of [...(this.listeners.get(type) || [])]) {
            if (entry.once) this.removeEventListener(type, entry.callback);
            entry.callback({ type, target, ...properties });
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

function storageHarness(initial = {}) {
    const values = { ...initial };
    const listeners = [];
    const changes = {
        addListener: (listener) => { listeners.push(listener); },
    };
    const local = {
        async get(keys) {
            if (keys === null || keys === undefined) return { ...values };
            if (typeof keys === "string") return keys in values ? { [keys]: values[keys] } : {};
            if (Array.isArray(keys)) return Object.fromEntries(keys.filter((key) => key in values).map((key) => [key, values[key]]));
            return { ...keys, ...Object.fromEntries(Object.keys(keys).filter((key) => key in values).map((key) => [key, values[key]])) };
        },
        async set(update) {
            const changed = {};
            for (const [key, value] of Object.entries(update)) {
                if (values[key] === value) continue;
                changed[key] = { oldValue: values[key], newValue: value };
                values[key] = value;
            }
            if (Object.keys(changed).length) for (const listener of listeners) listener(changed, "local");
        },
    };
    return { local, onChanged: changes, values };
}

function contentHarness(replyForCall = () => HOLD, options = {}) {
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
        querySelector: (selector) => selector === "video" && options.hasVideo !== false ? video : null,
        querySelectorAll: (selector) => selector === "video" && options.hasVideo !== false ? [video] : [],
    });
    const window = new Events();
    const requests = [];
    const storage = storageHarness(options.enabled === undefined ? {} : { captionEmbeddingEnabled: options.enabled });
    const messageListeners = [];
    const reports = [];
    const harness = { clock, document, window, video, requests, reports, storage, replyForCall };
    const runtime = {
        onMessage: { addListener: (listener) => { messageListeners.push(listener); } },
        sendMessage(message) {
            if (message?.type === "caption-page-report") {
                reports.push(message.page);
                return Promise.resolve({ received: true });
            }
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
        browser: { runtime, storage },
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
    harness.message = async (message) => {
        const result = messageListeners.map((listener) => listener(message, {})).find((reply) => reply !== undefined);
        await flush();
        return result;
    };
    return harness;
}

function backgroundHarness(replyForCall = () => HOLD) {
    const clock = new Clock();
    const requests = [];
    const storage = storageHarness();
    const frames = new Map();
    const broadcasts = [];
    const tabUpdated = [];
    const tabRemoved = [];
    const harness = { clock, requests, replyForCall, storage, broadcasts };
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
    const tabs = {
        async query() { return [...new Set([...frames.values()].map((frame) => frame.tabId))].map((id) => ({ id })); },
        async sendMessage(tabId, message) {
            broadcasts.push({ tabId, message });
            const matching = [...frames.values()].filter((frame) => frame.tabId === tabId);
            if (!matching.length) throw new Error("No receiver in this tab");
            const replies = await Promise.all(matching.map((frame) => frame.receive(message)));
            return replies.find((reply) => reply !== undefined);
        },
        onUpdated: { addListener: (listener) => { tabUpdated.push(listener); } },
        onRemoved: { addListener: (listener) => { tabRemoved.push(listener); } },
    };
    vm.runInNewContext(backgroundSource, { ...clock.globals(), browser: { runtime, storage, tabs }, console }, { filename: "background.js" });
    harness.read = (sender = {}) => harness.receive({ type: "captions" }, sender);
    harness.message = (message, sender = {}) => harness.receive(message, sender);
    harness.addFrame = (tabId, frameId, receive) => { frames.set(`${tabId}:${frameId}`, { tabId, frameId, receive }); };
    harness.removeFrames = (tabId) => { for (const [key, frame] of frames) if (frame.tabId === tabId) frames.delete(key); };
    harness.report = (tabId, frameId, page) => harness.message({ type: "caption-page-report", page }, { tab: { id: tabId }, frameId });
    harness.navigate = (tabId) => { for (const listener of tabUpdated) listener(tabId, { status: "loading" }, { id: tabId }); };
    harness.removeTab = (tabId) => { for (const listener of tabRemoved) listener(tabId); };
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
    await flush(); // startup storage read precedes creation of the native request timer
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

test("a new page read expires an overdue native request even when background timers were suspended", async () => {
    const h = backgroundHarness((index) => index === 0 ? HOLD : active("Resumed background caption"));
    const first = observe(h.read({ tab: { id: 7 }, frameId: 0 }));
    await flush();
    await h.clock.advance(12_000, { runTimers: false });
    const nextPage = observe(h.read({ tab: { id: 8 }, frameId: 0 }));
    await flush();
    assert.equal(first.settled, true, "a later reader must check the old native deadline independently of setTimeout");
    assert.equal(first.value?.status, "transport-error");
    assert.equal(nextPage.settled, true, "the new page cannot inherit a Promise whose deadline already passed");
    assert.equal(nextPage.value?.status, "transport-error", "the timeout still observes retry cooldown");
    assert.equal(h.requests.length, 1);
    await h.clock.advance(2500, { runTimers: false });
    assert.equal((await h.read({ tab: { id: 8 }, frameId: 0 })).text, "Resumed background caption");
    assert.equal(h.requests.length, 2);
});

test("native reservations expire without waiting for an obsolete native Promise to settle", async () => {
    const h = backgroundHarness();
    const first = observe(h.read());
    await flush();
    await h.clock.advance(8500);
    assert.equal(first.value?.status, "transport-error");
    await h.clock.advance(2500);
    const second = observe(h.read());
    await flush();
    await h.clock.advance(8500);
    assert.equal(second.value?.status, "transport-error");
    const blocked = Array.from({ length: 40 }, () => observe(h.read()));
    await flush();
    assert.equal(h.requests.length, 2, "retry bursts must remain bounded while the failed read cools down");
    assert.ok(blocked.every((result) => result.settled && result.value?.status === "transport-error"));
    await h.clock.advance(4500);
    h.replyForCall = () => active("New native result", "B");
    const recovered = observe(h.read());
    await flush();
    assert.equal(h.requests.length, 3, "the 20-second logical reservation must not block all future native reads");
    assert.equal(recovered.value?.text, "New native result");
    assert.equal(recovered.value?.bridge.requests, 3);
    assert.equal(recovered.value?.bridge.timeouts, 2);
    assert.equal(recovered.value?.bridge.replies, 1);
    assert.ok(recovered.value?.bridge.expiredLeases >= 1, "bridge metadata must distinguish expired logical reservations from completed native calls");
    assert.ok(h.requests.slice(0, 2).every((request) => !request.settled), "expired reservations are not evidence of native cancellation");
    h.requests[0].resolve(active("Obsolete native result"));
    await flush();
    const cached = observe(h.read());
    await flush();
    assert.equal(h.requests.length, 3, "an obsolete native settlement must not discard the healthy current cache");
    assert.equal(cached.value?.text, "New native result", "a late old native result must not overwrite the recovered feed");
});

test("navigation recovers a new document after the former page exhausted native request capacity", async () => {
    const h = backgroundHarness();
    const sender = { tab: { id: 7 }, frameId: 0 };
    const first = observe(h.read(sender));
    await flush();
    await h.clock.advance(8500);
    assert.equal(first.value?.status, "transport-error");
    await h.clock.advance(2500);
    const second = observe(h.read(sender));
    await flush();
    await h.clock.advance(8500);
    assert.equal(second.value?.status, "transport-error");
    assert.equal(h.requests.length, 2);
    h.navigate(7);
    h.replyForCall = () => active("Second page caption", "B");
    assert.equal((await h.read(sender)).status, "transport-error", "navigation cannot bypass the current transport cooldown");
    assert.equal(h.requests.length, 2);
    let recovered;
    for (let elapsed = 0; elapsed < 60_000 && !recovered?.active; elapsed += 500) {
        await h.clock.advance(500);
        recovered = await h.read(sender);
    }
    assert.equal(recovered?.text, "Second page caption", "a new document must not inherit an unbounded old native-capacity stall");
    assert.equal(h.requests.length, 3, "a bounded recovery probe must give the new document fresh captions");
    assert.ok(h.requests.slice(0, 2).every((request) => !request.settled), "recovery cannot depend on obsolete native requests settling");
});

test("closing the old tab cannot leave a newly opened tab permanently blocked by old native requests", async () => {
    const h = backgroundHarness();
    const first = observe(h.read({ tab: { id: 7 }, frameId: 0 }));
    await flush();
    await h.clock.advance(8500);
    assert.equal(first.value?.status, "transport-error");
    await h.clock.advance(2500);
    const second = observe(h.read({ tab: { id: 7 }, frameId: 0 }));
    await flush();
    await h.clock.advance(8500);
    assert.equal(second.value?.status, "transport-error");
    h.removeTab(7);
    h.replyForCall = () => active("New tab caption", "B");
    const sender = { tab: { id: 8 }, frameId: 0 };
    assert.equal((await h.read(sender)).status, "transport-error", "closing a tab cannot bypass the current transport cooldown");
    assert.equal(h.requests.length, 2);
    let recovered;
    for (let elapsed = 0; elapsed < 60_000 && !recovered?.active; elapsed += 500) {
        await h.clock.advance(500);
        recovered = await h.read(sender);
    }
    assert.equal(recovered?.text, "New tab caption", "closing the last stalled page must release the next page's retry path");
    assert.equal(h.requests.length, 3);
    assert.ok(h.requests.slice(0, 2).every((request) => !request.settled));
});

test("persistent native failures keep making globally limited recovery probes across navigation", async () => {
    const h = backgroundHarness();
    for (let elapsed = 0; elapsed < 120_000; elapsed += 250) {
        const tabId = elapsed % 500 === 0 ? 7 : 8;
        h.navigate(tabId);
        if (elapsed % 5000 === 0) h.removeTab(tabId);
        const burst = Array.from({ length: 20 }, () => observe(h.read({ tab: { id: tabId }, frameId: 0 })));
        await flush();
        await h.clock.advance(250);
        assert.ok(burst.filter((result) => result.settled).every((result) => result.value?.status === "transport-error"));
    }
    assert.ok(h.requests.length >= 4 && h.requests.length <= 8, `expected bounded probes, got ${h.requests.length} native starts in two minutes`);
    for (let index = 1; index < h.requests.length; ++index) {
        assert.ok(h.requests[index].at - h.requests[index - 1].at >= 10_000, "failure recovery probes must be globally spaced by at least 10 seconds");
    }
    assert.ok(h.requests.every((request) => !request.settled), "probe recovery must not require any old native Promise to finish");
    const obsolete = [...h.requests];
    h.replyForCall = () => active("Healthy caption after prolonged interruption", "B");
    await h.clock.advance(31_000);
    const healthy = await h.read({ tab: { id: 9 }, frameId: 0 });
    assert.equal(healthy.text, "Healthy caption after prolonged interruption");
    for (const request of obsolete) request.resolve(active("Late obsolete native caption", "A"));
    await flush();
    assert.equal((await h.read()).text, "Healthy caption after prolonged interruption", "retired native replies must not poison a newly healthy connection");
});

test("pagehide cancels a pending content read and pageshow requests fresh captions", async () => {
    const h = contentHarness((index) => index === 0 ? active("Before navigation", "A") : HOLD);
    h.hooks.start();
    await flush();
    await h.clock.advance(350);
    const pending = observe(h.hooks.poll());
    const oldRequest = h.requests.at(-1);
    const requestsBeforeHide = h.requests.length;
    const timeoutsBeforeHide = h.hooks.diagnostics().timeouts;
    h.window.emit("pagehide", h.window, { persisted: true });
    await flush();
    assert.equal(pending.settled, true, "entering BFCache must cancel the page's pending poll");
    assert.equal(h.hooks.diagnostics().timeouts, timeoutsBeforeHide, "page suspension is not a native timeout");
    assert.equal(h.text(), "", "a suspended page must not preserve its caption cue");
    h.replyForCall = () => active("Restored page caption", "B");
    await h.clock.advance(10_000);
    await h.event("timeupdate");
    await h.event("playing");
    assert.equal(h.requests.length, requestsBeforeHide, "a page in BFCache must not restart polling from media events");
    h.window.emit("pageshow", h.window, { persisted: true });
    await flush();
    assert.equal(h.requests.length, requestsBeforeHide + 1, "pageshow must issue a fresh read immediately");
    assert.equal(h.text(), "Restored page caption");
    oldRequest.resolve(active("Obsolete pre-navigation reply", "A"));
    await flush();
    assert.equal(h.text(), "Restored page caption", "the former pending reply cannot overwrite the restored document");
    h.hooks.stop();
});

test("content diagnostics retain the native transport reason and bridge counters without caption text", async () => {
    const h = contentHarness((index) => index === 0
        ? { status: "transport-error", reason: "native-timeout", bridge: { requests: 2, replies: 0, timeouts: 2, expiredLeases: 1, reservations: 1, pending: false } }
        : active("Sensitive caption content", "PRIVATE-SESSION", { bridge: { requests: 3, replies: 1, timeouts: 2, expiredLeases: 1, reason: null } }));
    await h.hooks.poll();
    const interrupted = h.hooks.diagnostics();
    assert.equal(interrupted.transportReason, "native-timeout");
    assert.equal(interrupted.bridge.requests, 2);
    assert.equal(interrupted.bridge.timeouts, 2);
    assert.equal(interrupted.responses, 0);
    await h.hooks.poll();
    const recovered = h.hooks.diagnostics();
    assert.equal(recovered.transportReason, null);
    assert.equal(recovered.bridge.replies, 1);
    assert.equal(recovered.responses, 1);
    const report = h.document.documentElement.attributes.get("data-translate-caption-status");
    assert.equal(report.includes("Sensitive caption content"), false);
    assert.equal(report.includes("PRIVATE-SESSION"), false);
    h.hooks.stop();
});

test("pageshow starts a fresh content read instead of retaining the former document's retry delay", async () => {
    const h = contentHarness(() => ({ status: "transport-error", reason: "native-timeout" }));
    h.hooks.start();
    await flush();
    await h.clock.advance(12_000);
    assert.ok(h.hooks.diagnostics().failures >= 4);
    assert.ok(h.hooks.diagnostics().nextPollAt > h.clock.now, "the failed page must currently be backing off");
    h.window.emit("pagehide", h.window, { persisted: true });
    await flush();
    const before = h.requests.length;
    h.replyForCall = () => active("Fresh restored caption", "B");
    h.window.emit("pageshow", h.window, { persisted: true });
    await flush();
    assert.equal(h.requests.length, before + 1, "restoring a page must discard its local retry delay while the background keeps the global limits");
    assert.equal(h.text(), "Fresh restored caption");
    assert.equal(h.hooks.diagnostics().failures, 0);
    h.hooks.stop();
});

test("pageshow respects a disabled embedding setting and does not restart suspended polling", async () => {
    const h = contentHarness(() => active("Must remain hidden"));
    h.hooks.start();
    await flush();
    h.window.emit("pagehide", h.window, { persisted: true });
    await flush();
    await h.storage.local.set({ captionEmbeddingEnabled: false });
    const before = h.requests.length;
    h.window.emit("pageshow", h.window, { persisted: true });
    await flush();
    await h.event("playing");
    await h.event("timeupdate");
    await h.clock.advance(10_000);
    assert.equal(h.requests.length, before, "restoring BFCache must not override the user's display toggle");
    assert.equal(h.text(), "");
    assert.equal(h.hooks.pageStatus().enabled, false);
    h.hooks.stop();
});

test("enabling embedding during page suspension waits for pageshow", async () => {
    const h = contentHarness(() => active("Fresh after restore"), { enabled: false });
    await h.hooks.initialize();
    await flush();
    h.window.emit("pagehide", h.window, { persisted: true });
    await flush();
    await h.storage.local.set({ captionEmbeddingEnabled: true });
    await h.clock.advance(5000);
    assert.equal(h.requests.length, 0, "a storage/broadcast toggle must not restart an inactive document");
    assert.equal(h.text(), "");
    h.window.emit("pageshow", h.window, { persisted: true });
    await flush();
    assert.equal(h.requests.length, 1);
    assert.equal(h.text(), "Fresh after restore");
    h.hooks.stop();
});

test("pagehide also suspends no-video discovery until pageshow", async () => {
    const h = contentHarness(() => active("Video appeared"), { hasVideo: false });
    await h.hooks.initialize();
    await flush();
    h.window.emit("pagehide", h.window, { persisted: true });
    await flush();
    h.document.querySelector = (selector) => selector === "video" ? h.video : null;
    h.document.querySelectorAll = (selector) => selector === "video" ? [h.video] : [];
    await h.clock.advance(5000);
    assert.equal(h.requests.length, 0, "the inactive document's video recheck must not launch new native work");
    h.window.emit("pageshow", h.window, { persisted: true });
    await flush();
    assert.equal(h.requests.length, 1);
    assert.equal(h.text(), "Video appeared");
    h.hooks.stop();
});

test("slow setting reads spanning pagehide and pageshow cannot undo a newer storage change", async () => {
    const h = contentHarness(() => active("Must stay disabled"));
    const settingReads = [];
    h.storage.local.get = () => new Promise((resolve) => { settingReads.push(resolve); });
    const initializing = h.hooks.initialize();
    await flush();
    h.window.emit("pagehide", h.window, { persisted: true });
    h.window.emit("pageshow", h.window, { persisted: true });
    await flush();
    assert.equal(settingReads.length, 2, "restoring the document must read its current persisted setting");
    await h.storage.local.set({ captionEmbeddingEnabled: false });
    settingReads[1]({ captionEmbeddingEnabled: true });
    settingReads[0]({ captionEmbeddingEnabled: true });
    await initializing;
    await flush();
    await h.event("playing");
    await h.clock.advance(5000);
    assert.equal(h.hooks.pageStatus().enabled, false, "both stale snapshots must yield to the newer live preference revision");
    assert.equal(h.requests.length, 0);
    assert.equal(h.text(), "");
    h.hooks.stop();
});

test("a pre-pagehide settings snapshot cannot overwrite a newer pageshow settings read", async () => {
    const h = contentHarness(() => active("Must stay disabled"));
    const settingReads = [];
    h.storage.local.get = () => new Promise((resolve) => { settingReads.push(resolve); });
    const initializing = h.hooks.initialize();
    await flush();
    h.window.emit("pagehide", h.window, { persisted: true });
    h.window.emit("pageshow", h.window, { persisted: true });
    await flush();
    settingReads[1]({ captionEmbeddingEnabled: false });
    await flush();
    assert.equal(h.hooks.pageStatus().enabled, false);
    settingReads[0]({ captionEmbeddingEnabled: true });
    await initializing;
    await flush();
    assert.equal(h.hooks.pageStatus().enabled, false, "the older suspended initialization must not replace the restored document's current setting");
    assert.equal(h.requests.length, 0);
    h.hooks.stop();
});

test("a persisted disabled setting prevents startup reads and subtitle rendering", async () => {
    const h = contentHarness(() => active("Must stay hidden"), { enabled: false });
    await h.hooks.initialize();
    await flush();
    h.hooks.start();
    await h.hooks.poll();
    h.hooks.show("A direct render cannot bypass the setting", "zh-Hans");
    await h.event("playing");
    await h.clock.advance(10_000);
    assert.equal(h.requests.length, 0, "disabled pages must not read the caption feed");
    assert.equal(h.text(), "");
    assert.equal(h.video.textTracks.length, 0);
    assert.equal(h.hooks.pageStatus().enabled, false);
    assert.equal(h.hooks.pageStatus().hasVideo, true, "the toggle must not remove video detection");
    assert.ok(h.reports.length >= 1, "disabled pages must still report their state to the popup");
    h.hooks.stop();
});

test("a slow initial setting read cannot undo a newer toggle", async () => {
    const h = contentHarness(() => active("Must stay disabled"));
    let resolveSettings;
    h.storage.local.get = () => new Promise((resolve) => { resolveSettings = resolve; });
    const initializing = h.hooks.initialize();
    await h.message({ type: "caption-embedding-changed", enabled: false });
    resolveSettings({ captionEmbeddingEnabled: true });
    await initializing;
    await h.event("playing");
    await h.clock.advance(5000);
    assert.equal(h.hooks.pageStatus().enabled, false, "the older saved value cannot replace a newer live change");
    assert.equal(h.requests.length, 0);
    assert.equal(h.text(), "");
    h.hooks.stop();
});

test("disabling embedding cancels pending work without timeout and ignores its late reply", async () => {
    const h = contentHarness((index) => index === 0 ? active("Before disabling") : HOLD);
    h.hooks.start();
    await flush();
    assert.equal(h.text(), "Before disabling");
    await h.clock.advance(350);
    assert.equal(h.requests.length, 2);
    const pending = observe(h.hooks.poll());
    const timeouts = h.hooks.diagnostics().timeouts;
    h.hooks.setEmbeddingEnabled(false);
    await flush();
    assert.equal(pending.settled, true, "cancelled polling callers must not hang forever");
    assert.equal(h.hooks.diagnostics().timeouts, timeouts, "a user toggle is not a transport timeout");
    assert.equal(h.text(), "");
    assert.equal(h.video.textTracks[0].cues.length, 0);
    assert.equal(h.video.textTracks[0].mode, "disabled");
    assert.equal(h.video.hasAttribute("data-translate-live-captions"), false);
    assert.equal(h.video.player.hasAttribute("data-translate-native-captions"), false);
    h.requests[1].resolve(active("Late caption from the disabled period"));
    await flush();
    for (const type of ["seeked", "playing", "timeupdate", "webkitbeginfullscreen", "visibilitychange"]) await h.event(type);
    h.window.emit("focus");
    await h.clock.advance(15_000);
    assert.equal(h.requests.length, 2, "media events must not re-enable disabled embedding");
    assert.equal(h.text(), "", "late replies must not recreate a cue after disabling");
    assert.equal(h.hooks.pageStatus().hasCaption, false);
    h.hooks.stop();
});

test("reenabling requests a fresh caption immediately and never restores cached text", async () => {
    const h = contentHarness((index) => index === 0 ? active("Old caption", "A") : HOLD);
    h.hooks.start();
    await flush();
    h.hooks.setEmbeddingEnabled(false);
    await flush();
    const before = h.requests.length;
    h.hooks.setEmbeddingEnabled(true);
    await flush();
    assert.equal(h.requests.length, before + 1, "enabling must not wait for the old polling deadline");
    assert.equal(h.text(), "", "the old caption must stay absent while a fresh read is pending");
    h.requests.at(-1).resolve(active("Fresh caption", "B"));
    await flush();
    assert.equal(h.text(), "Fresh caption");
    assert.equal(h.hooks.state.session, "B");
    h.hooks.stop();
});

test("storage updates and embedding broadcasts apply to already loaded video frames", async () => {
    const h = contentHarness(() => active("Live caption"));
    h.hooks.start();
    await flush();
    await h.storage.local.set({ captionEmbeddingEnabled: false });
    await flush();
    assert.equal(h.text(), "");
    const before = h.requests.length;
    await h.event("playing");
    await h.clock.advance(5000);
    assert.equal(h.requests.length, before);
    await h.message({ type: "caption-embedding-changed", enabled: true });
    assert.equal(h.text(), "Live caption");
    await h.message({ type: "caption-embedding-changed", enabled: false });
    assert.equal(h.text(), "");
    h.hooks.stop();
});

test("page reports include video and rendering state without caption text", async () => {
    const h = contentHarness(() => active("Sensitive live caption", "PRIVATE-SESSION"));
    h.hooks.start();
    await flush();
    const page = await h.message({ type: "caption-page-status-request" });
    assert.equal(page.hasVideo, true);
    assert.equal(page.hasCaption, true);
    assert.equal(page.trackMode, "showing");
    assert.equal(page.activeCues, 1);
    assert.ok(h.reports.length >= 1);
    for (const report of [page, ...h.reports]) {
        const json = JSON.stringify(report);
        assert.equal(json.includes("Sensitive live caption"), false);
        assert.equal(json.includes("PRIVATE-SESSION"), false);
        assert.equal(Object.hasOwn(report, "text"), false);
    }
    h.hooks.stop();
});

test("frames without video report their state without requesting native captions", async () => {
    const h = contentHarness(() => active("No video"), { hasVideo: false });
    await h.hooks.initialize();
    await h.clock.advance(5000);
    assert.equal(h.requests.length, 0);
    assert.equal(h.hooks.pageStatus().hasVideo, false);
    assert.ok(h.reports.length >= 1);
    h.hooks.stop();
});

test("the embedding setting persists and broadcasts to every open tab", async () => {
    const h = backgroundHarness(() => active("Unused"));
    h.addFrame(7, 0, () => undefined);
    h.addFrame(8, 0, () => undefined);
    const result = await h.message({ type: "caption-embedding-set", enabled: false });
    await flush();
    assert.equal(result.enabled, false);
    assert.equal(h.storage.values.captionEmbeddingEnabled, false);
    const broadcast = h.broadcasts.filter((item) => item.message.type === "caption-embedding-changed");
    assert.deepEqual([...new Set(broadcast.map((item) => item.tabId))].sort(), [7, 8]);
    assert.ok(broadcast.every((item) => item.message.enabled === false));
    assert.equal(h.requests.length, 0, "changing the display setting does not read the native feed");
});

test("disabled embedding suppresses page reads while the popup still reports the app source", async () => {
    const h = backgroundHarness(() => active("App is still translating", "A", { status: "active" }));
    await h.message({ type: "caption-embedding-set", enabled: false });
    assert.equal((await h.read()).active, false);
    assert.equal(h.requests.length, 0, "disabled content frames cannot keep polling the native bridge");
    h.addFrame(7, 0, (message) => message.type === "caption-page-status-request" ? h.report(7, 0, {
        enabled: false, hasVideo: true, status: "disabled", hasCaption: false, playingVideo: true,
    }) : undefined);
    const status = await h.message({ type: "caption-popup-status", tabId: 7 });
    assert.equal(status.enabled, false);
    assert.equal(status.source.status, "active", "the app may keep producing captions while display is off");
    assert.equal(status.page.status, "disabled");
    assert.equal(status.page.hasCaption, false);
    assert.equal(h.requests.length, 1);
});

test("popup status prefers the frame rendering captions and never exposes native text", async () => {
    const h = backgroundHarness(() => active("Sensitive native caption", "PRIVATE-SESSION", { status: "active", diagnostics: { audioBufferCount: 5 } }));
    const blank = { enabled: true, hasVideo: false, status: "no-video", hasCaption: false, playingVideo: false, fullscreen: false, trackMode: null, activeCues: 0 };
    const playing = { enabled: true, hasVideo: true, status: "active", hasCaption: true, playingVideo: true, fullscreen: true, trackMode: "showing", activeCues: 1 };
    h.addFrame(7, 0, (message) => message.type === "caption-page-status-request" ? h.report(7, 0, blank) : undefined);
    h.addFrame(7, 4, (message) => message.type === "caption-page-status-request" ? h.report(7, 4, playing) : undefined);
    const status = await h.message({ type: "caption-popup-status", tabId: 7 });
    assert.equal(status.enabled, true, "a missing saved setting defaults to embedding on");
    assert.equal(status.source.status, "active");
    assert.equal(status.source.hasText, true);
    assert.equal(status.page.available, true);
    assert.equal(status.page.hasVideo, true);
    assert.equal(status.page.hasCaption, true);
    assert.equal(status.page.activeCues, 1);
    assert.equal(status.page.trackMode, "showing");
    const json = JSON.stringify(status);
    assert.equal(json.includes("Sensitive native caption"), false);
    assert.equal(json.includes("PRIVATE-SESSION"), false);
    assert.equal(Object.hasOwn(status.source, "text"), false);
    assert.equal(Object.hasOwn(status.source, "session"), false);
});

test("popup receives saved caption languages even when the app is stopped, without arbitrary native fields", async () => {
    const h = backgroundHarness(() => ({ active: false, status: "stopped", text: "Private captions", configuration: {
        spokenLanguage: "ja", targetLanguage: "zh-Hans", translationEnabled: true, apiKey: "private", text: "private"
    } }));
    const status = await h.message({ type: "caption-popup-status" });
    assert.equal(status.source.status, "stopped");
    assert.deepEqual(JSON.parse(JSON.stringify(status.source.configuration)), {
        spokenLanguage: "ja", targetLanguage: "zh-Hans", translationEnabled: true
    });
    assert.ok(!JSON.stringify(status).includes("private"));
    assert.ok(!JSON.stringify(status).includes("Private captions"));
});

test("popup rejects malformed language metadata without losing source status", async () => {
    const h = backgroundHarness(() => ({ active: true, status: "active", text: "Hello", configuration: {
        spokenLanguage: "<script>", targetLanguage: "zh-Hans", translationEnabled: true
    } }));
    const status = await h.message({ type: "caption-popup-status" });
    assert.equal(status.source.configuration, null);
    assert.equal(status.source.status, "active");
});

test("popup refresh failure and navigation cannot reuse a previous page's caption state", async () => {
    const h = backgroundHarness(() => active("Caption"));
    const page = { enabled: true, hasVideo: true, status: "active", hasCaption: true, playingVideo: true, fullscreen: false, trackMode: "showing", activeCues: 1 };
    h.addFrame(7, 0, (message) => message.type === "caption-page-status-request" ? h.report(7, 0, page) : undefined);
    assert.equal((await h.message({ type: "caption-popup-status", tabId: 7 })).page.hasCaption, true);
    h.removeFrames(7);
    assert.equal((await h.message({ type: "caption-popup-status", tabId: 7 })).page.available, false, "a failed refresh must not show an old rendering state");
    h.report(7, 0, page);
    h.navigate(7);
    assert.equal((await h.message({ type: "caption-popup-status", tabId: 7 })).page.available, false);
    h.report(7, 0, page);
    h.removeTab(7);
    assert.equal((await h.message({ type: "caption-popup-status", tabId: 7 })).page.available, false);
});

test("navigation during a popup refresh rejects the former document's delayed reply", async () => {
    const h = backgroundHarness(() => active("Caption"));
    let resolvePage;
    h.addFrame(7, 0, () => new Promise((resolve) => { resolvePage = resolve; }));
    const status = observe(h.message({ type: "caption-popup-status", tabId: 7 }));
    await flush();
    assert.equal(status.settled, false);
    h.navigate(7);
    resolvePage({ available: true, enabled: true, hasVideo: true, hasCaption: true, status: "active", trackMode: "showing", activeCues: 1 });
    await flush();
    assert.equal(status.settled, true);
    assert.equal(status.value.page.available, false, "a loading tab must not display metadata from its former document");
});

test("a popup refresh expires an overdue page read when background timers were suspended", async () => {
    const h = backgroundHarness(() => active("Caption"));
    const currentPage = { available: true, enabled: true, hasVideo: true, hasCaption: false, status: "active", trackMode: "showing", activeCues: 0 };
    let queries = 0;
    let resolveOldPage;
    h.addFrame(7, 0, (message) => {
        if (message.type !== "caption-page-status-request") return undefined;
        queries += 1;
        if (queries === 1) return new Promise((resolve) => { resolveOldPage = resolve; });
        return currentPage;
    });
    const oldStatus = observe(h.message({ type: "caption-popup-status", tabId: 7 }));
    await flush();
    assert.equal(queries, 1);
    assert.equal(oldStatus.settled, false);
    await h.clock.advance(3000, { runTimers: false });
    const freshStatus = observe(h.message({ type: "caption-popup-status", tabId: 7 }));
    await flush();
    assert.equal(oldStatus.settled, true, "the new popup request must check the old page read's actual deadline");
    assert.equal(oldStatus.value.page.available, false, "an expired page query must not retain stale rendering state");
    assert.equal(queries, 2, "the new refresh must issue a fresh page query instead of sharing the overdue Promise");
    assert.equal(freshStatus.settled, true);
    assert.equal(freshStatus.value.page.available, true);
    assert.equal(freshStatus.value.page.hasCaption, false);
    resolveOldPage({ ...currentPage, hasCaption: true, activeCues: 1 });
    await flush();
    assert.equal(oldStatus.value.page.available, false, "the expired caller must ignore its late reply");
    assert.equal(freshStatus.value.page.hasCaption, false, "the obsolete page reply cannot overwrite the new rendering state");
    const verified = await h.message({ type: "caption-popup-status", tabId: 7 });
    assert.equal(verified.page.hasCaption, false);
    assert.equal(verified.page.activeCues, 0);
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
