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

## 播放几分钟后停止更新

真机反馈：屏幕共享指示仍在，字幕几分钟后消失或停止，拖动进度或切回 App 后恢复。
这不是确认系统停止采集的证据，也不能单凭“拖动恢复”确定 feed 恢复了：
旧实现的 seeked 只重新显示缓存字幕，能让已经过期的 cue 临时重新出现。

本次修复处理了可复现的恢复缺口：

- content script 的消息请求有 4 秒截止时间。超时后退避重试，迟到回复不能覆盖新字幕。
  `timeupdate` 也检查截止时间、字幕有效期和下一次请求，作为 DOM 定时器被延迟时的恢复入口。
  首次请求还没有轨道、feed 变为 inactive 后，也允许当前播放视频唤醒轮询。
  这个入口依赖媒体事件仍能执行；如果 WebKit 已暂停整个页面的 JavaScript，
  网页脚本不能自行唤醒它，原生视频继续播放也不能证明脚本仍在运行。
- 临时 native messaging 失败不再伪装成用户关闭字幕。缓存文字有最多 8 秒的宽限，
  且不会超过 native feed 的有效期；seek 不会将过期缓存重新显示。
- 相同文字不再每 350 毫秒修改 cue.endTime。WebKit 的这个修改会实际移除、重新加入
  cue，重建字幕显示树；现在只在 cue 快到期时续期。
- background script 合并不同 frame 的 native 请求，提供 8 秒截止时间、短缓存和退避。
  JS 无法取消已经发出的 NSExtension 请求，所以同时未结束的 native 请求最多两个，
  避免系统扩展请求无限积压。两个永久不结束的底层请求仍需要 Safari/系统恢复，
  不能声称网页 JS 能修复任意原生进程故障。
- 音频输入与识别结果共同管理生命周期。识别器出错或结束时立即结束输入，
  不再等待永远运行的音频流才观察错误；取消与启动失败也会完成清理。
  heartbeat 和延迟发布会检查会话，旧任务不能在新会话中继续发布或停止采集。

### 不记录字幕内容的状态诊断

用 Safari 远程 Web Inspector 选择视频所在的 frame，运行：

```js
JSON.parse(document.documentElement.getAttribute("data-translate-caption-status") || "{}")
```

在出现故障时比较两次读数：

| 读数 | 可定位的问题 |
| --- | --- |
| mediaEvents 增长，status 为 timeout / transport-error，responses 不增长 | 扩展消息通道停滞 |
| status 为 stale，source.feedAge 持续增长 | App 未继续发布字幕文件；不能仅凭此区分 App 被暂停与写入失败 |
| source.audioBufferCount 增长，transcriptEventCount 不增长 | 音频仍进入 App，识别没有新结果；需排除视频本身没有人说话 |
| feedAge 很小，识别及回复计数均增长，cue/画面仍停滞 | 检查 TextTrack 时间轴与原生字幕渲染 |
| reportedAt 和 lastMediaEventAt 都不再变化 | 页面 JS / 媒体事件没有继续执行 |

source.audioAge 和 transcriptAge 是 App 最近采集/识别事件距 native 回复的秒数。
replyAge 是距最后一次成功回复的秒数。诊断只包含时间、数量和状态，不包含音频、
字幕文字或网站 URL。旧版 feed 文件仍可读取。

验证命令：

```sh
node Tools/CaptionPollingTests.mjs
cd Packages/TranslationKit
swift test --filter CaptionFeedTests --filter LiveCaptionsTests
```

确定性故障注入、macOS WebKit 渲染和 Swift 的识别生命周期测试已通过；
这些测试没有复现真机的屏幕采集 + ASR + Safari 长时间后台运行。
本次真机精确原因仍需依据上面的状态信息确认。

本次恢复修复的验证：

- Node：16 项轮询回归通过，覆盖挂起/迟到回复、定时器延迟、首次无轨道、
  inactive 后恢复、过期缓存与跨 frame native 请求合并/上限。
- Swift：14 项 LiveCaptions、7 项 CaptionFeed 测试通过，含识别结果失败时
  结束音频输入、取消清理以及正常结束时排空 final 结果。
- macOS WKWebView：25 项轨道与实际字幕像素检查通过。
- 最新 iOS 模拟器和无签名真机目标构建成功。
- iOS 27.0 / iPhone 18 Pro 模拟器 Safari：原生全屏连续播放 240 秒 HLS，
  模拟一次 6 秒消息延迟和一次消息拒绝，完整播放后 mock 请求数为 782，
  两次故障均已触发，媒体事件持续增长。另用递增字幕序号确认原生画面更新，
  超时及拒绝后回复、cue 序号与原生画面继续增长，无需 seek 或切回 App。

HLS 验证使用中性生成视频与 mock feed，没有调用真实 App Group/native messaging，
也没有执行 iPhone 上的 ScreenCaptureKit 或 ASR。两层 JS 消息逻辑由 Node 故障测试覆盖；
真机后台采集是否继续仍以 source 音频/识别/发布计数为依据。
