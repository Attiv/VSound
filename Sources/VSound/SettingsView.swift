import AppKit
import MusicCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        TabView {
            general.tabItem { Label("通用", systemImage: "gearshape") }
            shortcuts.tabItem { Label("快捷键", systemImage: "keyboard") }
        }.frame(width: 590, height: 480)
    }
    private var general: some View {
        Form {
            Section("音乐曲库") {
                LabeledContent("音乐文件夹", value: "\(model.folders.count) 个 · \(model.tracks.count) 首歌曲")
                HStack {
                    Button("添加文件夹…", action: model.chooseFolders).disabled(model.isImporting)
                    Button("重新扫描", action: model.refreshLibrary).disabled(model.folders.isEmpty || model.isImporting)
                }
                Text("曲库只建立索引，不移动、不改名、不删除你的音乐。关闭主窗口后仍可继续播放，退出应用请使用 ⌘Q。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("歌词") {
                Toggle("自动联网匹配歌词", isOn: Binding(get: { model.onlineLyrics }, set: model.setOnlineLyrics))
                Text("优先使用同目录 LRC、缓存和内嵌歌词。联网时向 LRCLIB 发送歌名、歌手、专辑和时长，不上传音频；下载后缓存在本机。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("本地数据") {
                Button("在访达中打开应用数据目录") {
                    let directory = StateStore().directory
                    do {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(directory)
                    } catch { model.error = error.localizedDescription }
                }
                LabeledContent("版本", value: "维音 · VSound 1.0.0")
            }
        }.formStyle(.grouped)
    }
    private var shortcuts: some View {
        @Bindable var model = model
        return Form {
            Section {
                Toggle("启用全局快捷键", isOn: $model.hotKeysEnabled).onChange(of: model.hotKeysEnabled) { _, _ in
                    model.registerShortcuts(); model.scheduleSave()
                }
                Text("在其他应用中也能控制播放。点击右侧组合键后直接录制，按 Esc 取消；至少包含 ⌘、⌥ 或 ⌃。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("播放控制") {
                ForEach(HotKeyAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(action.title)
                            Spacer()
                            ShortcutRecorder(label: (model.hotKeys[action.rawValue] ?? action.defaultBinding).label) {
                                model.changeShortcut(action, binding: $0)
                            }.frame(width: 185, height: 28).disabled(!model.hotKeysEnabled)
                        }
                        if let error = model.shortcuts.errors[action.rawValue] {
                            Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                        }
                    }
                }
                Button("恢复默认快捷键", action: model.resetShortcuts)
            }
            Section {
                Text("应用内快捷键：Space 播放 / 暂停，⌘← / ⌘→ 切歌，⌘O 添加文件夹，⌘E 打开均衡器。系统媒体键与耳机控制也可控制当前播放。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
