import AppKit
import SwiftUI

struct RemoteView: View {
    @ObservedObject var tv: TVController
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 10) {
            SectionLabel(text: "Remote")
            Card {
                HStack {
                    Text(tv.title(for: tv.screen)).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    HStack(spacing: 5) {
                        StatusDot(color: tv.isConnected ? Theme.online : Theme.tertiary, size: 5)
                        Text(tv.isConnected ? "Remote ready" : "Not connected")
                            .font(.system(size: 10.5))
                            .foregroundColor(Theme.secondary)
                    }
                }
                HStack(spacing: 0) {
                    VStack(spacing: 14) {
                        IconButton(symbol: "house", size: 36, help: "Home") { tv.press(.home) }
                        IconButton(symbol: "arrow.uturn.backward", size: 36, help: "Back") { tv.press(.back) }
                    }
                    Spacer()
                    DPad(tv: tv)
                    Spacer()
                    VStack(spacing: 14) {
                        IconButton(symbol: "gearshape", size: 36, help: "TV settings") { tv.press(.menu) }
                        IconButton(symbol: "xmark", size: 36, help: "Exit") { tv.press(.exit) }
                    }
                }
                .padding(.horizontal, 6)
                HStack(spacing: 6) {
                    MediaKey(symbol: "backward.fill", help: "Rewind") { tv.press(.rewind) }
                    MediaKey(symbol: "play.fill", help: "Play") { tv.press(.play) }
                    MediaKey(symbol: "pause.fill", help: "Pause") { tv.press(.pause) }
                    MediaKey(symbol: "stop.fill", help: "Stop") { tv.press(.stop) }
                    MediaKey(symbol: "forward.fill", help: "Fast forward") { tv.press(.fastForward) }
                }
                Caption("Arrow keys, Return and Delete work while this tab is open.")
            }
            CursorPad(tv: tv)
            VolumeCard(tv: tv)
            HStack(spacing: 8) {
                WideButton(symbol: "chevron.down", title: "Channel −") { tv.press(.channelDown) }
                WideButton(symbol: "chevron.up", title: "Channel +") { tv.press(.channelUp) }
            }
            KeyboardCard(tv: tv)
            HStack(spacing: 8) {
                WideButton(symbol: "rectangle.on.rectangle", title: "Source") { tv.press(.source) }
                WideButton(symbol: "info.circle", title: "Info") { tv.press(.info) }
                WideButton(symbol: "list.bullet.rectangle", title: "Guide") { tv.press(.guide) }
            }
        }
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Leave typing in text fields alone.
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            let keys: [UInt16: RemoteKey] = [126: .up, 125: .down, 123: .left, 124: .right, 36: .enter, 76: .enter, 51: .back, 53: .back]
            guard let key = keys[event.keyCode] else { return event }
            tv.press(key)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

private struct DPad: View {
    @ObservedObject var tv: TVController
    @Environment(\.accent) private var accent

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.05))
            Circle().strokeBorder(Color.white.opacity(0.07))
            arrow("chevron.up", .up).offset(y: -52)
            arrow("chevron.down", .down).offset(y: 52)
            arrow("chevron.left", .left).offset(x: -52)
            arrow("chevron.right", .right).offset(x: 52)
            Button { tv.press(.enter) } label: {
                Text("OK")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(accent)
                    .frame(width: 54, height: 54)
            }
            .buttonStyle(PadButtonStyle(shape: AnyShape(Circle()), fill: accent.opacity(0.22)))
        }
        .frame(width: 144, height: 144)
    }

    private func arrow(_ symbol: String, _ key: RemoteKey) -> some View {
        Button { tv.press(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(PadButtonStyle(shape: AnyShape(Circle()), fill: .clear))
    }
}

private struct MediaKey: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(PadButtonStyle())
        .help(help)
    }
}

/// Drag to move the TV's pointer, tap to click. Works where the TV shows a pointer (browser, some apps).
private struct CursorPad: View {
    @ObservedObject var tv: TVController
    @Environment(\.accent) private var accent
    @State private var last: CGPoint?
    @State private var travel: CGFloat = 0
    @State private var active = false

    var body: some View {
        Card {
            CardHeader(symbol: "cursorarrow", title: "TV Cursor") {
                Text("Drag · tap to click").font(.system(size: 10.5)).foregroundColor(Theme.tertiary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? accent.opacity(0.16) : Color.black.opacity(0.25))
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 20))
                    .foregroundColor(active ? accent : Theme.tertiary)
            }
            .frame(height: 96)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        active = true
                        if let last {
                            let delta = CGSize(width: drag.location.x - last.x, height: drag.location.y - last.y)
                            travel += abs(delta.width) + abs(delta.height)
                            tv.moveCursor(by: delta)
                        }
                        last = drag.location
                    }
                    .onEnded { _ in
                        if travel < 4 { tv.click() }
                        last = nil
                        travel = 0
                        active = false
                    }
            )
        }
    }
}

private struct KeyboardCard: View {
    @ObservedObject var tv: TVController
    @State private var text = ""

    var body: some View {
        Card {
            CardHeader(symbol: "keyboard", title: "Keyboard") {
                if tv.keyboardOpen {
                    HStack(spacing: 4) {
                        StatusDot(color: Theme.online, size: 5)
                        Text("TV keyboard open").font(.system(size: 10.5)).foregroundColor(Theme.secondary)
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("Type into the field open on the TV", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
                    .onSubmit(send)
                IconButton(symbol: "paperplane.fill", size: 30, help: "Send to TV", action: send)
                    .disabled(text.isEmpty)
            }
        }
    }

    private func send() {
        tv.sendText(text)
        text = ""
    }
}
