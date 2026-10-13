import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Plays a local file on the TV: this Mac serves it over HTTP and the TV's DLNA renderer pulls it.
@MainActor
final class CastSession: ObservableObject {
    enum State: Equatable {
        case idle, starting, playing, paused, finished
        case failed(String)
    }

    @Published var file: URL?
    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed = ""
    @Published private(set) var duration = ""

    private let server = MediaServer()
    private var host: String?
    private var monitor: Task<Void, Never>?
    private var awake: NSObjectProtocol?

    var isActive: Bool { state == .starting || state == .playing || state == .paused }

    func play(on host: String) async {
        guard let file else { return }
        guard let mime = DLNA.mime(for: file) else {
            state = .failed("This file type can't be sent. Try MP4 (H.264), MP3 or JPEG.")
            return
        }
        guard let local = LocalNetwork.localAddress(toward: host) else {
            state = .failed("This Mac doesn't seem to be on the TV's network.")
            return
        }
        self.host = host
        state = .starting
        do {
            let (port, path) = try await server.serve(file, mime: mime)
            guard let url = URL(string: "http://\(local):\(port)\(path)") else { throw TVError.badResponse("media URL") }
            let renderer = UPnPClient(host: host)
            try? await renderer.stop()
            try await renderer.load(url, title: file.deletingPathExtension().lastPathComponent, mime: mime)
            try await renderer.play()
            state = .playing
            keepAwake(true)
            watch()
        } catch {
            server.stop()
            state = .failed(error.localizedDescription)
        }
    }

    func togglePause() async {
        guard let host else { return }
        let renderer = UPnPClient(host: host)
        if state == .playing {
            try? await renderer.pause()
            state = .paused
        } else if state == .paused {
            try? await renderer.play()
            state = .playing
        }
    }

    func stop() async {
        if let host { try? await UPnPClient(host: host).stop() }
        end(.idle)
    }

    private func watch() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            var stoppedTicks = 0
            var started = false
            let began = Date()
            while !Task.isCancelled {
                try? await Task.sleep(seconds: 2)
                guard let self, let host = self.host, self.isActive else { return }
                let renderer = UPnPClient(host: host)
                if let position = try? await renderer.position() {
                    self.elapsed = Self.trim(position.elapsed)
                    self.duration = Self.trim(position.duration)
                }
                switch try? await renderer.transportState() {
                case "PLAYING": self.state = .playing; stoppedTicks = 0; started = true
                case "PAUSED_PLAYBACK": self.state = .paused; stoppedTicks = 0; started = true
                case "STOPPED", "NO_MEDIA_PRESENT":
                    // The TV reports STOPPED while it buffers; only treat it as the end once playback began.
                    stoppedTicks += 1
                    if stoppedTicks >= 2, started || Date().timeIntervalSince(began) > 30 { self.end(.finished) }
                default: break
                }
            }
        }
    }

    private func end(_ final: State) {
        monitor?.cancel()
        server.stop()
        keepAwake(false)
        state = final
        elapsed = ""
        duration = ""
    }

    private func keepAwake(_ on: Bool) {
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Casting to TV")
        } else if !on, let awake {
            ProcessInfo.processInfo.endActivity(awake)
            self.awake = nil
        }
    }

    private static func trim(_ time: String) -> String {
        time.hasPrefix("0:") ? String(time.dropFirst(2)) : time.hasPrefix("00:") ? String(time.dropFirst(3)) : time
    }
}

enum ImagePrep {
    /// Re-encodes any image (HEIC, oversized, rotated by EXIF) to a JPEG the Frame accepts.
    static func jpeg(from url: URL, maxPixels: Int = 3840, quality: Double = 0.92) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw TVError.badResponse("unreadable image") }
        return try jpeg(from: source, maxPixels: maxPixels, quality: quality)
    }

    static func jpeg(from data: Data, maxPixels: Int, quality: Double = 0.85) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw TVError.badResponse("unreadable image") }
        return try jpeg(from: source, maxPixels: maxPixels, quality: quality)
    }

    private static func jpeg(from source: CGImageSource, maxPixels: Int, quality: Double) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw TVError.badResponse("unreadable image")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw TVError.badResponse("JPEG encoder")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TVError.badResponse("JPEG encoder") }
        return output as Data
    }
}

/// Disk cache for art thumbnails and app icons, per TV.
struct ImageCache {
    static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.vivekkaushik.clicky/Images", isDirectory: true)

    let folder: URL

    init(tv: String, kind: String) {
        folder = Self.root.appendingPathComponent("\(tv)/\(kind)", isDirectory: true)
    }

    func image(_ key: String) -> NSImage? {
        NSImage(contentsOf: file(key))
    }

    func store(_ data: Data, for key: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file(key), options: .atomic)
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: file(key))
    }

    private func file(_ key: String) -> URL {
        folder.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".img")
    }
}
