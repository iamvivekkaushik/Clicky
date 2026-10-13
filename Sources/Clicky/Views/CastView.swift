import AppKit
import SwiftUI

struct CastView: View {
    @ObservedObject var tv: TVController
    @ObservedObject var cast: CastSession
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(spacing: 10) {
            SectionLabel(text: "Cast")
            Card {
                HStack(spacing: 10) {
                    SymbolTile(symbol: "airplayvideo", color: accent, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Your Mac, on the big screen").font(.system(size: 13, weight: .semibold))
                        Text("AirPlay mirroring").font(.system(size: 10.5)).foregroundColor(Theme.secondary)
                    }
                }
                Text("In the Mac's Control Center, open Screen Mirroring and choose “\(tv.info?.displayName ?? "The Frame")”. You can also use the TV as a second display in Displays settings.")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: openDisplays) {
                    Label("Open Displays settings", systemImage: "arrow.up.right")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(accent)
                }
                .buttonStyle(.plain)
            }

            Card {
                CardHeader(symbol: "play.rectangle.fill", title: "Send a file")
                Text("Choose a video, a song or a photo.")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.secondary)
                if let file = cast.file {
                    HStack(spacing: 10) {
                        SymbolTile(symbol: symbol(for: file), color: accent, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text(detail(for: file)).font(.system(size: 10)).foregroundColor(Theme.secondary)
                        }
                        Spacer()
                    }
                }
                HStack(spacing: 8) {
                    WideButton(symbol: "folder", title: "Choose file", action: choose)
                    WideButton(symbol: "play.fill", title: "Play on TV", prominent: true) {
                        guard let host = tv.prefs.host else { return }
                        Task { await cast.play(on: host) }
                    }
                    .disabled(cast.file == nil || cast.state == .starting || tv.prefs.host == nil)
                }
                playback
            }
            Caption("The file opens on the TV when you choose Play. Compatibility depends on format and codec; MP4 (H.264), MP3 and JPEG are good first tests. Clicky keeps this Mac awake while it plays.")
                .padding(.horizontal, 2)
        }
    }

    @ViewBuilder private var playback: some View {
        switch cast.state {
        case .idle:
            EmptyView()
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting on the TV…").font(.system(size: 11)).foregroundColor(Theme.secondary)
            }
        case .playing, .paused:
            HStack(spacing: 8) {
                IconButton(symbol: cast.state == .playing ? "pause.fill" : "play.fill", size: 30, help: "Play/Pause") {
                    Task { await cast.togglePause() }
                }
                IconButton(symbol: "stop.fill", size: 30, help: "Stop") {
                    Task { await cast.stop() }
                }
                Text(cast.state == .playing ? "Playing on the TV" : "Paused")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                if !cast.duration.isEmpty {
                    Text("\(cast.elapsed) / \(cast.duration)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(Theme.secondary)
                }
            }
        case .finished:
            Label("Finished playing", systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundColor(Theme.online)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .audio, .image]
        panel.message = "Choose a video, song or photo to play on the TV"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { cast.file = url }
    }

    private func openDisplays() {
        let urls = ["x-apple.systempreferences:com.apple.Displays-Settings.extension", "x-apple.systempreferences:com.apple.preference.displays"]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    private func symbol(for file: URL) -> String {
        let mime = DLNA.mime(for: file) ?? ""
        if mime.hasPrefix("video") { return "film" }
        if mime.hasPrefix("audio") { return "music.note" }
        return "photo"
    }

    private func detail(for file: URL) -> String {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return DLNA.mime(for: file) == nil ? "\(formatted) · format may not play" : formatted
    }
}
