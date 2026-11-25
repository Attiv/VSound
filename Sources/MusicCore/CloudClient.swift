import Foundation

private struct CloudTokenResponse: Decodable {
    var access_token: String
    var refresh_token: String?
    var expires_in: Double?
    var token_type: String?
}

public actor CloudClient {
    private let credentials: any CloudCredentialStore
    private let session: URLSession
    private var refreshes: [CloudProvider: Task<CloudCredential, Error>] = [:]
    private var blockedUntil: [CloudProvider: Date] = [:]

    public init(credentials: any CloudCredentialStore = KeychainCloudCredentialStore(), session: URLSession? = nil) {
        self.credentials = credentials
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: CloudRedirectPolicy(), delegateQueue: nil)
    }

    public func connectedProviders() throws -> Set<CloudProvider> {
        try Set(CloudProvider.allCases.filter { try credentials.load($0) != nil })
    }

    public func connect(flow: CloudOAuthFlow, code: String, configuration: CloudClientConfiguration) async throws {
        guard flow.clientID == configuration.clientID, !code.isEmpty else { throw CloudError.configuration }
        refreshes[flow.provider]?.cancel(); refreshes[flow.provider] = nil
        var fields = ["grant_type": "authorization_code", "code": code, "client_id": configuration.clientID,
                      "redirect_uri": flow.redirectURI.absoluteString, "code_verifier": flow.verifier]
        if flow.provider == .googleDrive, !configuration.clientSecret.isEmpty { fields["client_secret"] = configuration.clientSecret }
        let token = try await tokenRequest(flow.provider, fields: fields)
        let credential = try makeCredential(token, clientID: configuration.clientID, secret: configuration.clientSecret)
        try Task.checkCancellation()
        try credentials.save(credential, for: flow.provider)
        blockedUntil[flow.provider] = nil
    }

    public func disconnect(_ provider: CloudProvider) throws {
        refreshes[provider]?.cancel(); refreshes[provider] = nil
        try credentials.delete(provider)
    }

    public func namespace(for provider: CloudProvider) throws -> UUID {
        guard let value = try credentials.load(provider) else { throw CloudError.disconnected }
        return value.namespace
    }

    public func list(_ provider: CloudProvider, folderID: String) async throws -> [CloudItem] {
        var result: [CloudItem] = [], cursor: String?
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            var request: URLRequest
            if provider == .googleDrive {
                let folder = folderID.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
                url.queryItems = [.init(name: "q", value: "'\(folder)' in parents and trashed = false"),
                                  .init(name: "pageSize", value: "1000"), .init(name: "orderBy", value: "folder,name"),
                                  .init(name: "supportsAllDrives", value: "true"), .init(name: "includeItemsFromAllDrives", value: "true"),
                                  .init(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,modifiedTime,version,capabilities(canDownload))")]
                if let cursor { url.queryItems?.append(.init(name: "pageToken", value: cursor)) }
                request = URLRequest(url: url.url!)
            } else {
                let endpoint = cursor == nil ? "list_folder" : "list_folder/continue"
                request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/\(endpoint)")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body: [String: Any] = cursor.map { ["cursor": $0] }
                    ?? ["path": folderID, "recursive": false, "include_deleted": false, "limit": 2000]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let data = try await data(request, provider: provider)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = object[provider == .googleDrive ? "files" : "entries"] as? [[String: Any]] else { throw CloudError.invalidResponse }
            for entry in entries {
                guard let id = entry["id"] as? String, !id.isEmpty, let name = entry["name"] as? String else { continue }
                let folder = provider == .googleDrive
                    ? entry["mimeType"] as? String == "application/vnd.google-apps.folder" : entry[".tag"] as? String == "folder"
                if provider == .dropbox, !folder, entry[".tag"] as? String != "file" { continue }
                let size = (entry["size"] as? String).flatMap(Int64.init) ?? (entry["size"] as? NSNumber)?.int64Value
                let revision = (entry["rev"] as? String) ?? [entry["version"] as? String, entry["modifiedTime"] as? String].compactMap { $0 }.joined(separator: ":")
                let canDownload = (entry["capabilities"] as? [String: Any])?["canDownload"] as? Bool ?? true
                result.append(CloudItem(id: id, name: name, isFolder: folder, size: size, revision: revision, canDownload: canDownload))
            }
            if provider == .googleDrive { cursor = object["nextPageToken"] as? String }
            else {
                guard let more = object["has_more"] as? Bool else { throw CloudError.invalidResponse }
                cursor = more ? object["cursor"] as? String : nil
                if more && cursor == nil { throw CloudError.invalidResponse }
            }
            if let cursor, !seen.insert(cursor).inserted { throw CloudError.invalidResponse }
        } while cursor != nil
        var ids = Set<String>()
        return result.filter { ids.insert($0.id).inserted }.sorted {
            $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func download(_ item: CloudItem, provider: CloudProvider) async throws -> URL {
        guard !item.isFolder, item.canDownload else { throw CloudError.permissionDenied }
        var request: URLRequest
        if provider == .googleDrive {
            var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            url.path += "/" + item.id
            url.queryItems = [.init(name: "alt", value: "media"), .init(name: "supportsAllDrives", value: "true")]
            request = URLRequest(url: url.url!)
        } else {
            request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
            request.httpMethod = "POST"
            let arg = try JSONSerialization.data(withJSONObject: ["path": item.id])
            let header = String(data: arg, encoding: .utf8)!
            guard header.unicodeScalars.allSatisfy({ $0.isASCII }) else { throw CloudError.invalidResponse }
            request.setValue(header, forHTTPHeaderField: "Dropbox-API-Arg")
        }
        request.timeoutInterval = 180
        for attempt in 0...1 {
            try checkRateLimit(provider)
            let credential = try await authorized(provider, forceRefresh: attempt > 0)
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            let (file, response) = try await session.download(for: request)
            do {
                guard let http = response as? HTTPURLResponse else { throw CloudError.invalidResponse }
                if http.statusCode == 401, attempt == 0 { try? FileManager.default.removeItem(at: file); continue }
                try validate(http, provider: provider)
                if let expected = item.size, expected >= 0 {
                    let actual = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    guard actual.map(Int64.init) == expected else { throw CloudError.cacheDamaged }
                }
                return file
            } catch { try? FileManager.default.removeItem(at: file); throw error }
        }
        throw CloudError.disconnected
    }

    private func data(_ original: URLRequest, provider: CloudProvider) async throws -> Data {
        for attempt in 0...1 {
            try checkRateLimit(provider)
            let credential = try await authorized(provider, forceRefresh: attempt > 0)
            var request = original
            request.timeoutInterval = 30
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw CloudError.invalidResponse }
            if response.statusCode == 401, attempt == 0 { continue }
            try validate(response, provider: provider)
            return data
        }
        throw CloudError.disconnected
    }

    private func authorized(_ provider: CloudProvider, forceRefresh: Bool) async throws -> CloudCredential {
        guard let current = try credentials.load(provider) else { throw CloudError.disconnected }
        if !forceRefresh, current.expiresAt.timeIntervalSinceNow > 60 { return current }
        if let pending = refreshes[provider] { return try await pending.value }
        guard let refresh = current.refreshToken, !refresh.isEmpty else { throw CloudError.disconnected }
        let task = Task<CloudCredential, Error> {
            var fields = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": current.clientID]
            if provider == .googleDrive, !current.clientSecret.isEmpty { fields["client_secret"] = current.clientSecret }
            let response = try await self.tokenRequest(provider, fields: fields)
            let value = try self.makeCredential(response, clientID: current.clientID, secret: current.clientSecret,
                                                refresh: current.refreshToken, namespace: current.namespace)
            try Task.checkCancellation()
            try self.credentials.save(value, for: provider)
            return value
        }
        refreshes[provider] = task
        defer { refreshes[provider] = nil }
        return try await task.value
    }

    private func tokenRequest(_ provider: CloudProvider, fields: [String: String]) async throws -> CloudTokenResponse {
        try checkRateLimit(provider)
        var request = URLRequest(url: provider.tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = CloudOAuthFlow.form(fields)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CloudError.invalidResponse }
        if response.statusCode == 400 || response.statusCode == 401 { throw CloudError.disconnected }
        try validate(response, provider: provider)
        return try JSONDecoder().decode(CloudTokenResponse.self, from: data)
    }

    private func makeCredential(_ response: CloudTokenResponse, clientID: String, secret: String,
                                refresh: String? = nil, namespace: UUID = UUID()) throws -> CloudCredential {
        guard !response.access_token.isEmpty,
              response.access_token.rangeOfCharacter(from: .controlCharacters) == nil,
              (response.token_type?.lowercased() ?? "bearer") == "bearer" else { throw CloudError.invalidResponse }
        let expires = response.expires_in ?? 3600
        guard expires.isFinite, expires > 0 else { throw CloudError.invalidResponse }
        return CloudCredential(clientID: clientID, clientSecret: secret, accessToken: response.access_token,
                               refreshToken: response.refresh_token ?? refresh, expiresAt: Date().addingTimeInterval(expires), namespace: namespace)
    }

    private func checkRateLimit(_ provider: CloudProvider) throws {
        if let until = blockedUntil[provider], until > Date() { throw CloudError.rateLimited }
    }
    private func validate(_ response: HTTPURLResponse, provider: CloudProvider) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401: throw CloudError.disconnected
        case 403: throw CloudError.permissionDenied
        case 404, 409: throw CloudError.notFound
        case 429:
            let wait = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            blockedUntil[provider] = Date().addingTimeInterval(min(86_400, max(1, wait)))
            throw CloudError.rateLimited
        default: throw CloudError.server(response.statusCode)
        }
    }
}

final class CloudRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func redirected(_ request: URLRequest, from original: URL) -> URLRequest? {
        guard let url = request.url, url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        var safe = request
        if url.host?.lowercased() != original.host?.lowercased() || url.port != original.port {
            safe.setValue(nil, forHTTPHeaderField: "Authorization")
            safe.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        return safe
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = response.url else { completionHandler(nil); return }
        completionHandler(Self.redirected(request, from: original))
    }
}
