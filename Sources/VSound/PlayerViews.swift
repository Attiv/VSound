import MusicCore
import SwiftUI

struct PlayerBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var onExpand: () -> Void
    var body: some View {
        HStack(spacing: 25) {
            Button(action: onExpand) {
                HStack(spacing: 12) {
                    CoverArt(track: model.currentTrack, radius: 8).frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.currentTrack?.title ?? "还未播放").font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(model.currentTrack?.artist ?? "好音乐，慢慢听。")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).frame(width: 225).disabled(model.currentTrack == nil).help("展开正在播放")
            VStack(spacing: 8) {
                PlaybackControls()
                PlaybackScrubber()
            }.frame(maxWidth: .infinity)
            HStack(spacing: 7) {
                VolumeControl().frame(width: 125)
                Rectangle().fill(Theme.line).frame(width: 1, height: 24).padding(.horizontal, 5)
                IconButton(symbol: "slider.horizontal.3", label: "均衡器", active: model.equalizer.enabled) { openWindow(id: "equalizer") }
                IconButton(symbol: "list.bullet", label: "播放队列", active: model.showInspector && model.inspectorTab == "queue") {
                    model.inspectorTab = "queue"; model.showInspector = true
                }
                IconButton(symbol: "pip", label: "迷你播放器") { openWindow(id: "mini") }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 17)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

struct PlaybackControls: View {
    @Environment(AppModel.self) private var model
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 10 : 17) {
            if !compact { IconButton(symbol: "shuffle", label: model.queue.isShuffled ? "关闭随机播放" : "开启随机播放", active: model.queue.isShuffled, size: 13, action: model.toggleShuffle) }
            IconButton(symbol: "backward.end.fill", label: "上一首", size: compact ? 14 : 17, action: model.previous)
                .disabled(model.currentTrack == nil)
            Button(action: model.togglePlayback) {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: compact ? 14 : 17, weight: .semibold))
                    .offset(x: model.player.isPlaying ? 0 : 1)
                    .foregroundStyle(Theme.sidebar)
                    .frame(width: compact ? 34 : 40, height: compact ? 34 : 40)
                    .background(Theme.accent, in: Circle())
            }.buttonStyle(.plain).disabled(model.tracks.isEmpty)
                .help(model.player.isPlaying ? "暂停 · Space" : "播放 · Space")
                .accessibilityLabel(model.player.isPlaying ? "暂停" : "播放")
            IconButton(symbol: "forward.end.fill", label: "下一首", size: compact ? 14 : 17) { model.next() }
                .disabled(model.currentTrack == nil)
            if !compact {
                IconButton(symbol: model.queue.repeatMode == .one ? "repeat.1" : "repeat",
                           label: model.queue.repeatMode.title + "，点击切换", active: model.queue.repeatMode != .off,
                           size: 14, action: model.cycleRepeat)
            }
        }
    }
}

struct PlaybackScrubber: View {
    @Environment(AppModel.self) private var model
    @State private var isEditing = false
    @State private var draft = 0.0
    var body: some View {
        HStack(spacing: 9) {
            Text(MusicFormatting.time(isEditing ? draft : model.player.position)).frame(width: 37, alignment: .trailing)
            Slider(value: Binding(get: { isEditing ? draft : model.player.position }, set: {
                draft = $0
                if !isEditing { model.seek($0) }
            }),
                   in: 0...max(1, model.player.duration), onEditingChanged: { editing in
                if editing { draft = model.player.position; isEditing = true }
                else { model.seek(draft); isEditing = false }
            }).controlSize(.mini).disabled(model.player.loadedID == nil).accessibilityLabel("播放进度")
            Text(MusicFormatting.time(model.player.duration)).frame(width: 37, alignment: .leading)
        }.font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted)
    }
}

struct VolumeControl: View {
    @Environment(AppModel.self) private var model
    @State private var previousVolume: Float = 0.7
    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", label: "静音 / 恢复音量", size: 12) {
                if model.volume > 0 { previousVolume = model.volume; model.setVolume(0) }
                else { model.setVolume(previousVolume > 0 ? previousVolume : 0.7) }
            }
            Slider(value: Binding(get: { Double(model.volume) }, set: { model.setVolume(Float($0)) }), in: 0...1)
                .controlSize(.mini).accessibilityLabel("音量").help("音量 \(Int(model.volume * 100))%")
        }
    }
}

struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 13) {
                CoverArt(track: model.currentTrack, radius: 9).frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.currentTrack?.title ?? "维音").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(model.currentTrack?.artist ?? "选择一首喜欢的歌").font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                PlaybackControls(compact: true)
            }
            PlaybackScrubber()
        }.padding(18).frame(width: 420).background(Theme.canvas)
        .contextMenu { Button("打开曲库") { openWindow(id: "main") } }
    }
}

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Eyebrow(text: "NOW PLAYING")
                Spacer()
                IconButton(symbol: "xmark", label: "收起正在播放") { dismiss() }
            }.padding(.horizontal, 28).padding(.top, 16)
            HStack(spacing: 45) {
                VStack(alignment: .leading, spacing: 12) {
                    CoverArt(track: model.currentTrack, radius: 18).frame(width: 300, height: 300)
                        .shadow(color: .black.opacity(0.3), radius: 24, y: 18).padding(.bottom, 12)
                    Text(model.currentTrack?.title ?? "还未播放").font(.system(size: 25, weight: .semibold)).lineLimit(2)
                    Text(model.currentTrack?.artist ?? "").font(.system(size: 14)).foregroundStyle(Theme.muted)
                    Text(model.currentTrack?.album ?? "").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }.frame(width: 310)
                LyricsPane().frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(.horizontal, 42).padding(.vertical, 25)
            PlayerBar(onExpand: { dismiss() })
        }.frame(width: 900, height: 650).background(Theme.canvas)
    }
}
