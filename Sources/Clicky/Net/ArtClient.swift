import Foundation
import Network

struct ArtItem: Identifiable, Hashable {
    let id: String
    let categoryID: String?
    var matteID: String?
    let width: Int?
    let height: Int?
    let date: String?

    init?(_ json: JSON) {
        guard let id = json.string("content_id"), !id.isEmpty else { return nil }
        self.id = id
        categoryID = json.string("category_id")
        matteID = json.string("matte_id")
        width = json.int("width")
        height = json.int("height")
        date = json.string("image_date")
    }

    var isPortrait: Bool { (height ?? 0) > (width ?? 0) }
    /// Photos uploaded by the user. The TV files them under several MY-C categories.
    var isUserPhoto: Bool { id.hasPrefix("MY_F") }
}

enum ArtCategory: String, CaseIterable, Identifiable {
    case myPhotos = "MY-C0002"
    case favorites = "MY-C0004"
    /// Recently shown art, both photos and Art Store pieces.
    case recent = "MY-C0008"

    var id: String { rawValue }

    func contains(_ item: ArtItem) -> Bool {
        switch self {
        case .myPhotos: return item.isUserPhoto
        case .favorites, .recent: return item.categoryID == rawValue
        }
    }

    var title: String {
        switch self {
        case .myPhotos: return "My Photos"
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        }
    }
}

struct SlideshowSetting: Equatable {
    /// "off" or a duration in minutes.
    var interval: String
    var shuffle: Bool
    var categoryID: String

    init(interval: String, shuffle: Bool, categoryID: String) {
        self.interval = interval
        self.shuffle = shuffle
        self.categoryID = categoryID
    }

    init(_ json: JSON) {
        interval = json.string("value") ?? "off"
        shuffle = json.string("type") == "shuffleslideshow"
        // Empty while the slideshow is off.
        categoryID = json.string("category_id").flatMap { $0.isEmpty ? nil : $0 } ?? ArtCategory.myPhotos.rawValue
    }

    static let intervals: [(value: String, title: String)] = [
        ("off", "Off"), ("3", "3 min"), ("15", "15 min"), ("60", "1 hour"), ("720", "12 hours"), ("1440", "1 day"),
    ]
}

struct ArtSetting: Identifiable, Equatable {
    var id: String { item }
    let item: String
    var value: String
    let min: Int?
    let max: Int?
    let options: [String]

    init?(_ json: JSON) {
        guard let item = json.string("item") else { return nil }
        self.init(item: item, json: json)
    }

    init(item: String, json: JSON) {
        self.item = item
        value = json.string("value") ?? ""
        min = json.int("min")
        max = json.int("max")
        options = (json.nested("valid_values") as? [Any])?.compactMap { "\($0)" } ?? []
    }
}

/// The Frame's Art Mode API on the `com.samsung.art-app` channel. Requests travel as
/// `art_app_request` events; replies come back as `d2d_service_message` events whose
/// `data` is itself a JSON document. Images move over a separate TCP socket the TV opens.
@MainActor
final class ArtClient {
    let channel: WebSocketChannel
    var onPush: ((String, JSON) -> Void)?

    private let replies = WaiterSet()
    private var legacySlideshow = false
    private var lastTransfer: Task<Void, Never>?

    init(channel: WebSocketChannel) {
        self.channel = channel
        channel.onMessage = { [weak self] in self?.handle($0) }
    }

    private func handle(_ message: JSON) {
        guard message["event"] as? String == "d2d_service_message", let inner = message.nested("data") as? JSON else { return }
        if !replies.deliver(inner), let event = inner["event"] as? String {
            onPush?(event, inner)
        }
    }

    private static func requestID(_ inner: JSON) -> String? {
        if let id = inner.string("request_id") ?? inner.string("id") { return id }
        if let original = inner.nested("request_data") as? JSON { return original.string("request_id") ?? original.string("id") }
        return nil
    }

    nonisolated static func newID() -> String { UUID().uuidString.lowercased() }

    /// Sends an art request and waits for its reply. Current firmware tags replies with our `request_id`
    /// and names them after the request; `until` can skip early acknowledgements. Older firmware omits
    /// ids, so `legacy` names the reply event it sends instead.
    @discardableResult
    func request(_ name: String, _ params: JSON = [:], until accept: ((JSON) -> Bool)? = nil, legacy: String? = nil,
                 id: String = ArtClient.newID(), timeout: TimeInterval = 8) async throws -> JSON {
        var payload = params
        payload["request"] = name
        payload["id"] = id
        payload["request_id"] = id
        let body = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)

        let reply = replies.expect(timeout: timeout) { inner in
            let kind = inner["event"] as? String
            if let replyID = Self.requestID(inner) {
                return replyID == id && (kind == "error" || accept?(inner) ?? true)
            }
            return kind == (legacy ?? name)
        }
        try await channel.send([
            "method": "ms.channel.emit",
            "params": ["event": "art_app_request", "to": "host", "data": body],
        ])
        let inner = try await reply.value
        if inner["event"] as? String == "error" {
            throw TVError.art(inner.string("error_code").map { "\(name) failed (code \($0))" } ?? "\(name) failed")
        }
        return inner
    }

    /// Setters that many firmwares never acknowledge: only an explicit error is reported.
    func command(_ name: String, _ params: JSON = [:]) async throws {
        do {
            try await request(name, params, timeout: 3)
        } catch TVError.timeout {
        }
    }

    func apiVersion() async throws -> String? {
        let reply: JSON
        do {
            reply = try await request("api_version", timeout: 3)
        } catch {
            reply = try await request("get_api_version", legacy: "api_version", timeout: 3)
        }
        return reply.string("version") ?? reply.string("value")
    }

    func isArtModeOn() async throws -> Bool {
        try await request("get_artmode_status", legacy: "artmode_status").string("value") == "on"
    }

    func setArtMode(_ on: Bool) async throws {
        try await command("set_artmode_status", ["value": on ? "on" : "off"])
    }

    func currentArtwork() async throws -> ArtItem? {
        ArtItem(try await request("get_current_artwork", legacy: "current_artwork"))
    }

    /// Everything stored on the TV; group with `ArtCategory.contains`.
    func contentList() async throws -> [ArtItem] {
        let reply = try await request("get_content_list", ["category": NSNull()], legacy: "content_list", timeout: 15)
        return (reply.nested("content_list") as? [JSON] ?? []).compactMap(ArtItem.init)
    }

    func select(_ contentID: String, categoryID: String?) async throws {
        try await command("select_image", ["content_id": contentID, "category_id": categoryID ?? NSNull(), "show": true])
    }

    func delete(_ contentIDs: [String]) async throws {
        try await request("delete_image_list", ["content_id_list": contentIDs.map { ["content_id": $0] }],
                          legacy: "image_deleted", timeout: 10)
    }

    func matteOptions() async throws -> (types: [String], colors: [String]) {
        let reply = try await request("get_matte_list", legacy: "matte_list")
        let types = (reply.nested("matte_type_list") as? [JSON] ?? []).compactMap { $0.string("matte_type") }
        let colors = (reply.nested("matte_color_list") as? [JSON] ?? []).compactMap { $0.string("color") }
        return (types, colors)
    }

    func changeMatte(_ contentID: String, matte: String) async throws {
        try await command("change_matte", ["content_id": contentID, "matte_id": matte])
    }

    func slideshow() async throws -> SlideshowSetting {
        do {
            return SlideshowSetting(try await request("get_slideshow_status"))
        } catch TVError.art {
            legacySlideshow = true
            return SlideshowSetting(try await request("get_auto_rotation_status"))
        }
    }

    func setSlideshow(_ setting: SlideshowSetting) async throws {
        try await command(legacySlideshow ? "set_auto_rotation_status" : "set_slideshow_status", [
            "value": setting.interval,
            "category_id": setting.categoryID,
            "type": setting.shuffle ? "shuffleslideshow" : "slideshow",
        ])
    }

    func settings() async throws -> [ArtSetting] {
        do {
            let reply = try await request("get_artmode_settings")
            return (reply.nested("data") as? [JSON] ?? []).compactMap(ArtSetting.init)
        } catch TVError.art {
            var settings: [ArtSetting] = []
            for item in ["brightness", "color_temperature"] {
                if let reply = try? await request("get_\(item)") { settings.append(ArtSetting(item: item, json: reply)) }
            }
            return settings
        }
    }

    func set(_ item: String, value: Any) async throws {
        try await command("set_\(item)", ["value": value])
    }

    /// The TV serves one image socket at a time; overlapping transfers fail with error -1.
    private func oneAtATime<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = lastTransfer
        let current = Task { () async throws -> T in
            await previous?.value
            return try await operation()
        }
        lastTransfer = Task { _ = try? await current.value }
        return try await current.value
    }

    func thumbnails(_ contentIDs: [String]) async throws -> [String: Data] {
        try await oneAtATime { try await self.fetchThumbnails(contentIDs) }
    }

    private func fetchThumbnails(_ contentIDs: [String]) async throws -> [String: Data] {
        guard !contentIDs.isEmpty else { return [:] }
        do {
            let id = Self.newID()
            let ready = try await request("get_thumbnail_list", [
                "content_id_list": contentIDs.map { ["content_id": $0] },
                "conn_info": Self.connectionRequest(id),
            ], until: Self.hasConnection, legacy: "ready_to_use", id: id, timeout: 12)
            let files = try await ArtTransfer.download(ConnInfo(ready), expected: contentIDs.count)
            return Self.match(files, to: contentIDs)
        } catch TVError.art {
            // Pre-2022 firmware: one thumbnail per request.
            var result: [String: Data] = [:]
            for contentID in contentIDs {
                let id = Self.newID()
                let ready = try await request("get_thumbnail", ["content_id": contentID, "conn_info": Self.connectionRequest(id)],
                                              until: Self.hasConnection, legacy: "ready_to_use", id: id, timeout: 10)
                result[contentID] = try await ArtTransfer.download(ConnInfo(ready), expected: 1).first?.data
            }
            return result
        }
    }

    /// Uploads a JPEG or PNG to My Photos and returns its new content id.
    func upload(_ data: Data, fileType: String, matte: String) async throws -> String {
        try await oneAtATime { try await self.send(data, fileType: fileType, matte: matte) }
    }

    private func send(_ data: Data, fileType: String, matte: String) async throws -> String {
        let id = Self.newID()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let ready = try await request("send_image", [
            "file_type": fileType,
            "conn_info": Self.connectionRequest(id),
            "image_date": formatter.string(from: Date()),
            "matte_id": matte,
            "portrait_matte_id": matte,
            "file_size": data.count,
        ], until: Self.hasConnection, legacy: "ready_to_use", id: id, timeout: 15)

        let added = replies.expect(timeout: 120) { inner in
            let kind = inner["event"] as? String
            return kind == "image_added" || (kind == "error" && Self.requestID(inner) == id)
        }
        let connection = try await ArtTransfer.upload(data, fileType: fileType, to: ConnInfo(ready))
        defer { connection.cancel() }
        let reply = try await added.value
        guard reply["event"] as? String == "image_added", let contentID = reply.string("content_id") else {
            throw TVError.art("upload rejected (code \(reply.string("error_code") ?? "?"))")
        }
        return contentID
    }

    /// Transfer replies tell us where to open the image socket.
    private static func hasConnection(_ reply: JSON) -> Bool { reply["conn_info"] != nil }

    private static func connectionRequest(_ id: String) -> JSON {
        ["d2d_mode": "socket", "connection_id": Int.random(in: 0..<Int(Int32.max)), "id": id]
    }

    /// The transfer header names each file by content id; fall back to request order.
    private static func match(_ files: [(id: String, data: Data)], to contentIDs: [String]) -> [String: Data] {
        var result: [String: Data] = [:]
        for (index, file) in files.enumerated() {
            let name = file.id.components(separatedBy: ".").first ?? file.id
            if contentIDs.contains(name) {
                result[name] = file.data
            } else if index < contentIDs.count {
                result[contentIDs[index]] = file.data
            }
        }
        return result
    }
}

struct ConnInfo {
    let host: String
    let port: UInt16
    let key: String?
    let secured: Bool

    init(_ reply: JSON) throws {
        guard let info = reply.nested("conn_info") as? JSON, let host = info.string("ip"),
              let port = info.int("port").flatMap(UInt16.init(exactly:)) else {
            throw TVError.badResponse("conn_info")
        }
        self.host = host
        self.port = port
        key = info.string("key")
        secured = (info["secured"] as? Bool) ?? (info.string("secured") == "true")
    }
}

/// Image bytes move over a one-off TCP (sometimes TLS) socket: a 4-byte big-endian header
/// length, a JSON header, then the file.
enum ArtTransfer {
    static func open(_ info: ConnInfo) async throws -> NWConnection {
        let parameters: NWParameters
        if info.secured {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        guard LocalNetwork.isPrivateIPv4(info.host), let port = NWEndpoint.Port(rawValue: info.port) else {
            throw TVError.badResponse("transfer address \(info.host)")
        }
        let connection = NWConnection(host: NWEndpoint.Host(info.host), port: port, using: parameters)
        try await connection.ready(timeout: 8)
        return connection
    }

    static func download(_ info: ConnInfo, expected: Int) async throws -> [(id: String, data: Data)] {
        let connection = try await open(info)
        defer { connection.cancel() }
        var files: [(id: String, data: Data)] = []
        var total = expected
        while files.count < total {
            let length = try await connection.read(exactly: 4).reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length < 1 << 20,
                  let header = try JSONSerialization.jsonObject(with: try await connection.read(exactly: length)) as? JSON,
                  let size = header.int("fileLength") else {
                throw TVError.badResponse("thumbnail header")
            }
            total = header.int("total") ?? total
            files.append((header.string("fileID") ?? "", try await connection.read(exactly: size)))
            if let number = header.int("num"), number + 1 >= total { break }
        }
        return files
    }

    /// Returns the open connection; close it once the TV confirms the upload.
    static func upload(_ data: Data, fileType: String, to info: ConnInfo) async throws -> NWConnection {
        let header: JSON = [
            "num": 0, "total": 1, "fileLength": data.count, "fileName": "dummy",
            "fileType": fileType, "secKey": info.key ?? "", "version": "0.0.1",
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header)
        var packet = Data()
        withUnsafeBytes(of: UInt32(headerData.count).bigEndian) { packet.append(contentsOf: $0) }
        packet.append(headerData)
        packet.append(data)

        let connection = try await open(info)
        do {
            try await connection.write(packet)
        } catch {
            connection.cancel()
            throw error
        }
        return connection
    }
}
