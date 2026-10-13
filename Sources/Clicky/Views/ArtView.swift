import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ArtView: View {
    @ObservedObject var tv: TVController
    @State private var category: ArtCategory = .myPhotos

    private var title: String {
        if tv.info?.isFrame == false { return "Art Mode needs The Frame" }
        return tv.artServiceMissing ? "The TV's Art service isn't running" : "Art Mode isn't connected yet"
    }

    private var detail: String {
        if tv.info?.isFrame == false { return "This TV doesn't report Frame support." }
        if tv.artServiceMissing {
            return "This can happen after a power cut. It usually returns once the TV has shown Art Mode; a short press of the power button on the TV remote switches to it. Clicky keeps checking."
        }
        return "Pair with the TV and keep it on. Clicky connects to the Art Mode service automatically."
    }

    var body: some View {
        VStack(spacing: 10) {
            SectionLabel(text: "Art Mode")
            if !tv.artConnected {
                Card {
                    HStack(alignment: .top, spacing: 10) {
                        SymbolTile(symbol: "photo.artframe", color: Theme.art)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(.system(size: 12.5, weight: .semibold))
                            Caption(detail)
                        }
                    }
                }
            } else {
                CurrentArtCard(tv: tv)
                if let item = tv.currentArt, item.isUserPhoto {
                    MatteCard(tv: tv, item: item)
                }
                GalleryCard(tv: tv, category: $category)
                UploadCard(tv: tv)
                if let slideshow = tv.slideshow {
                    SlideshowCard(tv: tv, setting: slideshow)
                }
                if !tv.artSettings.isEmpty {
                    ArtDisplayCard(tv: tv)
                }
                Caption("Art Mode uses the Frame's local Art API\(tv.artAPIVersion.map { " (v\($0))" } ?? "").")
            }
        }
        .onAppear {
            guard tv.artConnected else { return }
            Task { await tv.loadGallery(category) }
        }
        .onChange(of: category) { newValue in
            Task { await tv.loadGallery(newValue) }
        }
    }
}

private struct CurrentArtCard: View {
    @ObservedObject var tv: TVController

    private var selection: String {
        guard let item = tv.currentArt else { return "No artwork selected" }
        let source = item.isUserPhoto ? "My Photos" : "Samsung Art Store"
        guard let width = item.width, let height = item.height else { return "From \(source)" }
        return "From \(source) · \(width)×\(height)"
    }

    var body: some View {
        Card {
            ZStack {
                Rectangle().fill(Color(hex: 0xEDE6DA))
                Group {
                    if let item = tv.currentArt, let image = tv.thumbnails[item.id] {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: "photo.artframe").font(.system(size: 28)).foregroundColor(.black.opacity(0.3))
                    }
                }
                .padding(10)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 3)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tv.artModeOn ? "Art Mode is on" : "Art Mode is off")
                        .font(.system(size: 13, weight: .semibold))
                    Text(selection)
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

private struct MatteCard: View {
    @ObservedObject var tv: TVController
    let item: ArtItem

    var body: some View {
        let current = ArtCatalog.split(item.matteID)
        Card {
            CardHeader(symbol: "square.on.square", title: "Matte")
            HStack(spacing: 8) {
                Picker("Style", selection: Binding(get: { current.type }, set: { tv.setMatte(type: $0, color: current.color) })) {
                    ForEach(tv.matteTypes, id: \.self) { Text(ArtCatalog.title($0)).tag($0) }
                }
                Picker("Color", selection: Binding(get: { current.color }, set: { tv.setMatte(type: current.type, color: $0) })) {
                    ForEach(tv.matteColors, id: \.self) { Text(ArtCatalog.title($0)).tag($0) }
                }
                .disabled(current.type == "none")
            }
            .labelsHidden()
            .controlSize(.small)
            Caption("Applies to the photo on screen. Not every matte fits every photo's shape.")
        }
    }
}

private struct GalleryCard: View {
    @ObservedObject var tv: TVController
    @Binding var category: ArtCategory
    @State private var pendingDelete: ArtItem?
    @Environment(\.accent) private var accent

    var body: some View {
        let items = tv.gallery[category] ?? []
        Card {
            CardHeader(symbol: "photo.on.rectangle", title: "Collection") {
                Text("\(items.count)").font(.system(size: 11)).foregroundColor(Theme.tertiary)
            }
            PillPicker(options: ArtCategory.allCases.map { ($0, $0.title) }, selection: $category)
            if items.isEmpty {
                Text(category == .myPhotos ? "No photos yet. Add some below." : category == .favorites ? "No favorites on the TV." : "Nothing shown recently.")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(items) { item in
                        thumbnail(item)
                    }
                }
            }
        }
        .alert("Delete this photo from the TV?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { tv.deleteArtwork(pendingDelete) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's removed from My Photos on The Frame. Your original stays on this Mac.")
        }
    }

    private func thumbnail(_ item: ArtItem) -> some View {
        let selected = tv.currentArt?.id == item.id
        return Button { tv.showArtwork(item) } label: {
            ZStack {
                Rectangle().fill(Color.white.opacity(0.06))
                if let image = tv.thumbnails[item.id] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 58)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? accent : Color.white.opacity(0.08), lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show on The Frame")
        .contextMenu {
            Button("Show on TV") { tv.showArtwork(item) }
            if item.isUserPhoto {
                Button("Delete from TV…", role: .destructive) { pendingDelete = item }
            }
        }
    }
}

private struct UploadCard: View {
    @ObservedObject var tv: TVController
    @State private var targeted = false
    @Environment(\.accent) private var accent

    var body: some View {
        Card {
            CardHeader(symbol: "square.and.arrow.up", title: "Add photos")
            VStack(spacing: 6) {
                Image(systemName: "photo.stack").font(.system(size: 20)).foregroundColor(targeted ? accent : Theme.secondary)
                Text("Drop photos here").font(.system(size: 12, weight: .semibold))
                Caption("JPEG, PNG or HEIC. Resized to 4K and sent to My Photos.")
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    .foregroundColor(targeted ? accent : Color.white.opacity(0.18))
            )
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(targeted ? accent.opacity(0.1) : .clear))
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted, perform: drop)

            HStack(spacing: 8) {
                WideButton(symbol: "folder", title: "Choose photos…", prominent: true, action: choose)
                Picker("Matte", selection: Binding(get: { tv.prefs.uploadMatte }, set: { tv.prefs.uploadMatte = $0 })) {
                    Text("No matte").tag("none")
                    Text("Modern").tag("modern_polar")
                    Text("Shadow box").tag("shadowbox_polar")
                    Text("Flexible").tag("flexible_polar")
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 112)
            }
            Toggle("Show on The Frame after upload", isOn: Binding(get: { tv.prefs.showAfterUpload }, set: { tv.prefs.showAfterUpload = $0 }))
                .toggleStyle(AccentCheckboxStyle())
                .font(.system(size: 11))
            status
        }
    }

    @ViewBuilder private var status: some View {
        switch tv.uploadState {
        case .idle:
            EmptyView()
        case .working(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.system(size: 11)).foregroundColor(Theme.secondary)
            }
        case .done(let text):
            Label(text, systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundColor(Theme.online)
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(Theme.warning)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose photos to show on The Frame"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { tv.upload(panel.urls) }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { tv.upload(urls) }
        return true
    }
}

private struct SlideshowCard: View {
    @ObservedObject var tv: TVController
    let setting: SlideshowSetting

    var body: some View {
        Card {
            CardHeader(symbol: "play.rectangle", title: "Slideshow")
            HStack {
                Text("Change art every").font(.system(size: 12)).foregroundColor(Theme.secondary)
                Spacer()
                Picker("Interval", selection: Binding(get: { setting.interval }, set: { value in apply { $0.interval = value } })) {
                    ForEach(SlideshowSetting.intervals, id: \.value) { Text($0.title).tag($0.value) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)
            }
            HStack {
                Text("From").font(.system(size: 12)).foregroundColor(Theme.secondary)
                Spacer()
                Picker("Source", selection: Binding(get: { setting.categoryID }, set: { value in apply { $0.categoryID = value } })) {
                    ForEach([ArtCategory.myPhotos, .favorites]) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)
            }
            Toggle("Shuffle", isOn: Binding(get: { setting.shuffle }, set: { value in apply { $0.shuffle = value } }))
            .toggleStyle(AccentCheckboxStyle())
            .font(.system(size: 11.5))
            .disabled(setting.interval == "off")
        }
    }

    private func apply(_ change: (inout SlideshowSetting) -> Void) {
        var next = setting
        change(&next)
        tv.updateSlideshow(next)
    }
}

private struct ArtDisplayCard: View {
    @ObservedObject var tv: TVController

    var body: some View {
        Card {
            CardHeader(symbol: "sun.max.fill", title: "Art display")
            ForEach(tv.artSettings) { setting in
                row(setting)
            }
            Caption("Applies to Art Mode only. TV picture settings stay on the TV.")
        }
    }

    @ViewBuilder private func row(_ setting: ArtSetting) -> some View {
        switch setting.item {
        case "brightness", "color_temperature":
            let low = Double(setting.min ?? (setting.item == "brightness" ? 0 : -5))
            let high = Double(setting.max ?? (setting.item == "brightness" ? 10 : 5))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(setting.item == "brightness" ? "Brightness" : "Color tone",
                          systemImage: setting.item == "brightness" ? "sun.max" : "thermometer.medium")
                        .font(.system(size: 12))
                    Spacer()
                    Text(setting.value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                AccentSlider(value: Binding(get: { Double(setting.value) ?? low }, set: { _ in }), range: low...max(high, low + 1)) {
                    tv.setArtSetting(setting.item, value: String(Int($0)))
                }
            }
        case "motion_timer", "motion_sensitivity":
            HStack {
                Label(setting.item == "motion_timer" ? "Motion sensor sleep" : "Motion sensitivity",
                      systemImage: "figure.walk.motion")
                    .font(.system(size: 12))
                Spacer()
                Picker(setting.item, selection: Binding(get: { setting.value }, set: { tv.setArtSetting(setting.item, value: $0) })) {
                    ForEach(options(setting), id: \.self) { Text(optionTitle($0, setting.item)).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 100)
            }
        case "brightness_sensor_setting":
            HStack {
                Label("Auto brightness", systemImage: "light.max").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: Binding(get: { setting.value == "on" }, set: { tv.setArtSetting(setting.item, value: $0 ? "on" : "off") }))
                    .toggleStyle(AccentSwitchStyle())
                    .labelsHidden()
                    .controlSize(.mini)
            }
        default:
            EmptyView()
        }
    }

    private func options(_ setting: ArtSetting) -> [String] {
        var values = setting.options
        if values.isEmpty, let low = setting.min, let high = setting.max, low <= high { values = (low...high).map(String.init) }
        if !values.contains(setting.value) { values.insert(setting.value, at: 0) }
        return values
    }

    private func optionTitle(_ value: String, _ item: String) -> String {
        guard item == "motion_timer" else { return value }
        if value == "off" { return "Off" }
        guard let minutes = Int(value) else { return value }
        return minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min"
    }
}
