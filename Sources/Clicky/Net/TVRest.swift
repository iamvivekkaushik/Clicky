import Foundation

struct TVInfo: Decodable, Equatable {
    struct Device: Decodable, Equatable {
        var frameTVSupport: String?
        var powerState: String?
        var tokenAuthSupport: String?
        var os: String?
        var model: String?
        var modelName: String?
        var name: String?
        var wifiMac: String?
        var resolution: String?
        var firmwareVersion: String?

        enum CodingKeys: String, CodingKey {
            case frameTVSupport = "FrameTVSupport"
            case powerState = "PowerState"
            case tokenAuthSupport = "TokenAuthSupport"
            case os = "OS"
            case model, modelName, name, wifiMac, resolution, firmwareVersion
        }
    }

    var device: Device
    var name: String?
    var version: String?

    var isFrame: Bool { device.frameTVSupport == "true" }
    /// Older firmware omits PowerState; if it answers at all, it's on.
    var isOn: Bool { (device.powerState ?? "on") == "on" }
    var displayName: String { name ?? device.name ?? "Samsung TV" }
    var modelName: String { device.modelName ?? device.model ?? "" }
}

struct AppStatus: Decodable {
    var id: String
    var name: String
    var running: Bool
    var visible: Bool
}

/// The unauthenticated REST API on port 8001.
struct TVRestClient {
    let host: String

    private func url(_ path: String = "") -> URL {
        URL(string: "http://\(host):8001/api/v2/\(path)")!
    }

    func info(timeout: TimeInterval = 3) async throws -> TVInfo {
        let (data, response) = try await TVSession.http.data(for: URLRequest(url: url(), timeoutInterval: timeout))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TVError.badResponse("device info") }
        return try JSONDecoder().decode(TVInfo.self, from: data)
    }

    /// nil when the app isn't installed (404) or is a restricted system app (401). Throws when the TV gives no definite answer.
    func appStatus(_ appID: String, timeout: TimeInterval = 3) async throws -> AppStatus? {
        let request = URLRequest(url: url("applications/\(appID)"), timeoutInterval: timeout)
        let (data, response) = try await TVSession.http.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return try JSONDecoder().decode(AppStatus.self, from: data)
        case 401, 404: return nil
        default: throw TVError.badResponse("app status")
        }
    }

    func launch(_ appID: String) async throws {
        try await app(appID, method: "POST", action: "app launch")
    }

    /// Quits the app, not just hides it; the TV reports it as no longer running.
    func close(_ appID: String) async throws {
        try await app(appID, method: "DELETE", action: "app close")
    }

    private func app(_ appID: String, method: String, action: String) async throws {
        var request = URLRequest(url: url("applications/\(appID)"), timeoutInterval: 5)
        request.httpMethod = method
        let (_, response) = try await TVSession.http.data(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
            throw TVError.badResponse(action)
        }
    }
}

struct DiscoveredTV: Identifiable, Hashable {
    var id: String { host }
    let host: String
    let name: String
    let model: String
    let isFrame: Bool
}

enum Discovery {
    static func scan(timeout: TimeInterval = 3) async -> [DiscoveredTV] {
        let hosts = await Task.detached { ssdpSearch(timeout: timeout) }.value
        return await withTaskGroup(of: DiscoveredTV?.self) { group in
            for host in hosts {
                group.addTask {
                    guard let info = try? await TVRestClient(host: host).info(timeout: 2) else { return nil }
                    return DiscoveredTV(host: host, name: info.displayName, model: info.modelName, isFrame: info.isFrame)
                }
            }
            var found: [DiscoveredTV] = []
            for await tv in group { if let tv { found.append(tv) } }
            return found.sorted { ($0.isFrame ? 0 : 1, $0.name) < ($1.isFrame ? 0 : 1, $1.name) }
        }
    }

    /// SSDP M-SEARCH; returns the addresses of anything that identifies as Samsung.
    private static func ssdpSearch(timeout: TimeInterval) -> Set<String> {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var wait = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(1900).bigEndian
        destination.sin_addr.s_addr = inet_addr("239.255.255.250")

        let targets = [
            "urn:samsung.com:device:RemoteControlReceiver:1",
            "urn:dial-multiscreen-org:service:dial:1",
            "urn:schemas-upnp-org:device:MediaRenderer:1",
        ]
        for target in targets {
            let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target)\r\n\r\n"
            let bytes = Array(message.utf8)
            _ = withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var hosts = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0 else { continue }
            guard String(decoding: buffer[0..<count], as: UTF8.self).lowercased().contains("samsung") else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
            hosts.insert(String(cString: text))
        }
        return hosts
    }
}

enum WakeOnLAN {
    /// Works when "Power On with Mobile" is enabled on the TV.
    @discardableResult
    static func wake(mac: String, near host: String?) -> Bool {
        let bytes = mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return false }
        let packet = [UInt8](repeating: 0xFF, count: 6) + (0..<16).flatMap { _ in bytes }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var targets = ["255.255.255.255"]
        if let host, case let parts = host.split(separator: "."), parts.count == 4 {
            targets.append(parts.prefix(3).joined(separator: ".") + ".255")
            // Wi-Fi doesn't acknowledge or retry broadcasts; unicast is retried and works while the ARP entry lasts.
            targets.append(host)
        }
        var sent = false
        for target in targets {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(9).bigEndian
            address.sin_addr.s_addr = inet_addr(target)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            sent = sent || result == packet.count
        }
        return sent
    }
}
