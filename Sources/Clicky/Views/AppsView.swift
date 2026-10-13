import SwiftUI

struct AppsView: View {
    @ObservedObject var tv: TVController
    @State private var query = ""
    @State private var showHidden = false
    @Environment(\.accent) private var accent

    private var hiddenCount: Int { tv.apps.filter { tv.prefs.hiddenApps.contains($0.id) }.count }

    private var filtered: [TVApp] {
        let apps = showHidden ? tv.apps : tv.apps.filter { !tv.prefs.hiddenApps.contains($0.id) }
        return query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var inputs: [InputConfig] {
        let named = tv.prefs.inputs.filter { $0.visible && $0.isNamed }
        return query.isEmpty ? named : named.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 10) {
            SectionLabel(text: "Apps")
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(Theme.tertiary)
                    TextField("Search apps", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
                IconButton(symbol: "arrow.clockwise", size: 30, help: "Reload apps") {
                    Task { await tv.loadApps() }
                }
            }

            if tv.apps.isEmpty {
                Card {
                    HStack(spacing: 10) {
                        if tv.isConnected { ProgressView().controlSize(.small) }
                        Text(tv.isConnected ? "Loading apps from the TV…" : "Connect to the TV to see its apps.")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.secondary)
                    }
                }
            } else {
                Card {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 12) {
                        ForEach(inputs) { input in
                            InputCell(tv: tv, input: input)
                        }
                        ForEach(filtered) { app in
                            AppCell(tv: tv, app: app)
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Caption("Click to open on the TV. Right-click to quit, hide or change favorites.")
                    Spacer(minLength: 8)
                    if hiddenCount > 0 || showHidden {
                        Button(showHidden ? "Done" : "\(hiddenCount) hidden") { showHidden.toggle() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(accent)
                            .help(showHidden ? "Hide them again" : "Show hidden apps so you can unhide them")
                    }
                }
            }
        }
    }
}

private struct AppCell: View {
    @ObservedObject var tv: TVController
    let app: TVApp
    @Environment(\.accent) private var accent

    var body: some View {
        let favorite = tv.prefs.favorites.contains(app.id)
        let hidden = tv.prefs.hiddenApps.contains(app.id)
        let onScreen: Bool = { if case .app(let id, _) = tv.screen { return id == app.id }; return false }()
        Button { tv.launch(app.id) } label: {
            VStack(spacing: 5) {
                AppTile(id: app.id, name: app.name, icon: tv.icons[app.id], size: 48)
                    .overlay(alignment: .topTrailing) {
                        if favorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.yellow)
                                .padding(3)
                                .background(Circle().fill(Color.black.opacity(0.7)))
                                .offset(x: 4, y: -4)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(onScreen ? accent : .clear, lineWidth: 2)
                            .padding(-3)
                    )
                Text(app.name)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .opacity(hidden ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(app.name)
        .contextMenu {
            if !hidden {
                Button(favorite ? "Remove from Favorites" : "Add to Favorites") { tv.prefs.toggleFavorite(app.id) }
            }
            Button("Open on TV") { tv.launch(app.id) }
            Button("Quit on TV") { tv.close(app.id) }
            Divider()
            Button(hidden ? "Unhide" : "Hide from Clicky") { tv.prefs.toggleHidden(app.id) }
        }
    }
}

private struct InputCell: View {
    @ObservedObject var tv: TVController
    let input: InputConfig
    @Environment(\.accent) private var accent

    var body: some View {
        let current = tv.screen == .input(input.port)
        Button { tv.selectInput(input.port) } label: {
            VStack(spacing: 5) {
                Image(systemName: input.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 48 * 0.22, style: .continuous)
                            .fill(LinearGradient(colors: [Color(hex: 0x48484A), Color(hex: 0x2C2C2E)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 48 * 0.22, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(current ? accent : .clear, lineWidth: 2)
                            .padding(-3)
                    )
                Text(input.name)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(input.name) · \(input.label)")
        .contextMenu {
            Button("Switch to \(input.label)") { tv.selectInput(input.port) }
        }
    }
}
