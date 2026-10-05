import Foundation

public enum ConnectionHealth: String, Codable, Sendable {
    case checking, online, uncertain, offline, sleeping, disabled
    public var label: String {
        switch self {
        case .checking: "Checking internet"
        case .online: "Internet reachable"
        case .uncertain: "Internet uncertain"
        case .offline: "Internet unavailable"
        case .sleeping: "Mac sleeping"
        case .disabled: "Checks paused"
        }
    }
}
public enum ProbeOutcome: Sendable { case success, failed, unexpected }
public struct HealthTransition: Sendable {
    public var from: ConnectionHealth
    public var to: ConnectionHealth
    public var date: Date
    public var outageStart: Date?
    public var newOutage: Bool
}
public struct HealthMachine: Sendable {
    public private(set) var state: ConnectionHealth = .checking
    public private(set) var lastChecked: Date?
    public private(set) var outageStart: Date?
    private var firstFailure: Date?
    private var failures = 0
    public init() {}
    public mutating func reset(to state: ConnectionHealth = .checking) {
        self.state = state; failures = 0; firstFailure = nil; outageStart = nil; lastChecked = nil
    }
    public mutating func receive(_ result: ProbeOutcome, at date: Date) -> HealthTransition? {
        let old = state
        let previousOutage = outageStart
        lastChecked = date
        switch result {
        case .success:
            failures = 0; firstFailure = nil; state = .online; outageStart = nil
        case .unexpected:
            failures = 0; firstFailure = nil
            // A portal or unexpected page is uncertain even after a confirmed failure.
            // Preserve the event start so a later valid response can log recovery.
            state = .uncertain
        case .failed:
            // A backward clock change restarts the confirmation window instead of stalling it.
            if firstFailure.map({ date < $0 }) ?? true { firstFailure = date }
            failures += 1
            if failures >= 2, date.timeIntervalSince(firstFailure!) >= 5 {
                state = .offline
                if outageStart == nil { outageStart = date }
            } else if state != .offline { state = .uncertain }
        }
        guard old != state else { return nil }
        return HealthTransition(from: old, to: state, date: date, outageStart: previousOutage ?? outageStart, newOutage: previousOutage == nil && state == .offline)
    }
}

public struct ProbeEndpoint: Sendable {
    public var url: URL
    public var status: Int
    public var body: Data?
    public init(url: URL, status: Int, body: Data? = nil) { self.url = url; self.status = status; self.body = body }
    public func accepts(status: Int, body: Data, finalURL: URL?) -> Bool {
        status == self.status && finalURL == url && (self.body.map { $0 == body } ?? body.isEmpty)
    }
    public static let primary = ProbeEndpoint(url: URL(string: "https://www.gstatic.com/generate_204")!, status: 204)
    public static let fallback = ProbeEndpoint(url: URL(string: "https://cp.cloudflare.com/generate_204")!, status: 204)
}

// A fresh ephemeral session, no cookies/cache, no redirects, hard 4 KiB response limit.
// Delegate cancellation bounds captive-portal bodies before they are downloaded in full.
private final class BoundedProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let endpoint: ProbeEndpoint
    private let configuration: URLSessionConfiguration?
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var bytes = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<ProbeOutcome, Never>?
    private var session: URLSession?
    private var unexpected = false
    init(endpoint: ProbeEndpoint, configuration: URLSessionConfiguration?) { self.endpoint = endpoint; self.configuration = configuration }
    func run() async -> ProbeOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    guard !cancelled else { continuation.resume(returning: .failed); return }
                    self.continuation = continuation
                    let config = configuration ?? URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = 4; config.timeoutIntervalForResource = 5
                    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                    config.httpCookieStorage = nil; config.urlCache = nil
                    config.waitsForConnectivity = false
                    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                    var request = URLRequest(url: endpoint.url)
                    request.setValue("Current/0.1", forHTTPHeaderField: "User-Agent")
                    task = session!.dataTask(with: request)
                    task!.resume()
                }
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true; self.task?.cancel() }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        unexpected = true; completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        if response.expectedContentLength > 4096 { unexpected = true; completionHandler(.cancel) }
        else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if bytes.count + data.count > 4096 { unexpected = true; dataTask.cancel() }
        else { bytes.append(data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome: ProbeOutcome
        if unexpected { outcome = .unexpected }
        else if error != nil { outcome = .failed }
        else if let response, endpoint.accepts(status: response.statusCode, body: bytes, finalURL: response.url) { outcome = .success }
        else { outcome = .unexpected }
        let waiting = lock.withLock {
            let waiting = continuation; continuation = nil; self.task = nil; self.session = nil
            return waiting
        }
        waiting?.resume(returning: outcome)
        session.finishTasksAndInvalidate()
    }
}
public enum ConnectivityProbe {
    public static func check(primary endpoint: ProbeEndpoint = .primary, fallback fallbackEndpoint: ProbeEndpoint = .fallback, configuration: URLSessionConfiguration? = nil) async -> ProbeOutcome {
        let primary = await BoundedProbe(endpoint: endpoint, configuration: configuration).run()
        if Task.isCancelled { return .failed }
        if case .success = primary { return .success }
        let fallback = await BoundedProbe(endpoint: fallbackEndpoint, configuration: configuration).run()
        if case .success = fallback { return .success }
        if case .unexpected = primary { return .unexpected }
        if case .unexpected = fallback { return .unexpected }
        return .failed
    }
}
