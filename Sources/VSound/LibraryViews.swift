import AppKit
import MusicCore
import SwiftUI

struct TrackTable: View {
    let tracks: [Track]
    @Environment(AppModel.self) private var model
    @State private var selectedID: String?
    var body: some View {
        Table(tracks, selection: $selectedID) {
            TableColumn("歌曲") { track in
                HStack(spacing: 11) {
                    CoverArt(track: track, radius: 6).frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(model.queue.currentID == track.id ? Theme.accent : Color.primary).lineLimit(1)
                        Text(track.artist).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .draggable(track.id)
                    Spacer(minLength: 0)
                    if model.queue.currentID == track.id {
                        Image(systemName: model.player.isPlaying ? "waveform" : "pause.fill")
                            .foregroundStyle(Theme.accent).font(.system(size: 11)).accessibilityLabel("当前歌曲")
                    }
                }.frame(height: 52)
            }.width(min: 190, ideal: 260)
            TableColumn("专辑") { track in
                Text(track.album).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }.width(min: 80, ideal: 130)
            TableColumn("时长") { track in
                Text(MusicFormatting.time(track.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
            }.width(47)
            TableColumn("") { track in
                Button { model.toggleFavorite(track) } label: {
                    Image(systemName: model.favorites.contains(track.id) ? "heart.fill" : "heart")
                        .foregroundStyle(model.favorites.contains(track.id) ? Theme.accent : Theme.muted.opacity(0.55))
                }.buttonStyle(.plain).help("收藏 / 取消收藏").accessibilityLabel("收藏或取消收藏 \(track.title)")
            }.width(28)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let track = tracks.first(where: { $0.id == id }) {
                Button("播放") { model.play(track, in: tracks) }
                Button("下一首播放") { model.enqueue(track, next: true) }
                Button("添加到队列") { model.enqueue(track, next: false) }
                Menu("添加到歌单") {
                    ForEach(model.playlists) { playlist in
                        Button(playlist.name) { model.addToPlaylist(tracks.filter { ids.contains($0.id) }.map(\.id), playlistID: playlist.id) }
                    }
                    Button("新建歌单…", action: model.createPlaylist)
                }
                Divider()
                Button(model.favorites.contains(track.id) ? "取消收藏" : "收藏") { model.toggleFavorite(track) }
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([track.url]) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let track = tracks.first(where: { $0.id == id }) { model.play(track, in: tracks) }
        }
        .onKeyPress(.return) {
            guard let selectedID, let track = tracks.first(where: { $0.id == selectedID }) else { return .ignored }
            model.play(track, in: tracks); return .handled
        }
        .padding(.horizontal, 15)
    }
}

struct PlaylistTracksView: View {
    let tracks: [Track]
    @Environment(AppModel.self) private var model
    var body: some View {
        if tracks.isEmpty {
            ContentUnavailableView("把喜欢的歌放进来", systemImage: "music.note.list",
                                   description: Text("在所有歌曲中右键添加到歌单，或把歌曲拖到侧栏的歌单。M3U 中未加入曲库的歌曲需要先添加音乐文件夹。"))
        } else {
            List {
                ForEach(tracks) { track in
                    HStack(spacing: 12) {
                        CoverArt(track: track, radius: 5).frame(width: 38, height: 38)
                        Button { model.play(track, in: tracks) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(track.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(track.artist).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Text(MusicFormatting.time(track.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        Menu {
                            Button("下一首播放") { model.enqueue(track, next: true) }
                            if let index = tracks.firstIndex(where: { $0.id == track.id }) {
                                Button("上移") { model.movePlaylistTracks(IndexSet(integer: index), to: index - 1) }.disabled(index == 0 || !model.search.isEmpty)
                                Button("下移") { model.movePlaylistTracks(IndexSet(integer: index), to: index + 2) }.disabled(index == tracks.count - 1 || !model.search.isEmpty)
                            }
                            Button("从歌单移除", role: .destructive) { model.removeFromPlaylist(track) }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("歌曲操作：\(track.title)")
                    }.padding(.vertical, 6)
                }.onMove(perform: model.movePlaylistTracks).moveDisabled(!model.search.isEmpty)
            }.listStyle(.inset).scrollContentBackground(.hidden).padding(.horizontal, 15)
        }
    }
}

private struct MusicCollection: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let tracks: [Track]
}

struct CollectionGrid: View {
    let tracks: [Track]
    let albums: Bool
    @Environment(AppModel.self) private var model
    private var groups: [MusicCollection] {
        Dictionary(grouping: tracks, by: { albums ? $0.albumID : $0.artist }).map { key, songs in
            MusicCollection(id: key, title: albums ? songs[0].album : songs[0].artist,
                            subtitle: albums ? songs[0].artist : "\(songs.count) 首歌曲", tracks: songs)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 210), spacing: 22)], alignment: .leading, spacing: 26) {
                ForEach(groups) { group in
                    Button { model.selectedGroup = group.id } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            CoverArt(track: group.tracks.first, radius: albums ? 12 : 80)
                                .aspectRatio(1, contentMode: .fit).padding(.bottom, 3)
                            Text(group.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(group.subtitle).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .contextMenu {
                        Button("播放") { if let first = group.tracks.first { model.play(first, in: group.tracks) } }
                        Button("随机播放") { model.shufflePlay(group.tracks) }
                    }
                }
            }.padding(.horizontal, 28).padding(.bottom, 28)
        }
    }
}
