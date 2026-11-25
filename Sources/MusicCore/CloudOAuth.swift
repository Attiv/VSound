import CryptoKit
import Foundation
import Security

public struct CloudOAuthFlow: Sendable {
    public static let redirectURI = URL(string: "http://127.0.0.1:53682/oauth/callback")!
    public let provider: CloudProvider
    public let clientID: String
    public let redirectURI: URL
    public let verifier: String
    public let state: String

    public init(provider: CloudProvider, clientID: String, redirectURI: URL = Self.redirectURI) throws {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudError.configuration }
        self.provider = provider; self.clientID = clientID; self.redirectURI = redirectURI
        verifier = try Self.randomString(); state = try Self.randomString()
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public var authorizationURL: URL {
        var components = URLComponents(url: provider.authorizationURL, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "client_id", value: clientID),
                     .init(name: "redirect_uri", value: redirectURI.absoluteString),
                     .init(name: "response_type", value: "code"),
                     .init(name: "scope", value: provider.scopes.joined(separator: " ")),
                     .init(name: "state", value: state),
                     .init(name: "code_challenge", value: Self.challenge(for: verifier)),
                     .init(name: "code_challenge_method", value: "S256")]
        if provider == .googleDrive {
            items += [.init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")]
        } else { items.append(.init(name: "token_access_type", value: "offline")) }
        components.queryItems = items
        return components.url!
    }

    public func code(from callback: URL) throws -> String {
        guard callback.scheme == redirectURI.scheme, callback.host == redirectURI.host,
              callback.port == redirectURI.port, callback.path == redirectURI.path,
              callback.user == nil, callback.password == nil, callback.fragment == nil,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { throw CloudError.invalidCallback }
        let items = components.queryItems ?? []
        for key in ["state", "code", "error"] where items.filter({ $0.name == key }).count > 1 { throw CloudError.invalidCallback }
        guard items.first(where: { $0.name == "state" })?.value == state else { throw CloudError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw CloudError.authorizationDenied }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.utf8.count <= 8192 else { throw CloudError.invalidCallback }
        return code
    }

    public static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" +
            ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
    }

    private static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CloudError.invalidResponse }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public struct KeychainCloudCredentialStore: CloudCredentialStore {
    private let service = "app.localmusic.player.cloud"
    public init() {}
    private func query(_ provider: CloudProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }
    public func load(_ provider: CloudProvider) throws -> CloudCredential? {
        var query = query(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess else { throw CloudError.keychain(code) }
        guard let data = result as? Data else { throw CloudError.invalidResponse }
        return try JSONDecoder().decode(CloudCredential.self, from: data)
    }
    public func save(_ credential: CloudCredential, for provider: CloudProvider) throws {
        let data = try JSONEncoder().encode(credential)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let code = SecItemUpdate(query(provider) as CFDictionary, attributes as CFDictionary)
        if code == errSecItemNotFound {
            var insert = query(provider)
            insert[kSecValueData as String] = data
            insert[kSecAttrLabel as String] = "VSound · \(provider.title)"
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw CloudError.keychain(added) }
        } else if code != errSecSuccess { throw CloudError.keychain(code) }
    }
    public func delete(_ provider: CloudProvider) throws {
        let code = SecItemDelete(query(provider) as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw CloudError.keychain(code) }
    }
}
