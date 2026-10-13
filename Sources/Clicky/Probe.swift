import AppKit
import SwiftUI

/// Command-line diagnostics: `Clicky --probe <command>`.
///
///   discover            list Samsung TVs on the network
///   use <ip>            save the TV address
///   tvs                 list saved TVs (* is active)
///   add [ip]            save another TV and make it active (no ip: stop at setup)
///   switch <n>          make TV number n from `tvs` active
///   forget              remove the active TV
///   pair                pair with the TV (choose Allow on the TV)
///   wake                send Wake-on-LAN and wait for the TV
///   launch <app id>     open an app the way the Apps tab does and wait for it on screen
///   close <app id>      quit an app the way the Close button does and wait for it to stop
///   input <port>        switch input the way the input buttons do
///   status              connect and print everything the app knows
///   upload-test         upload a generated image to My Photos, read it back, delete it
///   snapshot <folder>   render every tab to PNG using live data
enum Probe {
    static func run(_ arguments: [String]) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await perform(arguments)
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        NSApp.run()
    }

    @MainActor
    private static func perform(_ arguments: [String]) async throws {
        let tv = TVController(autostart: false)
        switch arguments.first ?? "status" {
        case "discover":
            for found in await Discovery.scan() {
                print("\(found.host)\t\(found.name)\t\(found.model)\(found.isFrame ? "\tThe Frame" : "")")
            }
        case "use":
            guard arguments.count > 1 else { throw TVError.badResponse("usage: use <ip>") }
            tv.prefs.host = arguments[1]
            print("saved \(arguments[1])")
        case "tvs":
            for (index, profile) in tv.prefs.tvs.enumerated() {
                let mark = profile.id == tv.prefs.activeID ? "*" : " "
                print("\(mark) \(index + 1)  \(profile.displayName)\t\(profile.host ?? "-")\ttoken: \(profile.token == nil ? "no" : "yes")\tfavorites: \(profile.favorites.count)\tnamed inputs: \(profile.inputs.filter(\.isNamed).map(\.name))")
            }
        case "add":
            tv.addTV()
            if arguments.count > 1 {
                tv.choose(host: arguments[1])
                print("added \(arguments[1]); now active")
            } else {
                print("new TV waiting for setup")
            }
        case "switch":
            guard arguments.count > 1, let index = Int(arguments[1]), tv.prefs.tvs.indices.contains(index - 1) else {
                throw TVError.badResponse("usage: switch <number from tvs>")
            }
            tv.switchTo(tv.prefs.tvs[index - 1].id)
            print("active: \(tv.prefs.active.displayName)")
        case "forget":
            let name = tv.prefs.active.displayName
            tv.forgetTV()
            print("forgot \(name); active: \(tv.prefs.active.displayName)")
        case "pair":
            tv.requestPairing()
            print("Choose Allow on the TV…")
            await tv.tick()
            print("link: \(tv.link)  token: \(tv.prefs.token == nil ? "none" : "saved")")
        case "wake":
            guard tv.prefs.host != nil else { throw TVError.badResponse("no TV saved yet; run: use <ip>") }
            let start = Date()
            let on = await tv.powerOn(timeout: 40)
            print(on ? "TV on after \(String(format: "%.1f", Date().timeIntervalSince(start)))s" : "TV didn't turn on within 40s")
        case "launch":
            guard arguments.count > 1, let host = tv.prefs.host else { throw TVError.badResponse("usage: launch <app id>") }
            await tv.tick()
            tv.launch(arguments[1])
            for second in 1...8 {
                try await Task.sleep(seconds: 1)
                if let status = try? await TVRestClient(host: host).appStatus(arguments[1]), status.visible {
                    print("\(status.name) on screen after ~\(second)s")
                    return
                }
            }
            print("not on screen after 8s")
        case "input":
            // input <port> — switches the way the input buttons do; checks the visible app goes away
            guard arguments.count > 1, let port = Int(arguments[1]) else { throw TVError.badResponse("usage: input <port>") }
            await tv.tick()
            await tv.tick()
            let before = tv.title(for: tv.screen)
            tv.selectInput(port)
            try await Task.sleep(seconds: 6)
            await tv.tick()
            print("before: \(before)  after: \(tv.title(for: tv.screen))")
        case "close":
            guard arguments.count > 1, let host = tv.prefs.host else { throw TVError.badResponse("usage: close <app id>") }
            await tv.tick()
            tv.close(arguments[1])
            for second in 1...6 {
                try await Task.sleep(seconds: 1)
                if let status = try? await TVRestClient(host: host).appStatus(arguments[1]), !status.running {
                    print("\(status.name) quit after ~\(second)s")
                    return
                }
            }
            print("still running after 6s")
        case "status":
            try await warm(tv)
            report(tv)
        case "art-raw":
            // art-raw <request> [json params]  — prints the first reply
            guard arguments.count > 1, let host = tv.prefs.host else { throw TVError.badResponse("usage: art-raw <request> [json]") }
            let params = arguments.count > 2 ? (try JSONSerialization.jsonObject(with: Data(arguments[2].utf8)) as? JSON ?? [:]) : [:]
            let channel = WebSocketChannel(host: host, channel: "com.samsung.art-app", clientName: TVController.clientName, token: tv.prefs.token)
            let art = ArtClient(channel: channel)
            try await channel.connect(timeout: 8)
            try await Task.sleep(seconds: 1)
            let reply = try await art.request(arguments[1], params, timeout: 10)
            let pretty = try JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: pretty, as: UTF8.self))
        case "remote-raw":
            // remote-raw <event> [json data]  — emits on the remote channel and prints everything for 6 s
            guard arguments.count > 1, let host = tv.prefs.host else { throw TVError.badResponse("usage: remote-raw <event> [json]") }
            let channel = WebSocketChannel(host: host, channel: "samsung.remote.control", clientName: TVController.clientName, token: tv.prefs.token)
            channel.onMessage = { message in
                let data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
                print(String(decoding: data.prefix(600), as: UTF8.self))
            }
            try await channel.connect(timeout: 8)
            var params: JSON = ["event": arguments[1], "to": "host"]
            if arguments.count > 2 { params["data"] = try JSONSerialization.jsonObject(with: Data(arguments[2].utf8)) }
            try await channel.send(["method": "ms.channel.emit", "params": params])
            try await Task.sleep(seconds: 6)
        case "upload-test":
            try await uploadTest(tv)
        case "snapshot":
            let folder = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "snapshots", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await warm(tv)
            try snapshot(tv, to: folder)
            print("wrote \(folder.path)")
        default:
            throw TVError.badResponse("unknown command \(arguments.first ?? "")")
        }
    }

    @MainActor
    private static func uploadTest(_ tv: TVController) async throws {
        guard let host = tv.prefs.host else { throw TVError.notConnected }
        let channel = WebSocketChannel(host: host, channel: "com.samsung.art-app", clientName: TVController.clientName, token: tv.prefs.token)
        let art = ArtClient(channel: channel)
        try await channel.connect(timeout: 8)
        try await Task.sleep(seconds: 1)
        let before = try await art.contentList()
        print("items before: \(before.count) (\(before.filter(\.isUserPhoto).count) user photos)")

        let image = NSImage(size: NSSize(width: 1920, height: 1080), flipped: false) { rect in
            NSGradient(colors: [NSColor(calibratedRed: 0.1, green: 0.2, blue: 0.5, alpha: 1), .black])?.draw(in: rect, angle: -30)
            let text = NSAttributedString(string: "Clicky upload test", attributes: [
                .font: NSFont.systemFont(ofSize: 96, weight: .bold), .foregroundColor: NSColor.white,
            ])
            text.draw(at: NSPoint(x: 160, y: 480))
            return true
        }
        guard let tiff = image.tiffRepresentation, let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw TVError.badResponse("test image")
        }
        let started = Date()
        let id = try await art.upload(jpeg, fileType: "jpg", matte: "none")
        print("uploaded \(jpeg.count) bytes as \(id) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        // The TV needs a moment to render a preview for a new image.
        try await Task.sleep(seconds: 4)
        do {
            let thumbnail = try await art.thumbnails([id])[id]
            print("thumbnail: \(thumbnail.map { "\($0.count) bytes" } ?? "missing")")
        } catch {
            print("thumbnail failed: \(error.localizedDescription)")
        }
        try await art.delete([id])
        let after = try await art.contentList()
        print("items after delete: \(after.count); test image still present: \(after.contains { $0.id == id })")
    }

    @MainActor
    private static func warm(_ tv: TVController) async throws {
        await tv.tick()
        await tv.tick()
        await tv.loadApps()
        if tv.artConnected {
            await tv.loadArtDetails()
        }
        try await Task.sleep(seconds: 1)
    }

    @MainActor
    private static func report(_ tv: TVController) {
        print("link:        \(tv.link)")
        print("tv:          \(tv.info?.displayName ?? "-") \(tv.info?.modelName ?? "") frame=\(tv.info?.isFrame ?? false) power=\(tv.info?.device.powerState ?? "-")")
        print("screen:      \(tv.title(for: tv.screen))")
        print("volume:      \(tv.volumeKnown ? "\(Int(tv.volume))" : "unknown") muted=\(tv.muted)")
        print("apps:        \(tv.apps.count) installed, \(tv.icons.count) icons; favorites \(tv.prefs.favorites)")
        print("             \(tv.apps.map { "\($0.name) (\($0.id))" }.joined(separator: ", "))")
        print("art:         connected=\(tv.artConnected) api=\(tv.artAPIVersion ?? "-") on=\(tv.artModeOn)")
        print("current art: \(tv.currentArt.map { "\($0.id) matte=\($0.matteID ?? "-")" } ?? "-")")
        for category in ArtCategory.allCases {
            print("gallery:     \(category.title): \(tv.gallery[category]?.count ?? 0)")
        }
        print("thumbnails:  \(tv.thumbnails.count)")
        print("mattes:      \(tv.matteTypes.joined(separator: ","))")
        print("slideshow:   \(tv.slideshow.map { "\($0.interval) shuffle=\($0.shuffle) \($0.categoryID)" } ?? "-")")
        for setting in tv.artSettings {
            print("setting:     \(setting.item)=\(setting.value) [\(setting.min.map(String.init) ?? "")…\(setting.max.map(String.init) ?? "")] \(setting.options)")
        }
    }

    @MainActor
    private static func snapshot(_ tv: TVController, to folder: URL) throws {
        for tab in Tab.allCases {
            try render(PopoverView(tv: tv, tab: tab), to: folder.appendingPathComponent("popover-\(tab.rawValue).png"))
            try render(fullContent(tv, tab), to: folder.appendingPathComponent("full-\(tab.rawValue).png"))
        }
        let settings = SettingsView(tv: tv, done: {})
            .padding(12)
            .frame(width: 360)
            .background(Theme.background)
            .environment(\.colorScheme, .dark)
            .environment(\.accent, tv.accent)
        try render(settings, to: folder.appendingPathComponent("settings.png"))
    }

    @MainActor
    private static func fullContent(_ tv: TVController, _ tab: Tab) -> some View {
        Group {
            switch tab {
            case .now: NowView(tv: tv, tab: .constant(.now))
            case .remote: RemoteView(tv: tv)
            case .apps: AppsView(tv: tv)
            case .art: ArtView(tv: tv)
            case .cast: CastView(tv: tv, cast: tv.cast)
            case .activity: ActivityView(tv: tv, activity: tv.activity)
            }
        }
        .padding(12)
        .frame(width: 360)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
        .environment(\.accent, tv.accent)
    }

    @MainActor
    private static func render<V: View>(_ view: V, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw TVError.badResponse("bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
