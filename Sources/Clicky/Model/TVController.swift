import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// App state for one TV: polls it, keeps the WebSocket channels open and exposes actions to the UI.
@MainActor
final class TVController: ObservableObject {
    enum Link: Equatable {
        case setup, offline, standby, needsPairing, pairing, connecting, connected
        case failed(String)
    }

    enum Screen: Equatable {
        case off, art, tv
        case app(id: String, name: String)
        case input(Int)
    }

    enum UploadState: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    static let clientName = "Clicky for Mac"

    @Published private(set) var link: Link = .setup
    @Published private(set) var info: TVInfo?
    @Published private(set) var screen: Screen = .off
    @Published private(set) var volume: Double = 0
    @Published private(set) var volumeKnown = false
    @Published private(set) var muted = false
    @Published private(set) var apps: [TVApp] = []
    @Published private(set) var icons: [String: NSImage] = [:]
    @Published private(set) var keyboardOpen = false
    @Published private(set) var discovered: [DiscoveredTV] = []
    @Published private(set) var scanning = false
    @Published private(set) var message: String?

    @Published private(set) var artConnected = false
    /// The art channel is reachable but the TV's Art service hasn't joined it (seen after a power cut).
    @Published private(set) var artServiceMissing = false
    @Published private(set) var artModeOn = false
    @Published private(set) var artAPIVersion: String?
    @Published private(set) var currentArt: ArtItem?
    @Published private(set) var gallery: [ArtCategory: [ArtItem]] = [:]
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var matteTypes = ArtCatalog.matteTypes
    @Published private(set) var matteColors = ArtCatalog.matteColors
    @Published private(set) var slideshow: SlideshowSetting?
    @Published private(set) var artSettings: [ArtSetting] = []
    @Published private(set) var uploadState: UploadState = .idle

    let prefs: Preferences
    let activity: ActivityStore
    let cast: CastSession

    private var remote: RemoteClient?
    private var art: ArtClient?
    private var loop: Task<Void, Never>?
    private var ticking = false
    private var pairingRequested = false
    private var lastTick: Date?
    private var misses = 0
    private var remoteFailures = 0
    private var remoteRetryAt = Date.distantPast
    private var artRetryAt = Date.distantPast
    private var holdScreenUntil = Date.distantPast
    private var lastLaunched: String?
    private var lastVisibleApp: String?
    private var wakeTask: Task<Void, Never>?
    private var volumeWrite: Task<Void, Never>?
    private var settingWrites: [String: Task<Void, Never>] = [:]
    private var cursorPending = CGSize.zero
    private var cursorFlush: Task<Void, Never>?
    private var messageClear: Task<Void, Never>?
    private var loadingThumbs = Set<String>()
    private var iconsUnsupported = false
    private var storeIconsTried = Set<String>()
    private var appListUnsupported = false
    private var forwarding: [AnyCancellable] = []

    init(autostart: Bool = true) {
        prefs = Preferences()
        activity = ActivityStore()
        cast = CastSession()
        link = prefs.host == nil ? .setup : .connecting
        // Views read settings and cast state through the controller.
        forwarding = [
            prefs.objectWillChange.sink { [weak self] in self?.objectWillChange.send() },
            cast.objectWillChange.sink { [weak self] in self?.objectWillChange.send() },
        ]
        if autostart { start() }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(seconds: 4)
            }
        }
    }

    func refreshNow() {
        Task { await tick() }
    }

    // MARK: - Polling

    func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }

        recordActivity(until: Date())
        guard let host = prefs.host else {
            link = .setup
            screen = .off
            return
        }
        // Results that arrive after a switch to another TV are dropped.
        let profile = prefs.activeID
        do {
            let info = try await TVRestClient(host: host).info(timeout: 2.5)
            guard prefs.activeID == profile else { return }
            misses = 0
            self.info = info
            if let mac = info.device.wifiMac, mac != prefs.macAddress { prefs.macAddress = mac }
            if prefs.roomName.isEmpty { prefs.roomName = info.displayName }
            guard info.isOn else {
                setScreen(.off)
                closeChannels()
                link = .standby
                return
            }
            await ensureChannels(host)
            guard prefs.activeID == profile else { return }
            await refreshScreen(host)
            guard prefs.activeID == profile else { return }
            await refreshVolume(host)
        } catch {
            guard prefs.activeID == profile else { return }
            misses += 1
            if misses >= 2 {
                setScreen(.off)
                closeChannels()
                link = .offline
            }
        }
    }

    private func ensureChannels(_ host: String) async {
        if remote == nil {
            let tokenRequired = info?.device.tokenAuthSupport == "true"
            if prefs.token == nil, tokenRequired, !pairingRequested {
                if case .failed = link {} else { link = .needsPairing }
                return
            }
            guard pairingRequested || Date() >= remoteRetryAt else { return }
            await openRemote(host)
        }
        if remote != nil, info?.isFrame == true, art == nil, Date() >= artRetryAt {
            await openArt(host)
        }
    }

    private func openRemote(_ host: String) async {
        let pairing = prefs.token == nil
        let profile = prefs.activeID
        let channel = WebSocketChannel(host: host, channel: "samsung.remote.control", clientName: Self.clientName, token: prefs.token)
        let client = RemoteClient(channel: channel)
        channel.onToken = { [weak self] token in
            guard let self, self.prefs.activeID == profile else { return }
            self.prefs.token = token
        }
        channel.onClose = { [weak self, weak client] in
            guard let self, let client, self.remote === client else { return }
            self.remote = nil
            self.keyboardOpen = false
            if self.link == .connected { self.link = .connecting }
        }
        client.onKeyboardChange = { [weak self] open in self?.keyboardOpen = open }

        link = pairing ? .pairing : .connecting
        do {
            try await channel.connect(timeout: pairing ? 45 : 8)
            guard prefs.activeID == profile else { return channel.close() }
            remote = client
            pairingRequested = false
            remoteFailures = 0
            link = .connected
            Task { await loadApps() }
        } catch TVError.unauthorized {
            guard prefs.activeID == profile else { return }
            prefs.token = nil
            pairingRequested = false
            link = .failed("Pairing was declined on the TV.")
        } catch {
            guard prefs.activeID == profile else { return }
            pairingRequested = false
            remoteFailures += 1
            // A stale token makes the TV prompt again; don't keep re-prompting.
            remoteRetryAt = Date().addingTimeInterval(Double(min(remoteFailures, 6)) * 10)
            if pairing || remoteFailures >= 3 {
                link = .failed("The TV didn't respond. Pair again and choose Allow on the TV.")
            } else {
                link = .connecting
            }
        }
    }

    private func openArt(_ host: String) async {
        let profile = prefs.activeID
        let channel = WebSocketChannel(host: host, channel: "com.samsung.art-app", clientName: Self.clientName, token: prefs.token)
        let client = ArtClient(channel: channel)
        client.onPush = { [weak self] event, payload in self?.artEvent(event, payload) }
        channel.onClose = { [weak self, weak client] in
            guard let self, let client, self.art === client else { return }
            self.art = nil
            self.artConnected = false
        }
        let ready = channel.waiters.expect(timeout: 3) { $0["event"] as? String == "ms.channel.ready" }
        do {
            try await channel.connect(timeout: 8)
            _ = try? await ready.value
            guard prefs.activeID == profile else { return channel.close() }
            guard channel.hostPresent else {
                channel.close()
                artServiceMissing = true
                artRetryAt = Date().addingTimeInterval(20)
                return
            }
            artServiceMissing = false
            art = client
            artConnected = true
            artAPIVersion = try? await client.apiVersion()
            Task { await loadArtDetails() }
        } catch {
            artRetryAt = Date().addingTimeInterval(30)
        }
    }

    private func closeChannels() {
        remote?.channel.close()
        remote = nil
        art?.channel.close()
        art = nil
        artConnected = false
        keyboardOpen = false
    }

    private func refreshScreen(_ host: String) async {
        guard Date() >= holdScreenUntil else { return }
        let profile = prefs.activeID
        if let art, let on = try? await art.isArtModeOn(), prefs.activeID == profile {
            artModeOn = on
            if on {
                if screen != .art { Task { await refreshCurrentArt() } }
                setScreen(.art)
                return
            }
        }
        let app = await visibleApp(host)
        guard prefs.activeID == profile else { return }
        if let app {
            let name = AppCatalog.isKnown(app.id) ? AppCatalog.brand(id: app.id, name: app.name).name : app.name
            lastVisibleApp = app.id
            if prefs.lastInput != nil { prefs.lastInput = nil }
            setScreen(.app(id: app.id, name: name))
        } else if let port = prefs.lastInput {
            setScreen(.input(port))
        } else {
            setScreen(.tv)
        }
    }

    /// The REST API reports `visible` per app; check the ones likely to be on screen.
    private func visibleApp(_ host: String) async -> AppStatus? {
        var ids = prefs.favorites
        let extra = [lastLaunched, lastVisibleApp].compactMap { $0 } + apps.map(\.id).filter(AppCatalog.isKnown)
        for id in extra where !ids.contains(id) { ids.append(id) }
        let candidates = Array(ids.prefix(14))
        return await withTaskGroup(of: AppStatus?.self) { group in
            for id in candidates {
                group.addTask { try? await TVRestClient(host: host).appStatus(id, timeout: 2) }
            }
            for await status in group {
                if let status, status.visible {
                    group.cancelAll()
                    return status
                }
            }
            return nil
        }
    }

    private func refreshVolume(_ host: String) async {
        guard volumeWrite == nil else { return }
        let renderer = UPnPClient(host: host)
        let profile = prefs.activeID
        if let value = try? await renderer.volume(), prefs.activeID == profile {
            volume = Double(value)
            volumeKnown = true
        }
        if let value = try? await renderer.isMuted(), prefs.activeID == profile { muted = value }
    }

    private func setScreen(_ new: Screen) {
        if screen != new { screen = new }
    }

    private func recordActivity(until now: Date) {
        defer { lastTick = now }
        guard let lastTick else { return }
        // Cap gaps so time asleep or offline isn't counted.
        let seconds = min(now.timeIntervalSince(lastTick), 15)
        switch screen {
        case .off: break
        case .art: activity.add(key: "art", name: "Art Mode", seconds: seconds)
        case .tv: activity.add(key: "tv", name: "TV", seconds: seconds)
        case .app(let id, let name): activity.add(key: "app:\(id)", name: name, seconds: seconds)
        case .input(let port): activity.add(key: "input:\(port)", name: prefs.input(port).name, seconds: seconds)
        }
    }

    private func artEvent(_ event: String, _ payload: JSON) {
        switch event {
        case "art_mode_changed", "artmode_status":
            let on = (payload.string("status") ?? payload.string("value")) == "on"
            artModeOn = on
            if on { setScreen(.art) } else if screen == .art { setScreen(.tv) }
            Task { await refreshCurrentArt() }
        case "image_selected", "slideshow_image_changed":
            Task { await refreshCurrentArt() }
        case "image_added", "image_deleted":
            Task { await loadGallery(.myPhotos) }
        case "go_to_standby":
            setScreen(.off)
            holdScreenUntil = Date().addingTimeInterval(6)
        default:
            break
        }
    }

    private func refreshSoon(after seconds: Double = 1.5) {
        Task {
            try? await Task.sleep(seconds: seconds)
            await tick()
        }
    }

    private func report(_ error: Error) {
        Debug.log("error: \(error.localizedDescription)")
        show(error.localizedDescription)
    }

    func show(_ text: String) {
        message = text
        messageClear?.cancel()
        messageClear = Task { [weak self] in
            try? await Task.sleep(seconds: 4)
            if !Task.isCancelled { self?.message = nil }
        }
    }

    // MARK: - Setup

    func scan() async {
        scanning = true
        discovered = await Discovery.scan()
        scanning = false
    }

    func choose(host: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        // A TV that's already saved is opened rather than added twice.
        if let saved = prefs.tvs.first(where: { $0.host == host && $0.id != prefs.activeID }) {
            return switchTo(saved.id)
        }
        if host != prefs.host {
            closeChannels()
            prefs.resetConnection()
            resetState()
            prefs.host = host
        }
        pairingRequested = true
        link = .connecting
        refreshNow()
    }

    func pairAgain() {
        requestPairing()
        refreshNow()
    }

    /// Forgets the token so the next poll asks the TV for permission again.
    func requestPairing() {
        closeChannels()
        prefs.token = nil
        pairingRequested = true
        remoteFailures = 0
        remoteRetryAt = .distantPast
        link = .pairing
    }

    func switchTo(_ id: String) {
        guard id != prefs.activeID else { return }
        leaveTV()
        prefs.select(id)
        enterTV()
    }

    /// Starts setup for another TV; the current one stays saved.
    func addTV() {
        guard prefs.host != nil else { return }
        leaveTV()
        prefs.addTV()
        enterTV()
    }

    /// Leaves setup for a new TV and goes back to a saved one.
    func cancelSetup() {
        guard let saved = prefs.tvs.first(where: { $0.host != nil && $0.id != prefs.activeID }) else { return }
        switchTo(saved.id)
    }

    /// Removes this TV; Clicky moves to another saved one, or back to setup if it was the only one.
    func forgetTV() {
        leaveTV()
        prefs.forgetTV()
        enterTV()
    }

    private func leaveTV() {
        closeChannels()
        if cast.isActive { Task { await cast.stop() } }
        resetState()
    }

    private func enterTV() {
        pairingRequested = false
        link = prefs.host == nil ? .setup : .connecting
        refreshNow()
    }

    private func resetState() {
        wakeTask?.cancel()
        wakeTask = nil
        volumeWrite?.cancel()
        volumeWrite = nil
        info = nil
        screen = .off
        misses = 0
        holdScreenUntil = .distantPast
        lastLaunched = nil
        lastVisibleApp = nil
        apps = []
        icons = [:]
        appListUnsupported = false
        volume = 0
        muted = false
        keyboardOpen = false
        artModeOn = false
        artServiceMissing = false
        artAPIVersion = nil
        uploadState = .idle
        gallery = [:]
        thumbnails = [:]
        currentArt = nil
        slideshow = nil
        artSettings = []
        volumeKnown = false
        iconsUnsupported = false
        remoteFailures = 0
        remoteRetryAt = .distantPast
        artRetryAt = .distantPast
    }

    // MARK: - Remote

    func press(_ key: RemoteKey) {
        send { try await $0.key(key.rawValue) }
    }

    private func send(_ action: @escaping (RemoteClient) async throws -> Void) {
        Task {
            guard let remote else { return report(TVError.notConnected) }
            do { try await action(remote) } catch { report(error) }
        }
    }

    func powerButton() {
        if screen == .off {
            guard wakeTask == nil else { return show("Waking the TV…") }
            show("Waking the TV…")
            wakeTask = Task {
                let on = await powerOn()
                guard !Task.isCancelled else { return }
                wakeTask = nil
                if on {
                    message = nil
                    refreshNow()
                } else {
                    show("The TV didn't wake. Check “Power On with Mobile” is on in the TV's network settings.")
                }
            }
        } else {
            // On The Frame a short press toggles Art Mode; holding it turns the TV off.
            send { try await $0.hold(RemoteKey.power.rawValue, seconds: 3) }
            holdScreenUntil = Date().addingTimeInterval(8)
            setScreen(.off)
        }
    }

    /// Keeps trying until the TV reports on. Which signal works depends on how deeply it sleeps:
    /// - Network standby (about 20 s after power-off): REST answers "standby" and the remote channel
    ///   still accepts connections, but Wake-on-LAN is ignored. KEY_POWER over the channel wakes it.
    /// - Leaving the network: for a few seconds nothing works and magic packets are lost.
    /// - Deep standby: only Wake-on-LAN works, and only with "Power On with Mobile" enabled.
    func powerOn(timeout: TimeInterval = 30) async -> Bool {
        guard let host = prefs.host else { return false }
        let rest = TVRestClient(host: host)
        let deadline = Date().addingTimeInterval(timeout)
        var keySentAt = Date.distantPast
        while Date() < deadline, !Task.isCancelled {
            // Sent before the REST check so deep standby doesn't wait out a timeout; a TV that's on ignores it.
            if let mac = prefs.macAddress { WakeOnLAN.wake(mac: mac, near: host) }
            if let info = try? await rest.info(timeout: 1.2) {
                if info.isOn { return true }
                // KEY_POWER takes about half a second to land; don't send a second one that toggles Art Mode.
                let channelAllowed = prefs.token != nil || info.device.tokenAuthSupport != "true"
                if channelAllowed, Date().timeIntervalSince(keySentAt) > 4, await pressPowerOnce(host) {
                    keySentAt = Date()
                }
            }
            try? await Task.sleep(seconds: 1)
        }
        return false
    }

    /// Short KEY_POWER on a throwaway channel; the main channel is closed while the TV is in standby.
    private func pressPowerOnce(_ host: String) async -> Bool {
        let channel = WebSocketChannel(host: host, channel: "samsung.remote.control", clientName: Self.clientName, token: prefs.token)
        defer { channel.close() }
        do {
            try await channel.connect(timeout: 3)
            try await RemoteClient(channel: channel).key(RemoteKey.power.rawValue)
            try? await Task.sleep(seconds: 0.3)
            return true
        } catch {
            Debug.log("standby KEY_POWER failed: \(error.localizedDescription)")
            return false
        }
    }

    func launch(_ appID: String) {
        lastLaunched = appID
        prefs.lastInput = nil
        let app = apps.first { $0.id == appID }
        let name = AppCatalog.brand(id: appID, name: app?.name ?? "App").name
        Task {
            do {
                guard let host = prefs.host else { throw TVError.notConnected }
                do {
                    // REST first: ed.apps.launch needs the TV-side host on the channel, which isn't always there.
                    try await TVRestClient(host: host).launch(appID)
                } catch {
                    guard let remote else { throw error }
                    try await remote.launch(appID, type: app?.type)
                }
                holdScreenUntil = Date().addingTimeInterval(5)
                setScreen(.app(id: appID, name: name))
                refreshSoon(after: 5.5)
            } catch {
                report(error)
            }
        }
    }

    func close(_ appID: String) {
        guard let host = prefs.host else { return report(TVError.notConnected) }
        Task {
            do {
                try await TVRestClient(host: host).close(appID)
                if lastLaunched == appID { lastLaunched = nil }
                if case .app(let id, _) = screen, id == appID {
                    holdScreenUntil = Date().addingTimeInterval(3)
                    setScreen(prefs.lastInput.map(Screen.input) ?? .tv)
                }
                refreshSoon(after: 3.5)
            } catch {
                report(error)
            }
        }
    }

    /// Tizen 6.5 ignores KEY_HDMI1…4. Plain KEY_HDMI switches to an HDMI input (the last one used), so the port
    /// can't be chosen; with one HDMI device that's the right one. It isn't pressed again while that input is
    /// already on screen, since a repeat press may move on to the next port.
    func selectInput(_ port: Int) {
        let alreadyOn = screen == .input(port)
        prefs.lastInput = port
        holdScreenUntil = Date().addingTimeInterval(5)
        setScreen(.input(port))
        if !alreadyOn { send { try await $0.key("KEY_HDMI") } }
    }

    func setVolume(_ value: Double) {
        volume = value
        volumeWrite?.cancel()
        volumeWrite = Task { [weak self] in
            try? await Task.sleep(seconds: 0.15)
            guard let self, !Task.isCancelled, let host = self.prefs.host else { return }
            do { try await UPnPClient(host: host).setVolume(Int(value.rounded())) } catch { self.report(error) }
            if !Task.isCancelled { self.volumeWrite = nil }
        }
    }

    func stepVolume(_ delta: Int) {
        if volumeKnown {
            setVolume(min(100, max(0, volume + Double(delta))))
        } else {
            press(delta > 0 ? .volumeUp : .volumeDown)
        }
    }

    func toggleMute() {
        guard let host = prefs.host else { return }
        let target = !muted
        muted = target
        Task {
            do { try await UPnPClient(host: host).setMuted(target) } catch { press(.mute) }
        }
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        send { try await $0.text(text) }
    }

    func moveCursor(by delta: CGSize) {
        cursorPending.width += delta.width
        cursorPending.height += delta.height
        guard cursorFlush == nil else { return }
        cursorFlush = Task { [weak self] in
            try? await Task.sleep(seconds: 0.04)
            guard let self else { return }
            let pending = self.cursorPending
            self.cursorPending = .zero
            self.cursorFlush = nil
            let dx = Int((pending.width * 2).rounded())
            let dy = Int((pending.height * 2).rounded())
            guard dx != 0 || dy != 0, let remote = self.remote else { return }
            try? await remote.moveCursor(dx: dx, dy: dy)
        }
    }

    func click() {
        send { try await $0.click() }
    }

    func loadApps() async {
        guard let host = prefs.host else { return }
        let profile = prefs.activeID
        if apps.isEmpty, let data = Preferences.store.data(forKey: prefs.appsKey),
           let cached = try? JSONDecoder().decode([TVApp].self, from: data) {
            apps = cached
        }
        var list: [TVApp] = []
        var complete = true
        if !appListUnsupported, let remote {
            list = (try? await remote.installedApps()) ?? []
            appListUnsupported = list.isEmpty
        }
        if list.isEmpty {
            // Tizen 6.5 (2022) ignores ed.installedApp.get; the REST status call still names installed apps.
            (list, complete) = await probeKnownApps(host, keeping: apps)
        }
        guard !list.isEmpty, prefs.activeID == profile else { return }
        apps = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        Preferences.store.set(try? JSONEncoder().encode(apps), forKey: prefs.appsKey)
        // Only re-pick default favorites from a complete answer, never from a partial one.
        if complete, !prefs.favoritesCustomized {
            let installed = Set(list.map(\.id)).subtracting(prefs.hiddenApps)
            let picks = Array(AppCatalog.popular.filter(installed.contains).prefix(4))
            if !picks.isEmpty, picks != prefs.favorites { prefs.favorites = picks }
        }
        await loadIcons()
    }

    /// Returns the installed apps and whether every id got a definite answer.
    private func probeKnownApps(_ host: String, keeping known: [TVApp]) async -> (apps: [TVApp], complete: Bool) {
        await withTaskGroup(of: (id: String, app: TVApp?, answered: Bool).self) { group in
            func probe(_ id: String) {
                group.addTask {
                    do {
                        guard let status = try await TVRestClient(host: host).appStatus(id, timeout: 3) else { return (id, nil, true) }
                        let name = AppCatalog.isKnown(status.id) ? AppCatalog.brand(id: status.id, name: status.name).name : status.name
                        return (id, TVApp(id: status.id, name: name), true)
                    } catch {
                        return (id, nil, false)
                    }
                }
            }
            // A few hundred ids: keep within the session's 8 connections so queued requests don't time out.
            var pending = AppCatalog.candidates.dropFirst(8)
            for id in AppCatalog.candidates.prefix(8) { probe(id) }
            var found: [TVApp] = []
            var complete = true
            for await result in group {
                if let next = pending.popFirst() { probe(next) }
                // A timeout says nothing about whether the app is installed; keep what we knew.
                let app = result.answered ? result.app : known.first { $0.id == result.id }
                complete = complete && result.answered
                if let app, !found.contains(where: { $0.name == app.name }) { found.append(app) }
            }
            return (found, complete)
        }
    }

    private func loadIcons() async {
        guard let host = prefs.host else { return }
        let cache = ImageCache(tv: host, kind: "icons")
        for app in apps where icons[app.id] == nil {
            if let image = cache.image(app.id) {
                icons[app.id] = image
                continue
            }
            guard !iconsUnsupported, let remote, let path = app.iconPath, !path.isEmpty else { continue }
            do {
                guard let data = try await remote.icon(path: path), let image = NSImage(data: data) else { continue }
                icons[app.id] = image
                cache.store(data, for: app.id)
            } catch TVError.timeout {
                iconsUnsupported = true
            } catch {
                break
            }
        }

        let missing = apps.filter { icons[$0.id] == nil && !storeIconsTried.contains($0.id) }
        guard !missing.isEmpty else { return }
        storeIconsTried.formUnion(missing.map(\.id))
        for (appID, data) in await AppStoreIcons.fetch(for: missing) {
            guard let image = NSImage(data: data) else { continue }
            icons[appID] = image
            cache.store(data, for: appID)
        }
    }

    // MARK: - Art Mode

    func setArtMode(_ on: Bool) {
        guard let art else { return report(TVError.notConnected) }
        artModeOn = on
        holdScreenUntil = Date().addingTimeInterval(5)
        if on { setScreen(.art) } else if screen == .art { setScreen(prefs.lastInput.map(Screen.input) ?? .tv) }
        Task {
            do { try await art.setArtMode(on) } catch { report(error) }
            refreshSoon(after: 5.5)
        }
    }

    func loadArtDetails() async {
        guard let art else { return }
        await refreshCurrentArt()
        if let mattes = try? await art.matteOptions(), !mattes.types.isEmpty {
            matteTypes = mattes.types
            if !mattes.colors.isEmpty { matteColors = mattes.colors }
        }
        slideshow = try? await art.slideshow()
        artSettings = (try? await art.settings()) ?? []
        await loadGallery(.myPhotos)
    }

    func refreshCurrentArt() async {
        guard let art, let item = try? await art.currentArtwork() else { return }
        currentArt = item
        await loadThumbnails([item.id])
    }

    func loadGallery(_ category: ArtCategory) async {
        guard let art else { return }
        do {
            let items = try await art.contentList()
            for group in ArtCategory.allCases {
                // The TV lists a piece once per category it's in; keep the first of each.
                var seen = Set<String>()
                let members = items.filter { group.contains($0) && seen.insert($0.id).inserted }
                gallery[group] = group == .recent ? members : members.sorted { ($0.date ?? "", $0.id) > ($1.date ?? "", $1.id) }
            }
            await loadThumbnails((gallery[category] ?? []).map(\.id))
        } catch {
            report(error)
        }
    }

    private func loadThumbnails(_ ids: [String]) async {
        guard let art, let host = prefs.host else { return }
        let cache = ImageCache(tv: host, kind: "art")
        var missing: [String] = []
        for id in NSOrderedSet(array: ids).array as? [String] ?? ids where thumbnails[id] == nil && !loadingThumbs.contains(id) {
            if let image = cache.image(id) { thumbnails[id] = image } else { missing.append(id) }
        }
        for start in stride(from: 0, to: missing.count, by: 6) {
            let batch = Array(missing[start..<min(start + 6, missing.count)])
            loadingThumbs.formUnion(batch)
            let files = try? await art.thumbnails(batch)
            loadingThumbs.subtract(batch)
            for (id, data) in files ?? [:] {
                let small = (try? ImagePrep.jpeg(from: data, maxPixels: 640)) ?? data
                cache.store(small, for: id)
                thumbnails[id] = NSImage(data: small)
            }
        }
    }

    func showArtwork(_ item: ArtItem) {
        guard let art else { return report(TVError.notConnected) }
        currentArt = item
        Task {
            do { try await art.select(item.id, categoryID: item.categoryID) } catch { report(error) }
        }
    }

    func deleteArtwork(_ item: ArtItem) {
        guard let art, let host = prefs.host else { return report(TVError.notConnected) }
        Task {
            do {
                try await art.delete([item.id])
                for category in ArtCategory.allCases { gallery[category]?.removeAll { $0.id == item.id } }
                thumbnails[item.id] = nil
                ImageCache(tv: host, kind: "art").remove(item.id)
                if currentArt?.id == item.id { await refreshCurrentArt() }
            } catch {
                report(error)
            }
        }
    }

    func setMatte(type: String, color: String) {
        guard let art, var item = currentArt else { return }
        let matte = type == "none" ? "none" : "\(type)_\(color)"
        item.matteID = matte
        currentArt = item
        Task {
            do { try await art.changeMatte(item.id, matte: matte) } catch { report(error) }
        }
    }

    func updateSlideshow(_ setting: SlideshowSetting) {
        guard let art else { return }
        slideshow = setting
        Task {
            do { try await art.setSlideshow(setting) } catch { report(error) }
        }
    }

    func setArtSetting(_ item: String, value: String) {
        if let index = artSettings.firstIndex(where: { $0.item == item }) { artSettings[index].value = value }
        settingWrites[item]?.cancel()
        settingWrites[item] = Task { [weak self] in
            try? await Task.sleep(seconds: 0.25)
            guard let self, !Task.isCancelled, let art = self.art else { return }
            do { try await art.set(item, value: Int(value) ?? value as Any) } catch { self.report(error) }
        }
    }

    func upload(_ urls: [URL]) {
        guard let art, let host = prefs.host else { return report(TVError.notConnected) }
        let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        guard !images.isEmpty else { return show("Choose JPEG, PNG or HEIC images.") }
        let cache = ImageCache(tv: host, kind: "art")
        Task {
            var lastID: String?
            for (index, url) in images.enumerated() {
                uploadState = .working(images.count > 1 ? "Uploading \(index + 1) of \(images.count)…" : "Uploading \(url.lastPathComponent)…")
                do {
                    let data = try ImagePrep.jpeg(from: url)
                    let id = try await art.upload(data, fileType: "jpg", matte: prefs.uploadMatte)
                    if let small = try? ImagePrep.jpeg(from: data, maxPixels: 640) {
                        cache.store(small, for: id)
                        thumbnails[id] = NSImage(data: small)
                    }
                    lastID = id
                } catch {
                    uploadState = .failed(error.localizedDescription)
                    return
                }
            }
            uploadState = .done(images.count == 1 ? "Added to My Photos" : "Added \(images.count) photos to My Photos")
            await loadGallery(.myPhotos)
            if prefs.showAfterUpload, let lastID {
                try? await art.select(lastID, categoryID: ArtCategory.myPhotos.rawValue)
                await refreshCurrentArt()
            }
        }
    }

    // MARK: - Presentation

    var isConnected: Bool { link == .connected }

    func title(for screen: Screen) -> String {
        switch screen {
        case .off: return "TV off"
        case .art: return "Art Mode"
        case .tv: return "TV on"
        case .app(_, let name): return name
        case .input(let port): return prefs.input(port).name
        }
    }

    var accent: Color {
        switch screen {
        case .art: return Theme.art
        case .app(let id, let name): return AppCatalog.brand(id: id, name: name).color
        default: return Theme.samsungBlue
        }
    }

    var menuBarSymbol: String {
        switch screen {
        case .off: return "tv"
        case .art: return "photo.artframe"
        default: return "tv.fill"
        }
    }

    var statusText: String {
        switch link {
        case .setup: return "Not set up"
        case .offline: return "TV unreachable"
        case .standby: return "Standby"
        case .needsPairing: return "Not paired"
        case .pairing: return "Waiting for Allow on the TV…"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .failed: return "Needs attention"
        }
    }

    var statusColor: Color {
        switch link {
        case .connected: return Theme.online
        case .pairing, .connecting, .standby: return Theme.warning
        case .needsPairing, .failed: return Color(hex: 0xFF453A)
        case .setup, .offline: return Theme.tertiary
        }
    }
}
