import AppKit
import MusicCore
import SwiftUI

struct CloudSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        @Bindable var cloud = model.cloud
        Form {
            Section {
                Text("云端收藏，本地聆听。").font(.system(size: 20, weight: .semibold))
                Text("连接网盘，选择音乐文件夹，下载后离线播放。沿用现有均衡器、快捷键和播放模式。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(CloudProvider.allCases) { provider in
                Section(provider.title) {
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive.badge.icloud").font(.system(size: 20)).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.title).font(.system(size: 13, weight: .semibold))
                            Text(cloud.connected.contains(provider) ? "已连接 · 只读访问" : "未连接")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if cloud.connected.contains(provider) {
                            Button("浏览音乐") { cloud.browse(provider); openWindow(id: "cloud") }.disabled(cloud.isBusy)
                            Button("断开") { cloud.disconnect(provider) }.disabled(cloud.isBusy)
                        } else {
                            Button(cloud.connectingProvider == provider ? "等待授权…" : "连接账号") { cloud.connect(provider) }
                                .disabled(cloud.isBusy || (cloud.clientIDs[provider] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if (cloud.clientIDs[provider] ?? "").isEmpty {
                        Text("此构建尚未配置应用 ID。开发者可在下方完成一次性配置，也可直接添加已同步的网盘文件夹。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("开发者应用配置") {
                        TextField(provider == .googleDrive ? "Desktop OAuth Client ID" : "Dropbox App key",
                                  text: Binding(get: { cloud.clientIDs[provider] ?? "" }, set: { cloud.setClientID($0, provider: provider) }))
                            .textFieldStyle(.roundedBorder).disabled(cloud.isBusy)
                        if provider == .googleDrive {
                            SecureField("Client Secret（可选）", text: $cloud.googleClientSecret)
                                .textFieldStyle(.roundedBorder).disabled(cloud.isBusy)
                        }
                        Text("开发者只需为维音配置一次应用 ID。令牌只保存到 macOS 钥匙串，不写入曲库。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        if provider == .dropbox {
                            Text("回调地址：\(CloudOAuthFlow.redirectURI.absoluteString)")
                                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
            }
            if cloud.isConnecting {
                Section {
                    HStack { ProgressView().controlSize(.small); Text("请在浏览器中完成授权").font(.system(size: 11)); Spacer(); Button("取消", action: cloud.cancelAuthorization) }
                }
            }
            Section("已有网盘客户端") {
                Button("添加已同步的网盘文件夹…", action: model.chooseFolders).disabled(model.isImporting)
                Text("也支持通过访达选择 Google Drive、Dropbox、OneDrive 或 iCloud Drive 已同步的音乐文件夹。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let error = cloud.error { Section { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) } }
            Section {
                Text("只请求读取和下载权限，不上传、不修改网盘文件。断开连接会移除本机令牌，已下载音乐会保留；可在网盘账户中进一步撤销应用访问。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct CloudBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        @Bindable var cloud = model.cloud
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow(text: "YOUR MUSIC, EVERYWHERE.")
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("把云端的喜欢，带回身边。").font(.system(size: 25, weight: .semibold))
                        Text("下载一份到本地，离线也能慢慢听。").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("账号设置") { model.settingsTab = "cloud"; openSettings() }.buttonStyle(.bordered)
                }
                HStack(spacing: 10) {
                    ForEach(CloudProvider.allCases) { provider in
                        Button { cloud.browse(provider) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "externaldrive")
                                Text(provider.title)
                                if cloud.connected.contains(provider) { Circle().fill(Theme.accent).frame(width: 5, height: 5) }
                            }.font(.system(size: 12, weight: .medium))
                        }.buttonStyle(QuietButtonStyle(prominent: cloud.provider == provider)).disabled(cloud.isBusy)
                    }
                    Spacer()
                    TextField("搜索当前文件夹", text: $cloud.search).textFieldStyle(.roundedBorder).frame(width: 205)
                }
            }.padding(26)
            Rectangle().fill(Theme.line).frame(height: 1)
            if cloud.connected.contains(cloud.provider) {
                breadcrumb
                if cloud.isLoading {
                    ProgressView("正在读取文件夹…").font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if cloud.visibleItems.isEmpty {
                    ContentUnavailableView("这里没有可显示的音乐", systemImage: "music.note.list",
                                           description: Text("支持文件夹、常见音频和 LRC 歌词，可返回上一级浏览。"))
                } else {
                    List(cloud.visibleItems) { item in
                        HStack(spacing: 13) {
                            Image(systemName: item.isFolder ? "folder.fill" : item.isLyric ? "text.alignleft" : "music.note")
                                .foregroundStyle(item.isFolder ? Theme.accent : Theme.muted).frame(width: 25)
                            if item.isFolder {
                                Button { cloud.browse(cloud.provider, folder: item) } label: {
                                    Text(item.name).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(cloud.isDownloading)
                            } else {
                                Text(item.name).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                            }
                            if let size = item.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.system(size: 10)).foregroundStyle(Theme.muted) }
                            if !item.canDownload { Image(systemName: "lock").foregroundStyle(.secondary).help("网盘不允许下载此文件") }
                            if item.isFolder { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                        }.padding(.vertical, 10)
                    }.listStyle(.inset).scrollContentBackground(.hidden)
                }
            } else {
                VStack(spacing: 17) {
                    Image(systemName: "icloud.and.arrow.down").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(Theme.accent)
                    Text("连接 \(cloud.provider.title)，发现你的音乐。").font(.system(size: 18, weight: .medium))
                    Text("在账号设置中连接后，即可浏览并导入整个音乐文件夹。")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Button("打开网盘设置") { model.settingsTab = "cloud"; openSettings() }.buttonStyle(QuietButtonStyle(prominent: true))
                    Button("添加已同步的网盘文件夹…", action: model.chooseFolders)
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted).disabled(model.isImporting)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .frame(minWidth: 780, minHeight: 570).background(Theme.canvas)
        .onAppear { if model.cloud.items.isEmpty, model.cloud.connected.contains(model.cloud.provider) { model.cloud.browse(model.cloud.provider) } }
        .onChange(of: model.cloud.connected) { _, connected in
            if connected.contains(model.cloud.provider) { model.cloud.browse(model.cloud.provider) }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            Button(model.cloud.provider.title) { model.cloud.browse(model.cloud.provider) }
            ForEach(Array(model.cloud.breadcrumbs.enumerated()), id: \.element.id) { index, item in
                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Theme.muted)
                Button(item.name) { model.cloud.browse(model.cloud.provider, ancestor: index + 1) }.lineLimit(1)
            }
            Spacer()
            Button { model.cloud.browse(model.cloud.provider, ancestor: model.cloud.breadcrumbs.count) } label: { Image(systemName: "arrow.clockwise") }
                .help("刷新当前文件夹").accessibilityLabel("刷新当前文件夹")
        }.buttonStyle(.plain).font(.system(size: 11)).disabled(model.cloud.isDownloading)
            .padding(.horizontal, 26).padding(.vertical, 15)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.cloud.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3).textSelection(.enabled) }
            if model.cloud.isDownloading {
                HStack {
                    if model.cloud.total > 0 { ProgressView(value: Double(model.cloud.completed), total: Double(model.cloud.total)).frame(maxWidth: 220) }
                    else { ProgressView().controlSize(.small) }
                    Text("\(model.cloud.completed) / \(model.cloud.total) 首").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("停止下载", action: model.cloud.cancelDownload)
                }
            } else {
                HStack {
                    Text("包含子文件夹及同名 LRC，已下载的相同版本会复用缓存。")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button(action: model.cloud.importCurrentFolder) {
                        Label("导入当前文件夹", systemImage: "arrow.down.to.line").font(.system(size: 12, weight: .medium))
                    }.buttonStyle(QuietButtonStyle(prominent: true))
                        .disabled(!model.cloud.connected.contains(model.cloud.provider) || model.cloud.isBusy || model.cloud.isLoading || model.isImporting)
                }
            }
            if let status = model.cloud.status { Text(status).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1) }
        }.padding(.horizontal, 26).padding(.vertical, 18)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
