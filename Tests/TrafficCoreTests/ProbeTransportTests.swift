import Foundation
import XCTest
@testable import TrafficCore

private enum MockResponse: Sendable {
    case success, failure, portal, largeHeader, largeStream, stall
}
private final class MockState: @unchecked Sendable {
    let lock = NSLock()
    var responses: [String: MockResponse] = [:]
    var requested: [String] = []
    var cancellations = 0
    func configure(_ primary: MockResponse, _ fallback: MockResponse) {
        lock.withLock { responses = ["primary.test": primary, "fallback.test": fallback]; requested = []; cancellations = 0 }
    }
    func take(_ host: String) -> MockResponse { lock.withLock { requested.append(host); return responses[host] ?? .failure } }
    func stopped() { lock.withLock { cancellations += 1 } }
    func requests() -> [String] { lock.withLock { requested } }
}
private final class MockProtocol: URLProtocol, @unchecked Sendable {
    static let state = MockState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.state.take(request.url!.host!)
        switch response {
        case .stall: return
        case .failure:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        default:
            let status = response == .success ? 204 : 200
            let headers = response == .largeHeader ? ["Content-Length": "1000000"] : [:]
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            if response == .portal { client?.urlProtocol(self, didLoad: Data("<html>Sign in</html>".utf8)) }
            if response == .largeStream { client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 5000)) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { Self.state.stopped() }
}
final class ProbeTransportTests: XCTestCase {
    let primary = ProbeEndpoint(url: URL(string: "https://primary.test/check")!, status: 204)
    let fallback = ProbeEndpoint(url: URL(string: "https://fallback.test/check")!, status: 204)
    func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]; return config
    }
    func testHealthyPrimarySkipsFallback() async {
        MockProtocol.state.configure(.success, .failure)
        let result = await ConnectivityProbe.check(primary: primary, fallback: fallback, configuration: configuration())
        XCTAssertEqual(result, .success); XCTAssertEqual(MockProtocol.state.requests(), ["primary.test"])
    }
    func testFallbackCanRecoverFailedPrimary() async {
        MockProtocol.state.configure(.failure, .success)
        let result = await ConnectivityProbe.check(primary: primary, fallback: fallback, configuration: configuration())
        XCTAssertEqual(result, .success); XCTAssertEqual(MockProtocol.state.requests(), ["primary.test", "fallback.test"])
    }
    func testBothFailuresAreRequiredForFailedRound() async {
        MockProtocol.state.configure(.failure, .failure)
        let result = await ConnectivityProbe.check(primary: primary, fallback: fallback, configuration: configuration())
        XCTAssertEqual(result, .failed)
    }
    func testCaptivePageAndFailedFallbackRemainUncertain() async {
        MockProtocol.state.configure(.portal, .failure)
        let result = await ConnectivityProbe.check(primary: primary, fallback: fallback, configuration: configuration())
        XCTAssertEqual(result, .unexpected)
    }
    func testLargeDeclaredAndStreamingResponsesAreRejected() async {
        for response in [MockResponse.largeHeader, .largeStream] {
            MockProtocol.state.configure(response, .failure)
            let result = await ConnectivityProbe.check(primary: primary, fallback: fallback, configuration: configuration())
            XCTAssertEqual(result, .unexpected)
        }
    }
    func testCancellationStopsRequestAndDoesNotStartFallback() async {
        MockProtocol.state.configure(.stall, .success)
        let config = configuration(), primary = self.primary, fallback = self.fallback
        let task = Task { await ConnectivityProbe.check(primary: primary, fallback: fallback, configuration: config) }
        for _ in 0..<100 where MockProtocol.state.requests().isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .failed); XCTAssertEqual(MockProtocol.state.requests(), ["primary.test"])
    }
}
