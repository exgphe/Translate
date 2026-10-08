按规划连续自用一周收集问题；然后做菜单栏入口与 iOS 布局；图片区域高亮、术语表 UI、多语言 UI 字符串目录尚未实现。

iOS不应该显示optional for local server（iOS上看不到前面的标签），而是显示API Key。

iOS界面美化和优化（参考系统自带翻译app）

iOS: TranslationUIProvider https://developer.apple.com/documentation/translationuiprovider and https://developer.apple.com/documentation/translationuiprovider/preparing-your-app-to-be-the-default-translation-app

visionOS: 模型选单、translate按钮离窗口边框太近，很难通过眼球追踪选中。可以做成工具栏按钮，加底色，这样在visionOS上面可以浮动出来。

safari web extension：翻译网页内容，不仅翻译文字，还能翻译图片（翻译后文字叠加在图片上）。


visionOS键盘输入困难，系统的语音输入准确度又太低，可以看看能否集成voxtral/whisper/scribe提供语音输入。

macOS和visionOS: 通过screencapturekit等技术实时翻译另一个app（比如Safari）播放的视频并且显示字幕。iOS不一定能实现，看看web extension能不能有这样的自由度，比如修改<video>标签添加一个字幕流，或者把视频变成blob。由于实时性要求高，可以考虑添加系统自带的Translation框架作为选项。

有没有可能开发一个safari/chrome web extension，在HTML的video标签中实时地插入一个字幕流，达到实时字幕和翻译的效果？

完全可能。这类浏览器扩展在技术架构上非常成熟，整个实现主要分为三个核心环节：音频流捕获、实时语音识别与翻译（ASR/MT）、以及字幕渲染与同步。

一、 核心技术实现路径

1. 音频捕获 (Audio Capture)

浏览器扩展无法直接跨域“窃取”所有媒体文件的原始音频流，但有两种标准途径：

⚬ 方案 A：chrome.tabCapture / chrome.desktopCapture（推荐后台方案）
  ⚬ 机制：通过 Background Service Worker 调用 chrome.tabCapture.capture({ audio: true })，捕获当前标签页的所有音频流。
  ⚬ 优势：绕过跨域限制（CORS）；即使视频使用 MSE (Media Source Extensions)、WebRTC 或复杂加密播放器也能拿到音频。
  ⚬ 注意：捕获音频后，需要使用 AudioContext 将音频重新路由输出给用户（AudioDestinationNode），否则页面会静音。
⚬ 方案 B：Web Audio API + HTMLMediaElement（前端 DOM 方案）
  ⚬ 机制：Content Script 中通过 AudioContext.createMediaElementSource(videoElement)。
  ⚬ 局限：受同源策略限制，如果视频源跨域且未配置 crossorigin="anonymous"，Web Audio 会直接抛出安全异常或输出静音。因此通用扩展通常采用方案 A。

2. 实时流式 ASR 与翻译

拿到 MediaStream 后，处理链路通常如下：

⚬ 音频分块与编码：使用 AudioWorkletNode 实时采集 PCM 数据（例如重采样为 16kHz 16-bit 单声道），打包为二进制数据块。
⚬ 双向通信 (WebSocket / WebRTC)：
  ⚬ 云端模型：将音频流通过 WebSocket 持续推送到自建或第三方服务端（如 OpenAI Whisper 实时端点、Deepgram、Google Cloud Speech-to-Text 等），服务端返回流式文本和翻译结果。
  ⚬ 本地模型：Chrome 提供了内置的客户端 AI API（如 Prompt API、Translation API），轻量级模型亦可通过 Transformers.js / ONNX Runtime Web 在本地运行，但持续低延迟转录目前云端专用流式 ASR（如 Conformer、Whisper streaming）延迟和准确度更优。

3. 字幕注入与渲染

向网页渲染字幕主要有两种方式：

⚬ 方式 1：利用 HTML5 原生 TextTrack API（原生结合最好）
  直接为 <video> 添加动态字幕轨：
  const track = videoElement.addTextTrack("subtitles", "实时翻译", "zh");
  track.mode = "showing";
  
  // 收到翻译文本与时间戳时：
  const currentTime = videoElement.currentTime;
  const cue = new VTTCue(currentTime, currentTime + 3.0, "翻译后的字幕文本");
  track.addCue(cue);
  
  ⚬ 优势：完美适配原生全屏模式、自带样式、跟随视频控制条显隐。
⚬ 方式 2：自定义 DOM 浮层 (Overlay)
  ⚬ 在 <video> 的父容器上挂载一个绝对定位的 div。
  ⚬ 优势：样式完全自定义（双语显示、字号颜色调整、划词翻译）。
  ⚬ 注意：如果视频进入浏览器原生全屏（Native Fullscreen），非视频子节点的 DOM 会被遮盖，需监听全屏事件将浮层挂载到 fullscreenElement 下。

二、 Chrome 与 Safari 的平台差异

维度	Google Chrome	Apple Safari (Safari Web Extension)
音频捕获 API	支持 chrome.tabCapture，开发体验顺畅	不支持 tabCapture API；无法直接从后台静默捕获标签页音频流
替代捕获方案	无需降级方案	依赖 navigator.mediaDevices.getDisplayMedia 弹窗让用户手动授权屏幕/音频录制
跨域限制	方案 A 避开 CORS	若无法通过屏幕共享捕获，Content Script 会直接受制于跨域媒体源
架构结论	非常适合开发且体验无缝	交互成本较高（每次需弹窗提示用户授权录屏音频）

三、 关键工程挑战

1. 音频直通与防静音：在 Chrome 后台捕获流后，必须正确建立音频回放管道，避免用户听不到原声。
2. 端到端延迟控制：流式 ASR 的切片步长（VAD 语音断句、分块长度）直接决定延迟。通常需要控制在 500ms ~ 1.5s 内，字幕才有可用性。
3. 滚动字幕 vs 替换字幕：实时转录通常分为 Partial Transcript（临时识别）和 Final Transcript（终态识别）。在渲染层需设计动态更新逻辑，避免频繁闪烁。