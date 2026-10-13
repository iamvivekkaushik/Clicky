import Foundation

/// One of the TV's WebSocket channels on port 8002 (`samsung.remote.control`, `com.samsung.art-app`).
/// The first connection without a token makes the TV ask the user to Allow; the TV then issues a token.
@MainActor
final class WebSocketChannel {
    let host: String
    let channel: String
    let clientName: String
    private(set) var token: String?
    private(set) var isOpen = false
    /// Whether the TV-side service (the "host" client) has joined the channel.
    private(set) var hostPresent = false

    let waiters = WaiterSet()
    var onMessage: ((JSON) -> Void)?
    var onToken: ((String) -> Void)?
    var onClose: (() -> Void)?

    private var task: URLSessionWebSocketTask?
    private var connectPromise: Promise<Void>?
    private var pinger: Task<Void, Never>?

    init(host: String, channel: String, clientName: String, token: String?) {
        self.host = host
        self.channel = channel
        self.clientName = clientName
        self.token = token
    }

    func connect(timeout: TimeInterval) async throws {
        close()
        var address = "wss://\(host):8002/api/v2/channels/\(channel)?name=\(Data(clientName.utf8).base64EncodedString())"
        if let token { address += "&token=\(token)" }
        guard let url = URL(string: address) else { throw TVError.badResponse("channel URL") }

        let task = TVSession.sockets.webSocketTask(with: url)
        task.maximumMessageSize = 32 << 20
        self.task = task
        let promise = Promise<Void>()
        connectPromise = promise
        task.resume()
        listen(task)

        let timer = Task { [weak self] in
            try? await Task.sleep(seconds: timeout)
            guard !Task.isCancelled else { return }
            promise.resolve(.failure(TVError.timeout))
            if let self, self.task === task, !self.isOpen { self.close() }
        }
        defer { timer.cancel() }
        try await promise.value
    }

    func close() {
        guard let task else { return }
        task.cancel(with: .goingAway, reason: nil)
        closed()
    }

    func send(_ object: JSON) async throws {
        guard let task, isOpen else { throw TVError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: object)
        if Debug.enabled { Debug.log(">> \(channel): \(String(decoding: data.prefix(1500), as: UTF8.self))") }
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// Sends `object` and waits for the first incoming message accepted by `match`.
    func request(_ object: JSON, timeout: TimeInterval = 6, match: @escaping (JSON) -> Bool) async throws -> JSON {
        let reply = waiters.expect(timeout: timeout, match: match)
        try await send(object)
        return try await reply.value
    }

    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .failure:
                    self.closed()
                case .success(let message):
                    let data: Data?
                    switch message {
                    case .string(let text): data = text.data(using: .utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: data = nil
                    }
                    if Debug.enabled, let data { Debug.log("<< \(self.channel): \(String(decoding: data.prefix(1500), as: UTF8.self))") }
                    if let data, let object = try? JSONSerialization.jsonObject(with: data) as? JSON {
                        self.handle(object)
                    }
                    if self.task === task { self.listen(task) }
                }
            }
        }
    }

    private func handle(_ message: JSON) {
        switch message["event"] as? String {
        case "ms.channel.connect":
            if let data = message["data"] as? JSON, let token = data.string("token"), !token.isEmpty, token != self.token {
                self.token = token
                onToken?(token)
            }
            let clients = (message["data"] as? JSON)?["clients"] as? [JSON] ?? []
            hostPresent = clients.contains { $0["isHost"] as? Bool == true }
            isOpen = true
            startPinging()
            connectPromise?.resolve(.success(()))
        case "ms.channel.unauthorized":
            connectPromise?.resolve(.failure(TVError.unauthorized))
            close()
            return
        case "ms.channel.timeOut":
            connectPromise?.resolve(.failure(TVError.timeout))
            close()
            return
        case "ms.channel.clientConnect", "ms.channel.clientDisconnect":
            if (message["data"] as? JSON)?["isHost"] as? Bool == true {
                hostPresent = message["event"] as? String == "ms.channel.clientConnect"
            }
        default:
            break
        }
        waiters.deliver(message)
        onMessage?(message)
    }

    private func closed() {
        let wasOpen = isOpen
        task = nil
        isOpen = false
        pinger?.cancel()
        connectPromise?.resolve(.failure(TVError.closed))
        waiters.failAll(TVError.closed)
        if wasOpen { onClose?() }
    }

    private func startPinging() {
        pinger?.cancel()
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(seconds: 20)
                guard let task = self?.task else { return }
                task.sendPing { _ in }
            }
        }
    }
}

enum RemoteKey: String {
    case power = "KEY_POWER"
    case up = "KEY_UP", down = "KEY_DOWN", left = "KEY_LEFT", right = "KEY_RIGHT", enter = "KEY_ENTER"
    case back = "KEY_RETURN", home = "KEY_HOME", menu = "KEY_MENU", exit = "KEY_EXIT"
    case volumeUp = "KEY_VOLUP", volumeDown = "KEY_VOLDOWN", mute = "KEY_MUTE"
    case channelUp = "KEY_CHUP", channelDown = "KEY_CHDOWN"
    case play = "KEY_PLAY", pause = "KEY_PAUSE", stop = "KEY_STOP", rewind = "KEY_REWIND", fastForward = "KEY_FF"
    case source = "KEY_SOURCE", info = "KEY_INFO", guide = "KEY_GUIDE"
}

struct TVApp: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let type: Int?
    let iconPath: String?

    init(id: String, name: String, type: Int? = nil, iconPath: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.iconPath = iconPath
    }

    init?(_ json: JSON) {
        guard let id = json.string("appId"), let name = json.string("name") else { return nil }
        self.id = id
        self.name = name
        type = json.int("app_type")
        iconPath = json.string("icon")
    }
}

/// Remote-control commands over the `samsung.remote.control` channel.
@MainActor
final class RemoteClient {
    let channel: WebSocketChannel
    var onKeyboardChange: ((Bool) -> Void)?

    init(channel: WebSocketChannel) {
        self.channel = channel
        channel.onMessage = { [weak self] message in
            switch message["event"] as? String {
            case "ms.remote.imeStart": self?.onKeyboardChange?(true)
            case "ms.remote.imeEnd", "ms.remote.imeDone": self?.onKeyboardChange?(false)
            default: break
            }
        }
    }

    func key(_ code: String, _ command: String = "Click") async throws {
        try await channel.send([
            "method": "ms.remote.control",
            "params": ["Cmd": command, "DataOfCmd": code, "Option": "false", "TypeOfRemote": "SendRemoteKey"],
        ])
    }

    func hold(_ code: String, seconds: Double) async throws {
        try await key(code, "Press")
        try await Task.sleep(seconds: seconds)
        try await key(code, "Release")
    }

    func launch(_ appID: String, type: Int?) async throws {
        try await channel.send([
            "method": "ms.channel.emit",
            "params": [
                "event": "ed.apps.launch", "to": "host",
                "data": ["appId": appID, "action_type": type == 4 ? "NATIVE_LAUNCH" : "DEEP_LINK"],
            ] as JSON,
        ])
    }

    func installedApps() async throws -> [TVApp] {
        let reply = try await channel.request(
            ["method": "ms.channel.emit", "params": ["event": "ed.installedApp.get", "to": "host"]],
            timeout: 5
        ) { $0["event"] as? String == "ed.installedApp.get" }
        let list = (reply["data"] as? JSON)?["data"] as? [JSON] ?? []
        return list.compactMap(TVApp.init)
    }

    /// App icons live on the TV's filesystem; the TV returns them base64-encoded. Call serially.
    func icon(path: String) async throws -> Data? {
        let reply = try await channel.request(
            ["method": "ms.channel.emit", "params": ["event": "ed.apps.icon", "to": "host", "data": ["iconPath": path]] as JSON],
            timeout: 4
        ) { $0["event"] as? String == "ed.apps.icon" }
        guard let encoded = (reply["data"] as? JSON)?.string("imageBase64") else { return nil }
        return Data(base64Encoded: encoded)
    }

    /// Fills the text field currently open on the TV.
    func text(_ text: String) async throws {
        try await channel.send([
            "method": "ms.remote.control",
            "params": ["Cmd": Data(text.utf8).base64EncodedString(), "DataOfCmd": "base64", "TypeOfRemote": "SendInputString"],
        ])
        try await channel.send(["method": "ms.remote.control", "params": ["TypeOfRemote": "SendInputEnd"]])
    }

    func moveCursor(dx: Int, dy: Int) async throws {
        try await channel.send([
            "method": "ms.remote.control",
            "params": [
                "Cmd": "Move", "TypeOfRemote": "ProcessMouseDevice",
                "Position": ["x": dx, "y": dy, "Time": String(Int(Date().timeIntervalSince1970 * 1000))],
            ] as JSON,
        ])
    }

    func click() async throws {
        try await channel.send(["method": "ms.remote.control", "params": ["Cmd": "LeftClick", "TypeOfRemote": "ProcessMouseDevice"]])
    }
}
