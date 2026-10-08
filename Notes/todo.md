按规划连续自用一周收集问题；然后做菜单栏入口与 iOS 布局；图片区域高亮、术语表 UI、多语言 UI 字符串目录尚未实现。

iOS不应该显示optional for local server（iOS上看不到前面的标签），而是显示API Key。

iOS: TranslationUIProvider https://developer.apple.com/documentation/translationuiprovider and https://developer.apple.com/documentation/translationuiprovider/preparing-your-app-to-be-the-default-translation-app

visionOS: 模型选单、translate按钮离窗口边框太近，可以做成工具栏

safari web extension：翻译网页内容，不仅翻译文字，还能翻译图片（翻译后文字叠加在图片上）。

macOS和visionOS: 通过screencapturekit等技术实时翻译另一个app（比如Safari）播放的视频并且显示字幕。iOS不一定能实现，看看web extension能不能有这样的自由度，比如修改<video>标签添加一个字幕流，或者把视频变成blob。由于实时性要求高，可以考虑添加系统自带的Translation框架作为选项。

visionOS键盘输入困难，系统的语音输入准确度又太低，可以看看能否集成voxtral/whisper/scribe提供语音输入。
