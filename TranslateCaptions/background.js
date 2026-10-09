// Relays caption requests from content scripts to the extension's native handler, which reads
// the captions the Translate app is producing. In Safari only extension pages can use native
// messaging, so content scripts go through here.

const APPLICATION_ID = "wang.xiaolin.Translate"; // required by the API, ignored by Safari

browser.runtime.onMessage.addListener((message) => {
    if (message?.type !== "captions") return undefined;
    return browser.runtime
        .sendNativeMessage(APPLICATION_ID, { type: "captions" })
        .catch(() => ({ active: false }));
});
