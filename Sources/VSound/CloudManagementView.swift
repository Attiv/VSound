import MusicCore
import SwiftUI

struct CloudManagementView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            CloudManagementSections()
            if let error = model.cloud.error { Section { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) } }
            if let status = model.cloud.status { Section { Text(status).font(.system(size: 11)).foregroundStyle(.secondary) } }
        }.formStyle(.grouped).frame(minWidth: 640, minHeight: 480)
    }
}

struct CloudManagementSections: View {
    @Environment(AppModel.self) private var model
    @State private var pendingRemoval: CloudCacheEntry?
    var body: some View {
        Group {
            Section("下载任务") {
                if model.cloud.jobs.isEmpty { Text("尚无下载任务，在网盘窗口选择文件夹即可开始。").font(.system(size: 11)).foregroundStyle(.secondary) }
                ForEach(model.cloud.jobs.prefix(20)) { job in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Image(systemName: job.state == .completed ? "checkmark.circle" : job.state == .running ? "arrow.down.circle" : "exclamationmark.circle")
                                .foregroundStyle(job.state == .completed ? Theme.accent : Theme.muted)
                            Text(job.provider.title + " · " + job.folder.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(job.state.title).font(.system(size: 10)).foregroundStyle(.secondary)
                            if job.state == .running { Button("停止", action: model.cloud.cancelDownload) }
                            else { Button("重新导入") { model.cloud.retry(job) }.disabled(model.cloud.isBusy || !model.cloud.connected.contains(job.provider)) }
                        }
                        if job.state == .running, job.total > 0 { ProgressView(value: Double(job.completed), total: Double(job.total)) }
                        Text(job.message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                    }.padding(.vertical, 3)
                }
                Text("一次执行一个任务，关闭窗口仍会继续。保留最近 50 条记录；中断后重试会复用已完成文件。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Section("离线缓存") {
                HStack {
                    Text("占用 " + ByteCountFormatter.string(fromByteCount: model.cloud.cacheEntries.reduce(0) { $0 + $1.bytes }, countStyle: .file))
                    Spacer()
                    if model.cloud.isReadingCache { ProgressView().controlSize(.small) }
                    Button("刷新", action: model.cloud.reloadCache).disabled(model.cloud.isReadingCache)
                }
                if model.cloud.cacheEntries.isEmpty, !model.cloud.isReadingCache {
                    Text("没有已下载的网盘缓存。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(model.cloud.cacheEntries) { entry in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.name).font(.system(size: 12)).lineLimit(1)
                            Text("\(entry.songs) 首 · " + ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("清理…", role: .destructive) { pendingRemoval = entry }.disabled(model.cloud.isBusy || model.isImporting)
                    }
                }
                Text("清理会删除所选本机下载文件并移除对应曲库索引，不会删除网盘文件。当前歌曲所在缓存不能清理。缓存不会自动删除，请按需管理。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .onAppear { model.cloud.reloadCache() }
        .confirmationDialog("清理这份离线缓存？", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            if let entry = pendingRemoval { Button("清理 \(entry.name)", role: .destructive) { model.cloud.removeCache(entry); pendingRemoval = nil } }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: { Text("本机文件会被删除，再次播放需要重新下载。网盘原始文件不受影响。") }
    }
}
