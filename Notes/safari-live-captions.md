# Safari 实时字幕：Plyr 页面不显示的原因与验证

2026-10-09 检查用户提供的页面，读取到主视频为 `video.player`，播放器加载
Plyr 3.6.8 与 hls.js 1.4.3，配置 `fullscreen.iosNative: true`。
页面同时包含自动播放的小视频和很多预览视频。桌面浏览器走 MSE/HLS，
iPhone 的具体媒体路径应在真机检查，不能用桌面上的 `blob:` 推断。

## 已确认的阻挡因素

Plyr 3.6.8 的字幕样式包含：

```css
.plyr--full-ui ::-webkit-media-text-track-container { display: none; }
```

它隐藏 WebKit 原生字幕，以便自己在 `.plyr__captions` 中绘制字幕。
Plyr 默认 `captions.update: false`，不会将初始化后添加的轨道自动接入这个浮层；
即使接入，Plyr 也会将轨道设为 `hidden` 来避免重复绘制。
所以 `textTracks` 中存在轨道、cue 处于 active、系统选单显示 On，都不能证明画面可见。

iOS 原生全屏字幕也受这个 CSS 影响。WebKit 的
`MediaControlTextTrackContainerElement::createTextTrackRepresentationImage()`
先更新布局，再从字幕容器的 renderer/layer 绘制字幕图像；没有 renderer 就返回空。
这个图像会进入系统全屏播放器的字幕 CALayer。因此全屏播放器是原生界面，
并不意味着网页的字幕 CSS 已经失效。

来源：

- [Plyr 3.6.8 原生字幕隐藏规则](https://github.com/sampotts/plyr/blob/v3.6.8/src/sass/components/captions.scss)
- [Plyr 轨道管理](https://github.com/sampotts/plyr/blob/v3.6.8/src/js/captions.js)
- [Plyr 默认配置](https://github.com/sampotts/plyr/blob/v3.6.8/src/js/config/defaults.js)
- [WebKit 字幕图像生成](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/html/shadow/MediaControlTextTrackContainerElement.cpp)
- [WebKit 系统字幕图层](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/graphics/cocoa/TextTrackRepresentationCocoa.mm)

## 扩展中的修复

`manifest.json` 通过 content-script CSS 加载 `captions.css`。字幕有文本时，
`content.js` 给选中的 video 添加 `data-translate-live-captions`，用作用域内的
`display: block !important` 恢复原生容器，同时暂时隐藏该 Plyr 实例的字幕浮层，
避免重复绘制。文本为空或字幕会话结束时移除标记，恢复播放器样式。

继续使用 `addTextTrack("subtitles", ...)` 和 `VTTCue` 即可。
cue 时间来自 `video.currentTime`，与 HLS 或 MP4 的当前媒体时间轴一致。
不需要修改视频地址、重新封装 HLS、每次字幕变化都重新下载 VTT，或切换到 DOM 字幕浮层。

脚本还优先选择原生全屏视频，避免小型静音自动播放视频抢走字幕；
播放器清除了 cue、移除了轨道、cue 已过期或用户倒退播放时会重新插入字幕。
异常不会永久终止轮询。

## iPhone 验证与排查

重新构建并安装包含新 CSS 的扩展，然后重新加载网页。开始实时字幕、播放主视频，
先确认内嵌字幕，再进入原生全屏，等待多次文本更新并尝试拖动进度。
必须验证文字实际显示，不能只看字幕选单或 `activeCues`。

在 Mac Safari 的开发菜单中连接 iPhone，选择该网页，运行下面的只读诊断：

```js
Array.from(document.querySelectorAll("video")).map(video => ({
  isMain: video.matches("video.player"),
  nativeFullscreen: video.webkitDisplayingFullscreen,
  presentation: video.webkitPresentationMode,
  time: video.currentTime,
  paused: video.paused,
  marked: video.hasAttribute("data-translate-live-captions"),
  tracks: Array.from(video.textTracks).map(track => ({
    label: track.label,
    mode: track.mode,
    cues: Array.from(track.cues || []).map(cue => ({
      text: cue.text, start: cue.startTime, end: cue.endTime
    })),
    active: track.activeCues?.length
  }))
}))
```

主视频应标记 `marked: true`，`Live translation` 的 mode 为 `showing`，
播放时至少一个 cue 的 `start <= time < end`。如果没有文字/轨道，先检查
App Group 字幕 feed 和扩展的网站权限；如果 cue 已 active 仍不可见，
确认新 CSS 已随扩展安装，并检查是否有其他隐藏容器、透明文字或裁剪样式。
Safari 的扩展 content script 在隔离世界中执行，控制台不一定能读取脚本内部状态；
DOM 标记和 TextTrack 可用于跨世界诊断。

`Tools/ContentScriptTests.swift` 使用 macOS WKWebView 验证轨道逻辑和渲染，
不等于用户这台 iPhone、该网页 HLS 路径的端到端验证。

## 本次验证结果

- macOS WKWebView：25 项检查通过。保持同一个 active cue，仅切换修复 CSS，
  字幕由不可见变为可见；截图还检查了实际字幕像素。
- iOS 27.0 / iPhone 18 Pro 模拟器 Safari：使用中性 MP4 和正常轮询脚本，
  确认内嵌字幕以及原生全屏中的动态字幕均可见。保持系统字幕为 On，
  禁用修复 CSS 后两种模式都消失，恢复 CSS 后原生全屏字幕再次出现。
  初次全屏时原生选单默认 Off，即使 DOM mode 已为 showing，仍需在系统选单开启。
- iOS 模拟器构建成功，`captions.css` 和修改后的 manifest 已在扩展包内。

模拟器的 caption feed 是测试数据，没有使用 App Group/native messaging；
视频为生成的 MP4。这验证了原生字幕渲染及 CSS 问题，真机上的该网页 HLS
与实际字幕 feed 仍应在重新安装扩展后做最终验证。
