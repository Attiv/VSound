import Foundation
@testable import MusicCore
import XCTest

private final class CloudTestVault: CloudCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CloudProvider: CloudCredential] = [:]
    func load(_ provider: CloudProvider) throws -> CloudCredential? { lock.withLock { values[provider] } }
    func save(_ credential: CloudCredential, for provider: CloudProvider) throws { lock.withLock { values[provider] = credential } }
    func delete(_ provider: CloudProvider) throws { _ = lock.withLock { values.removeValue(forKey: provider) } }
}

private final class CloudStubProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, Data, [String: String]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = Self.lock.withLock { Self.handler }
            let result = try handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: result.2)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class CloudOAuthTests: XCTestCase {
    func testPKCEAndReadOnlyAuthorizationURLs() throws {
        XCTAssertEqual(CloudOAuthFlow.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        for provider in CloudProvider.allCases {
            let flow = try CloudOAuthFlow(provider: provider, clientID: "unit+client")
            let query = URLComponents(url: flow.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
            let values = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            XCTAssertEqual(values["client_id"], "unit+client")
            XCTAssertEqual(values["code_challenge_method"], "S256")
            XCTAssertEqual(values["state"], flow.state)
            XCTAssertEqual(flow.verifier.count, 43)
            XCTAssertFalse(flow.authorizationURL.absoluteString.contains(flow.verifier))
            XCTAssertFalse(provider.scopes.contains { $0.contains("write") })
            XCTAssertNil(values["client_secret"])
            XCTAssertEqual(values[provider == .googleDrive ? "access_type" : "token_access_type"], "offline")
            XCTAssertNotEqual(try CloudOAuthFlow(provider: provider, clientID: "unit").state, flow.state)
        }
    }

    func testCallbackRejectsWrongStateOriginPathAndDuplicateParameters() throws {
        let flow = try CloudOAuthFlow(provider: .googleDrive, clientID: "unit")
        let base = flow.redirectURI.absoluteString
        XCTAssertEqual(try flow.code(from: URL(string: base + "?state=\(flow.state)&code=unit-code")!), "unit-code")
        for url in [base + "?state=wrong&code=x", base + "?state=\(flow.state)&code=a&code=b",
                    base + "?state=\(flow.state)&state=\(flow.state)&code=a", base + "?state=\(flow.state)&code=a#fragment",
                    "http://localhost:53682/oauth/callback?state=\(flow.state)&code=a",
                    "http://127.0.0.1:53683/oauth/callback?state=\(flow.state)&code=a",
                    "http://127.0.0.1:53682/wrong?state=\(flow.state)&code=a"] {
            XCTAssertThrowsError(try flow.code(from: URL(string: url)!))
        }
        XCTAssertThrowsError(try flow.code(from: URL(string: base + "?state=\(flow.state)&error=access_denied")!)) {
            guard case CloudError.authorizationDenied = $0 else { return XCTFail("Expected authorization denial") }
        }
    }

    func testFormEncodingAndFileNamesAreSafe() throws {
        var components = URLComponents()
        components.percentEncodedQuery = String(data: CloudOAuthFlow.form(["code": "a+b&空 格", "client_id": "client"]), encoding: .utf8)
        XCTAssertEqual(components.queryItems?.first { $0.name == "code" }?.value, "a+b&空 格")
        for name in ["../../music.flac", "a/b\\c:track.mp3", String(repeating: "🎵", count: 100) + ".flac", "\u{0}track.wav"] {
            let safe = CloudFileNames.safe(name)
            XCTAssertFalse(safe.contains("/")); XCTAssertFalse(safe.contains("\\"))
            XCTAssertFalse(safe.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
            XCTAssertLessThan(safe.utf8.count, 255)
        }
        XCTAssertNotEqual(CloudFileNames.safe(".."), "..")
    }

    func testRedirectsNeverSendCredentialsAcrossOriginsOrDowngradeTLS() {
        let original = URL(string: "https://www.googleapis.com/drive/v3/files/id")!
        var request = URLRequest(url: URL(string: "https://download.example.test/file")!)
        request.setValue("unit-access", forHTTPHeaderField: "Authorization")
        request.setValue("unit-cookie", forHTTPHeaderField: "Cookie")
        let crossOrigin = CloudRedirectPolicy.redirected(request, from: original)
        XCTAssertNil(crossOrigin?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(crossOrigin?.value(forHTTPHeaderField: "Cookie"))
        request.url = URL(string: "http://download.example.test/file")!
        XCTAssertNil(CloudRedirectPolicy.redirected(request, from: original))
        request.url = original
        XCTAssertEqual(CloudRedirectPolicy.redirected(request, from: original)?.value(forHTTPHeaderField: "Authorization"), "unit-access")
    }

    func testRealLoopbackReceiverRejectsInvalidStateAndAcceptsValidCode() async throws {
        let receiver = CloudOAuthReceiver(port: 0)
        defer { receiver.cancel() }
        let redirect = try await receiver.start()
        XCTAssertEqual(redirect.host, "127.0.0.1")
        XCTAssertNotEqual(redirect.port, 0)
        let flow = try CloudOAuthFlow(provider: .googleDrive, clientID: "unit", redirectURI: redirect)
        let opened = expectation(description: "Authorization browser opens after receiver is ready")
        let waiting = Task { try await receiver.waitForCode(flow: flow) { _ in opened.fulfill() } }
        await fulfillment(of: [opened], timeout: 2)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var bad = URLRequest(url: URL(string: redirect.absoluteString + "?state=wrong&code=unit-code")!, timeoutInterval: 2)
        bad.httpMethod = "GET"
        let (_, rejected) = try await session.data(for: bad)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
        let valid = URLRequest(url: URL(string: redirect.absoluteString + "?state=\(flow.state)&code=unit-code")!, timeoutInterval: 2)
        let (body, response) = try await session.data(for: valid)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            receiver.cancel(); _ = try? await waiting.value
            return XCTFail("Loopback authorization did not succeed")
        }
        let code = try await waiting.value
        XCTAssertEqual(code, "unit-code")
        XCTAssertFalse(String(data: body, encoding: .utf8)!.contains("unit-code"))
    }

    func testReceiverCancellationReleasesTheWaitingContinuation() async throws {
        let receiver = CloudOAuthReceiver(port: 0)
        let redirect = try await receiver.start()
        let flow = try CloudOAuthFlow(provider: .dropbox, clientID: "unit", redirectURI: redirect)
        let opened = expectation(description: "Waiting")
        let waiting = Task { try await receiver.waitForCode(flow: flow) { _ in opened.fulfill() } }
        await fulfillment(of: [opened], timeout: 2)
        receiver.cancel()
        do { _ = try await waiting.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

final class CloudClientTests: XCTestCase {
    private var vault: CloudTestVault!
    private var session: URLSession!
    private var client: CloudClient!
    override func setUpWithError() throws {
        vault = CloudTestVault()
        for provider in CloudProvider.allCases {
            try vault.save(.init(clientID: "unit-client", accessToken: "unit-access", refreshToken: "unit-refresh",
                                 expiresAt: Date().addingTimeInterval(3600)), for: provider)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudStubProtocol.self]
        session = URLSession(configuration: config)
        client = CloudClient(credentials: vault, session: session)
    }
    override func tearDownWithError() throws { session.invalidateAndCancel(); CloudStubProtocol.handler = nil }

    private func stub(_ handler: @escaping (URLRequest) throws -> (Int, Data, [String: String])) {
        CloudStubProtocol.lock.withLock { CloudStubProtocol.handler = handler }
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func requestBody(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    func testCodeExchangeUsesPKCEAndPersistsCredentialsForBothProviders() async throws {
        for provider in CloudProvider.allCases {
            let flow = try CloudOAuthFlow(provider: provider, clientID: "unit-client")
            let configuration = CloudClientConfiguration(clientID: "unit-client", clientSecret: "unit-secret")
            stub { request in
                XCTAssertEqual(request.url, provider.tokenURL)
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                var components = URLComponents()
                components.percentEncodedQuery = String(data: self.requestBody(request), encoding: .utf8)
                let fields = Dictionary(components.queryItems!.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
                XCTAssertEqual(fields["grant_type"], "authorization_code")
                XCTAssertEqual(fields["code"], "unit-code")
                XCTAssertEqual(fields["client_id"], configuration.clientID)
                XCTAssertEqual(fields["code_verifier"], flow.verifier)
                XCTAssertEqual(fields["redirect_uri"], flow.redirectURI.absoluteString)
                XCTAssertEqual(fields["client_secret"], provider == .googleDrive ? "unit-secret" : nil)
                return (200, try self.json(["access_token": "connected", "refresh_token": "offline", "expires_in": 3600, "token_type": "Bearer"]), [:])
            }
            try await client.connect(flow: flow, code: "unit-code", configuration: configuration)
            let saved = try vault.load(provider)!
            XCTAssertEqual(saved.accessToken, "connected")
            XCTAssertEqual(saved.refreshToken, "offline")
            XCTAssertEqual(saved.clientID, configuration.clientID)
            XCTAssertGreaterThan(saved.expiresAt.timeIntervalSinceNow, 3500)
        }
    }

    func testInvalidTokenCannotReplaceExistingCredentials() async throws {
        let original = try vault.load(.googleDrive)!
        let flow = try CloudOAuthFlow(provider: .googleDrive, clientID: "unit-client")
        stub { _ in (200, try self.json(["access_token": "", "expires_in": 3600]), [:]) }
        do {
            try await client.connect(flow: flow, code: "unit-code", configuration: .init(clientID: "unit-client"))
            XCTFail("Expected invalid token rejection")
        } catch { guard case CloudError.invalidResponse = error else { return XCTFail("Wrong token validation error") } }
        let saved = try vault.load(.googleDrive)!
        XCTAssertEqual(saved.accessToken, original.accessToken)
        XCTAssertEqual(saved.namespace, original.namespace)
    }

    func testGoogleDrivePaginationAndDeduplication() async throws {
        var calls = 0
        stub { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-access")
            let params = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(params.contains { $0.name == "q" && $0.value == "'root' in parents and trashed = false" })
            calls += 1
            if calls == 1 {
                return (200, try self.json(["nextPageToken": "second", "files": [
                    ["id": "folder", "name": "Album", "mimeType": "application/vnd.google-apps.folder"],
                    ["id": "song", "name": "Song.flac", "size": "42", "version": "1"]
                ]]), [:])
            }
            XCTAssertTrue(params.contains { $0.name == "pageToken" && $0.value == "second" })
            return (200, try self.json(["files": [["id": "song", "name": "Song.flac"],
                                                ["id": "lyric", "name": "Song.lrc", "size": "8"]]]), [:])
        }
        let items = try await client.list(.googleDrive, folderID: "root")
        XCTAssertEqual(calls, 2); XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items[0].isFolder)
        XCTAssertEqual(items.first { $0.id == "song" }?.size, 42)
    }

    func testDropboxPaginationAndBody() async throws {
        var calls = 0
        stub { request in
            calls += 1
            let body = try JSONSerialization.jsonObject(with: self.requestBody(request)) as! [String: Any]
            if calls == 1 {
                XCTAssertEqual(body["path"] as? String, "")
                XCTAssertEqual(body["recursive"] as? Bool, false)
                return (200, try self.json(["entries": [[".tag": "folder", "id": "id:folder", "name": "Album"]], "has_more": true, "cursor": "next"]), [:])
            }
            XCTAssertTrue(request.url!.path.hasSuffix("list_folder/continue"))
            XCTAssertEqual(body["cursor"] as? String, "next")
            return (200, try self.json(["entries": [[".tag": "file", "id": "id:song", "name": "Song.mp3", "size": 8, "rev": "one"]], "has_more": false, "cursor": "done"]), [:])
        }
        let items = try await client.list(.dropbox, folderID: "")
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[1].isAudio); XCTAssertEqual(items[1].revision, "one")
    }

    func testUnauthorizedRequestRefreshesOnceAndPreservesRefreshToken() async throws {
        var calls = 0, refreshCalls = 0
        let original = try vault.load(.googleDrive)!
        stub { request in
            calls += 1
            if request.url!.host == "oauth2.googleapis.com" {
                refreshCalls += 1
                let body = String(data: self.requestBody(request), encoding: .utf8)!
                XCTAssertTrue(body.contains("grant_type=refresh_token"))
                return (200, try self.json(["access_token": "renewed", "expires_in": 3600, "token_type": "Bearer"]), [:])
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer unit-access" { return (401, Data(), [:]) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer renewed")
            return (200, try self.json(["files": []]), [:])
        }
        _ = try await client.list(.googleDrive, folderID: "root")
        XCTAssertEqual(calls, 3); XCTAssertEqual(refreshCalls, 1)
        let credential = try vault.load(.googleDrive)!
        XCTAssertEqual(credential.refreshToken, "unit-refresh")
        XCTAssertEqual(credential.namespace, original.namespace)
    }

    func testRateLimitPreventsImmediateRepeatedRequests() async throws {
        var calls = 0
        stub { _ in calls += 1; return (429, Data(), ["Retry-After": "60"]) }
        for _ in 0..<2 {
            do { _ = try await client.list(.dropbox, folderID: ""); XCTFail("Expected rate limiting") }
            catch { guard case CloudError.rateLimited = error else { return XCTFail("Wrong error") } }
        }
        XCTAssertEqual(calls, 1)
    }

    func testDisconnectRemovesOnlySelectedCredentials() async throws {
        try await client.disconnect(.googleDrive)
        XCTAssertNil(try vault.load(.googleDrive))
        XCTAssertNotNil(try vault.load(.dropbox))
        let providers = try await client.connectedProviders()
        XCTAssertEqual(providers, [.dropbox])
    }

    func testRecursiveFolderImportReusesAudioAndLyricCaches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tone = directory.appendingPathComponent("tone.wav")
        try makeTone(at: tone)
        let audio = try Data(contentsOf: tone), lyric = Data("[00:00.00]Local test".utf8)
        var downloads = 0
        stub { request in
            let url = request.url!
            if url.path.contains("/files/") {
                downloads += 1
                let bytes = url.lastPathComponent == "lyric" ? lyric : audio
                return (200, bytes, ["Content-Type": "application/octet-stream"])
            }
            let parent = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "q" }!.value!
            let song: [String: Any] = ["id": "song", "name": "Tone.wav", "size": String(audio.count), "version": "1"]
            if parent.hasPrefix("'root'") {
                return (200, try self.json(["files": [song,
                    ["id": "lyric", "name": "Tone.lrc", "size": String(lyric.count), "version": "1"],
                    ["id": "child", "name": "Child", "mimeType": "application/vnd.google-apps.folder"]]]), [:])
            }
            return (200, try self.json(["files": [song,
                ["id": "second", "name": "Second.wav", "size": String(audio.count), "version": "1"],
                ["id": "root", "name": "Cycle", "mimeType": "application/vnd.google-apps.folder"]]]), [:])
        }
        let importer = CloudMusicImporter(client: client, directory: directory.appendingPathComponent("CloudMusic"))
        let folder = CloudItem(id: "root", name: "Music", isFolder: true)
        let first = try await importer.importFolder(folder, provider: .googleDrive) { _ in }
        XCTAssertEqual(first.downloaded, 2); XCTAssertEqual(first.reused, 0)
        XCTAssertEqual(downloads, 3)
        let scanner = LibraryScanner(artworkDirectory: directory.appendingPathComponent("Artwork"))
        let indexed = try await scanner.scan(.init(url: first.directory), existing: []) { _ in }
        XCTAssertEqual(indexed.tracks.count, 2)
        let localLyrics = LyricsClient(directory: directory.appendingPathComponent("Lyrics"))
        let track = indexed.tracks.first { $0.title == "Tone" }!
        let document = await localLyrics.localOrCached(for: track)
        XCTAssertEqual(document?.lines.first?.text, "Local test")
        let second = try await importer.importFolder(folder, provider: .googleDrive) { _ in }
        XCTAssertEqual(second.downloaded, 0); XCTAssertEqual(second.reused, 2)
        XCTAssertEqual(downloads, 3)
    }

    func testDownloadWritesActualFileAndValidatesByteCount() async throws {
        let audio = Data("unit audio data".utf8)
        stub { request in
            XCTAssertEqual(request.url!.host, "content.dropboxapi.com")
            XCTAssertEqual(request.httpMethod, "POST")
            let arg = request.value(forHTTPHeaderField: "Dropbox-API-Arg")!
            let json = try JSONSerialization.jsonObject(with: Data(arg.utf8)) as! [String: String]
            XCTAssertEqual(json["path"], "id:audio")
            return (200, audio, ["Content-Type": "application/octet-stream"])
        }
        let file = try await client.download(.init(id: "id:audio", name: "声音.flac", size: Int64(audio.count)), provider: .dropbox)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), audio)
        do {
            _ = try await client.download(.init(id: "id:audio", name: "声音.flac", size: 999), provider: .dropbox)
            XCTFail("Expected size validation failure")
        } catch { guard case CloudError.cacheDamaged = error else { return XCTFail("Wrong download error") } }
    }
}

final class CloudCacheTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testCacheReuseReplacementAndSameNamedFiles() throws {
        let cache = CloudFileCache(directory: directory.appendingPathComponent("cache"))
        var item = CloudItem(id: "opaque-id", name: "Song.flac", size: 3, revision: "one")
        let source = directory.appendingPathComponent("download")
        try Data("abc".utf8).write(to: source)
        let destination = cache.destination(for: item)
        try cache.install(source, item: item, at: destination)
        XCTAssertTrue(cache.isFresh(item, at: destination))
        item.revision = "two"
        XCTAssertFalse(cache.isFresh(item, at: destination))
        try Data("xyz".utf8).write(to: source)
        try cache.install(source, item: item, at: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("xyz".utf8))
        XCTAssertTrue(cache.isFresh(item, at: destination))
        var renamed = item; renamed.name = "New name.flac"
        XCTAssertEqual(cache.destination(for: renamed), destination)
        XCTAssertNotEqual(cache.destination(for: .init(id: "different-id", name: "Song.flac")), destination)
    }

    func testTruncatedDownloadAndTraversalCannotOverwritePreviousCache() throws {
        let cache = CloudFileCache(directory: directory.appendingPathComponent("cache"))
        let item = CloudItem(id: "item", name: "Song.mp3", size: 3, revision: "one")
        let source = directory.appendingPathComponent("download")
        try Data("old".utf8).write(to: source)
        let destination = cache.destination(for: item)
        try cache.install(source, item: item, at: destination)
        try Data("broken".utf8).write(to: source)
        XCTAssertThrowsError(try cache.install(source, item: item, at: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        XCTAssertThrowsError(try cache.install(source, item: item, at: directory.appendingPathComponent("outside.mp3")))
    }

    func testLocalLyricSidecarDoesNotInvalidateAudioMarker() throws {
        let cache = CloudFileCache(directory: directory.appendingPathComponent("cache"))
        let audio = CloudItem(id: "audio", name: "Track.wav", size: 3, revision: "one")
        let lyric = CloudItem(id: "lyric", name: "Track.lrc", size: 3, revision: "two")
        let source = directory.appendingPathComponent("download")
        try Data("abc".utf8).write(to: source)
        let url = cache.destination(for: audio)
        try cache.install(source, item: audio, at: url)
        try cache.install(source, item: lyric, at: url.deletingPathExtension().appendingPathExtension("lrc"))
        XCTAssertTrue(cache.isFresh(audio, at: url))
        XCTAssertTrue(cache.isFresh(lyric, at: url.deletingPathExtension().appendingPathExtension("lrc")))
    }

    func testLegacyFolderDecodingAndManagedFolderPersistence() throws {
        let id = UUID()
        let legacy = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "url": directory.absoluteString])
        let decoded = try JSONDecoder().decode(LibraryFolder.self, from: legacy)
        XCTAssertNil(decoded.sourceProvider); XCTAssertNil(decoded.displayName)
        XCTAssertEqual(decoded.name, directory.lastPathComponent)
        let managed = LibraryFolder(url: directory, displayName: "Dropbox · Music", sourceProvider: "dropbox")
        let restored = try JSONDecoder().decode(LibraryFolder.self, from: JSONEncoder().encode(managed))
        XCTAssertEqual(restored.name, "Dropbox · Music")
        XCTAssertEqual(restored.sourceProvider, "dropbox")
    }
}
