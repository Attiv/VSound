import MusicCore
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Eyebrow(text: "ON THE RECORD")
                Spacer()
                if let track = model.currentTrack {
                    Text(track.fileType).font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.muted).padding(.horizontal, 6).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
                }
            }.padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 20)
            CoverArt(track: model.currentTrack, radius: 14).aspectRatio(1, contentMode: .fit).padding(.horizontal, 28)
                .shadow(color: .black.opacity(0.2), radius: 16, y: 10)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.currentTrack?.title ?? "此刻，留给音乐").font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    Text(model.currentTrack?.artist ?? "从一首喜欢的歌开始。")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let track = model.currentTrack {
                    IconButton(symbol: model.favorites.contains(track.id) ? "heart.fill" : "heart", label: "收藏当前歌曲",
                               active: model.favorites.contains(track.id)) { model.toggleFavorite(track) }
                }
            }.padding(.horizontal, 25).padding(.top, 22).padding(.bottom, 20)
            Picker("歌词或队列", selection: $model.inspectorTab) {
                Text("歌词").tag("lyrics")
                Text("播放队列").tag("queue")
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 12)
            if model.inspectorTab == "lyrics" { LyricsPane() }
            else { QueuePane() }
        }.frame(maxHeight: .infinity).background(Theme.sidebar.opacity(0.55))
    }
}

struct LyricsPane: View {
    @Environment(AppModel.self) private var model
    @State private var showSearch = false
    @State private var following = true
    var body: some View {
        VStack(spacing: 0) {
            if let document = model.lyrics.document {
                if document.isSynced {
                    SyncedLyrics(document: document, following: following)
                } else {
                    ScrollView {
                        Text(document.plainText).font(.system(size: 14)).lineSpacing(12)
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(24)
                    }
                }
            } else {
                VStack(spacing: 14) {
                    Spacer(minLength: 8)
                    if model.lyrics.isLoading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "text.alignleft").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.muted.opacity(0.5)) }
                    Text(model.lyrics.status).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center).lineSpacing(5).padding(.horizontal, 22)
                    if model.currentTrack != nil, !model.lyrics.isLoading {
                        Button("联网匹配歌词") { model.setOnlineLyrics(true) }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                        Button("导入本地 LRC", action: model.lyrics.importFile)
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 12)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.currentTrack != nil {
                VStack(spacing: 9) {
                    if model.lyrics.document?.isSynced == true {
                        HStack(spacing: 8) {
                            Button { model.setLyricsOffset(model.lyricsOffset - 0.5) } label: { Image(systemName: "minus") }
                                .help("歌词提前 0.5 秒").accessibilityLabel("歌词提前半秒")
                            Text(String(format: "%+.1fs", model.lyricsOffset)).font(.system(size: 9, design: .monospaced)).frame(width: 43)
                            Button { model.setLyricsOffset(model.lyricsOffset + 0.5) } label: { Image(systemName: "plus") }
                                .help("歌词延后 0.5 秒").accessibilityLabel("歌词延后半秒")
                            Spacer()
                            Button(following ? "跟随中" : "跟随歌词") { following.toggle() }
                                .foregroundStyle(following ? Theme.accent : Theme.muted)
                        }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                    HStack {
                        Text(model.lyrics.document?.source ?? "歌词").font(.system(size: 9)).foregroundStyle(Theme.muted)
                        Spacer()
                        Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                            .help("手动搜索歌词").accessibilityLabel("手动搜索歌词")
                        Menu {
                            Button("导入歌词…", action: model.lyrics.importFile)
                            Button("导出歌词…", action: model.lyrics.exportFile).disabled(model.lyrics.document == nil)
                            Button("重新匹配歌词") { if let track = model.currentTrack { model.lyrics.load(track, online: true) } }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }.padding(.horizontal, 24).padding(.vertical, 13)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
        }
        .sheet(isPresented: $showSearch) { LyricsSearchView().environment(model) }
    }
}

private struct SyncedLyrics: View {
    let document: LyricsDocument
    let following: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let active = document.activeLine(at: model.player.position - model.lyricsOffset)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(document.lines) { line in
                        Button { model.seek(line.time + model.lyricsOffset) } label: {
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: 16, weight: line.id == active ? .semibold : .medium))
                                .foregroundStyle(line.id == active ? Color.primary : Theme.muted.opacity(0.7))
                                .lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).id(line.id)
                            .accessibilityLabel("\(line.text)，跳到 \(MusicFormatting.time(line.time))")
                    }
                }.padding(.horizontal, 25).padding(.vertical, 28)
            }
            .onChange(of: active, initial: true) { _, line in
                guard following, let line else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.26)) { proxy.scrollTo(line, anchor: .center) }
            }
            .onChange(of: following) { _, follow in
                if follow, let active { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(active, anchor: .center) } }
            }
        }
    }
}

struct QueuePane: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let lookup = Dictionary(model.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let upcoming = model.queue.upcomingIDs.compactMap { lookup[$0] }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if let current = model.currentTrack {
                    Text("正在播放").font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.bottom, 6)
                    queueRow(current, current: true)
                    Text("接下来 · \(upcoming.count)").font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.top, 18).padding(.bottom, 6)
                }
                ForEach(upcoming) { track in
                    queueRow(track, current: false)
                        .contextMenu { Button("从队列移除") { model.removeFromQueue(track.id) } }
                }
                if upcoming.isEmpty {
                    Text(model.currentTrack == nil ? "播放一首歌曲，即可在这里查看队列。" : model.queue.repeatMode == .all ? "本轮结束后会继续循环。" : "这里已经是队列的最后。")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(5).padding(.vertical, 14)
                }
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
    private func queueRow(_ track: Track, current: Bool) -> some View {
        Button {
            let queueTracks = model.queue.trackIDs.compactMap { id in model.tracks.first { $0.id == id } }
            model.play(track, in: queueTracks)
        } label: {
            HStack(spacing: 10) {
                CoverArt(track: track, radius: 5).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.system(size: 11, weight: .medium)).foregroundStyle(current ? Theme.accent : Color.primary).lineLimit(1)
                    Text(track.artist).font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(MusicFormatting.time(track.duration)).font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.muted)
            }.padding(7).background(current ? Theme.accent.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
}

struct LyricsSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var lyrics = model.lyrics
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("找到这一首的歌词").font(.system(size: 21, weight: .semibold))
                    Text("搜索会将输入的歌名和歌手发送给 LRCLIB，不上传音乐文件。")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                IconButton(symbol: "xmark", label: "关闭搜索") { dismiss() }
            }
            HStack {
                TextField("歌名或歌手", text: $lyrics.searchQuery).textFieldStyle(.roundedBorder).onSubmit(lyrics.searchOnline)
                Button("搜索", action: lyrics.searchOnline).disabled(lyrics.isSearching || lyrics.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if lyrics.isSearching { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
            if let message = lyrics.searchMessage { Text(message).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            List(lyrics.candidates) { candidate in
                Button {
                    lyrics.choose(candidate); dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(candidate.trackName).font(.system(size: 13, weight: .medium))
                            Text("\(candidate.artistName) · \(candidate.albumName)").font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer()
                        Text(candidate.document?.isSynced == true ? "逐行" : "文本").font(.system(size: 9)).foregroundStyle(Theme.accent)
                        Text(MusicFormatting.time(candidate.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                    }.padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.listStyle(.inset).scrollContentBackground(.hidden)
        }.padding(26).frame(width: 590, height: 450).background(Theme.canvas)
    }
}
