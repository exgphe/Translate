// Relays caption requests from content scripts to the extension's native handler, which reads
// the captions the Translate app is producing. In Safari only extension pages can use native
// messaging, so content scripts go through here.

const APPLICATION_ID = "wang.xiaolin.Translate"; // required by the API, ignored by Safari
const NATIVE_TIMEOUT_MS = 8000;
const CACHE_MS = 100;
// A native reply may never settle in JS. Keep a bounded
// number of logical reservations, but expire them so lost callbacks cannot lock every tab
// forever. JS cannot cancel the underlying NSExtension request; recovery probes are paced.
const MAX_OUTSTANDING_NATIVE = 2;
const NATIVE_LEASE_MS = 20_000;
const RECOVERY_PROBE_MS = 10_000;
const outstanding = new Set();
let pending = null;
let cached = null;
let cachedAt = 0;
let failures = 0;
let retryAt = 0;
let lastNativeStartAt = -Infinity;
const bridge = { requests: 0, replies: 0, timeouts: 0, expiredLeases: 0, lastReplyAt: null, reason: null };
const SETTING_KEY = "captionEmbeddingEnabled";
const pageReports = new Map();
const pageReads = new Map();
let embeddingEnabled = true;
let preferenceRevision = 0;
const initialRevision = preferenceRevision;
const settingsReady = Promise.resolve(browser.storage?.local.get(SETTING_KEY)).then((settings) => {
    if (preferenceRevision === initialRevision) embeddingEnabled = settings?.[SETTING_KEY] !== false;
}).catch(() => {});

function transportError(reason) {
    return { status: "transport-error", reason, bridge: bridgeStatus(reason) };
}

function bridgeStatus(reason = bridge.reason) {
    return { ...bridge, reason, pending: Boolean(pending), reservations: outstanding.size,
        retryAt, replyAge: bridge.lastReplyAt === null ? null : (Date.now() - bridge.lastReplyAt) / 1000 };
}

function readCaptions() {
    // The background timer may have been suspended. A new page message must check the
    // actual deadline before sharing an old request, even if its timer has not run yet.
    const now = Date.now();
    if (pending && now >= pending.deadline) pending.expire();
    for (const token of outstanding) {
        if (now >= token.leaseExpiresAt) {
            outstanding.delete(token);
            bridge.expiredLeases += 1;
            token.expire();
        }
    }
    if (pending) return pending.promise;
    if (cached && now - cachedAt < CACHE_MS) return Promise.resolve({ ...cached, bridge: bridgeStatus() });
    if (Date.now() < retryAt) return Promise.resolve(transportError("native-retry-backoff"));
    if (outstanding.size >= MAX_OUTSTANDING_NATIVE) return Promise.resolve(transportError("native-requests-pending"));
    if (failures > 0 && now - lastNativeStartAt < RECOVERY_PROBE_MS) return Promise.resolve(transportError("native-recovery-cooldown"));

    const token = { deadline: now + NATIVE_TIMEOUT_MS, leaseExpiresAt: now + NATIVE_LEASE_MS, promise: null, expire: null };
    outstanding.add(token);
    let resolve;
    const promise = new Promise((done) => { resolve = done; });
    token.promise = promise;
    pending = token;
    lastNativeStartAt = now;
    bridge.requests += 1;
    let finished = false;
    const finish = (reply, error) => {
        if (finished) return;
        finished = true;
        clearTimeout(timeout);
        if (pending === token) pending = null;
        if (error || !reply || typeof reply.active !== "boolean") {
            bridge.reason = error || "invalid-native-reply";
            if (error === "native-timeout") bridge.timeouts += 1;
            failures += 1;
            retryAt = Date.now() + Math.min(30_000, 2000 * 2 ** Math.min(failures - 1, 4));
            cached = null;
            resolve(transportError(error || "invalid-native-reply"));
        } else {
            bridge.reason = null;
            bridge.replies += 1;
            bridge.lastReplyAt = Date.now();
            failures = 0;
            retryAt = 0;
            cached = reply;
            cachedAt = Date.now();
            resolve({ ...reply, bridge: bridgeStatus() });
        }
    };
    token.expire = () => finish(null, "native-timeout");
    const timeout = setTimeout(token.expire, NATIVE_TIMEOUT_MS);
    try {
        Promise.resolve(browser.runtime.sendNativeMessage(APPLICATION_ID, { type: "captions" })).then(
            (reply) => { outstanding.delete(token); finish(reply); },
            () => { outstanding.delete(token); finish(null, "native-message-failed"); }
        );
    } catch (_) { outstanding.delete(token); finish(null, "native-message-failed"); }
    return promise;
}

function cleanPage(page) {
    return {
        available: true,
        enabled: page.enabled !== false,
        hasVideo: page.hasVideo === true,
        hasCaption: page.hasCaption === true,
        hasSourceText: page.hasSourceText === true,
        playingVideo: page.playingVideo === true,
        fullscreen: page.fullscreen === true,
        status: ["idle", "active", "inactive", "missing", "stopped", "stale", "disabled", "timeout", "transport-error"].includes(page.status) ? page.status : "idle",
        trackMode: ["disabled", "hidden", "showing"].includes(page.trackMode) ? page.trackMode : null,
        activeCues: Number.isFinite(page.activeCues) ? Math.max(0, page.activeCues) : 0,
        reportedAt: Number.isFinite(page.reportedAt) ? page.reportedAt : Date.now(),
    };
}

function storePage(page, sender) {
    const tabID = sender?.tab?.id;
    if (!page || !Number.isInteger(tabID)) return;
    let frames = pageReports.get(tabID);
    if (!frames) { frames = new Map(); pageReports.set(tabID, frames); }
    frames.set(sender.frameId ?? 0, { ...cleanPage(page), receivedAt: Date.now() });
}

function selectPage(tabID, since, fallback) {
    const candidates = Array.from(pageReports.get(tabID)?.values() || []).filter((page) => page.receivedAt >= since);
    if (!candidates.length && fallback?.available) candidates.push(cleanPage(fallback));
    const score = (page) => (page.hasCaption ? 100 : 0) + (page.fullscreen ? 50 : 0) + (page.playingVideo ? 20 : 0) + (page.hasVideo ? 10 : 0);
    const best = candidates.sort((a, b) => score(b) - score(a))[0];
    if (!best) return { available: false, hasVideo: false, hasCaption: false, status: "unavailable" };
    const { receivedAt, ...page } = best;
    return page;
}

function refreshPage(tabID) {
    if (!Number.isInteger(tabID) || !browser.tabs?.sendMessage) return Promise.resolve(selectPage(tabID, Infinity));
    const since = Date.now();
    const previous = pageReads.get(tabID);
    if (previous && since >= previous.deadline) previous.expire();
    if (pageReads.has(tabID)) return pageReads.get(tabID);
    pageReports.delete(tabID);
    let resolve;
    const promise = new Promise((done) => { resolve = done; });
    pageReads.set(tabID, promise);
    let finished = false;
    const finish = (fallback, unavailable = false) => {
        if (finished) return;
        finished = true;
        clearTimeout(timeout);
        if (pageReads.get(tabID) === promise) pageReads.delete(tabID);
        resolve(unavailable ? selectPage(tabID, Infinity) : selectPage(tabID, since, fallback));
    };
    promise.deadline = since + 2000;
    promise.expire = () => finish();
    promise.cancel = () => finish(undefined, true);
    const timeout = setTimeout(promise.expire, 2000);
    try {
        Promise.resolve(browser.tabs.sendMessage(tabID, { type: "caption-page-status-request" })).then((reply) => finish(reply), () => finish());
    } catch (_) { finish(); }
    return promise;
}

async function broadcastPreference() {
    try {
        const tabs = await browser.tabs?.query({});
        await Promise.allSettled((tabs || []).filter((tab) => Number.isInteger(tab.id)).map((tab) =>
            browser.tabs.sendMessage(tab.id, { type: "caption-embedding-changed", enabled: embeddingEnabled })
        ));
    } catch (_) { /* storage.onChanged also notifies permitted frames */ }
}

browser.storage?.onChanged.addListener((changes, area) => {
    if (area !== "local" || !changes[SETTING_KEY]) return;
    preferenceRevision += 1;
    embeddingEnabled = changes[SETTING_KEY].newValue !== false;
    void broadcastPreference();
});
browser.tabs?.onRemoved?.addListener((tabID) => { pageReports.delete(tabID); pageReads.get(tabID)?.cancel(); });
browser.tabs?.onUpdated?.addListener((tabID, change) => {
    if (change.status === "loading") { pageReports.delete(tabID); pageReads.get(tabID)?.cancel(); }
});

function sourceStatus(reply) {
    const status = ["active", "stale", "stopped", "missing", "transport-error"].includes(reply?.status)
        ? reply.status : (reply?.active ? "active" : "missing");
    const diagnostics = {};
    for (const key of ["feedAge", "audioAge", "transcriptAge", "audioBufferCount", "transcriptEventCount"]) {
        if (Number.isFinite(reply?.diagnostics?.[key])) diagnostics[key] = reply.diagnostics[key];
    }
    const configuration = reply?.configuration;
    const languageCode = (value) => typeof value === "string" && /^[a-zA-Z0-9-]{1,64}$/.test(value);
    const settings = configuration && languageCode(configuration.spokenLanguage) && languageCode(configuration.targetLanguage)
        && typeof configuration.translationEnabled === "boolean" ? {
            spokenLanguage: configuration.spokenLanguage, targetLanguage: configuration.targetLanguage,
            translationEnabled: configuration.translationEnabled
        } : null;
    return { status, hasText: Boolean(reply?.active && reply.text), diagnostics,
        configuration: settings,
        reason: reply?.reason || null, bridge: reply?.bridge || bridgeStatus() };
}

browser.runtime.onMessage.addListener((message, sender) => {
    switch (message?.type) {
    case "captions":
        return settingsReady.then(() => embeddingEnabled ? readCaptions() : { active: false, status: "disabled" });
    case "caption-page-report":
        storePage(message.page, sender);
        return Promise.resolve({ received: true });
    case "caption-embedding-set":
        if (typeof message.enabled !== "boolean") return undefined;
        return settingsReady.then(async () => {
            await browser.storage.local.set({ [SETTING_KEY]: message.enabled });
            preferenceRevision += 1;
            embeddingEnabled = message.enabled;
            void broadcastPreference();
            return { enabled: embeddingEnabled };
        });
    case "caption-popup-status":
        return settingsReady.then(async () => {
            const [reply, page] = await Promise.all([readCaptions(), refreshPage(message.tabId)]);
            return { enabled: embeddingEnabled, source: sourceStatus(reply), page };
        });
    default:
        return undefined;
    }
});
