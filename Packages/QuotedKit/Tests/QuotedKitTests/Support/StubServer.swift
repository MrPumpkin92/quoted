import Foundation
import Synchronization
@testable import QuotedKit

/// A fake Supabase for request-level unit tests. Every request a ``Backend`` made with
/// ``StubServer/makeBackend()`` sends goes to this server's handler instead of the network, and is
/// recorded for assertions. Servers are isolated by an `X-Stub-ID` header, so tests can run in
/// parallel.
final class StubServer: Sendable {
    struct Request: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data?

        var path: String { url.path() }

        /// Query items by name (the last value wins).
        var query: [String: String] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        }

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        /// The body parsed as JSON.
        var json: Any? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        }
    }

    struct Response: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String] = ["Content-Type": "application/json"]

        static func json(_ status: Int, _ text: String) -> Response {
            Response(status: status, body: Data(text.utf8))
        }

        static let noContent = Response(status: 204, body: Data())

        /// A GoTrue error answer as the current API version sends it: `{"code": "<error code>", …}`
        /// with the `X-Supabase-Api-Version` header the SDK needs to read `code` as the error code.
        static func authError(_ status: Int, code: String, message: String) -> Response {
            Response(
                status: status,
                body: Data(#"{"code":"\#(code)","message":"\#(message)"}"#.utf8),
                headers: ["Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01"]
            )
        }

        /// One page of a `count=exact` select: `rows` starting at `offset`, out of `total`.
        static func page(_ rows: [String], offset: Int, total: Int) -> Response {
            let range = rows.isEmpty ? "*" : "\(offset)-\(offset + rows.count - 1)"
            return Response(
                status: 200,
                body: Data("[\(rows.joined(separator: ","))]".utf8),
                headers: ["Content-Type": "application/json", "Content-Range": "\(range)/\(total)"]
            )
        }

        static func notFound(_ request: Request) -> Response {
            .json(404, #"{"message":"no stub for \#(request.method) \#(request.path)"}"#)
        }
    }

    typealias Handler = @Sendable (Request) -> Response

    static let baseURL = URL(string: "http://stub.test:54321")!
    static let publishableKey = "sb_publishable_stub_key_for_tests_0000"
    static let userID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let accessToken = "stub-access-token"

    let id = UUID().uuidString
    private let state: Mutex<(handler: Handler, requests: [Request])>

    init(_ handler: @escaping Handler) {
        state = Mutex((handler: handler, requests: []))
        StubRegistry.shared.register(self)
    }

    deinit {
        StubRegistry.shared.unregister(id)
    }

    /// Every request received so far, in order.
    var requests: [Request] { state.withLock { $0.requests } }

    /// Requests to a REST table (`/rest/v1/<table>`).
    func requests(table: String) -> [Request] {
        requests.filter { $0.path == "/rest/v1/\(table)" }
    }

    func setHandler(_ handler: @escaping Handler) {
        state.withLock { $0.handler = handler }
    }

    fileprivate func respond(to request: Request) -> Response {
        let handler = state.withLock { state -> Handler in
            state.requests.append(request)
            return state.handler
        }
        return handler(request)
    }

    /// A backend whose traffic goes to this server, with an in-memory session.
    func makeBackend() -> Backend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return Backend(
            config: SupabaseConfig(url: Self.baseURL, publishableKey: Self.publishableKey),
            authStorage: InMemoryAuthStorage(),
            urlSession: URLSession(configuration: configuration),
            headers: [StubURLProtocol.header: id]
        )
    }

    /// A backend that is already signed in as ``userID`` (through a stubbed password sign-in).
    func makeSignedInBackend() async throws -> Backend {
        let backend = makeBackend()
        let previous = state.withLock { $0.handler }
        setHandler { request in
            if request.path == "/auth/v1/token" { return .json(200, Self.sessionJSON()) }
            return previous(request)
        }
        try await backend.auth.signIn(email: "stub@example.com", password: "password")
        setHandler(previous)
        state.withLock { $0.requests.removeAll() }
        return backend
    }

    /// An unsigned JWT whose payload is `claims` (enough for code that only reads claims).
    static func jwt(_ claims: String) -> String {
        func encode(_ text: String) -> String {
            Data(text.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(encode(#"{"alg":"HS256","typ":"JWT"}"#)).\(encode(claims)).c2lnbmF0dXJl"
    }

    /// A GoTrue session response for ``userID``.
    static func sessionJSON(userID: UUID = userID, accessToken: String = accessToken) -> String {
        let expiresAt = Int(Date().timeIntervalSince1970) + 3600
        return """
        {"access_token":"\(accessToken)","token_type":"bearer","expires_in":3600,"expires_at":\(expiresAt),
         "refresh_token":"stub-refresh-token",
         "user":{"id":"\(userID.uuidString.lowercased())","aud":"authenticated","role":"authenticated",
                 "email":"stub@example.com","app_metadata":{"provider":"email"},"user_metadata":{},
                 "created_at":"2026-10-19T00:00:00Z","updated_at":"2026-10-19T00:00:00Z","is_anonymous":false}}
        """
    }
}

/// Finds the ``StubServer`` for a request by its `X-Stub-ID` header.
final class StubRegistry: Sendable {
    static let shared = StubRegistry()
    private let servers = Mutex<[String: WeakServer]>([:])

    private struct WeakServer: @unchecked Sendable {
        weak var server: StubServer?
    }

    func register(_ server: StubServer) {
        servers.withLock { $0[server.id] = WeakServer(server: server) }
    }

    func unregister(_ id: String) {
        _ = servers.withLock { $0.removeValue(forKey: id) }
    }

    func server(for id: String?) -> StubServer? {
        guard let id else { return nil }
        return servers.withLock { $0[id]?.server }
    }
}

/// Routes requests to the registered ``StubServer``. Unknown requests fail with
/// `URLError(.cannotConnectToHost)`, so nothing reaches the network.
final class StubURLProtocol: URLProtocol {
    static let header = "X-Stub-ID"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let server = StubRegistry.shared.server(for: request.value(forHTTPHeaderField: Self.header))
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let recorded = StubServer.Request(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? request.httpBodyStream.map(Self.read)
        )
        let response = server.respond(to: recorded)
        guard let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
