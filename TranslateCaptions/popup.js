"use strict";

(() => {
    const api = globalThis.browser || globalThis.chrome;
    const language = navigator.language?.toLowerCase().startsWith("zh") ? "zh" : "en";
    const strings = globalThis.captionPopupStrings[language];
    const refreshButton = document.getElementById("refresh");
    const toggle = document.getElementById("embedding-enabled");
    const indicator = document.getElementById("overall-indicator");
    const overall = document.getElementById("overall-status");
    const sourceLabel = document.getElementById("source-status");
    const pageLabel = document.getElementById("page-status");
    const hint = document.getElementById("status-hint");
    const notice = document.getElementById("notice");
    const spokenLanguageLabel = document.getElementById("spoken-language");
    const targetLanguageLabel = document.getElementById("target-language");
    const startLink = document.getElementById("start-captions");
    const launchHint = document.getElementById("launch-hint");
    const sourceStatuses = new Set(["active", "stale", "stopped", "missing", "transport-error"]);
    const refreshInterval = 1500;
    const requestDeadline = 4000;
    const statusDeadline = 10000;
    let snapshot = null;
    let statusLoaded = false;
    let settingsRevision = 0;
    let refreshing = false;
    let toggling = false;
    let refreshTimer = null;
    let disposed = false;
    let statusError = false;
    let toggleError = false;
    let failedToggleDesired = null;

    try {
        if (api.runtime.getPlatformInfo) Promise.resolve(api.runtime.getPlatformInfo()).then(platform => {
            if (!disposed && platform?.os === "mac") document.documentElement.dataset.platform = "mac";
        }).catch(() => {});
    } catch { /* The responsive layout still works without platform information. */ }

    document.documentElement.lang = language === "zh" ? "zh-Hans" : "en";
    document.title = strings.title;
    for (const element of document.querySelectorAll("[data-i18n]")) {
        element.textContent = strings[element.dataset.i18n];
    }
    refreshButton.setAttribute("aria-label", strings.refresh);
    refreshButton.title = strings.refresh;
    overall.textContent = strings.checking;
    hint.textContent = strings.startAppHint;
    spokenLanguageLabel.textContent = strings.languageUnknown;
    targetLanguageLabel.textContent = strings.languageUnknown;

    function languageName(code) {
        if (typeof code !== "string" || !/^[a-zA-Z0-9-]{1,64}$/.test(code)) return strings.languageUnknown;
        try { return new Intl.DisplayNames([language], { type: "language" }).of(code) || code; }
        catch { return code; }
    }

    function withDeadline(promise, deadline = requestDeadline) {
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error("Caption request timed out")), deadline);
            Promise.resolve(promise).then(
                value => { clearTimeout(timer); resolve(value); },
                error => { clearTimeout(timer); reject(error); }
            );
        });
    }

    function sanitizedSnapshot(value) {
        if (!value || typeof value.enabled !== "boolean") throw new Error("Invalid caption status");
        const source = value.source || {};
        const page = value.page || {};
        return {
            enabled: value.enabled,
            source: {
                status: sourceStatuses.has(source.status) ? source.status : "transport-error",
                hasText: source.hasText === true,
                configuration: source.configuration && typeof source.configuration.translationEnabled === "boolean" ? {
                    spokenLanguage: source.configuration.spokenLanguage,
                    targetLanguage: source.configuration.targetLanguage,
                    translationEnabled: source.configuration.translationEnabled
                } : null
            },
            page: {
                available: page.available === true,
                hasVideo: page.hasVideo === true,
                hasCaption: page.hasCaption === true,
                hasSourceText: page.hasSourceText === true,
                trackMode: page.trackMode === "showing" || page.trackMode === "hidden" || page.trackMode === "disabled" ? page.trackMode : null
            }
        };
    }

    function sourceText(source) {
        if (source.status === "active") return strings[source.hasText ? "connected" : "listening"];
        if (source.status === "stale") return strings.staleSource;
        if (source.status === "transport-error") return strings.transportError;
        return strings.appStopped;
    }

    function pageText(value) {
        if (!value.enabled) return strings.disabled;
        if (!value.page.available) return strings.pageUnavailable;
        if (!value.page.hasVideo) return strings.noVideo;
        if (!value.page.hasSourceText) return strings.pageWaiting;
        if (value.page.hasSourceText && (value.page.trackMode === "disabled" || value.page.trackMode === "hidden")) return strings.trackOff;
        return strings[value.page.hasCaption ? "embedded" : "pageWaiting"];
    }

    function summary(value) {
        if (!value.enabled) return ["off", "offHint", "neutral"];
        if (!value.page.available) return ["pageUnavailable", "pageUnavailableHint", "warning"];
        if (!value.page.hasVideo) return ["noVideo", "noVideoHint", "neutral"];
        if (value.source.status === "transport-error") return ["reconnecting", "reconnectingHint", "warning"];
        if (value.source.status === "stale") return ["stale", "staleHint", "warning"];
        if (value.source.status === "stopped" || value.source.status === "missing") return ["startApp", "startAppHint", "neutral"];
        if (!value.page.hasSourceText) return ["waiting", value.source.hasText ? "waitingHint" : "noSpeechHint", "accent"];
        if (value.page.hasSourceText && (value.page.trackMode === "disabled" || value.page.trackMode === "hidden")) return ["trackOff", "trackOffHint", "warning"];
        if (value.page.hasCaption) return ["embedded", "embeddedHint", "success"];
        return ["waiting", value.source.hasText ? "waitingHint" : "noSpeechHint", "accent"];
    }

    function setText(element, text) {
        if (element.textContent !== text) element.textContent = text;
    }

    function render() {
        toggle.disabled = toggling || !snapshot;
        refreshButton.disabled = refreshing;
        const configuration = snapshot?.source.configuration;
        setText(spokenLanguageLabel, configuration ? languageName(configuration.spokenLanguage) : strings.languageUnknown);
        setText(targetLanguageLabel, configuration ? (configuration.translationEnabled ? languageName(configuration.targetLanguage) : strings.originalOnly) : strings.languageUnknown);
        const running = !statusError && snapshot?.source.status === "active";
        setText(startLink, strings[running ? "openCaptions" : "startCaptions"]);
        setText(launchHint, strings[running ? "settingsHint" : "launchHint"]);
        startLink.href = `translate-live-captions://captions/${running ? "settings" : "start"}`;
        if (snapshot && statusLoaded) {
            toggle.checked = snapshot.enabled;
            setText(sourceLabel, statusError ? strings.unknown : sourceText(snapshot.source));
            setText(pageLabel, statusError ? strings.unknown : pageText(snapshot));
            const [titleKey, hintKey, tone] = summary(snapshot);
            setText(overall, statusError ? strings.unknown : strings[titleKey]);
            setText(hint, strings[hintKey]);
            const nextTone = statusError ? "warning" : tone;
            if (indicator.dataset.tone !== nextTone) indicator.dataset.tone = nextTone;
        } else if (snapshot) {
            toggle.checked = snapshot.enabled;
            const checkingText = statusError ? strings.unknown : strings.checking;
            setText(sourceLabel, checkingText);
            setText(pageLabel, snapshot.enabled ? checkingText : strings.disabled);
            setText(overall, snapshot.enabled ? checkingText : strings.off);
            setText(hint, snapshot.enabled ? strings.startAppHint : strings.offHint);
            const nextTone = statusError && snapshot.enabled ? "warning" : "neutral";
            if (indicator.dataset.tone !== nextTone) indicator.dataset.tone = nextTone;
        } else if (statusError) {
            setText(overall, strings.unknown);
            setText(sourceLabel, strings.unknown);
            setText(pageLabel, strings.unknown);
            if (indicator.dataset.tone !== "warning") indicator.dataset.tone = "warning";
        }
        setText(notice, toggleError ? strings.toggleError : statusError ? strings.statusError : "");
        notice.hidden = !notice.textContent;
    }

    async function readPreference() {
        const revision = settingsRevision;
        try {
            if (!api.storage?.local) return;
            const preference = await withDeadline(api.storage.local.get("captionEmbeddingEnabled"));
            if (disposed || snapshot || toggling || revision !== settingsRevision) return;
            snapshot = {
                enabled: preference?.captionEmbeddingEnabled !== false,
                source: { status: "missing", hasText: false },
                page: { available: false, hasVideo: false, hasCaption: false, hasSourceText: false, trackMode: null }
            };
            render();
        } catch {
            // A status response can still supply the preference when storage is unavailable.
        }
    }

    function scheduleRefresh(delay = refreshInterval) {
        clearTimeout(refreshTimer);
        if (!disposed) refreshTimer = setTimeout(refreshStatus, delay);
    }

    async function refreshStatus() {
        if (disposed || refreshing || toggling) return;
        refreshing = true;
        const revision = settingsRevision;
        render();
        try {
            const tabs = await withDeadline(api.tabs.query({ active: true, currentWindow: true }));
            const message = { type: "caption-popup-status" };
            const tabId = tabs?.[0]?.id;
            if (Number.isInteger(tabId)) message.tabId = tabId;
            const response = await withDeadline(api.runtime.sendMessage(message), statusDeadline);
            if (disposed || revision !== settingsRevision || toggling) return;
            snapshot = sanitizedSnapshot(response);
            statusLoaded = true;
            statusError = false;
            if (toggleError && failedToggleDesired === snapshot.enabled) {
                toggleError = false;
                failedToggleDesired = null;
            }
        } catch {
            if (!disposed && revision === settingsRevision && !toggling) statusError = true;
        } finally {
            refreshing = false;
            if (!disposed) {
                render();
                scheduleRefresh();
            }
        }
    }

    async function setEmbedding() {
        if (disposed || toggling || !snapshot) return;
        const enabled = toggle.checked;
        const previousEnabled = snapshot.enabled;
        toggling = true;
        settingsRevision += 1;
        toggleError = false;
        failedToggleDesired = null;
        snapshot = { ...snapshot, enabled };
        render();
        try {
            const response = await withDeadline(api.runtime.sendMessage({ type: "caption-embedding-set", enabled }));
            if (disposed) return;
            if (typeof response?.enabled !== "boolean") throw new Error("Invalid caption setting");
            snapshot = { ...snapshot, enabled: response.enabled };
        } catch {
            if (!disposed) {
                snapshot = { ...snapshot, enabled: previousEnabled };
                toggleError = true;
                failedToggleDesired = enabled;
            }
        } finally {
            toggling = false;
            if (!disposed) {
                render();
                scheduleRefresh(0);
            }
        }
    }

    refreshButton.addEventListener("click", () => {
        clearTimeout(refreshTimer);
        refreshStatus();
    });
    toggle.addEventListener("change", setEmbedding);
    window.addEventListener("pagehide", () => {
        disposed = true;
        settingsRevision += 1;
        clearTimeout(refreshTimer);
    });
    window.addEventListener("pageshow", () => {
        if (disposed) {
            disposed = false;
            scheduleRefresh(0);
        }
    });
    readPreference();
    refreshStatus();
})();
