import CryptoKit
import Foundation

public enum CloudProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case googleDrive, dropbox
    public var id: String { rawValue }
    public var title: String { self == .googleDrive ? "Google Drive" : "Dropbox" }
    public var rootID: String { self == .googleDrive ? "root" : "" }
    public var authorizationURL: URL {
        URL(string: self == .googleDrive ? "https://accounts.google.com/o/oauth2/v2/auth" : "https://www.dropbox.com/oauth2/authorize")!
    }
    public var tokenURL: URL {
        URL(string: self == .googleDrive ? "https://oauth2.googleapis.com/token" : "https://api.dropboxapi.com/oauth2/token")!
    }
    public var scopes: [String] {
        self == .googleDrive ? ["https://www.googleapis.com/auth/drive.readonly"] : ["files.metadata.read", "files.content.read"]
    }
}

public struct CloudItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isFolder: Bool
    public var size: Int64?
    public var revision: String
    public var canDownload: Bool
    public init(id: String, name: String, isFolder: Bool = false, size: Int64? = nil,
                revision: String = "", canDownload: Bool = true) {
        self.id = id; self.name = name; self.isFolder = isFolder; self.size = size
        self.revision = revision; self.canDownload = canDownload
    }
    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    public var isAudio: Bool { !isFolder && LibraryScanner.extensions.contains(fileExtension) }
    public var isLyric: Bool { !isFolder && fileExtension == "lrc" }
}

public struct CloudClientConfiguration: Sendable {
    public var clientID: String
    public var clientSecret: String
    public init(clientID: String, clientSecret: String = "") {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct CloudCredential: Codable, Sendable {
    public var clientID: String
    public var clientSecret: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var namespace: UUID
    public init(clientID: String, clientSecret: String = "", accessToken: String, refreshToken: String?,
                expiresAt: Date, namespace: UUID = UUID()) {
        self.clientID = clientID; self.clientSecret = clientSecret; self.accessToken = accessToken
        self.refreshToken = refreshToken; self.expiresAt = expiresAt; self.namespace = namespace
    }
}

public protocol CloudCredentialStore: Sendable {
    func load(_ provider: CloudProvider) throws -> CloudCredential?
    func save(_ credential: CloudCredential, for provider: CloudProvider) throws
    func delete(_ provider: CloudProvider) throws
}

public enum CloudError: LocalizedError {
    case configuration, disconnected, authorizationDenied, invalidCallback, invalidResponse
    case permissionDenied, notFound, rateLimited, server(Int), cacheDamaged, noMusic, keychain(Int32)
    public var errorDescription: String? {
        switch self {
        case .configuration: "请先配置网盘应用的 Client ID / App key。"
        case .disconnected: "网盘授权已失效，请重新连接账号。"
        case .authorizationDenied: "授权未完成，可以重新连接。"
        case .invalidCallback: "授权回调校验失败，请重新连接。"
        case .invalidResponse: "网盘返回了无法识别的数据。"
        case .permissionDenied: "网盘拒绝了访问，请检查应用权限、Drive API 是否启用，以及文件是否允许下载。"
        case .notFound: "网盘文件或文件夹已不存在，请刷新后重试。"
        case .rateLimited: "网盘暂时限制了请求频率，请稍后重试。"
        case .server(let code): "网盘服务暂不可用（HTTP \(code)）。"
        case .cacheDamaged: "缓存文件不完整，原有缓存已保留，请重新下载。"
        case .noMusic: "这个文件夹及其子文件夹中没有可下载的受支持音乐。"
        case .keychain(let code): "无法访问 macOS 钥匙串（\(code)），请检查应用的钥匙串权限。"
        }
    }
}

public enum CloudFileNames {
    public static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func safe(_ value: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = value.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "untitled" }
        let ext = (cleaned as NSString).pathExtension
        let stem = (cleaned as NSString).deletingPathExtension
        var short = ""
        for character in stem {
            guard (short + String(character)).utf8.count <= 180 else { break }
            short.append(character)
        }
        if short.hasPrefix(".") { short = "_" + short }
        return ext.isEmpty ? short : short + "." + String(ext.prefix(12))
    }
}
