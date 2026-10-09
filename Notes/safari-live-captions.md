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
  逻辑占用最多两个，并在 20 秒后释放失去回调的旧占用，避免永久阻塞所有网页。
  故障恢复探测至少间隔 10 秒，同时保留最长 30 秒的退避。
  JS 无法取消已经发出的 NSExtension 请求；这里限制的是逻辑占用，不能保证
  实际未结束的底层请求数量。原生通道长期完全失效仍可能触及系统请求上限，
  需要 Safari/系统恢复。
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
| transportReason 为 native-requests-pending，bridge.reservations 为 2 | 两个 native 逻辑占用均在等待回调；过期后应释放并继续探测 |
| bridge.requests 增长，timeouts / expiredLeases 增长而 replies 不增长 | 后台继续重试，但原生请求仍未成功回复 |
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

## 扩展弹出界面与嵌入开关

在 iPhone Safari 的网页菜单中打开 `Translate Live Captions`，或点击 Mac Safari
工具栏中的扩展图标。弹窗分别显示 Translate 字幕来源与当前网页的状态，
支持中文、英文以及系统明暗外观，并可手动刷新；打开期间自动更新状态。

“嵌入实时字幕”默认开启，保存到扩展的本地设置，对所有网页生效。
关闭后立即清除自己的 cue、禁用自己的轨道并恢复播放器原有样式，同时停止
网页的字幕轮询。App 中的采集和识别继续运行。重新开启会获取新的字幕，
不会恢复关闭前的缓存。已加载的网页与视频 iframe 通过设置通知同步开关。

弹窗状态只读取源状态和网页的轨道元数据，不显示或缓存字幕正文及网页 URL。
“字幕已嵌入”表示有效 cue 已进入当前网页的显示轨道，并不能证明系统全屏
字幕位图已画出；原生播放器的字幕选单仍需开启。无语音时，轨道暂时为空或
disabled 是正常情况，界面显示等待字幕，不会把它误报为用户关闭了字幕。

更新安装后重新加载视频网页，使新的 content script 生效。新增资源由 Xcode
同步文件组自动打包；manifest 增加 action popup、storage 和 activeTab 权限。

验证：28 项消息/开关回归、31 项实际 WebKit 检查通过，后者验证关闭时字幕
像素消失及开启后新字幕像素恢复。中文、英文 320px 窄屏、点击/键盘开关、
重新打开后的偏好保留以及连接中断提示已用模拟源预览检查。iOS 模拟器和
无签名真机目标构建成功；预览不等于真实 Safari 扩展权限与 native feed 的端到端测试。

### 从扩展启动与打开实时字幕设置

弹窗正文改为适配 iOS 扩展面板宽度，修复固定 340px 在 iPhone 面板右侧留白的
问题。macOS 保留 360px 的内容大小弹窗；中英文 320px 和 430px 预览无横向溢出。

语言卡片显示语音语言及翻译语言；未翻译时显示“仅显示原文”。App 启动或更改
语言、翻译引擎时，将这三项配置原子写入 App Group 的 `live-caption-settings.json`。
配置独立于字幕 feed，停止字幕后仍可读取；首次没有配置时显示“在 App 中选择”。
原生消息与 popup 状态只转发允许的配置字段，不包含 API key、字幕正文或音频。

- “启动实时字幕”打开 `translate-live-captions://captions/start`，直接进入实时字幕
  控制页，并在 App 与控制页就绪后发起原有启动流程。系统仍要求确认打开 App
  以及选择/确认共享音频；扩展不能静默开始屏幕采集。
- “打开实时字幕设置”打开 `translate-live-captions://captions/settings`，只打开控制页。
  正在运行时，主按钮改为“打开实时字幕”，也进入控制页，避免再次发起共享选择。
- URL 路由只接受固定 scheme、host 和两条路径；不从链接更改语言或传递网页内容。
  请求在可见的实时字幕页、App 前台时消费；启动任务与手动 Start 按钮一致，
  不因系统共享选择器导致 App 暂时 inactive 而被视图任务取消。

验证：43 项消息回归、4 项 popup 行为回归和 9 项 CaptionFeed Swift 测试通过；
iOS 模拟器、无签名真机目标以及 macOS 构建通过。iOS 27.0 / iPhone 18 Pro
模拟器确认设置链接直接进入实时字幕页且不启动，启动链接进入启动流程。
真实 Safari 扩展弹窗的设置与启动入口也已确认可打开 App，返回 Safari 后仍显示
原网页。带本地签名的模拟器版本确认弹窗从 App Group 读取实际英语 → 简体中文
配置（未运行字幕时），而不是网页预览使用的日语 mock 数据。
模拟器不支持采集其他 App 的音频，真机系统共享与实际字幕运行仍需重测。

## 切换网页后无法恢复字幕连接

真机反馈：第一张网页正常，导航到第二张或关闭第一张再打开第二张后，弹窗
显示连接中断，等待超过一分钟仍未恢复。

确定性测试复现了原有后台桥接的永久阻塞路径：8 秒超时只结束包装 Promise，
原生请求的占用却一直保留到 `sendNativeMessage` 自身完成。两条 Promise 始终
不返回后，后续所有网页都会收到 `native-requests-pending`。测试证明这一代码缺口，
没有证明真机导航时 Safari 为什么没有返回原生回调。

修复包括：

- 读取入口根据实际时间检查原生请求的截止时间和 20 秒占用期限，
  不依赖可能暂停的后台定时器。过期后继续限速探测，旧回复不能覆盖新缓存。
- 页面 `pagehide` 停止轮询、清除字幕并废弃旧设置读取；`pageshow` 重读设置
  和字幕，清除本页旧退避。BFCache 恢复仍尊重持久化的嵌入开关。
- 弹窗查询网页状态也检查实际截止时间，导航和关闭旧页会结束旧查询，
  迟到回复不能替换新网页状态。
- 状态诊断增加 `suspended`、`transportReason` 和 `bridge` 请求、回复、超时、
  过期占用计数；这些信息不含字幕正文或网页 URL。

验证：41 项 Node 消息与生命周期回归、31 项 macOS WKWebView 轨道和字幕
像素检查通过；iOS 模拟器与无签名真机目标构建成功。回归覆盖导航、关闭旧页、
BFCache、后台计时器暂停、迟到回复及持续故障的全局限速。

更新安装后重新加载视频网页，用真实字幕源复测 A → B → A，以及关闭 A 后打开 B。
上述测试未运行真机的原生消息通道，不能替代这一步。若仍无法恢复，读取上面的
诊断 JSON，以 `transportReason` 和 `bridge` 区分网页轮询与原生桥接故障。
