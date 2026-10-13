import SwiftUI

struct NowView: View {
    @ObservedObject var tv: TVController
    @Binding var tab: Tab
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(spacing: 10) {
            PairingBanner(tv: tv)
            TVMockup(tv: tv)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    StatusDot(color: accent, size: 5)
                    Text("NOW ON SCREEN")
                        .font(.system(size: 9, weight: .bold))
                        .kerning(1)
                        .foregroundColor(Theme.secondary)
                    Spacer()
                    if case .input(let port) = tv.screen {
                        Text("HDMI \(port)").font(.system(size: 9, weight: .bold)).foregroundColor(accent)
                    }
                    if case .app(let id, let name) = tv.screen {
                        Button { tv.close(id) } label: {
                            Label("CLOSE", systemImage: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(accent)
                        }
                        .buttonStyle(.plain)
                        .help("Quit \(name) on the TV")
                    }
                }
                Text(tagline)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)

            if tv.artConnected {
                ArtModeCard(tv: tv)
            }
            VolumeCard(tv: tv)
            FavoritesCard(tv: tv) { tab = .apps }
            InputsCard(tv: tv)
        }
    }

    private var tagline: String {
        switch tv.screen {
        case .off: return "Your Frame is resting. Wake it with the power button."
        case .art: return "Art Mode. Your wall, curated."
        case .tv: return "Your Samsung. Your room. Your control."
        case .app: return "Everything you love, on the big screen."
        case .input: return "Your next world starts here."
        }
    }
}

struct PairingBanner: View {
    @ObservedObject var tv: TVController

    var body: some View {
        switch tv.link {
        case .needsPairing, .failed:
            Card(tint: Theme.warning) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.warning)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failure ?? "Pair this Mac with your TV")
                            .font(.system(size: 12, weight: .semibold))
                        Caption("The TV will ask you to allow Clicky. Remote, apps and Art Mode need it.")
                    }
                }
                WideButton(symbol: "link", title: "Pair with TV", prominent: true) { tv.pairAgain() }
            }
        case .pairing:
            Card(tint: Theme.samsungBlue) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check your TV").font(.system(size: 12, weight: .semibold))
                        Caption("Choose Allow on the TV screen to let Clicky control it.")
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private var failure: String? {
        if case .failed(let reason) = tv.link { return reason }
        return nil
    }
}

/// A Frame-style TV: black bezel normally, a picture-frame border in Art Mode.
struct TVMockup: View {
    @ObservedObject var tv: TVController
    @Environment(\.accent) private var accent

    var body: some View {
        let isArt = tv.screen == .art
        ZStack {
            RoundedRectangle(cornerRadius: isArt ? 3 : 7, style: .continuous)
                .fill(isArt ? Color(hex: 0xEDE6DA) : Color(hex: 0x0B0B0C))
            screenContent
                .clipShape(RoundedRectangle(cornerRadius: isArt ? 1 : 4, style: .continuous))
                .padding(isArt ? 9 : 4)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(width: 268)
        .overlay(
            RoundedRectangle(cornerRadius: isArt ? 3 : 7, style: .continuous)
                .strokeBorder(Color.white.opacity(isArt ? 0.0 : 0.12))
        )
        .shadow(color: (tv.screen == .off ? Color.black : accent).opacity(0.35), radius: 18, y: 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var screenContent: some View {
        switch tv.screen {
        case .off:
            ZStack {
                Color.black
                VStack(spacing: 6) {
                    Image(systemName: "power").font(.system(size: 20, weight: .light))
                    Text(tv.link == .offline ? "Can't reach the TV" : "TV off").font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Theme.tertiary)
            }
        case .art:
            if let item = tv.currentArt, let image = tv.thumbnails[item.id] {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                screen(symbol: "photo.artframe", title: "Art Mode", color: Theme.art)
            }
        case .app(let id, let name):
            ZStack {
                glow(AppCatalog.brand(id: id, name: name).color)
                VStack(spacing: 8) {
                    AppTile(id: id, name: name, icon: tv.icons[id], size: 46)
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                }
            }
        case .input(let port):
            let input = tv.prefs.input(port)
            screen(symbol: input.symbol, title: input.name, color: Theme.samsungBlue)
        case .tv:
            screen(symbol: "tv", title: "TV on", color: Theme.samsungBlue)
        }
    }

    private func screen(symbol: String, title: String, color: Color) -> some View {
        ZStack {
            glow(color)
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 30, weight: .regular)).foregroundColor(.white)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
            }
        }
    }

    private func glow(_ color: Color) -> some View {
        ZStack {
            Color(hex: 0x050506)
            RadialGradient(colors: [color.opacity(0.55), color.opacity(0.08), .clear], center: .center, startRadius: 4, endRadius: 170)
        }
    }
}

struct ArtModeCard: View {
    @ObservedObject var tv: TVController
    @Environment(\.accent) private var accent

    var body: some View {
        Card {
            HStack(spacing: 10) {
                SymbolTile(symbol: "photo.artframe", color: Theme.art)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Art Mode").font(.system(size: 13, weight: .semibold))
                    Text(tv.artModeOn ? "Showing art instead of a black screen" : "Turn the screen into a framed picture")
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { tv.artModeOn }, set: { tv.setArtMode($0) }))
                    .toggleStyle(AccentSwitchStyle())
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
    }
}

struct VolumeCard: View {
    @ObservedObject var tv: TVController

    var body: some View {
        Card {
            CardHeader(symbol: tv.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", title: "TV Audio") {
                Text(tv.volumeKnown ? "\(Int(tv.volume))" : "–")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundColor(Theme.tertiary)
                AccentSlider(value: Binding(get: { tv.volume }, set: { _ in }), onCommit: { tv.setVolume($0) })
                    .disabled(!tv.volumeKnown)
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundColor(Theme.tertiary)
            }
            HStack(spacing: 8) {
                Caption(tv.volumeKnown ? "TV speakers" : "Volume steps via remote keys")
                Spacer()
                IconButton(symbol: tv.muted ? "speaker.slash.fill" : "speaker.fill", size: 24, help: "Mute") { tv.toggleMute() }
                IconButton(symbol: "minus", size: 24, help: "Volume down") { tv.stepVolume(-1) }
                IconButton(symbol: "plus", size: 24, help: "Volume up") { tv.stepVolume(1) }
            }
        }
    }
}

struct FavoritesCard: View {
    @ObservedObject var tv: TVController
    let seeAll: () -> Void

    var body: some View {
        Card {
            CardHeader(symbol: "star.fill", title: "Favorites") {
                Button("See all", action: seeAll)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondary)
            }
            if tv.prefs.visibleFavorites.isEmpty {
                Caption("Right-click an app in Apps and choose Add to Favorites.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(tv.prefs.visibleFavorites.prefix(4), id: \.self) { id in
                        let name = tv.apps.first { $0.id == id }?.name ?? AppCatalog.brand(id: id, name: "App").name
                        Button { tv.launch(id) } label: {
                            VStack(spacing: 5) {
                                AppTile(id: id, name: name, icon: tv.icons[id], size: 44)
                                Text(AppCatalog.isKnown(id) ? AppCatalog.brand(id: id, name: name).name : name)
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(name)")
                    }
                }
            }
        }
    }
}

struct InputsCard: View {
    @ObservedObject var tv: TVController
    @Environment(\.accent) private var accent

    var body: some View {
        Card {
            CardHeader(symbol: "cable.connector.horizontal", title: "Inputs")
            VStack(spacing: 6) {
                ForEach(tv.prefs.inputs.filter(\.visible)) { input in
                    let current = tv.screen == .input(input.port)
                    Button { tv.selectInput(input.port) } label: {
                        HStack(spacing: 10) {
                            SymbolTile(symbol: input.symbol, color: current ? accent : Theme.secondary, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(input.name).font(.system(size: 12.5, weight: .semibold))
                                Text(input.name == input.label ? (current ? "On screen" : "Switch input") : current ? "\(input.label) · On screen" : input.label)
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.secondary)
                            }
                            Spacer()
                            if current {
                                Text("ON SCREEN").font(.system(size: 8.5, weight: .bold)).kerning(0.6).foregroundColor(accent)
                                Image(systemName: "checkmark.circle.fill").foregroundColor(accent)
                            } else {
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.tertiary)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(current ? accent.opacity(0.14) : Color.white.opacity(0.035))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button { tv.press(.source) } label: {
                    HStack {
                        Text("All sources on the TV").font(.system(size: 11)).foregroundColor(Theme.secondary)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundColor(Theme.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
