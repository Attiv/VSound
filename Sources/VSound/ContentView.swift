import AppKit
import MusicCore
import SwiftUI
import UniformTypeIdentifiers

private enum SidebarSelection: Hashable { case page(LibraryPage), folder(UUID) }

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var dropTargeted = false
    @State private var showNowPlaying = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 280)
        } detail: {
            HStack(spacing: 0) {
                LibraryContent().frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.showInspector {
                    Rectangle().fill(Theme.line).frame(width: 1)
                    InspectorView().frame(width: 290)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .background(Theme.canvas)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: model.chooseFolders) { Label("添加文件夹", systemImage: "folder.badge.plus") }
                        .help("添加音乐文件夹 · ⌘O").disabled(model.isImporting)
                    Button { openWindow(id: "equalizer") } label: { Label("均衡器", systemImage: "slider.horizontal.3") }
                        .help("均衡器 · ⌘E")
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { model.showInspector.toggle() }
                    } label: { Label("歌词与队列", systemImage: "sidebar.right") }
                    .help("显示或隐藏歌词与队列")
                }
            }
            .searchable(text: $model.search, placement: .toolbar, prompt: "搜索歌曲、歌手、专辑")
        }
        .navigationTitle("")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar(onExpand: { showNowPlaying = true })
        }
        .frame(minWidth: 980, minHeight: 640)
        .background(Theme.canvas)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(12).background(Theme.accent.opacity(0.04)).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url { urls.append(url) }
                }
                model.importFolders(urls)
            }
            return !providers.isEmpty
        }
        .alert("需要留意", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $showNowPlaying) { NowPlayingView().environment(model) }
        .onChange(of: model.notice) { _, value in
            guard let value else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if model.notice == value { model.notice = nil }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(Theme.accent)
                    Image(systemName: "waveform").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.sidebar)
                }.frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("维音").font(.system(size: 21, weight: .semibold))
                    Text("VSOUND").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(Theme.muted)
                }
                Spacer()
            }.padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 24)
            List(selection: Binding<SidebarSelection?>(
                get: { model.selectedFolderID.map(SidebarSelection.folder) ?? .page(model.page) },
                set: { selection in
                    switch selection {
                    case .page(let page): model.navigate(page)
                    case .folder(let id): model.navigate(.songs, folderID: id)
                    case nil: break
                    }
                }
            )) {
                Section("资料库") {
                    ForEach(LibraryPage.allCases) { page in
                        Label { Text(page.title) } icon: { Image(systemName: page.symbol).foregroundStyle(.secondary) }
                            .font(.system(size: 13)).padding(.vertical, 6)
                            .tag(SidebarSelection.page(page))
                    }
                }
                Section("音乐文件夹") {
                    ForEach(model.folders) { folder in
                        Label { Text(folder.url.lastPathComponent) } icon: {
                            Image(systemName: model.unavailableFolders.contains(folder.id) ? "folder.badge.questionmark" : "folder")
                                .foregroundStyle(.secondary)
                        }
                            .lineLimit(1).padding(.vertical, 5).tag(SidebarSelection.folder(folder.id))
                            .help(folder.url.path)
                            .contextMenu {
                                Button("在访达中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.url.path) }
                                Button("重新扫描") { model.importFolders([folder.url], refreshing: true) }.disabled(model.isImporting)
                                Divider()
                                Button("从曲库移除", role: .destructive) { model.removeFolder(folder) }.disabled(model.isImporting)
                            }
                    }
                    Button(action: model.chooseFolders) { Label("添加文件夹", systemImage: "plus") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.vertical, 5).disabled(model.isImporting)
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack(spacing: 7) {
                    Circle().fill(Theme.accent.opacity(0.8)).frame(width: 5, height: 5)
                    Text("你的音乐，只属于你。").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }.padding(.top, 9)
                Text("\(model.tracks.count) 首歌曲 · \(model.folders.count) 个文件夹")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted.opacity(0.7))
            }.padding(22)
        }.background(Theme.sidebar)
    }
}

struct LibraryContent: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let tracks = model.visibleTracks
        VStack(alignment: .leading, spacing: 0) {
            heading(tracks)
            if model.tracks.isEmpty { WelcomeView() }
            else if tracks.isEmpty {
                ContentUnavailableView(model.search.isEmpty ? "这里还很安静" : "没有找到歌曲",
                                       systemImage: model.search.isEmpty ? model.page.symbol : "magnifyingglass",
                                       description: Text(model.page == .favorites && model.search.isEmpty ? "点亮歌曲旁的爱心，把喜欢的留在这里。" : "试试其他关键词，或添加一个音乐文件夹。"))
            } else if (model.page == .albums || model.page == .artists), model.selectedGroup == nil, model.selectedFolderID == nil {
                CollectionGrid(tracks: tracks, albums: model.page == .albums)
            } else {
                TrackTable(tracks: tracks)
            }
            if model.isImporting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在扫描音乐… 已发现 \(model.importCount) 首").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("停止", action: model.cancelImport).buttonStyle(.plain).font(.system(size: 11))
                }.padding(14).background(Theme.surface)
            } else if let notice = model.notice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    Text(notice).lineLimit(2)
                    Spacer()
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭提示")
                }.font(.system(size: 11)).padding(12).background(Theme.surface)
            }
        }
    }

    private func heading(_ tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "YOUR SOUND. YOUR SPACE.")
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 7) {
                    if model.selectedGroup != nil {
                        Button { model.selectedGroup = nil } label: { Label("返回\(model.page.title)", systemImage: "chevron.left") }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text(title(tracks)).font(.system(size: 30, weight: .semibold)).lineLimit(1)
                    Text(tracks.isEmpty ? "好音乐，不必远行。" : "\(tracks.count) 首歌曲 · \(durationDescription(tracks))")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 12)
                if !tracks.isEmpty {
                    Button { if let first = tracks.first { model.play(first, in: tracks) } } label: {
                        Label("播放", systemImage: "play.fill").font(.system(size: 12, weight: .semibold))
                    }.buttonStyle(QuietButtonStyle(prominent: true))
                    Button { model.shufflePlay(tracks) } label: {
                        Image(systemName: "shuffle").frame(height: 14)
                    }.buttonStyle(QuietButtonStyle()).help("随机播放当前列表").accessibilityLabel("随机播放当前列表")
                }
            }
        }.padding(.horizontal, 28).padding(.top, 29).padding(.bottom, 25)
    }

    private func title(_ tracks: [Track]) -> String {
        if let title = model.folderTitle { return title }
        if model.selectedGroup != nil, let first = tracks.first { return model.page == .albums ? first.album : first.artist }
        return model.page.title
    }
    private func durationDescription(_ tracks: [Track]) -> String {
        let seconds = Int(tracks.reduce(0) { $0 + $1.duration })
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟"
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 10)
            ZStack {
                Circle().fill(Theme.accent.opacity(0.035)).frame(width: 258, height: 258)
                Circle().stroke(Theme.accent.opacity(0.08), lineWidth: 1).frame(width: 232, height: 232)
                CoverArt(radius: 24).frame(width: 178, height: 178).rotationEffect(.degrees(-9))
                    .shadow(color: .black.opacity(0.35), radius: 25, y: 18)
                Image(systemName: "music.note").font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.accent).frame(width: 52, height: 52)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line))
                    .offset(x: 85, y: 68)
            }.accessibilityHidden(true)
            Text("让喜欢的音乐，留在身边。").font(.system(size: 23, weight: .medium)).padding(.top, 22)
            Text("添加你的音乐文件夹，余下的交给维音。\n支持子文件夹，原始文件始终留在原处。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineSpacing(6).padding(.top, 12)
            Button(action: model.chooseFolders) { Label("选择音乐文件夹", systemImage: "folder.badge.plus").font(.system(size: 13, weight: .semibold)) }
                .buttonStyle(QuietButtonStyle(prominent: true)).disabled(model.isImporting).padding(.top, 24)
            Text("或将文件夹拖到窗口中").font(.system(size: 10)).foregroundStyle(Theme.muted.opacity(0.8)).padding(.top, 12)
            HStack(spacing: 9) {
                ForEach(["FLAC", "ALAC", "MP3", "AAC", "WAV"], id: \.self) { format in
                    Text(format).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(0.6)
                        .foregroundStyle(Theme.muted).padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(Theme.line))
                }
            }.padding(.top, 30)
            Spacer(minLength: 24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
