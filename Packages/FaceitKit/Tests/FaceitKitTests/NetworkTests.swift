import Foundation
import Testing
@testable import FaceitKit

/// Scripted HTTP responses keyed by path suffix; counts requests per path.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var requests: [String] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request.url!.path); let h = Self.handler; Self.lock.unlock()
        let (status, headers, body) = h!(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: c)
    }
}

@Suite(.serialized) struct NetworkTests {
    func client(attempts: Int = 3) -> FaceitAPIClient {
        FaceitAPIClient(session: MockURLProtocol.session(), apiKey: { "test-key" }, maxAttempts: attempts, sleeper: { _ in })
    }

    @Test func sendsBearerAndDecodes() async throws {
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { req in
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            return (200, [:], try! fixture("player"))
        }
        let p = try await client().player(nickname: "shmeeel")
        #expect(p.nickname == "shmeeel")
    }

    @Test func invalidKeyIsNotRetried() async {
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { _ in (400, [:], Data(#"{"error":"invalid_token","error_description":"Token was not recognised"}"#.utf8)) }
        await #expect(throws: FaceitAPIError.self) { try await client().player(id: "x") }
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test func serverErrorsAreRetriedThenSucceed() async throws {
        MockURLProtocol.requests = []
        var calls = 0
        MockURLProtocol.handler = { _ in
            calls += 1
            return calls < 3 ? (503, [:], Data()) : (200, [:], try! fixture("player"))
        }
        _ = try await client().player(id: "x")
        #expect(MockURLProtocol.requests.count == 3)
    }

    @Test func rateLimitSurfacesAfterRetries() async {
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { _ in (429, ["ratelimit-reset": "1"], Data()) }
        do {
            _ = try await client(attempts: 2).player(id: "x")
            Issue.record("expected error")
        } catch let e as FaceitAPIError {
            #expect(e == .rateLimited(retryAfter: 1))
        } catch { Issue.record("wrong error \(error)") }
        #expect(MockURLProtocol.requests.count == 2)
    }

    @Test func missingKey() async {
        let c = FaceitAPIClient(session: MockURLProtocol.session(), apiKey: { nil })
        await #expect(throws: FaceitAPIError.missingAPIKey) { try await c.player(id: "x") }
    }

    /// Full refresh against recorded responses, then a second refresh within the interval makes NO requests
    /// (this is what keeps several widgets from duplicating requests).
    @Test func repositoryRefreshAndDeduplication() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fk-\(UUID().uuidString)")
        AppGroup.overrideContainer = dir
        defer { AppGroup.overrideContainer = nil; try? FileManager.default.removeItem(at: dir) }
        let store = try LocalStore(directory: dir)
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { req in
            let p = req.url!.path
            if p.hasSuffix("/games/cs2/stats") { return (200, [:], try! fixture("games_stats")) }
            if p.hasSuffix("/stats/cs2") { return (200, [:], try! fixture("lifetime")) }
            if p.contains("/matches/") { return (200, [:], try! fixture("match")) }
            if p.contains("/players/") { return (200, [:], try! fixture("player")) }
            return (404, [:], Data())
        }
        let session = MockURLProtocol.session()
        let repo = StatsRepository(store: store, imageSession: session, clientFactory: { _ in
            FaceitAPIClient(session: session, apiKey: { "k" }, sleeper: { _ in })
        })
        let settings = AppSettings()
        settings.playerId = "73772170-dd92-4053-a056-4958d6709528"
        settings.refreshMinutes = 30
        defer { settings.playerId = nil }

        let first = try await repo.refresh(force: false)
        guard case .fetched(let d) = first else { Issue.record("expected fetch"); return }
        #expect(d.profile.elo == 1571)
        #expect(d.games.count == 30)
        #expect(d.summary.winRate == 40)
        #expect(d.strip.last?.id == d.games.first?.id)   // newest on the right
        let afterFirst = MockURLProtocol.requests.count
        #expect(afterFirst > 3)

        let second = try await repo.refresh(force: false)
        guard case .cached = second else { Issue.record("expected cache"); return }
        #expect(MockURLProtocol.requests.count == afterFirst)

        // Forced refresh right after a fetch is also served from cache (minimum spacing).
        _ = try await repo.refresh(force: true)
        #expect(MockURLProtocol.requests.count == afterFirst)
        #expect(store.snapshots(playerId: settings.playerId!).count == 1)
    }
}
