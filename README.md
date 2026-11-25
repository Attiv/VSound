# 维音 · VSound

一款离线优先的 macOS 原生音乐播放器。SwiftUI 界面，AVAudioEngine 播放引擎，无第三方运行时依赖。

## 运行

需要 macOS 14 或更新版本、完整 Xcode，以及 XcodeGen（`brew install xcodegen`）。

```bash
zsh scripts/build.sh --run
```

构建后的应用位于 `build/VSound.app`，显示名称为“维音”，可以复制到“应用程序”。也可直接用 Xcode 打开 `VSound.xcodeproj` 运行。未使用开发者证书签名和公证，当前构建用于本机运行。

## 功能

- 选择或拖入音乐文件夹，递归扫描子目录，建立索引，不移动或修改原始音频。
- 歌曲、专辑、歌手、文件夹、收藏、最近播放视图，支持搜索、播放队列和下一首播放。
- 播放、暂停、拖动进度、音量、顺序播放、单曲循环、列表循环和随机播放；随机一轮内不重复，支持播放历史。
- 系统媒体控制、可录制的全局快捷键、迷你播放器和正在播放视图。
- 真正接入音频链路的十段 EQ：原声、哈曼卡顿风格、流行、人声、摇滚、爵士、古典、电子、深夜，以及可保存的自定义预设。
- 同目录 LRC、内嵌歌词、手动导入、逐行高亮、点击跳转、时间偏移、联网搜索匹配、缓存和导出。
- 记住曲库、队列、播放位置、收藏和音效；重启恢复暂停状态，不自动出声。

支持扫描 MP3、M4A/AAC、FLAC、ALAC、WAV、AIFF、CAF，最终可播放性取决于系统解码器与文件是否有效。文件夹新增内容后使用 `⌘R` 重新扫描。符号链接不会被当成额外音乐导入。

## 快捷键

| 操作 | 应用内 | 默认全局快捷键 |
| --- | --- | --- |
| 播放 / 暂停 | Space | ⌃⌥⌘ Space |
| 上一首 | ⌘← | ⌃⌥⌘← |
| 下一首 | ⌘→ | ⌃⌥⌘→ |
| 添加文件夹 | ⌘O | — |
| 重新扫描 | ⌘R | — |
| 均衡器 | ⌘E | — |
| 迷你播放器 | ⇧⌘M | — |

全局快捷键可在“设置 → 快捷键”修改；冲突会显示提示。关闭窗口后播放继续，通过 Dock 图标重新打开，使用 `⌘Q` 退出。

## 音效说明

“哈曼卡顿风格”为自主设计的听感模拟，不是品牌官方预设，不包含或宣称实现 Logic 7、Clari-Fi 等专有算法，也不等同于针对指定耳机测量生成的哈曼曲线校正。

自动增益空间根据正向频段增益预留前级余量，开启提升型预设后音量可能减小。它用于降低 EQ 导致的削波风险，不是响度归一化，也不是硬件音箱仿真。手动关闭自动余量时请注意音量和失真。

## 歌词与隐私

自动联网默认关闭。在歌词面板选择“联网匹配歌词”或在设置中开启后，应用向 [LRCLIB](https://lrclib.net/docs) 发送歌名、歌手、专辑与时长，不上传音乐、文件路径或曲库数据库。手动搜索只发送输入的查询文本。歌词缺失或联网失败不会阻断播放；服务限流时不自动重试。

为兼容早期版本，更名后保留原有沙箱标识与数据目录。应用索引、歌词与封面缓存仍保存在 Application Support/LocalMusic 下，可在设置中打开。沙箱版本的实际路径位于 `~/Library/Containers/app.localmusic.player/Data/Library/Application Support/LocalMusic/`。导入的文件夹通过 security-scoped bookmarks 保留访问权；移走文件夹或撤销权限后可能需要重新选择。

## 开发与验证

```bash
swift test
xcodegen generate
xcodebuild -project VSound.xcodeproj -scheme VSound -configuration Debug -derivedDataPath .build/xcode build
graphify update .
```

`Sources/MusicCore` 包含播放、队列、扫描、歌词、音效和持久化。`Sources/VSound` 包含界面、系统集成与应用状态。测试使用临时目录和合成音频，不读取个人曲库。
