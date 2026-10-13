import Foundation
import Network

typealias JSON = [String: Any]

/// Set CLICKY_DEBUG=1 to print raw channel traffic.
enum Debug {
    static let enabled = ProcessInfo.processInfo.environment["CLICKY_DEBUG"] != nil

    static func log(_ text: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data((text() + "\n").utf8))
    }
}

enum TVError: LocalizedError {
    case timeout
    case closed
    case unauthorized
    case notConnected
    case badResponse(String)
    case art(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "The TV didn't answer in time."
        case .closed: return "The connection to the TV was closed."
        case .unauthorized: return "The TV declined the connection. Choose Allow on the TV and try again."
        case .notConnected: return "Not connected to the TV."
        case .badResponse(let what): return "Unexpected reply from the TV (\(what))."
        case .art(let what): return "Art Mode error: \(what)."
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        switch self[key] {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    func int(_ key: String) -> Int? { string(key).flatMap { Int($0) } }

    /// Samsung often nests JSON documents as strings inside JSON. Returns the decoded value either way.
    func nested(_ key: String) -> Any? {
        if let s = self[key] as? String, let data = s.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }
        return self[key]
    }
}

extension Task where Success == Never, Failure == Never {
    static func sleep(seconds: Double) async throws {
        try await sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// A single-assignment value that any number of tasks can await.
@MainActor
final class Promise<T> {
    private var result: Result<T, Error>?
    private var waiting: [CheckedContinuation<T, Error>] = []

    func resolve(_ value: Result<T, Error>) {
        guard result == nil else { return }
        result = value
        waiting.forEach { $0.resume(with: value) }
        waiting = []
    }

    var value: T {
        get async throws {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { waiting.append($0) }
        }
    }
}

/// Pending replies matched against incoming messages. Register before sending so nothing is missed.
@MainActor
final class WaiterSet {
    private var entries: [UUID: (match: (JSON) -> Bool, promise: Promise<JSON>)] = [:]

    func expect(timeout: TimeInterval, match: @escaping (JSON) -> Bool) -> Promise<JSON> {
        let id = UUID()
        let promise = Promise<JSON>()
        entries[id] = (match, promise)
        Task { [weak self] in
            try? await Task.sleep(seconds: timeout)
            if let entry = self?.entries.removeValue(forKey: id) {
                entry.promise.resolve(.failure(TVError.timeout))
            }
        }
        return promise
    }

    @discardableResult
    func deliver(_ message: JSON) -> Bool {
        var matched = false
        for (id, entry) in entries where entry.match(message) {
            entries[id] = nil
            entry.promise.resolve(.success(message))
            matched = true
        }
        return matched
    }

    func failAll(_ error: Error) {
        let all = entries
        entries = [:]
        all.values.forEach { $0.promise.resolve(.failure(error)) }
    }
}

final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// The TV serves self-signed certificates. Trust them, but only for private LAN addresses.
final class LocalTrustDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        _ completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           LocalNetwork.isPrivateIPv4(space.host), let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum TVSession {
    private static let delegate = LocalTrustDelegate()

    static let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    /// WebSockets stay open for hours; connect timeouts are enforced by the channel itself.
    static let sockets: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 7 * 24 * 3600
        config.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
}

enum LocalNetwork {
    static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// This Mac's IPv4 address on the same subnet as `peer`, so the TV can reach files we serve.
    static func localAddress(toward peer: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        let peerAddress = inet_addr(peer)
        var fallback: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let netmask = entry.ifa_netmask else { continue }
            var ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &ip, &text, socklen_t(INET_ADDRSTRLEN))
            let string = String(cString: text)
            if peerAddress != INADDR_NONE, ip.s_addr & mask == peerAddress & mask { return string }
            if fallback == nil { fallback = string }
        }
        return fallback
    }
}

extension NWConnection {
    func ready(timeout: TimeInterval) async throws {
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.take() { continuation.resume(throwing: error); self?.cancel() }
                case .cancelled:
                    if once.take() { continuation.resume(throwing: TVError.closed) }
                default:
                    break
                }
            }
            start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                if once.take() { continuation.resume(throwing: TVError.timeout); self?.cancel() }
            }
        }
    }

    func read(exactly count: Int) async throws -> Data {
        var buffer = Data(capacity: count)
        while buffer.count < count {
            let wanted = count - buffer.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                receive(minimumIncompleteLength: 1, maximumLength: wanted) { data, _, complete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if complete {
                        continuation.resume(throwing: TVError.closed)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
