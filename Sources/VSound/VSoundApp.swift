import AppKit
import MusicCore
import SwiftUI

@main
struct VSoundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("维音", id: "main") {
            ContentView().environment(model).preferredColorScheme(.dark).tint(Theme.accent)
        }
        .defaultSize(width: 1260, height: 800)
        .windowStyle(.automatic)
        .commands {
            SidebarCommands()
            MusicCommands(model: model)
        }
        Window("均衡器", id: "equalizer") {
            EqualizerView().environment(model).preferredColorScheme(.dark).tint(Theme.accent)
        }
        .defaultSize(width: 850, height: 700)
        .windowResizability(.contentSize)
        Window("迷你播放器", id: "mini") {
            MiniPlayerView().environment(model).preferredColorScheme(.dark).tint(Theme.accent)
        }
        .defaultSize(width: 420, height: 140)
        .windowResizability(.contentSize)
        Settings {
            SettingsView().environment(model).preferredColorScheme(.dark).tint(Theme.accent)
        }
    }
}

struct MusicCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于维音") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: "维音 · VSound",
                    .applicationVersion: "1.0.0",
                    .credits: NSAttributedString(string: "本地音乐，恰到好处。\n歌词服务：LRCLIB\n哈曼卡顿风格预设为自主调音。")
                ])
            }
        }
        CommandGroup(after: .newItem) {
            Button("添加音乐文件夹…", action: model.chooseFolders).keyboardShortcut("o")
            Button("重新扫描曲库", action: model.refreshLibrary).keyboardShortcut("r")
                .disabled(model.folders.isEmpty || model.isImporting)
        }
        CommandMenu("播放") {
            Button(model.player.isPlaying ? "暂停" : "播放", action: model.togglePlayback)
                .keyboardShortcut(.space, modifiers: []).disabled(model.tracks.isEmpty)
            Button("下一首") { model.next() }.keyboardShortcut(.rightArrow).disabled(model.currentTrack == nil)
            Button("上一首", action: model.previous).keyboardShortcut(.leftArrow).disabled(model.currentTrack == nil)
            Divider()
            Button(model.queue.isShuffled ? "关闭随机播放" : "开启随机播放", action: model.toggleShuffle)
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("切换循环模式", action: model.cycleRepeat).keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("增大音量") { model.setVolume(model.volume + 0.05) }.keyboardShortcut(.upArrow)
            Button("减小音量") { model.setVolume(model.volume - 0.05) }.keyboardShortcut(.downArrow)
        }
        CommandMenu("工具") {
            Button("音乐曲库") { openWindow(id: "main") }.keyboardShortcut("1")
            Button("均衡器") { openWindow(id: "equalizer") }.keyboardShortcut("e")
            Button("迷你播放器") { openWindow(id: "mini") }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button("显示 / 隐藏歌词与队列") { model.showInspector.toggle() }.keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
