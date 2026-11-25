import AppKit
import Foundation
import MusicCore
import Observation
import UniformTypeIdentifiers

enum LibraryPage: String, CaseIterable, Identifiable {
    case songs, albums, artists, favorites, recent
    var id: String { rawValue }
    var title: String {
        switch self { case .songs: "所有歌曲"; case .albums: "专辑"; case .artists: "歌手"; case .favorites: "我的收藏"; case .recent: "最近播放" }
    }
    var symbol: String {
        switch self { case .songs: "music.note.list"; case .albums: "square.stack"; case .artists: "person.2"; case .favorites: "heart"; case .recent: "clock" }
    }
}

@MainActor @Observable
final class AppModel {
    var tracks: [Track] = []
    var folders: [LibraryFolder] = []
    var favorites: Set<String> = []
    var recentIDs: [String] = []
    var queue = PlaybackQueue()
    var equalizer = EQSettings()
    var customPresets: [SavedEQPreset] = []
    var volume: Float = 0.7
    var onlineLyrics = false
    var lyricsOffsets: [String: Double] = [:]
    var hotKeys: [String: HotKeyBinding] = [:]
    var hotKeysEnabled = true
    var page: LibraryPage = .songs
    var selectedFolderID: UUID?
    var selectedGroup: String?
    var search = ""
    var showInspector = true
    var settingsTab = "general"
    var inspectorTab = "lyrics"
    var isImporting = false
    var importCount = 0
    var notice: String?
    var error: String?
    var unavailableFolders: Set<UUID> = []
    let player = AudioPlayer()
    let lyrics: LyricsModel
    let cloud: CloudModel
    let shortcuts = HotKeyManager()
    @ObservationIgnored private let store: StateStore
    @ObservationIgnored private let scanner: LibraryScanner
    @ObservationIgnored private let diskQueue = DispatchQueue(label: "app.vsound.persistence", qos: .utility)
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var saveTimer: Timer?
    @ObservationIgnored private var scopedURLs: [UUID: URL] = [:]
    @ObservationIgnored private var canSave = true
    @ObservationIgnored private var remote: RemoteControl?

    init(store: StateStore = StateStore()) {
        self.store = store
        scanner = LibraryScanner(artworkDirectory: store.artworkDirectory)
        lyrics = LyricsModel(client: LyricsClient(directory: store.lyricsDirectory))
        cloud = CloudModel(directory: store.cloudMusicDirectory)
        do {
            let state = try store.load()
            tracks = state.tracks; folders = state.folders; favorites = state.favorites
            recentIDs = state.recentIDs; queue = state.queue
            equalizer = state.equalizer; equalizer.normalize(); customPresets = state.customPresets
            volume = state.volume.isFinite ? min(1, max(0, state.volume)) : 0.7
            onlineLyrics = state.onlineLyrics; lyricsOffsets = state.lyricsOffsets
            hotKeys = state.hotKeys; hotKeysEnabled = state.hotKeysEnabled
            restoreFolderAccess()
            queue.retain(Set(tracks.map(\.id)))
            if let track = currentTrack, FileManager.default.fileExists(atPath: track.url.path) {
                try? player.load(track, at: state.position, autoplay: false)
                lyrics.load(track, online: onlineLyrics)
            }
        } catch {
            do {
                let backup = try store.preserveUnreadableState()
                self.error = "曲库记录无法读取，已保留备份：\(backup.lastPathComponent)。音乐文件未受影响。"
            } catch {
                canSave = false
                self.error = "曲库记录无法读取，暂时停止保存以保护原始记录。请检查应用数据目录。"
            }
        }
        player.apply(equalizer)
        player.setVolume(volume)
        player.onEnded = { [weak self] in self?.next(automatic: true) }
        player.onStateChanged = { [weak self] in
            self?.remote?.update()
            self?.scheduleSave()
        }
        shortcuts.onAction = { [weak self] action in
            switch action { case .playPause: self?.togglePlayback(); case .previous: self?.previous(); case .next: self?.next() }
        }
        registerShortcuts()
        remote = RemoteControl(model: self)
        saveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.isPlaying else { return }
                self.scheduleSave(); self.remote?.update()
            }
        }
        AppDelegate.model = self
        cloud.onImport = { [weak self] result in
            guard let self else { throw CancellationError() }
            try await self.importCloudFolder(result)
        }
    }

    deinit { saveTimer?.invalidate() }

    var currentTrack: Track? { queue.currentID.flatMap { id in tracks.first { $0.id == id } } }
    var currentPresetName: String {
        EQPreset.builtIn.first { $0.id == equalizer.presetID }?.name
            ?? customPresets.first { $0.id == equalizer.presetID }?.name ?? "自定义"
    }
    var folderTitle: String? { folders.first { $0.id == selectedFolderID }?.name }
    var visibleTracks: [Track] {
        var result = tracks
        if let selectedFolderID, let folder = folders.first(where: { $0.id == selectedFolderID }) {
            result = result.filter { Self.isInside($0.url, folder: folder.url) }
        } else if page == .favorites { result = result.filter { favorites.contains($0.id) } }
        else if page == .recent {
            let lookup = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            result = recentIDs.compactMap { lookup[$0] }
        }
        if let selectedGroup {
            result = result.filter { page == .albums ? $0.albumID == selectedGroup : $0.artist == selectedGroup }
        }
        if !search.isEmpty { result = result.filter { $0.matches(search) } }
        if page != .recent {
            result.sort {
                if selectedGroup != nil, $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        return result
    }

    func navigate(_ page: LibraryPage, folderID: UUID? = nil) {
        self.page = page; selectedFolderID = folderID; selectedGroup = nil; search = ""
    }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.title = "添加音乐文件夹"; panel.prompt = "添加到曲库"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importFolders(panel.urls)
    }

    func importFolders(_ urls: [URL], refreshing: Bool = false) {
        guard !isImporting else { notice = "正在扫描音乐，请等待完成。"; return }
        let directories = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard !directories.isEmpty else { error = "请拖入或选择音乐文件夹。"; return }
        isImporting = true; importCount = 0
        importTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isImporting = false; self.importTask = nil }
            var added = 0, warnings: [String] = []
            for url in directories {
                if Task.isCancelled { break }
                let existingFolder = self.folders.first { $0.url.standardizedFileURL == url.standardizedFileURL }
                if let existingFolder, !refreshing, !self.unavailableFolders.contains(existingFolder.id) { continue }
                let access = url.startAccessingSecurityScopedResource()
                var keptScope = false
                defer { if access && !keptScope { url.stopAccessingSecurityScopedResource() } }
                do {
                    let folder: LibraryFolder
                    let managed = existingFolder?.sourceProvider != nil && self.isManagedCloudURL(url)
                    let bookmark = managed ? nil : try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                    folder = LibraryFolder(id: existingFolder?.id ?? UUID(), url: url, bookmark: bookmark,
                                           displayName: existingFolder?.displayName, sourceProvider: existingFolder?.sourceProvider)
                    let result = try await self.indexFolder(folder, progressBase: added)
                    if access {
                        if let old = self.scopedURLs.updateValue(url, forKey: folder.id) { old.stopAccessingSecurityScopedResource() }
                        keptScope = true
                    }
                    self.unavailableFolders.remove(folder.id)
                    added += result.added; warnings.append(contentsOf: result.skipped)
                    self.scheduleSave()
                } catch is CancellationError { break }
                catch { warnings.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            }
            self.notice = refreshing ? "曲库扫描完成，当前共 \(self.tracks.count) 首歌曲。" : "已添加 \(added) 首歌曲。"
            if !warnings.isEmpty {
                self.error = "有 \(warnings.count) 个项目未能读取，其余音乐已保留。\n\n" + warnings.prefix(6).joined(separator: "\n")
            }
            self.remote?.update()
        }
    }

    func cancelImport() { importTask?.cancel() }
    func refreshLibrary() { importFolders(folders.map(\.url), refreshing: true) }

    private func indexFolder(_ folder: LibraryFolder, progressBase: Int = 0) async throws -> (added: Int, skipped: [String]) {
        let result = try await scanner.scan(folder, existing: tracks) { count in
            await MainActor.run { self.importCount = progressBase + count }
        }
        try Task.checkCancellation()
        if folders.contains(where: { $0.id == folder.id }) {
            // Preserve previous entries when a partial scan cannot read every subfolder.
            if result.skipped.isEmpty { tracks.removeAll { $0.folderID == folder.id } }
            else {
                let scanned = Set(result.tracks.map(\.id))
                tracks.removeAll { $0.folderID == folder.id && scanned.contains($0.id) }
            }
        }
        var seen = Set(tracks.map(\.id))
        let fresh = result.tracks.filter { seen.insert($0.id).inserted }
        tracks.append(contentsOf: fresh)
        if let index = folders.firstIndex(where: { $0.id == folder.id }) { folders[index] = folder }
        else { folders.append(folder) }
        queue.retain(Set(tracks.map(\.id)))
        if queue.currentID == nil, player.loadedID != nil { player.stop(); lyrics.clear() }
        return (fresh.count, result.skipped)
    }

    private func importCloudFolder(_ result: CloudImportResult) async throws {
        guard !isImporting else {
            throw NSError(domain: "VSound", code: 1, userInfo: [NSLocalizedDescriptionKey: "曲库正在扫描，请完成后重新导入；完整下载会复用缓存。"])
        }
        guard isManagedCloudURL(result.directory) else { throw CloudError.cacheDamaged }
        isImporting = true; importCount = 0
        defer { isImporting = false }
        let existing = folders.first { $0.url.standardizedFileURL == result.directory.standardizedFileURL }
        let folder = LibraryFolder(id: existing?.id ?? UUID(), url: result.directory,
                                   displayName: result.displayName, sourceProvider: result.provider.rawValue)
        let scan = try await indexFolder(folder)
        notice = "已将 \(result.displayName) 加入曲库。"
        if !scan.skipped.isEmpty { error = scan.skipped.prefix(5).joined(separator: "\n") }
        scheduleSave(); remote?.update()
    }

    private func isManagedCloudURL(_ url: URL) -> Bool {
        Self.isInside(url.resolvingSymlinksInPath(), folder: store.cloudMusicDirectory.resolvingSymlinksInPath())
    }

    func removeFolder(_ folder: LibraryFolder) {
        guard !isImporting else { return }
        folders.removeAll { $0.id == folder.id }
        tracks = tracks.compactMap { track in
            guard let owner = folders.first(where: { Self.isInside(track.url, folder: $0.url) }) else { return nil }
            var copy = track; copy.folderID = owner.id; return copy
        }
        if let url = scopedURLs.removeValue(forKey: folder.id) { url.stopAccessingSecurityScopedResource() }
        unavailableFolders.remove(folder.id)
        queue.retain(Set(tracks.map(\.id)))
        if queue.currentID == nil { player.stop(); lyrics.clear() }
        if selectedFolderID == folder.id { navigate(.songs) }
        notice = "已从曲库移除文件夹，原始音乐文件保持不变。"
        scheduleSave(); remote?.update()
    }

    func play(_ track: Track, in list: [Track]? = nil) {
        queue.start(track.id, in: (list ?? visibleTracks).map(\.id))
        loadCurrent()
    }

    private func loadCurrent() {
        guard let track = currentTrack else { return }
        do {
            try player.load(track)
            recentIDs.removeAll { $0 == track.id }; recentIDs.insert(track.id, at: 0)
            recentIDs = Array(recentIDs.prefix(200))
            lyrics.load(track, online: onlineLyrics)
            scheduleSave(); remote?.update()
        } catch { self.error = "无法播放「\(track.title)」：\(error.localizedDescription)\n请确认文件仍在原位置，或重新授权音乐文件夹。" }
    }

    func togglePlayback() {
        if player.isPlaying { player.pause() }
        else if player.loadedID != nil {
            do { try player.play() } catch { self.error = error.localizedDescription }
        } else if currentTrack != nil { loadCurrent() }
        else if let first = visibleTracks.first { play(first) }
    }

    func next(automatic: Bool = false) {
        if queue.next(automatic: automatic) != nil { loadCurrent() }
        else { player.pause(); scheduleSave(); remote?.update() }
    }

    func previous() {
        if player.position > 3 { seek(0); return }
        if queue.previous() != nil { loadCurrent() }
    }

    func seek(_ seconds: Double) {
        do { try player.seek(to: seconds) } catch { self.error = error.localizedDescription }
        scheduleSave()
    }
    func setVolume(_ value: Float) { volume = min(1, max(0, value)); player.setVolume(volume); scheduleSave() }
    func toggleFavorite(_ track: Track) {
        if !favorites.insert(track.id).inserted { favorites.remove(track.id) }
        scheduleSave()
    }
    func toggleShuffle() { queue.toggleShuffle(); scheduleSave(); remote?.update() }
    func cycleRepeat() { queue.repeatMode.cycle(); scheduleSave(); remote?.update() }
    func shufflePlay(_ list: [Track]) {
        guard let first = list.randomElement() else { return }
        if !queue.isShuffled { queue.toggleShuffle() }
        play(first, in: list)
    }
    func enqueue(_ track: Track, next: Bool) {
        if next { queue.playNext(track.id) } else { queue.append(track.id) }
        notice = next ? "已设为下一首播放。" : "已添加到播放队列。"
        scheduleSave()
    }
    func removeFromQueue(_ id: String) { queue.removeUpcoming(id); scheduleSave() }

    func choosePreset(id: String, gains: [Float]) {
        equalizer.presetID = id; equalizer.gains = gains; equalizer.enabled = true
        updateEQ()
    }
    func setBand(_ index: Int, gain: Float) {
        guard equalizer.gains.indices.contains(index) else { return }
        equalizer.gains[index] = gain; equalizer.presetID = "custom"
        updateEQ()
    }
    func updateEQ() { equalizer.normalize(); player.apply(equalizer); scheduleSave() }
    func savePreset(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let preset = SavedEQPreset(name: String(clean.prefix(30)), gains: equalizer.gains)
        customPresets.append(preset); equalizer.presetID = preset.id; scheduleSave()
    }
    func deletePreset(_ id: String) {
        customPresets.removeAll { $0.id == id }
        if equalizer.presetID == id { equalizer.presetID = "custom" }
        scheduleSave()
    }
    func setOnlineLyrics(_ enabled: Bool) {
        onlineLyrics = enabled
        if let track = currentTrack { lyrics.load(track, online: enabled) }
        scheduleSave()
    }
    func setLyricsOffset(_ value: Double) {
        guard let id = currentTrack?.id else { return }
        lyricsOffsets[id] = min(30, max(-30, value)); scheduleSave()
    }
    var lyricsOffset: Double { currentTrack.flatMap { lyricsOffsets[$0.id] } ?? 0 }

    func registerShortcuts() {
        if hotKeysEnabled { shortcuts.registerAll(hotKeys) } else { shortcuts.unregisterAll() }
    }
    func changeShortcut(_ action: HotKeyAction, binding: HotKeyBinding) {
        let current = hotKeys[action.rawValue] ?? action.defaultBinding
        if current.keyCode == binding.keyCode, current.modifiers == binding.modifiers {
            shortcuts.errors.removeValue(forKey: action.rawValue)
            return
        }
        if shortcuts.register(action, binding: binding) {
            hotKeys[action.rawValue] = binding; scheduleSave()
            if !hotKeysEnabled { shortcuts.unregisterAll() }
        }
    }
    func resetShortcuts() { hotKeys = [:]; registerShortcuts(); scheduleSave() }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            self?.persist()
        }
    }

    func persist(synchronously: Bool = false) {
        guard canSave else { return }
        var state = LibraryState()
        state.tracks = tracks; state.folders = folders; state.favorites = favorites
        state.recentIDs = recentIDs; state.queue = queue; state.position = player.position
        state.volume = volume; state.equalizer = equalizer; state.customPresets = customPresets
        state.onlineLyrics = onlineLyrics; state.lyricsOffsets = lyricsOffsets
        state.hotKeys = hotKeys; state.hotKeysEnabled = hotKeysEnabled
        let store = store
        let snapshot = state
        if synchronously {
            diskQueue.sync { do { try store.save(snapshot) } catch { NSLog("VSound: %@", error.localizedDescription) } }
        } else {
            diskQueue.async { [weak self] in
                do { try store.save(snapshot) }
                catch {
                    let message = error.localizedDescription
                    Task { @MainActor [weak self] in self?.error = "无法保存曲库记录：\(message)" }
                }
            }
        }
    }

    private func restoreFolderAccess() {
        for index in folders.indices {
            if folders[index].sourceProvider != nil, isManagedCloudURL(folders[index].url) {
                if !FileManager.default.isReadableFile(atPath: folders[index].url.path) { unavailableFolders.insert(folders[index].id) }
                continue
            }
            guard let data = folders[index].bookmark else { unavailableFolders.insert(folders[index].id); continue }
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                if url.startAccessingSecurityScopedResource() { scopedURLs[folders[index].id] = url }
                folders[index].url = url
                if stale { folders[index].bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) }
                if !FileManager.default.isReadableFile(atPath: url.path) { unavailableFolders.insert(folders[index].id) }
            } catch { unavailableFolders.insert(folders[index].id) }
        }
    }

    static func isInside(_ file: URL, folder: URL) -> Bool {
        file.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { Self.model?.persist(synchronously: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = sender.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "维音" }) {
                window.makeKeyAndOrderFront(nil)
            } else { sender.windows.first?.makeKeyAndOrderFront(nil) }
        }
        return true
    }
}
