import AppKit
import Foundation
import MusicCore
import Observation

@MainActor @Observable
final class CloudModel {
    var connected: Set<CloudProvider> = []
    var provider: CloudProvider = .googleDrive
    var breadcrumbs: [CloudItem] = []
    var items: [CloudItem] = []
    var search = ""
    var clientIDs: [CloudProvider: String] = [:]
    var googleClientSecret = ""
    var isConnecting = false
    var connectingProvider: CloudProvider?
    var isLoading = false
    var isDownloading = false
    var completed = 0
    var total = 0
    var status: String?
    var error: String?
    var jobs: [CloudDownloadJob] = []
    var cacheEntries: [CloudCacheEntry] = []
    var isReadingCache = false
    var cleaningDirectory: URL?
    @ObservationIgnored var canRemoveCache: ((URL) -> Bool)?
    @ObservationIgnored var onCacheRemoved: ((URL) -> Void)?
    @ObservationIgnored private let cache: CloudCacheStore
    @ObservationIgnored private let historyURL: URL
    @ObservationIgnored var onImport: ((CloudImportResult) async throws -> Void)?
    @ObservationIgnored private let client: CloudClient
    @ObservationIgnored private let importer: CloudMusicImporter
    @ObservationIgnored private var authorization: Task<Void, Never>?
    @ObservationIgnored private var browsing: Task<Void, Never>?
    @ObservationIgnored private var downloading: Task<Void, Never>?
    @ObservationIgnored private var receiver: CloudOAuthReceiver?

    init(directory: URL) {
        let client = CloudClient()
        self.client = client
        importer = CloudMusicImporter(client: client, directory: directory)
        cache = CloudCacheStore(directory: directory)
        historyURL = directory.appendingPathComponent("download-history.json")
        if let data = try? Data(contentsOf: historyURL), data.count < 1_000_000,
           let saved = try? JSONDecoder().decode([CloudDownloadJob].self, from: data) {
            jobs = Array(saved.prefix(50)).map { item in
                var job = item
                if job.state == .running { job.state = .cancelled; job.message = "上次下载已中断，完整缓存可重试复用。" }
                return job
            }
        }
        for provider in CloudProvider.allCases {
            let key = provider == .googleDrive ? "VSoundGoogleClientID" : "VSoundDropboxAppKey"
            clientIDs[provider] = UserDefaults.standard.string(forKey: "cloud.clientID.\(provider.rawValue)")
                ?? Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        }
        Task { [weak self] in
            do { self?.connected = try await client.connectedProviders() }
            catch { self?.error = error.localizedDescription }
        }
    }

    var currentFolder: CloudItem {
        breadcrumbs.last ?? CloudItem(id: provider.rootID, name: provider.title, isFolder: true)
    }
    var visibleItems: [CloudItem] {
        items.filter { ($0.isFolder || $0.isAudio || $0.isLyric) && (search.isEmpty || $0.name.localizedStandardContains(search)) }
    }
    var isBusy: Bool { isConnecting || isDownloading || cleaningDirectory != nil }

    func setClientID(_ value: String, provider: CloudProvider) {
        clientIDs[provider] = String(value.prefix(2048))
        UserDefaults.standard.set(clientIDs[provider], forKey: "cloud.clientID.\(provider.rawValue)")
    }

    func connect(_ provider: CloudProvider) {
        guard !isBusy else { return }
        let config = CloudClientConfiguration(clientID: clientIDs[provider] ?? "",
                                               clientSecret: provider == .googleDrive ? googleClientSecret : "")
        guard !config.clientID.isEmpty else { error = CloudError.configuration.localizedDescription; return }
        isConnecting = true; connectingProvider = provider; error = nil
        status = "正在打开 \(provider.title) 官方授权页面…"
        authorization = Task { [weak self, client] in
            guard let self else { return }
            let receiver = CloudOAuthReceiver()
            self.receiver = receiver
            defer { self.isConnecting = false; self.connectingProvider = nil; self.receiver = nil; receiver.cancel() }
            do {
                let redirect = try await receiver.start()
                let flow = try CloudOAuthFlow(provider: provider, clientID: config.clientID, redirectURI: redirect)
                let code = try await receiver.waitForCode(flow: flow) { url in
                    Task { @MainActor in if !NSWorkspace.shared.open(url) { receiver.cancel() } }
                }
                try await client.connect(flow: flow, code: code, configuration: config)
                try Task.checkCancellation()
                self.connected.insert(provider); self.googleClientSecret = ""
                self.status = "\(provider.title) 已连接。"
                self.browse(provider)
            } catch is CancellationError { self.status = "已取消授权。" }
            catch {
                self.error = "连接 \(provider.title) 失败：\(error.localizedDescription)\n如无法打开回调，请检查 53682 端口是否被其他程序占用。"
                self.status = nil
            }
        }
    }

    func cancelAuthorization() { authorization?.cancel(); receiver?.cancel() }
    func cancelDownload() { downloading?.cancel() }

    func disconnect(_ provider: CloudProvider) {
        guard !isBusy else { return }
        Task { [weak self, client] in
            do {
                try await client.disconnect(provider)
                self?.connected.remove(provider)
                if self?.provider == provider { self?.browsing?.cancel(); self?.items = []; self?.breadcrumbs = [] }
                self?.status = "已断开 \(provider.title)，已下载的本地音乐会保留。"
            } catch { self?.error = error.localizedDescription }
        }
    }

    func browse(_ provider: CloudProvider, folder: CloudItem? = nil, ancestor: Int? = nil) {
        guard !isDownloading else { return }
        browsing?.cancel()
        let changedProvider = self.provider != provider
        self.provider = provider
        if changedProvider || (folder == nil && ancestor == nil) { breadcrumbs = [] }
        if let ancestor { breadcrumbs = Array(breadcrumbs.prefix(ancestor)) }
        if let folder { breadcrumbs.append(folder) }
        let target = currentFolder
        search = ""; items = []; error = nil
        guard connected.contains(provider) else { isLoading = false; return }
        isLoading = true
        browsing = Task { [weak self, client] in
            do {
                let items = try await client.list(provider, folderID: target.id)
                guard !Task.isCancelled, let self else { return }
                self.items = items; self.isLoading = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.error = error.localizedDescription; self.isLoading = false
            }
        }
    }

    func importCurrentFolder() {
        guard !isBusy, !isLoading, connected.contains(provider) else { return }
        startImport(provider, folder: currentFolder)
    }

    func retry(_ job: CloudDownloadJob) {
        guard !isBusy, connected.contains(job.provider) else { error = "请先连接对应网盘，等待当前任务完成后再重试。"; return }
        startImport(job.provider, folder: job.folder)
    }

    private func startImport(_ selectedProvider: CloudProvider, folder: CloudItem) {
        let job = CloudDownloadJob(provider: selectedProvider, folder: folder)
        jobs.insert(job, at: 0); jobs = Array(jobs.prefix(50)); saveJobs()
        isDownloading = true; error = nil; completed = 0; total = 0
        status = "正在读取网盘音乐…"
        downloading = Task { [weak self, importer] in
            guard let self else { return }
            defer { self.isDownloading = false; self.saveJobs(); self.reloadCache() }
            do {
                let result = try await importer.importFolder(folder, provider: selectedProvider) { progress in
                    await MainActor.run {
                        self.completed = progress.completed; self.total = progress.total; self.status = progress.message
                        if let index = self.jobs.firstIndex(where: { $0.id == job.id }) {
                            self.jobs[index].completed = progress.completed; self.jobs[index].total = progress.total; self.jobs[index].message = progress.message
                        }
                    }
                }
                try Task.checkCancellation()
                try await self.onImport?(result)
                self.status = "已下载 \(result.downloaded) 首，复用缓存 \(result.reused) 首，已加入曲库。"
                self.finishJob(job.id, state: .completed, message: self.status ?? "已完成")
                if !result.warnings.isEmpty { self.error = result.warnings.prefix(5).joined(separator: "\n") }
            } catch is CancellationError {
                self.status = "已停止下载，完整缓存可在下次继续复用。"
                self.finishJob(job.id, state: .cancelled, message: self.status ?? "已停止")
            }
            catch {
                self.error = error.localizedDescription; self.status = nil
                self.finishJob(job.id, state: .failed, message: error.localizedDescription)
            }
        }
    }

    private func finishJob(_ id: UUID, state: CloudDownloadState, message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state; jobs[index].message = message
    }
    private func saveJobs() {
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(to: historyURL, options: .atomic)
        } catch { self.error = "无法保存下载记录：\(error.localizedDescription)" }
    }
    func reloadCache() {
        guard !isReadingCache else { return }
        isReadingCache = true
        Task { [weak self, cache] in
            defer { self?.isReadingCache = false }
            do { self?.cacheEntries = try await cache.entries() }
            catch { self?.error = "读取缓存失败：\(error.localizedDescription)" }
        }
    }
    func removeCache(_ entry: CloudCacheEntry) {
        guard !isBusy, canRemoveCache?(entry.directory) == true else { error = "缓存正在使用或曲库正在扫描，请先切换到其他音乐再清理。"; return }
        cleaningDirectory = entry.directory
        Task { [weak self, cache] in
            defer { self?.cleaningDirectory = nil }
            do {
                try await cache.remove(entry.directory)
                self?.onCacheRemoved?(entry.directory); self?.reloadCache()
                self?.status = "已清理 \(entry.name)，远端文件不受影响。"
            } catch { self?.error = "清理失败：\(error.localizedDescription)" }
        }
    }
}
