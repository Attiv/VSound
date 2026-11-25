import Foundation
import Network

public final class CloudOAuthReceiver: @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "app.vsound.oauth-loopback")
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var waiting: CheckedContinuation<String, Error>?
    private var flow: CloudOAuthFlow?
    private var result: Result<String, Error>?
    private var connections: [UUID: NWConnection] = [:]

    public init(port: UInt16 = 53682) { self.port = port }

    public func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard self.listener == nil, self.result == nil else { continuation.resume(throwing: CancellationError()); return }
                    self.ready = continuation
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: self.port)!)
                        parameters.allowLocalEndpointReuse = false
                        let listener = try NWListener(using: parameters)
                        self.listener = listener
                        listener.stateUpdateHandler = { [weak self] state in
                            guard let self else { return }
                            switch state {
                            case .ready:
                                guard let port = listener.port,
                                      let uri = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback") else {
                                    self.finish(.failure(CloudError.invalidCallback)); return
                                }
                                self.ready?.resume(returning: uri); self.ready = nil
                            case .failed(let error): self.finish(.failure(error))
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                        listener.start(queue: self.queue)
                        self.queue.asyncAfter(deadline: .now() + 180) { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
                    } catch { self.finish(.failure(error)) }
                }
            }
        } onCancel: { self.cancel() }
    }

    public func waitForCode(flow: CloudOAuthFlow, openBrowser: @escaping @Sendable (URL) -> Void) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result { continuation.resume(with: result); return }
                    guard self.waiting == nil, self.listener != nil else { continuation.resume(throwing: CloudError.invalidCallback); return }
                    self.flow = flow; self.waiting = continuation
                    openBrowser(flow.authorizationURL)
                }
            }
        } onCancel: { self.cancel() }
    }

    public func cancel() { queue.async { self.finish(.failure(CancellationError())) } }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8, result == nil else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            connection?.cancel(); self?.connections.removeValue(forKey: id)
        }
        receive(connection, id: id, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 8192, error == nil else { self.respond(connection, id: id, success: false); return }
            if buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
                if complete { self.respond(connection, id: id, success: false) }
                else { self.receive(connection, id: id, buffer: buffer) }
                return
            }
            guard let text = String(data: buffer, encoding: .utf8), let flow = self.flow else {
                self.respond(connection, id: id, success: false); return
            }
            let lines = text.components(separatedBy: "\r\n")
            let request = lines[0].split(separator: " ")
            let expectedHost = "127.0.0.1:\(flow.redirectURI.port ?? 53682)"
            let host = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("host:") })?
                .dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard request.count == 3, request[0] == "GET", request[1].hasPrefix("/"), !request[1].hasPrefix("//"),
                  host == expectedHost, let callback = URL(string: "http://\(expectedHost)\(request[1])") else {
                self.respond(connection, id: id, success: false); return
            }
            do {
                let code = try flow.code(from: callback)
                self.respond(connection, id: id, success: true, result: .success(code))
            } catch CloudError.authorizationDenied {
                self.respond(connection, id: id, success: false, result: .failure(CloudError.authorizationDenied))
            } catch { self.respond(connection, id: id, success: false) }
        }
    }

    private func respond(_ connection: NWConnection, id: UUID, success: Bool, result: Result<String, Error>? = nil) {
        let body = success ? "VSound authorization received. You may close this window and return to VSound."
            : "Authorization response was not accepted. Return to VSound and try again."
        let response = "HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel(); self?.connections.removeValue(forKey: id)
            if let result { self?.finish(result) }
        })
    }

    private func finish(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        if let ready {
            if case .failure(let error) = result { ready.resume(throwing: error) }
            else { ready.resume(throwing: CloudError.invalidCallback) }
            self.ready = nil
        }
        waiting?.resume(with: result); waiting = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
    }
}
