// Popup behavior with mocked extension replies. Layout and app handoff need browser checks.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const directory = new URL("../TranslateCaptions/", import.meta.url);
const html = fs.readFileSync(new URL("popup.html", directory), "utf8");
const scripts = ["popup-i18n.js", "popup.js"].map(name => fs.readFileSync(new URL(name, directory), "utf8"));
const flush = () => new Promise(setImmediate);
const snapshot = (status = "missing", translationEnabled = true) => ({
    enabled: true,
    source: { status, hasText: status === "active", configuration: {
        spokenLanguage: "ja", targetLanguage: "zh-Hans", translationEnabled
    } },
    page: { available: true, hasVideo: true, hasCaption: status === "active", hasSourceText: status === "active", trackMode: "showing" }
});

function popup(reply, language = "en") {
    const elements = new Map();
    const timers = new Map();
    let timerID = 0;
    for (const match of html.matchAll(/id="([^"]+)"/g)) {
        const tag = html.slice(html.lastIndexOf("<", match.index), html.indexOf(">", match.index));
        elements.set(match[1], { textContent: "", dataset: {}, href: /href="([^"]+)"/.exec(tag)?.[1],
            events: {}, setAttribute(name, value) { this[name] = value; },
            addEventListener(name, listener) { this.events[name] = listener; } });
    }
    const state = { reply };
    const context = {
        Intl, navigator: { language },
        document: { documentElement: {}, getElementById: id => elements.get(id), querySelectorAll: () => [] },
        window: { addEventListener() {} },
        setTimeout(callback) { timers.set(++timerID, callback); return timerID; },
        clearTimeout(id) { timers.delete(id); },
        browser: {
            storage: { local: { get: async () => ({}) } },
            tabs: { query: async () => [{ id: 1 }] },
            runtime: { sendMessage: async () => state.reply instanceof Error ? Promise.reject(state.reply) : state.reply }
        }
    };
    vm.createContext(context);
    for (const script of scripts) vm.runInContext(script, context);
    return { elements, state, refresh: () => elements.get("refresh").events.click() };
}

const stopped = popup(snapshot());
await flush();
assert.equal(stopped.elements.get("spoken-language").textContent, "Japanese");
assert.match(stopped.elements.get("target-language").textContent, /Chinese/);
assert.equal(stopped.elements.get("start-captions").href, "translate-live-captions://captions/start");
assert.equal(stopped.elements.get("open-settings").href, "translate-live-captions://captions/settings");
console.log("PASS stopped captions show saved languages and separate start/settings links");

stopped.state.reply = snapshot("active");
stopped.refresh();
await flush();
assert.equal(stopped.elements.get("start-captions").textContent, "Open live captions");
assert.equal(stopped.elements.get("start-captions").href, "translate-live-captions://captions/settings");
console.log("PASS an active session opens its panel instead of requesting another capture");

const original = popup(snapshot("missing", false), "zh-CN");
await flush();
assert.equal(original.elements.get("spoken-language").textContent, "日语");
assert.equal(original.elements.get("target-language").textContent, "仅显示原文");
console.log("PASS original-only captions do not misrepresent the saved target as an active translation");

const malformed = snapshot();
malformed.source.configuration.spokenLanguage = "<script>";
const offline = popup(malformed);
await flush();
assert.equal(offline.elements.get("spoken-language").textContent, "Open app to choose");
offline.state.reply = new Error("Disconnected");
offline.refresh();
await flush();
assert.equal(offline.elements.get("start-captions").href, "translate-live-captions://captions/start");
assert.equal(offline.elements.get("open-settings").href, "translate-live-captions://captions/settings");
console.log("PASS app links remain usable during bridge failure and invalid language values stay inert");
console.log("4/4 caption popup regressions passed");
