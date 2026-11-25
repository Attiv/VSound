import AppKit
import Foundation
import MusicCore
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class LyricsModel {
    var document: LyricsDocument?
    var status = "添加音乐，开始你的聆听。"
    var isLoading = false
    var isSearching = false
    var candidates: [LyricsCandidate] = []
    var searchQuery = ""
    var searchMessage: String?
    var sources: [LyricSource] = LyricSource.allCases
    var isResolving = false
    var isFilling = false
    var fillProgress = 0
    var fillTotal = 0
    var fillMessage: String?
    @ObservationIgnored private let client: LyricsClient
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var fillTask: Task<Void, Never>?
    @ObservationIgnored private var track: Track?

    init(client: LyricsClient) { self.client = client }

    func clear() {
        task?.cancel(); searchTask?.cancel(); track = nil
        document = nil; candidates = []; isLoading = false; isSearching = false; isResolving = false
        status = "选择一首歌，让音乐发生。"
    }

    func load(_ track: Track, online: Bool) {
        task?.cancel(); searchTask?.cancel()
        self.track = track; document = nil; candidates = []
        searchQuery = "\(track.title) \(track.artist == "未知歌手" ? "" : track.artist)".trimmingCharacters(in: .whitespaces)
        status = "正在寻找歌词…"; isLoading = true; isSearching = false; isResolving = false; searchMessage = nil
        task = Task { [weak self, client] in
            let local = await client.localOrCached(for: track)
            guard !Task.isCancelled, let self, self.track?.id == track.id else { return }
            if let local { self.document = local; self.status = local.source; self.isLoading = false; return }
            guard online else {
                self.isLoading = false
                self.status = "还没有本地歌词，可以导入 LRC 或开启联网匹配。"
                return
            }
            do {
                let document = try await client.match(for: track, sources: self.sources)
                guard !Task.isCancelled, self.track?.id == track.id else { return }
                self.document = document; self.status = document.source + " · 已缓存"
            } catch {
                guard !Task.isCancelled, self.track?.id == track.id else { return }
                self.status = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    func searchOnline() {
        searchTask?.cancel()
        guard let id = track?.id else { return }
        isSearching = true; searchMessage = nil; candidates = []
        let query = searchQuery
        searchTask = Task { [weak self, client] in
            do {
                let response = try await client.searchAll(query, sources: self?.sources ?? [.lrclib])
                guard !Task.isCancelled, let self, self.track?.id == id else { return }
                self.candidates = response.candidates
                self.searchMessage = response.failures.isEmpty ? (response.candidates.isEmpty ? "没有找到结果，试试更简短的歌名和歌手。" : nil) : response.failures.joined(separator: "\n")
                self.isSearching = false
            } catch {
                guard !Task.isCancelled, let self, self.track?.id == id else { return }
                self.searchMessage = error.localizedDescription; self.isSearching = false
            }
        }
    }

    func choose(_ candidate: LyricsCandidate, completion: @escaping () -> Void = {}) {
        guard let id = track?.id else { return }
        searchTask?.cancel(); isResolving = true; searchMessage = nil
        searchTask = Task { [weak self, client] in
            do {
                let document = try await client.resolve(candidate)
                guard !Task.isCancelled, let self, self.track?.id == id else { return }
                self.setDocument(document); self.isResolving = false; completion()
            } catch {
                guard !Task.isCancelled else { return }
                self?.searchMessage = error.localizedDescription; self?.isResolving = false
            }
        }
    }

    func fillMissing(_ tracks: [Track]) {
        guard !isFilling else { return }
        let sources = sources
        isFilling = true; fillProgress = 0; fillTotal = tracks.count; fillMessage = "正在查找缺失歌词…"
        fillTask = Task { [weak self, client] in
            var added = 0, missing = 0
            defer { self?.isFilling = false }
            do {
                for (index, track) in tracks.enumerated() {
                    try Task.checkCancellation()
                    if await client.localOrCached(for: track) == nil {
                        do { _ = try await client.match(for: track, sources: sources); added += 1 }
                        catch is CancellationError { throw CancellationError() }
                        catch { missing += 1 }
                        try await Task.sleep(for: .milliseconds(400))
                    }
                    self?.fillProgress = index + 1
                    self?.fillMessage = "已处理 \(index + 1)/\(tracks.count) 首，新增 \(added) 首歌词，\(missing) 首未匹配。"
                }
                if let self, let track = self.track { self.load(track, online: false) }
            } catch { self?.fillMessage = "已停止补齐，已缓存的 \(added) 首歌词会保留。" }
        }
    }
    func cancelFill() { fillTask?.cancel() }

    func importFile() {
        guard track != nil else { return }
        let panel = NSOpenPanel()
        panel.title = "导入歌词"; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "lrc") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            setDocument(LyricsDocument(text: try LyricsClient.readText(at: url), source: "手动导入"))
        } catch { status = error.localizedDescription }
    }

    func exportFile() {
        guard let document else { return }
        let panel = NSSavePanel()
        panel.title = "导出歌词"
        panel.nameFieldStringValue = (track?.title ?? "歌词") + (document.isSynced ? ".lrc" : ".txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { try document.rawText.write(to: url, atomically: true, encoding: .utf8) }
        catch { status = "导出失败：\(error.localizedDescription)" }
    }

    private func setDocument(_ document: LyricsDocument) {
        task?.cancel()
        self.document = document; status = document.source; isLoading = false
        guard let track else { return }
        Task { [weak self, client] in
            do { try await client.cache(document, for: track) }
            catch { self?.status = "歌词已显示，但缓存失败：\(error.localizedDescription)" }
        }
    }
}
