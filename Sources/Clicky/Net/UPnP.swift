import Foundation

/// The TV's DLNA media renderer on port 9197: volume/mute (RenderingControl) and file playback (AVTransport).
struct UPnPClient {
    enum Service {
        case rendering, transport

        var urn: String {
            switch self {
            case .rendering: return "urn:schemas-upnp-org:service:RenderingControl:1"
            case .transport: return "urn:schemas-upnp-org:service:AVTransport:1"
            }
        }

        var path: String {
            switch self {
            case .rendering: return "/upnp/control/RenderingControl1"
            case .transport: return "/upnp/control/AVTransport1"
            }
        }
    }

    let host: String

    func volume() async throws -> Int {
        let reply = try await call(.rendering, "GetVolume", [("InstanceID", "0"), ("Channel", "Master")])
        guard let value = Self.value("CurrentVolume", in: reply).flatMap(Int.init) else { throw TVError.badResponse("GetVolume") }
        return value
    }

    func setVolume(_ volume: Int) async throws {
        try await call(.rendering, "SetVolume", [("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", String(volume))])
    }

    func isMuted() async throws -> Bool {
        let reply = try await call(.rendering, "GetMute", [("InstanceID", "0"), ("Channel", "Master")])
        return Self.value("CurrentMute", in: reply) == "1"
    }

    func setMuted(_ muted: Bool) async throws {
        try await call(.rendering, "SetMute", [("InstanceID", "0"), ("Channel", "Master"), ("DesiredMute", muted ? "1" : "0")])
    }

    func load(_ url: URL, title: String, mime: String) async throws {
        let upnpClass: String
        if mime.hasPrefix("video") { upnpClass = "object.item.videoItem" }
        else if mime.hasPrefix("audio") { upnpClass = "object.item.audioItem.musicTrack" }
        else { upnpClass = "object.item.imageItem.photo" }
        let metadata = """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="0" parentID="-1" restricted="1">\
        <dc:title>\(Self.escape(title))</dc:title><upnp:class>\(upnpClass)</upnp:class>\
        <res protocolInfo="http-get:*:\(mime):\(DLNA.features)">\(Self.escape(url.absoluteString))</res></item></DIDL-Lite>
        """
        try await call(.transport, "SetAVTransportURI", [
            ("InstanceID", "0"), ("CurrentURI", url.absoluteString), ("CurrentURIMetaData", metadata),
        ])
    }

    func play() async throws { try await call(.transport, "Play", [("InstanceID", "0"), ("Speed", "1")]) }
    func pause() async throws { try await call(.transport, "Pause", [("InstanceID", "0")]) }
    func stop() async throws { try await call(.transport, "Stop", [("InstanceID", "0")]) }

    /// PLAYING, PAUSED_PLAYBACK, STOPPED, TRANSITIONING or NO_MEDIA_PRESENT.
    func transportState() async throws -> String {
        let reply = try await call(.transport, "GetTransportInfo", [("InstanceID", "0")])
        return Self.value("CurrentTransportState", in: reply) ?? "STOPPED"
    }

    func position() async throws -> (elapsed: String, duration: String) {
        let reply = try await call(.transport, "GetPositionInfo", [("InstanceID", "0")])
        return (Self.value("RelTime", in: reply) ?? "0:00:00", Self.value("TrackDuration", in: reply) ?? "0:00:00")
    }

    @discardableResult
    private func call(_ service: Service, _ action: String, _ arguments: [(String, String)]) async throws -> String {
        let args = arguments.map { "<\($0)>\(Self.escape($1))</\($0)>" }.joined()
        let body = """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(service.urn)">\
        \(args)</u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: URL(string: "http://\(host):9197\(service.path)")!, timeoutInterval: 4)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await TVSession.http.data(for: request)
        let reply = String(decoding: data, as: UTF8.self)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TVError.badResponse(Self.value("errorDescription", in: reply) ?? action)
        }
        return reply
    }

    static func value(_ tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"), let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

enum DLNA {
    static let features = "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"

    static func mime(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        default: return nil
        }
    }
}
