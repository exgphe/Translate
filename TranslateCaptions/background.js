// Relays caption requests from content scripts to the extension's native handler, which reads
// the captions the Translate app is producing. In Safari only extension pages can use native
// messaging, so content scripts go through here.

const APPLICATION_ID = "wang.xiaolin.Translate"; // required by the API, ignored by Safari
const NATIVE_TIMEOUT_MS = 8000;
const CACHE_MS = 100;
// A JS timeout cannot cancel an NSExtension request. Bound those requests too, instead of
// piling up new native processes every time a page/frame asks for captions during a stall.
const MAX_OUTSTANDING_NATIVE = 2;
const outstanding = new Set();
let pending = null;
let cached = null;
let cachedAt = 0;
let failures = 0;
let retryAt = 0;

function transportError(reason) {
    return { status: "transport-error", reason };
}

function readCaptions() {
    if (pending) return pending;
    if (cached && Date.now() - cachedAt < CACHE_MS) return Promise.resolve(cached);
    if (Date.now() < retryAt) return Promise.resolve(transportError("native-retry-backoff"));
    if (outstanding.size >= MAX_OUTSTANDING_NATIVE) return Promise.resolve(transportError("native-requests-pending"));

    const token = {};
    outstanding.add(token);
    let resolve;
    const promise = new Promise((done) => { resolve = done; });
    pending = promise;
    let finished = false;
    const finish = (reply, error) => {
        if (finished) return;
        finished = true;
        clearTimeout(timeout);
        if (pending === promise) pending = null;
        if (error || !reply || typeof reply.active !== "boolean") {
            failures += 1;
            retryAt = Date.now() + Math.min(30_000, 2000 * 2 ** Math.min(failures - 1, 4));
            cached = null;
            resolve(transportError(error || "invalid-native-reply"));
        } else {
            failures = 0;
            retryAt = 0;
            cached = reply;
            cachedAt = Date.now();
            resolve(reply);
        }
    };
    const timeout = setTimeout(() => finish(null, "native-timeout"), NATIVE_TIMEOUT_MS);
    try {
        Promise.resolve(browser.runtime.sendNativeMessage(APPLICATION_ID, { type: "captions" })).then(
            (reply) => { outstanding.delete(token); finish(reply); },
            () => { outstanding.delete(token); finish(null, "native-message-failed"); }
        );
    } catch (_) { outstanding.delete(token); finish(null, "native-message-failed"); }
    return promise;
}

browser.runtime.onMessage.addListener((message) => {
    if (message?.type !== "captions") return undefined;
    return readCaptions();
});
