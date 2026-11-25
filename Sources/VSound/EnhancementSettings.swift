import MusicCore
import SwiftUI

struct PlaybackSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section("音频输出") {
                Picker("播放设备", selection: Binding(get: { model.preferences.selectedDeviceUID ?? "" }, set: { model.chooseOutput($0.isEmpty ? nil : $0) })) {
                    Text("跟随系统输出").tag("")
                    ForEach(model.outputs.devices) { device in Text(device.name).tag(device.id) }
                    if let uid = model.preferences.selectedDeviceUID, !model.outputs.devices.contains(where: { $0.id == uid }) {
                        Text("设备暂未连接 · 已回退系统输出").tag(uid)
                    }
                }
                Text("每个输出设备分别记住音量与 EQ。指定设备断开时回退到系统输出，重新连接后恢复。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("歌曲衔接") {
                Picker("播放方式", selection: $model.preferences.transition) { ForEach(TransitionMode.allCases) { Text($0.title).tag($0) } }
                    .onChange(of: model.preferences.transition) { _, _ in model.updatePreferences() }
                if model.preferences.transition == .crossfade {
                    HStack {
                        Text("淡入淡出 \(model.preferences.crossfadeSeconds, specifier: "%.1f") 秒")
                        Slider(value: $model.preferences.crossfadeSeconds, in: 0.2...10, step: 0.1) { editing in if !editing { model.updatePreferences() } }
                            .accessibilityLabel("淡入淡出秒数")
                    }
                }
                Text("提前解码下一首，连续播放。交叉淡入淡出使用双音轨；短曲目会自动缩短重叠时长。音频统一转换为 48 kHz 立体声送入 EQ。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("响度均衡") {
                Picker("模式", selection: $model.preferences.loudness) { ForEach(LoudnessMode.allCases) { Text($0.title).tag($0) } }
                    .onChange(of: model.preferences.loudness) { _, _ in model.updatePreferences() }
                Text("目标 −18 LUFS，保留至少 1 dB 采样峰值余量。单曲模式用于随机听歌，专辑模式保留同专辑内的音量差异；只在播放时调整，不改音乐文件。先分析曲库后生效。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button("分析曲库响度", action: model.analyzeLoudness).disabled(model.isAnalyzing || model.tracks.isEmpty)
                    if model.isAnalyzing { ProgressView().controlSize(.small); Button("停止", action: model.cancelLoudnessAnalysis) }
                    Spacer()
                    Text("已分析 \(model.loudnessRecords.count) 首").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let status = model.analysisStatus { Text(status).font(.system(size: 11)).foregroundStyle(.secondary) }
                if let track = model.currentTrack { LabeledContent("当前播放调整", value: String(format: "%+.1f dB", model.loudnessGain(track))) }
            }
        }.formStyle(.grouped)
    }
}

struct LyricsSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section("歌词来源") {
                Toggle("自动联网匹配歌词", isOn: Binding(get: { model.onlineLyrics }, set: model.setOnlineLyrics))
                ForEach(LyricSource.allCases) { source in
                    Toggle(source.title, isOn: Binding(get: { model.preferences.lyricSources.contains(source) }, set: { enabled in
                        if enabled { if !model.preferences.lyricSources.contains(source) { model.preferences.lyricSources.append(source) } }
                        else { model.preferences.lyricSources.removeAll { $0 == source } }
                        model.updatePreferences()
                    }))
                }
                Text("搜索和匹配会向已选择的服务发送歌名、歌手及匹配所需时长，不上传音频或文件路径。第三方接口可能变化；每个来源的失败会单独显示。至少保留一个来源。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button("为曲库补齐缺失歌词") { model.lyrics.fillMissing(model.tracks) }.disabled(model.lyrics.isFilling || model.tracks.isEmpty)
                    if model.lyrics.isFilling { ProgressView().controlSize(.small); Button("停止", action: model.lyrics.cancelFill) }
                }
                if let status = model.lyrics.fillMessage { Text(status).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Section("桌面歌词") {
                Toggle("显示悬浮歌词", isOn: $model.preferences.desktopLyrics.enabled)
                    .onChange(of: model.preferences.desktopLyrics.enabled) { _, _ in model.updatePreferences() }
                Toggle("锁定位置并允许点击穿透", isOn: $model.preferences.desktopLyrics.locked)
                    .onChange(of: model.preferences.desktopLyrics.locked) { _, _ in model.updatePreferences() }
                Toggle("显示双语 / 翻译行", isOn: $model.preferences.desktopLyrics.showsTranslation)
                    .onChange(of: model.preferences.desktopLyrics.showsTranslation) { _, _ in model.updatePreferences() }
                HStack { Text("字号 \(Int(model.preferences.desktopLyrics.fontSize))").frame(width: 90, alignment: .leading)
                    Slider(value: $model.preferences.desktopLyrics.fontSize, in: 14...72, step: 1) { editing in if !editing { model.updatePreferences() } }.accessibilityLabel("桌面歌词字号") }
                HStack { Text("背景透明度").frame(width: 90, alignment: .leading)
                    Slider(value: $model.preferences.desktopLyrics.opacity, in: 0.3...1) { editing in if !editing { model.updatePreferences() } }.accessibilityLabel("桌面歌词背景透明度") }
                Text("悬浮窗会跟随当前播放进度。锁定后从“工具 → 解锁桌面歌词”恢复操作。双语来自所选歌词源提供的翻译，不自动发送到翻译服务。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct UpdateSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section("维音 · VSound") {
                LabeledContent("当前版本", value: model.appVersion)
                Toggle("启动时检查新版本", isOn: $model.preferences.checksUpdatesAutomatically)
                    .onChange(of: model.preferences.checksUpdatesAutomatically) { _, enabled in model.updatePreferences(); if enabled { model.checkForUpdates() } }
                Text("只查询公开 GitHub Release 的版本信息，不发送曲库或设备标识。下载和安装由你决定，不会自动替换应用。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button("检查更新", action: model.checkForUpdates).disabled(model.isCheckingUpdates)
                    if model.isCheckingUpdates { ProgressView().controlSize(.small) }
                    if model.availableUpdate != nil { Button("打开版本下载页", action: model.openUpdate) }
                }
                if let status = model.updateStatus { Text(status).font(.system(size: 12)).textSelection(.enabled) }
            }
            if let release = model.availableUpdate {
                Section(release.version) { Text(String((release.body ?? "请前往 GitHub 查看更新说明。").prefix(10_000))).font(.system(size: 11)).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
    }
}
