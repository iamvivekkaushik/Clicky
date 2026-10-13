import Foundation

/// One saved TV and everything Clicky keeps for it.
struct TVProfile: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var host: String?
    /// Pairing token issued by the TV for this client.
    var token: String?
    var macAddress: String?
    /// Empty until the TV is reached; it then takes the TV's own name.
    var roomName = ""
    var favorites = Array(AppCatalog.popular.prefix(4))
    var favoritesCustomized = false
    /// Left out of the Apps tab. The TV reports some preinstalled apps it never shows on its own home screen.
    var hiddenApps: [String] = []
    var inputs = (1...4).map { InputConfig(port: $0, name: "HDMI \($0)", visible: true) }
    /// Input chosen from this app; the TV doesn't report its current source locally.
    var lastInput: Int?

    var displayName: String { roomName.isEmpty ? host ?? "New TV" : roomName }
}

/// Clicky used to be called FrameTV, and an early Clicky build kept its data under `dev.clicky`. Whatever an
/// earlier build left behind moves over on first launch; old settings domains are left as they were.
private enum LegacyNames {
    static func migrate(into store: UserDefaults) {
        if store.object(forKey: "tvs") == nil,
           let old = ["dev.clicky", "dev.frametv"].lazy.compactMap({ UserDefaults.standard.persistentDomain(forName: $0) }).first {
            for (key, value) in old { store.set(value, forKey: key) }
        }
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let moves = [
            ([support.appendingPathComponent("FrameTV")], support.appendingPathComponent("Clicky")),
            ([caches.appendingPathComponent("dev.clicky"), caches.appendingPathComponent("dev.frametv")], ImageCache.root),
        ]
        for (olds, new) in moves where !files.fileExists(atPath: new.path) {
            guard let old = olds.first(where: { files.fileExists(atPath: $0.path) }) else { continue }
            try? files.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? files.moveItem(at: old, to: new)
        }
    }
}

/// Persisted settings. Shared by the app and the `--probe` command line mode.
///
/// The per-TV properties mirror the active profile in `tvs`, so the rest of the app reads a single TV;
/// writing one updates that profile.
@MainActor
final class Preferences: ObservableObject {
    static let store: UserDefaults = {
        // Not the bundle id itself: the --probe binary has no bundle and must read the same domain.
        let store = UserDefaults(suiteName: "com.vivekkaushik.clicky.settings") ?? .standard
        LegacyNames.migrate(into: store)
        return store
    }()

    @Published private(set) var tvs: [TVProfile]
    @Published private(set) var activeID: String

    @Published var host: String? { didSet { edit { $0.host = host } } }
    @Published var token: String? { didSet { edit { $0.token = token } } }
    @Published var macAddress: String? { didSet { edit { $0.macAddress = macAddress } } }
    @Published var roomName: String { didSet { edit { $0.roomName = roomName } } }
    @Published var favorites: [String] { didSet { edit { $0.favorites = favorites } } }
    @Published var favoritesCustomized: Bool { didSet { edit { $0.favoritesCustomized = favoritesCustomized } } }
    @Published var hiddenApps: [String] { didSet { edit { $0.hiddenApps = hiddenApps } } }
    @Published var inputs: [InputConfig] { didSet { edit { $0.inputs = inputs } } }
    @Published var lastInput: Int? { didSet { edit { $0.lastInput = lastInput } } }

    @Published var uploadMatte: String { didSet { save(uploadMatte, "uploadMatte") } }
    @Published var showAfterUpload: Bool { didSet { save(showAfterUpload, "showAfterUpload") } }

    private var loading = false

    init() {
        let store = Self.store
        var tvs = store.data(forKey: "tvs").flatMap { try? JSONDecoder().decode([TVProfile].self, from: $0) } ?? []
        if tvs.isEmpty { tvs = [Self.migrateSingleTV(store)] }
        let active = store.string(forKey: "activeTV").flatMap { id in tvs.first { $0.id == id } } ?? tvs[0]
        self.tvs = tvs
        activeID = active.id
        host = active.host
        token = active.token
        macAddress = active.macAddress
        roomName = active.roomName
        favorites = active.favorites
        favoritesCustomized = active.favoritesCustomized
        hiddenApps = active.hiddenApps
        inputs = active.inputs
        lastInput = active.lastInput
        uploadMatte = store.string(forKey: "uploadMatte") ?? "none"
        showAfterUpload = store.object(forKey: "showAfterUpload") as? Bool ?? true
        persist()
    }

    /// Settings from before Clicky kept more than one TV become the first profile.
    private static func migrateSingleTV(_ store: UserDefaults) -> TVProfile {
        var profile = TVProfile()
        profile.host = store.string(forKey: "host")
        profile.token = store.string(forKey: "token")
        profile.macAddress = store.string(forKey: "macAddress")
        profile.roomName = store.string(forKey: "roomName") ?? (profile.host == nil ? "" : "Living Room")
        if let favorites = store.stringArray(forKey: "favorites") { profile.favorites = favorites }
        profile.favoritesCustomized = store.bool(forKey: "favoritesCustomized")
        profile.hiddenApps = store.stringArray(forKey: "hiddenApps") ?? []
        if let inputs = store.data(forKey: "inputs").flatMap({ try? JSONDecoder().decode([InputConfig].self, from: $0) }) {
            profile.inputs = inputs
        }
        profile.lastInput = store.object(forKey: "lastInput") as? Int
        if let apps = store.data(forKey: "apps") { store.set(apps, forKey: "apps.\(profile.id)") }
        for key in ["host", "token", "macAddress", "roomName", "favorites", "favoritesCustomized", "hiddenApps", "inputs", "lastInput", "apps"] {
            store.removeObject(forKey: key)
        }
        return profile
    }

    /// UserDefaults key for the active TV's cached app list.
    var appsKey: String { "apps.\(activeID)" }

    var active: TVProfile { tvs.first { $0.id == activeID } ?? TVProfile() }

    /// Makes another saved TV active. A TV that was never set up is dropped when you leave it.
    func select(_ id: String) {
        guard let profile = tvs.first(where: { $0.id == id }) else { return }
        tvs.removeAll { $0.host == nil && $0.id != id }
        activeID = id
        loading = true
        host = profile.host
        token = profile.token
        macAddress = profile.macAddress
        roomName = profile.roomName
        favorites = profile.favorites
        favoritesCustomized = profile.favoritesCustomized
        hiddenApps = profile.hiddenApps
        inputs = profile.inputs
        lastInput = profile.lastInput
        loading = false
        persist()
    }

    /// Adds an empty TV and makes it active; the app then shows setup for it.
    func addTV() {
        if active.host == nil { return }
        let profile = TVProfile()
        tvs.append(profile)
        select(profile.id)
    }

    /// Removes the active TV. The last one is cleared instead, so there's always one.
    func forgetTV() {
        Self.store.removeObject(forKey: appsKey)
        if let other = tvs.first(where: { $0.id != activeID && $0.host != nil }) {
            tvs.removeAll { $0.id == activeID }
            select(other.id)
        } else {
            resetConnection()
        }
    }

    /// Clears what belongs to the TV at the old address, for when the active profile points at a new one.
    func resetConnection() {
        Self.store.removeObject(forKey: appsKey)
        host = nil
        token = nil
        macAddress = nil
        lastInput = nil
    }

    func input(_ port: Int) -> InputConfig {
        inputs.first { $0.port == port } ?? InputConfig(port: port, name: "HDMI \(port)", visible: true)
    }

    func toggleFavorite(_ appID: String) {
        if favorites.contains(appID) {
            favorites.removeAll { $0 == appID }
        } else {
            favorites.append(appID)
        }
        favoritesCustomized = true
    }

    /// Favorites are kept, only not shown, so unhiding brings a hidden favorite back.
    func toggleHidden(_ appID: String) {
        if hiddenApps.contains(appID) {
            hiddenApps.removeAll { $0 == appID }
        } else {
            hiddenApps.append(appID)
        }
    }

    var visibleFavorites: [String] { favorites.filter { !hiddenApps.contains($0) } }

    private func edit(_ change: (inout TVProfile) -> Void) {
        guard !loading, let index = tvs.firstIndex(where: { $0.id == activeID }) else { return }
        change(&tvs[index])
        persist()
    }

    private func persist() {
        save(try? JSONEncoder().encode(tvs), "tvs")
        save(activeID, "activeTV")
    }

    private func save(_ value: Any?, _ key: String) {
        if let value { Self.store.set(value, forKey: key) } else { Self.store.removeObject(forKey: key) }
    }
}
