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
    @ObservationIgnored private let client: LyricsClient
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var track: Track?

    init(client: LyricsClient) { self.client = client }

    func clear() {
        task?.cancel(); searchTask?.cancel(); track = nil
        document = nil; candidates = []; isLoading = false; isSearching = false
        status = "选择一首歌，让音乐发生。"
    }

    func load(_ track: Track, online: Bool) {
        task?.cancel(); searchTask?.cancel()
        self.track = track; document = nil; candidates = []
        searchQuery = "\(track.title) \(track.artist == "未知歌手" ? "" : track.artist)".trimmingCharacters(in: .whitespaces)
        status = "正在寻找歌词…"; isLoading = true; isSearching = false; searchMessage = nil
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
                let document = try await client.fetch(for: track)
                guard !Task.isCancelled, self.track?.id == track.id else { return }
                self.document = document; self.status = "LRCLIB · 已缓存"
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
                let results = try await client.search(query)
                guard !Task.isCancelled, let self, self.track?.id == id else { return }
                self.candidates = results
                self.searchMessage = results.isEmpty ? "没有找到结果，试试更简短的歌名和歌手。" : nil
                self.isSearching = false
            } catch {
                guard !Task.isCancelled, let self, self.track?.id == id else { return }
                self.searchMessage = error.localizedDescription; self.isSearching = false
            }
        }
    }

    func choose(_ candidate: LyricsCandidate) {
        guard let document = candidate.document else { return }
        setDocument(document)
    }

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
