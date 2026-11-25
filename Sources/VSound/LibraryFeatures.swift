import AppKit
import MusicCore
import UniformTypeIdentifiers

extension AppModel {
    var selectedPlaylist: MusicPlaylist? { playlists.first { $0.id == selectedPlaylistID } }
    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0" }
    func configureEnhancements() {
        watcher = LibraryWatcher { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.preferences.watchesFolders else { return }
                if self.isImporting { self.needsRescan = true }
                else { self.importFolders(self.folders.filter { $0.sourceProvider == nil }.map(\.url), refreshing: true) }
            }
        }
        configureWatcher()
        cloud.canRemoveCache = { [weak self] url in
            guard let self, !self.isImporting else { return false }
            if let track = self.currentTrack, Self.isInside(track.url, folder: url) { return false }
            return true
        }
        cloud.onCacheRemoved = { [weak self] url in
            guard let self else { return }
            for folder in self.folders where folder.url.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() { self.removeFolder(folder) }
        }
        outputs.onChange = { [weak self] device in
            guard let self else { return }
            self.saveDeviceProfile()
            if let previous = self.profileUID, !self.outputs.devices.contains(where: { $0.id == previous }), self.player.isPlaying {
                self.player.pause(); self.notice = "音频设备已断开，播放已暂停。"
            }
            self.profileUID = device.id
            if let profile = self.preferences.deviceProfiles[device.id] {
                self.equalizer = profile.equalizer; self.equalizer.normalize()
                self.volume = profile.volume.isFinite ? min(1, max(0, profile.volume)) : 0.7
            }
            do { try self.player.setOutputDevice(device.systemID) }
            catch { self.error = "切换音频输出失败：\(error.localizedDescription)" }
            self.player.apply(self.equalizer); self.player.setVolume(self.volume)
            self.syncUpcoming(); self.scheduleSave()
        }
        outputs.select(preferences.selectedDeviceUID)
        updatePreferences()
        if preferences.checksUpdatesAutomatically { checkForUpdates() }
    }
    func configureWatcher() {
        watcher?.watch(preferences.watchesFolders ? folders.filter { $0.sourceProvider == nil }.map(\.url) : [])
    }
    func updatePreferences() {
        preferences.crossfadeSeconds = preferences.crossfadeSeconds.isFinite ? min(10, max(0.2, preferences.crossfadeSeconds)) : 3
        preferences.desktopLyrics.fontSize = preferences.desktopLyrics.fontSize.isFinite ? min(72, max(14, preferences.desktopLyrics.fontSize)) : 28
        preferences.desktopLyrics.opacity = preferences.desktopLyrics.opacity.isFinite ? min(1, max(0.3, preferences.desktopLyrics.opacity)) : 0.9
        if preferences.lyricSources.isEmpty { preferences.lyricSources = [.lrclib] }
        lyrics.sources = preferences.lyricSources
        if let currentTrack { player.setLoudnessGain(loudnessGain(currentTrack)) }
        syncUpcoming()
        desktopLyrics.update(model: self)
        scheduleSave()
    }
    func saveDeviceProfile() {
        guard let uid = profileUID else { return }
        preferences.deviceProfiles[uid] = .init(equalizer: equalizer, volume: volume)
    }
    func chooseOutput(_ uid: String?) {
        preferences.selectedDeviceUID = uid; outputs.select(uid); scheduleSave()
    }
    func loudnessGain(_ track: Track) -> Float {
        guard let record = loudnessRecords[track.id], record.isCurrent(for: track) else { return 0 }
        return record.gain(for: preferences.loudness)
    }
    func syncUpcoming() {
        var following = queue
        let track = following.next(automatic: true).flatMap { id in tracks.first { $0.id == id } }
        preparedQueue = track == nil ? nil : following
        player.setUpcoming(track, mode: preferences.transition, seconds: preferences.crossfadeSeconds, gain: track.map(loudnessGain) ?? 0)
    }
    func didStartCurrent() {
        guard let track = currentTrack else { return }
        recentIDs.removeAll { $0 == track.id }; recentIDs.insert(track.id, at: 0)
        recentIDs = Array(recentIDs.prefix(200))
        lyrics.load(track, online: onlineLyrics)
        scheduleSave()
    }
    func analyzeLoudness() {
        guard !isAnalyzing, !tracks.isEmpty else { return }
        isAnalyzing = true; analysisProgress = 0; analysisStatus = "正在分析响度，不修改原始文件…"
        let tracks = tracks
        analysisTask = Task { [weak self] in
            defer { self?.isAnalyzing = false }
            do {
                let records = try await LoudnessAnalyzer().analyze(tracks) { completed, total in
                    await MainActor.run { self?.analysisProgress = completed; self?.analysisStatus = "响度分析 \(completed)/\(total) 首" }
                }
                try Task.checkCancellation()
                self?.loudnessRecords.merge(records, uniquingKeysWith: { _, new in new })
                self?.analysisStatus = "已完成 \(records.count) 首音乐的响度分析。"
                self?.updatePreferences()
            } catch is CancellationError { self?.analysisStatus = "已取消响度分析，原有结果保持不变。" }
            catch { self?.analysisStatus = "分析未完成：\(error.localizedDescription)" }
        }
    }
    func cancelLoudnessAnalysis() { analysisTask?.cancel() }
    func checkForUpdates() {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true; availableUpdate = nil; updateStatus = "正在检查 GitHub Release…"
        let current = appVersion
        updateTask = Task { [weak self] in
            defer { self?.isCheckingUpdates = false }
            do {
                let update = try await UpdateClient().check(currentVersion: current)
                self?.availableUpdate = update
                self?.updateStatus = update.map { "发现新版本 \($0.version)" } ?? "当前已是最新正式版本（\(current)）。"
            } catch { self?.updateStatus = "检查失败：\(error.localizedDescription)" }
        }
    }
    func openUpdate() { if let page = availableUpdate?.validatedPage { NSWorkspace.shared.open(page) } }
    func createPlaylist() {
        let alert = NSAlert(); alert.messageText = "新建歌单"; alert.informativeText = "给这份喜欢起个名字。"
        let input = NSTextField(string: "我的歌单"); input.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = input; alert.addButton(withTitle: "创建"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let playlist = MusicPlaylist(name: input.stringValue)
        guard !playlist.name.isEmpty else { return }
        playlists.append(playlist); selectPlaylist(playlist.id); scheduleSave()
    }
    func selectPlaylist(_ id: UUID) { navigate(.songs); selectedPlaylistID = id }
    func renamePlaylist(_ id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let alert = NSAlert(); alert.messageText = "重命名歌单"
        let input = NSTextField(string: playlists[index].name); input.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = input; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = String(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty else { return }; playlists[index].name = name; scheduleSave()
    }
    func deletePlaylist(_ id: UUID) {
        let alert = NSAlert(); alert.messageText = "删除这份歌单？"; alert.informativeText = "只删除歌单记录，音乐文件和曲库不受影响。"
        alert.addButton(withTitle: "删除歌单"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        playlists.removeAll { $0.id == id }; if selectedPlaylistID == id { navigate(.songs) }; scheduleSave()
    }
    func addToPlaylist(_ ids: [String], playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let known = Set(tracks.map(\.id)); playlists[index].append(ids.filter { known.contains($0) }); scheduleSave()
    }
    func movePlaylistTracks(_ offsets: IndexSet, to destination: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == selectedPlaylistID }), search.isEmpty else { return }
        let visible = visibleTracks.map(\.id)
        let moving = Set(offsets.filter { visible.indices.contains($0) }.map { visible[$0] })
        let stored = playlists[index].trackIDs
        let actual = IndexSet(stored.indices.filter { moving.contains(stored[$0]) })
        let anchor = visible.indices.contains(destination) ? stored.firstIndex(of: visible[destination]) ?? stored.count : stored.count
        playlists[index].move(from: actual, to: anchor); scheduleSave()
    }
    func removeFromPlaylist(_ track: Track) {
        guard let index = playlists.firstIndex(where: { $0.id == selectedPlaylistID }) else { return }
        playlists[index].trackIDs.removeAll { $0 == track.id }; scheduleSave()
    }
    func importPlaylist() {
        let panel = NSOpenPanel(); panel.title = "导入 M3U 歌单"; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u") ?? .plainText, UTType(filenameExtension: "m3u8") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let content = try LyricsClient.readText(at: url)
            let urls = M3UPlaylist.urls(in: content, relativeTo: url)
            let known = Dictionary(tracks.map { ($0.url.standardizedFileURL.path, $0.id) }, uniquingKeysWith: { a, _ in a })
            let ids = urls.compactMap { known[$0.standardizedFileURL.path] }
            let playlist = MusicPlaylist(name: url.deletingPathExtension().lastPathComponent, trackIDs: ids)
            playlists.append(playlist); selectPlaylist(playlist.id); scheduleSave()
            notice = "已导入 \(ids.count) 首；\(urls.count - ids.count) 首未在曲库中，请先添加其音乐文件夹。"
        } catch { self.error = error.localizedDescription }
    }
    func exportPlaylist() {
        guard let playlist = selectedPlaylist else { return }
        let panel = NSSavePanel(); panel.title = "导出歌单"; panel.nameFieldStringValue = CloudFileNames.safe(playlist.name) + ".m3u8"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let lookup = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        do { try M3UPlaylist.text(for: playlist.trackIDs.compactMap { lookup[$0] }).write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
}
