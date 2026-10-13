import Foundation
import Network

/// A tiny HTTP server that hands one file to the TV, with Range support so it can seek.
final class MediaServer: @unchecked Sendable {
    private struct Item {
        let url: URL
        let mime: String
        let size: Int64
        let path: String
    }

    private let queue = DispatchQueue(label: "com.vivekkaushik.clicky.media")
    private var listener: NWListener?
    private var item: Item?

    /// Starts serving `file` and returns the port and path the TV should request.
    func serve(_ file: URL, mime: String) async throws -> (port: UInt16, path: String) {
        stop()
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        let path = "/media/\(UUID().uuidString.prefix(8).lowercased()).\(file.pathExtension.lowercased())"
        let item = Item(url: file, mime: mime, size: size, path: path)
        queue.sync { self.item = item }

        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        let once = OnceFlag()
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.take() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return (port, path)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.sync { item = nil }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHeader(connection, buffer: Data())
    }

    private func readHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, header: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if complete || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.readHeader(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ").map(String.init) ?? []
        guard request.count >= 2, let item, request[1].hasPrefix(item.path), ["GET", "HEAD"].contains(request[0]) else {
            return finish(connection, status: "404 Not Found")
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        var start: Int64 = 0
        var end = item.size - 1
        var partial = false
        if let range = fields["range"], range.hasPrefix("bytes=") {
            let bounds = range.dropFirst(6).split(separator: ",").first?.split(separator: "-", omittingEmptySubsequences: false) ?? []
            if bounds.count == 2 {
                if bounds[0].isEmpty, let suffix = Int64(bounds[1]) {
                    start = max(0, item.size - suffix)
                } else {
                    start = Int64(bounds[0]) ?? 0
                    if let last = Int64(bounds[1]) { end = min(last, item.size - 1) }
                }
                partial = true
            }
        }
        guard start <= end, start < item.size else {
            return finish(connection, status: "416 Range Not Satisfiable", extra: "Content-Range: bytes */\(item.size)\r\n")
        }

        let length = end - start + 1
        var head = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n"
        head += "Content-Type: \(item.mime)\r\nContent-Length: \(length)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(end)/\(item.size)\r\n" }
        head += "transferMode.dlna.org: \(item.mime.hasPrefix("image") ? "Interactive" : "Streaming")\r\n"
        head += "contentFeatures.dlna.org: \(DLNA.features)\r\nServer: Clicky UPnP/1.0 DLNADOC/1.50\r\n\r\n"

        let isGet = request[0] == "GET"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, isGet, let self, let handle = try? FileHandle(forReadingFrom: item.url) else {
                return connection.cancel()
            }
            try? handle.seek(toOffset: UInt64(start))
            self.pump(connection, handle, remaining: length)
        })
    }

    private func pump(_ connection: NWConnection, _ handle: FileHandle, remaining: Int64) {
        let chunk = remaining > 0 ? handle.readData(ofLength: Int(min(remaining, 512 * 1024))) : Data()
        guard !chunk.isEmpty else {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else {
                try? handle.close()
                return connection.cancel()
            }
            self.pump(connection, handle, remaining: remaining - Int64(chunk.count))
        })
    }

    private func finish(_ connection: NWConnection, status: String, extra: String = "") {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\(extra)\r\n"
        connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
