import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case now, remote, apps, art, cast, activity

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .now: return "tv"
        case .remote: return "dpad"
        case .apps: return "square.grid.2x2"
        case .art: return "photo.artframe"
        case .cast: return "airplayvideo"
        case .activity: return "chart.bar.xaxis"
        }
    }

    var title: String {
        switch self {
        case .now: return "Now Playing"
        case .remote: return "Remote"
        case .apps: return "Apps"
        case .art: return "Art Mode"
        case .cast: return "Cast"
        case .activity: return "Activity"
        }
    }
}

struct PopoverView: View {
    @ObservedObject var tv: TVController
    @State var tab: Tab = .now
    @State var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(tv: tv, showingSettings: $showingSettings)
            if tv.link == .setup {
                OnboardingView(tv: tv)
                    .frame(height: 560)
            } else if showingSettings {
                ScrollView {
                    SettingsView(tv: tv, done: { showingSettings = false })
                        .padding(12)
                }
                .frame(height: 560)
            } else {
                TabBar(selection: $tab)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                ScrollView {
                    content
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
                .frame(height: 512)
            }
            if let message = tv.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.08))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            FooterView(tv: tv, showingSettings: $showingSettings)
        }
        .frame(width: 360)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
        .environment(\.accent, tv.accent)
        .tint(tv.accent)
        .animation(.easeInOut(duration: 0.25), value: tv.screen)
        .animation(.easeInOut(duration: 0.2), value: tv.message)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            tv.refreshNow()
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .now: NowView(tv: tv, tab: $tab)
        case .remote: RemoteView(tv: tv)
        case .apps: AppsView(tv: tv)
        case .art: ArtView(tv: tv)
        case .cast: CastView(tv: tv, cast: tv.cast)
        case .activity: ActivityView(tv: tv, activity: tv.activity)
        }
    }
}

struct HeaderView: View {
    @ObservedObject var tv: TVController
    @Binding var showingSettings: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tv.screen == .art ? "photo.artframe" : "tv.inset.filled")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(accent)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(tv.prefs.active.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    TVSwitcher(tv: tv)
                }
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(Theme.secondary)
            }
            Spacer()
            Menu {
                Button("Refresh") { tv.refreshNow() }
                Button("Pair Again…") { tv.pairAgain() }
                Divider()
                Button("Settings…") { showingSettings = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(accent)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(tv.link == .setup)

            Button { tv.powerButton() } label: {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(tv.screen == .off ? Theme.secondary : accent)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(PadButtonStyle(shape: AnyShape(Circle()), fill: .clear))
            .help(tv.screen == .off ? "Turn on" : "Turn off")
            .disabled(tv.link == .setup)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        guard tv.prefs.host != nil else { return "Not set up yet" }
        var parts = ["Samsung"]
        if tv.info?.isFrame ?? true { parts.append("The Frame") }
        parts.append("Tizen")
        return parts.joined(separator: " · ")
    }
}

/// Lists saved TVs; Clicky controls one at a time.
private struct TVSwitcher: View {
    @ObservedObject var tv: TVController

    var body: some View {
        Menu {
            ForEach(tv.prefs.tvs.filter { $0.host != nil }) { profile in
                Button { tv.switchTo(profile.id) } label: {
                    if profile.id == tv.prefs.activeID {
                        Label(profile.displayName, systemImage: "checkmark")
                    } else {
                        Text(profile.displayName)
                    }
                }
            }
            Divider()
            Button("Add TV…") { tv.addTV() }
                .disabled(tv.prefs.host == nil)
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Theme.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch TV or add another")
    }
}

struct TabBar: View {
    @Binding var selection: Tab
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(selected ? accent : Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selected ? accent.opacity(0.2) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

struct FooterView: View {
    @ObservedObject var tv: TVController
    @Binding var showingSettings: Bool

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: tv.statusColor)
            Text(tv.statusText)
                .font(.system(size: 10.5))
                .foregroundColor(Theme.secondary)
            Spacer()
            Text(tv.info?.modelName ?? "")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.tertiary)
            Menu {
                Button("Settings…") { showingSettings = true }
                    .disabled(tv.link == .setup)
                Button("Refresh") { tv.refreshNow() }
                Divider()
                Button("Quit Clicky") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.18))
    }
}
