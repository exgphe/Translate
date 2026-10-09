// Exercises the content script in macOS WebKit with a mocked extension API. Reproduces
// Plyr's native-caption suppression, then checks that the bundled CSS reveals the caption.
// This does not verify iOS Safari's native fullscreen/HLS rendering path.
//
//   swiftc -O Tools/ContentScriptTests.swift -o /tmp/content-tests && /tmp/content-tests TranslateCaptions/content.js /tmp/out
//
// Prints PASS/FAIL and writes snapshots of hidden, visible, disabled, and reenabled captions.
import AppKit
import AVFoundation
import WebKit

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let contentScript = try String(contentsOf: scriptURL, encoding: .utf8)
let captionCSS = try String(contentsOf: scriptURL.deletingLastPathComponent().appending(path: "captions.css"), encoding: .utf8)

/// A short H.264 test video so playback and caption rendering can be checked.
func makeVideo(at url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<300 {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
        let shade = UInt8(60 + frame % 60)
        for i in 0..<(CVPixelBufferGetBytesPerRow(buffer!) * 360) { base[i] = i % 4 == 3 ? 255 : shade }
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
}

let videoURL = outputDirectory.appending(path: "test-video.mp4")
try makeVideo(at: videoURL)
let page = """
<!doctype html><html><head><style>
body { margin: 0; background: #222; }
video { display: block; }
#small { position: absolute; top: 0; left: 650px; }
.plyr { position: relative; width: 640px; }
.plyr__captions { position: absolute; bottom: 40px; display: block; }
.plyr--full-ui ::-webkit-media-text-track-container { display: none; }
</style></head><body>
<video id="small" width="120" height="68" muted playsinline></video>
<div id="player" class="plyr plyr--full-ui">
<video id="main" width="640" height="360" muted playsinline preload="auto" src="test-video.mp4"></video>
<div id="player-captions" class="plyr__captions"></div>
</div>
</body></html>
"""
try page.write(to: outputDirectory.appending(path: "index.html"), atomically: true, encoding: .utf8)

_ = NSApplication.shared
let configuration = WKWebViewConfiguration()
configuration.mediaTypesRequiringUserActionForPlayback = []
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 450), configuration: configuration)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450), styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = webView
window.orderFrontRegardless()

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: Any = "") {
    print(condition ? "PASS" : "FAIL", name, condition ? "" : "→ \(detail)")
    if !condition { failures += 1 }
}

func run(_ js: String) async throws -> Any? {
    try await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
}

/// The fixture has only dark grayscale pixels; bright neutral pixels come from captions.
func brightPixels(_ bitmap: NSBitmapImageRep) -> Int {
    var count = 0
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.alphaComponent > 0.9 && color.redComponent > 0.86 && color.greenComponent > 0.86 && color.blueComponent > 0.86 {
                count += 1
            }
        }
    }
    return count
}

@MainActor
func snapshot(named name: String) async throws -> Int {
    let image = try await webView.takeSnapshot(configuration: nil)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ContentScriptTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode caption snapshot"])
    }
    let url = outputDirectory.appending(path: name)
    try png.write(to: url)
    print("wrote", url.path)
    return brightPixels(bitmap)
}

Task { @MainActor in
    do {
        webView.loadFileURL(outputDirectory.appending(path: "index.html"), allowingReadAccessTo: outputDirectory)
        while webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        // Mock the extension API and capture the script's internals instead of starting its loop.
        _ = try await run("""
            window.__reply = { active: false };
            window.__captionRequests = 0;
            window.browser = { runtime: { sendMessage: async () => { window.__captionRequests += 1; return window.__reply; } } };
            window.__translateCaptionsTestHooks = (hooks) => { window.__hooks = hooks; };
            window.__seek = async (time) => {
                const v = document.getElementById('main');
                if (Math.abs(v.currentTime - time) < 0.001) return;
                await new Promise((resolve, reject) => {
                    const timeout = setTimeout(() => reject(new Error('Seek timed out')), 5000);
                    v.addEventListener('seeked', () => { clearTimeout(timeout); resolve(); }, { once: true });
                    v.currentTime = time;
                });
            };
            """)
        _ = try await run(contentScript)
        check("script exposes its hooks under test", try await run("return typeof window.__hooks?.show") as? String == "function")

        check("picks the largest video", try await run("return window.__hooks.pickVideo().id") as? String == "main")

        let fullscreenPick = try await run("""
            const v = document.getElementById('small');
            Object.defineProperty(v, 'webkitDisplayingFullscreen', { configurable: true, value: true });
            try { return window.__hooks.pickVideo().id; }
            finally { delete v.webkitDisplayingFullscreen; }
            """) as? String
        check("native fullscreen video wins over a larger video", fullscreenPick == "small", fullscreenPick ?? "nil")

        _ = try await run("window.__hooks.show('', 'zh-Hans')")
        check("empty captions do not create a track or change the player", try await run("return document.getElementById('main').textTracks.length === 0 && !document.getElementById('main').hasAttribute('data-translate-live-captions') && !document.getElementById('player').hasAttribute('data-translate-native-captions')") as? Bool == true)

        _ = try await run("window.__hooks.show('你好\\nHello', 'zh-Hans')")
        let track = try await run("""
            const v = document.getElementById('main');
            const t = Array.from(v.textTracks).find(t => t.label === 'Live translation');
            return [v.textTracks.length, t?.mode, t?.language, t?.cues?.length, t?.cues?.[0]?.text];
            """) as? [Any]
        check("adds one showing subtitle track with the caption", track?.count == 5 && track?[1] as? String == "showing" && track?[3] as? Int == 1 && track?[4] as? String == "你好\nHello", track ?? "nil")
        check("track uses the caption language", track?[2] as? String == "zh-Hans", track?[2] ?? "nil")
        check("small video untouched", try await run("return document.getElementById('small').textTracks.length") as? Int == 0)
        check("active captions mark their video and Plyr wrapper", try await run("return document.getElementById('main').hasAttribute('data-translate-live-captions') && document.getElementById('player').hasAttribute('data-translate-native-captions')") as? Bool == true)

        _ = try await run("window.__hooks.show('你好\\nHello', 'zh-Hans')")
        check("same text keeps one cue", try await run("return document.getElementById('main').textTracks[0].cues.length") as? Int == 1)

        let restoredCue = try await run("""
            const previous = window.__hooks.state.cue;
            window.__hooks.state.track.removeCue(previous);
            window.__hooks.show('你好\\nHello', 'zh-Hans');
            const t = window.__hooks.state.track;
            return [t.cues.length, t.cues[0]?.text, window.__hooks.state.cue !== previous];
            """) as? [Any]
        check("unchanged text restores a cue removed by the player", restoredCue?[0] as? Int == 1 && restoredCue?[1] as? String == "你好\nHello" && restoredCue?[2] as? Bool == true, restoredCue ?? "nil")

        // Wait for metadata before seeking. Tests use the real media timeline, not mocked cues.
        _ = try await run("""
            const v = document.getElementById('main');
            if (v.readyState === 0) await new Promise((resolve) => v.addEventListener('loadedmetadata', resolve, { once: true }));
            window.__previousCue = window.__hooks.state.cue;
            await window.__seek(8);
            window.__hooks.show('你好\\nHello', 'zh-Hans');
            """)
        let expiredCue = try await run("const v = document.getElementById('main'); const c = window.__hooks.state.cue; return [c !== window.__previousCue, c.startTime <= v.currentTime, c.endTime > v.currentTime, window.__hooks.state.track.cues.length]") as? [Any]
        check("unchanged text after an expired cue creates a current cue", expiredCue?[0] as? Bool == true && expiredCue?[1] as? Bool == true && expiredCue?[2] as? Bool == true && expiredCue?[3] as? Int == 1, expiredCue ?? "nil")

        _ = try await run("window.__previousCue = window.__hooks.state.cue; await window.__seek(1); window.__hooks.show('你好\\nHello', 'zh-Hans')")
        let rebasedCue = try await run("const v = document.getElementById('main'); const c = window.__hooks.state.cue; return [c !== window.__previousCue, c.startTime <= v.currentTime, c.endTime > v.currentTime, window.__hooks.state.track.cues.length]") as? [Any]
        check("seeking backwards rebases unchanged captions", rebasedCue?[0] as? Bool == true && rebasedCue?[1] as? Bool == true && rebasedCue?[2] as? Bool == true && rebasedCue?[3] as? Int == 1, rebasedCue ?? "nil")

        _ = try await run("window.__hooks.state.track.mode = 'hidden'; window.__hooks.show('你好\\nHello', 'zh-Hans')")
        check("player hiding the track is recovered on the next caption", try await run("return window.__hooks.state.track.mode") as? String == "showing")

        _ = try await run("window.__hooks.show('再见', 'zh-Hans')")
        let replaced = try await run("const c = document.getElementById('main').textTracks[0].cues; return [c.length, c[0].text]") as? [Any]
        check("new text replaces the cue", replaced?[0] as? Int == 1 && replaced?[1] as? String == "再见", replaced ?? "nil")

        _ = try await run("window.__hooks.show('', 'zh-Hans')")
        let empty = try await run("const v = document.getElementById('main'); const t = v.textTracks[0]; return [t.cues ? t.cues.length : 0, t.mode, v.hasAttribute('data-translate-live-captions'), document.getElementById('player').hasAttribute('data-translate-native-captions')]") as? [Any]
        check("empty text removes the cue and releases caption styling", empty?[0] as? Int == 0 && empty?[1] as? String == "disabled" && empty?[2] as? Bool == false && empty?[3] as? Bool == false, empty ?? "nil")

        _ = try await run("window.__reply = { active: true, session: 'A', language: 'zh-Hans', text: '会议改到周四。' }")
        let activeDelay = try await run("return await window.__hooks.poll()") as? Int
        let polled = try await run("const t = document.getElementById('main').textTracks[0]; return [t.mode, t.cues.length ? t.cues[0].text : null]") as? [Any]
        check("poll shows the app's captions and polls fast", activeDelay == 350 && polled?[1] as? String == "会议改到周四。", [activeDelay as Any, polled as Any])

        _ = try await run("window.__reply = { active: false }")
        let idleDelay = try await run("return await window.__hooks.poll()") as? Int
        let stopped = try await run("const t = document.getElementById('main').textTracks[0]; return [t.mode, t.cues ? t.cues.length : 0]") as? [Any]
        check("inactive feed hides the track and polls slowly", idleDelay == 3000 && stopped?[0] as? String == "disabled", [idleDelay as Any, stopped as Any])
        check("inactive feed releases video and Plyr caption styling", try await run("return !document.getElementById('main').hasAttribute('data-translate-live-captions') && !document.getElementById('player').hasAttribute('data-translate-native-captions')") as? Bool == true)

        _ = try await run("window.__reply = { active: true, session: 'B', language: 'zh-Hans', text: '字幕又回来了。' }")
        _ = try await run("return await window.__hooks.poll()")
        let resumed = try await run("const v = document.getElementById('main'); const t = Array.from(v.textTracks).filter(t => t.label === 'Live translation'); return [t.length, t[0].mode, t[0].cues[0]?.text]") as? [Any]
        check("a new session reuses the track and shows again", resumed?[0] as? Int == 1 && resumed?[1] as? String == "showing" && resumed?[2] as? String == "字幕又回来了。", resumed ?? "nil")

        let audiblePick = try await run("""
            const main = document.getElementById('main');
            const ad = document.getElementById('small');
            main.muted = false;
            ad.src = 'test-video.mp4';
            ad.width = 740; ad.height = 416;
            await Promise.all([main.play(), ad.play()]);
            const result = [window.__hooks.pickVideo().id, !main.paused, !ad.paused, ad.muted];
            ad.pause(); ad.removeAttribute('src'); ad.load(); ad.width = 120; ad.height = 68;
            return result;
            """) as? [Any]
        check("audible main playback wins over a larger muted advertisement", audiblePick?[0] as? String == "main" && audiblePick?[1] as? Bool == true && audiblePick?[2] as? Bool == true && audiblePick?[3] as? Bool == true, audiblePick ?? "nil")

        // Freeze the grayscale frame before snapshots, so changed pixels are caption rendering.
        try await Task.sleep(for: .milliseconds(800))
        _ = try await run("document.getElementById('main').pause(); window.__hooks.show('会议已改到周四，请带上签好的表格。\\nThe meeting moved to Thursday.', 'zh-Hans')")
        try await Task.sleep(for: .milliseconds(800))
        let active = try await run("const v = document.getElementById('main'); return [v.currentTime > 0, v.textTracks[0].activeCues?.length ?? 0]") as? [Any]
        check("caption remains active on the frozen playback frame", active?[0] as? Bool == true && active?[1] as? Int == 1, active ?? "nil")
        let hiddenPixels = try await snapshot(named: "caption-hidden-by-plyr.png")
        check("Plyr suppression leaves an active cue invisible", hiddenPixels < 20, "\(hiddenPixels) bright pixels")

        let cssData = try JSONSerialization.data(withJSONObject: [captionCSS])
        let cssLiteral = String(data: cssData, encoding: .utf8)!
        _ = try await run("const s = document.createElement('style'); s.id = 'translate-caption-css'; s.textContent = \(cssLiteral)[0]; document.head.append(s)")
        try await Task.sleep(for: .milliseconds(800))
        check("bundled CSS hides Plyr's duplicate caption overlay", try await run("return getComputedStyle(document.getElementById('player-captions')).display") as? String == "none")
        let visiblePixels = try await snapshot(named: "caption-render.png")
        check("bundled CSS makes native caption glyphs visible", visiblePixels > hiddenPixels + 100, "hidden: \(hiddenPixels), visible: \(visiblePixels) bright pixels")

        let disabled = try await run("""
            window.__hooks.setEmbeddingEnabled(false);
            const v = document.getElementById('main');
            const t = Array.from(v.textTracks).find(t => t.label === 'Live translation');
            return [t?.cues?.length ?? 0, t?.mode,
                v.hasAttribute('data-translate-live-captions'),
                document.getElementById('player').hasAttribute('data-translate-native-captions'),
                getComputedStyle(document.getElementById('player-captions')).display];
            """) as? [Any]
        check("disabling embedding clears its cue and disables its track", disabled?[0] as? Int == 0 && disabled?[1] as? String == "disabled", disabled ?? "nil")
        check("disabling embedding releases caption attributes and player styling", disabled?[2] as? Bool == false && disabled?[3] as? Bool == false && disabled?[4] as? String == "block", disabled ?? "nil")
        try await Task.sleep(for: .milliseconds(800))
        let disabledPixels = try await snapshot(named: "caption-embedding-off.png")
        check("disabling embedding removes actual native caption glyphs", disabledPixels < 20 && visiblePixels > disabledPixels + 100, "enabled: \(visiblePixels), disabled: \(disabledPixels) bright pixels")

        let reenabled = try await run("""
            const requestsBefore = window.__captionRequests;
            window.__reply = { active: true, session: 'C', language: 'zh-Hans', text: '重新开启后的新字幕。\\nFresh captions after enabling.' };
            window.__hooks.setEmbeddingEnabled(true);
            await window.__hooks.poll();
            const v = document.getElementById('main');
            const tracks = Array.from(v.textTracks).filter(t => t.label === 'Live translation');
            return [window.__captionRequests > requestsBefore, tracks.length, tracks[0]?.mode, tracks[0]?.cues?.[0]?.text,
                v.hasAttribute('data-translate-live-captions'),
                document.getElementById('player').hasAttribute('data-translate-native-captions'),
                getComputedStyle(document.getElementById('player-captions')).display];
            """) as? [Any]
        check("reenabling embedding reads fresh text and reuses the native track", reenabled?[0] as? Bool == true && reenabled?[1] as? Int == 1 && reenabled?[2] as? String == "showing" && reenabled?[3] as? String == "重新开启后的新字幕。\nFresh captions after enabling.", reenabled ?? "nil")
        check("reenabling embedding restores caption attributes and styling", reenabled?[4] as? Bool == true && reenabled?[5] as? Bool == true && reenabled?[6] as? String == "none", reenabled ?? "nil")
        try await Task.sleep(for: .milliseconds(800))
        let reenabledPixels = try await snapshot(named: "caption-embedding-on.png")
        check("reenabling embedding restores actual native caption glyphs", reenabledPixels > disabledPixels + 100, "disabled: \(disabledPixels), reenabled: \(reenabledPixels) bright pixels")

        _ = try await run("window.__hooks.show('', 'zh-Hans'); window.__hooks.stop()")
        check("empty captions restore the player's overlay styling", try await run("return getComputedStyle(document.getElementById('player-captions')).display") as? String == "block")
    } catch {
        print("ERROR", error)
        failures += 1
    }
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run(until: Date().addingTimeInterval(60))
print("TIMEOUT")
exit(2)
