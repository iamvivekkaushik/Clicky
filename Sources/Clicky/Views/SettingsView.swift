import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var tv: TVController
    let done: () -> Void
    @State private var address = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmForget = false

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button(action: done) {
                    Label("Back", systemImage: "chevron.left").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 44, height: 1)
            }
            .padding(.bottom, 2)

            Card {
                CardHeader(symbol: "tv", title: "Television")
                info("Name", tv.info?.displayName ?? "—")
                info("Model", tv.info?.modelName ?? "—")
                info("Address", tv.prefs.host ?? "—")
                info("Resolution", tv.info?.device.resolution ?? "—")
                if let version = tv.artAPIVersion { info("Art API", version) }
                HStack(spacing: 6) {
                    TextField("TV IP address", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { tv.choose(host: address) }
                    Button("Use") { tv.choose(host: address) }
                        .disabled(address.isEmpty || address == tv.prefs.host)
                }
                HStack(spacing: 8) {
                    WideButton(symbol: "link", title: "Pair again") { tv.pairAgain() }
                    WideButton(symbol: "xmark.circle", title: "Forget TV") { confirmForget = true }
                }
            }

            Card {
                CardHeader(symbol: "house", title: "Room")
                TextField("Room name", text: Binding(get: { tv.prefs.roomName }, set: { tv.prefs.roomName = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            Card {
                CardHeader(symbol: "cable.connector.horizontal", title: "Inputs")
                ForEach(tv.prefs.inputs.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Text("HDMI \(tv.prefs.inputs[index].port)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.secondary)
                            .frame(width: 48, alignment: .leading)
                        TextField("Name", text: Binding(get: { tv.prefs.inputs[index].name }, set: { tv.prefs.inputs[index].name = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        Toggle("Show", isOn: Binding(get: { tv.prefs.inputs[index].visible }, set: { tv.prefs.inputs[index].visible = $0 }))
                            .toggleStyle(AccentCheckboxStyle())
                            .font(.system(size: 11))
                    }
                }
                Caption("Name inputs after what's plugged in, like “PS5” or “Apple TV”. Samsung doesn't report the active input over the network, so Clicky remembers the one you picked here.")
            }

            Card {
                CardHeader(symbol: "gearshape", title: "General")
                HStack {
                    Text("Open Clicky at login").font(.system(size: 12))
                    Spacer()
                    Toggle("", isOn: $launchAtLogin)
                        .toggleStyle(AccentSwitchStyle())
                        .labelsHidden()
                }
                .onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        tv.show("Couldn't change login item: \(error.localizedDescription)")
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                    }
                Caption("To turn the TV on from here, enable Settings › General › Network › Expert Settings › Power On with Mobile on the TV.")
            }
        }
        .onAppear { address = tv.prefs.host ?? "" }
        .alert("Forget this TV?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) {
                tv.forgetTV()
                done()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(tv.prefs.tvs.count > 1
                 ? "Clicky removes this TV with its pairing token and settings, and switches to your other TV. Screen time history stays."
                 : "Clicky removes its pairing token and settings for this TV. Screen time history stays.")
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11.5)).foregroundColor(Theme.secondary)
            Spacer()
            Text(value).font(.system(size: 11.5, weight: .medium)).textSelection(.enabled)
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var tv: TVController
    @State private var address = ""

    /// Set when this is a second TV, so setup can be left without adding it.
    private var savedTV: TVProfile? { tv.prefs.tvs.first { $0.host != nil && $0.id != tv.prefs.activeID } }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 10)
            Image(systemName: "photo.artframe")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(Theme.art)
            VStack(spacing: 4) {
                Text(savedTV == nil ? "Find your Frame" : "Add another TV").font(.system(size: 17, weight: .semibold))
                Text("Make sure the TV is on and on the same Wi‑Fi as this Mac.")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            Card {
                HStack {
                    Text("TVs on this network").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if tv.scanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Search again") { Task { await tv.scan() } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.samsungBlue)
                    }
                }
                if tv.discovered.isEmpty && !tv.scanning {
                    Text("No Samsung TVs found yet.").font(.system(size: 11.5)).foregroundColor(Theme.secondary)
                }
                ForEach(tv.discovered) { found in
                    Button { tv.choose(host: found.host) } label: {
                        HStack(spacing: 10) {
                            SymbolTile(symbol: found.isFrame ? "photo.artframe" : "tv", color: found.isFrame ? Theme.art : Theme.samsungBlue)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(found.name).font(.system(size: 12.5, weight: .semibold))
                                Text("\(found.model) · \(found.host)").font(.system(size: 10)).foregroundColor(Theme.secondary)
                            }
                            Spacer()
                            let saved = tv.prefs.tvs.contains { $0.host == found.host }
                            Text(saved ? "Open" : "Connect").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.samsungBlue)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Card {
                Text("Or enter its IP address").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 6) {
                    TextField("192.168.1.20", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { tv.choose(host: address) }
                    Button("Connect") { tv.choose(host: address) }
                        .disabled(address.isEmpty)
                }
            }
            Caption("After you connect, the TV asks whether to allow Clicky. Choose Allow with the TV remote.")
                .multilineTextAlignment(.center)
            if let savedTV {
                Button("Back to \(savedTV.displayName)") { tv.cancelSetup() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Theme.samsungBlue)
            }
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 16)
        .task { await tv.scan() }
    }
}
