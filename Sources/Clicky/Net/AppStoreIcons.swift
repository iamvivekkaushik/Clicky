import Foundation

/// App icons from Apple's public App Store lookup API, for TVs that won't hand out their own.
/// Only App Store ids (or, for apps not in the catalog, the app's name) leave the Mac.
enum AppStoreIcons {
    static func fetch(for apps: [TVApp]) async -> [String: Data] {
        var artwork: [String: URL] = [:]

        let known = apps.compactMap { app in AppCatalog.appStoreID(app.id).map { (appID: app.id, storeID: $0) } }
        if !known.isEmpty {
            let ids = Set(known.map(\.storeID)).map(String.init).joined(separator: ",")
            let results = (try? await query("lookup?id=\(ids)&entity=software")) ?? []
            for entry in known {
                if let result = results.first(where: { $0.int("trackId") == entry.storeID }), let url = artworkURL(result) {
                    artwork[entry.appID] = url
                }
            }
        }

        // Unknown apps: accept only a store title that matches the TV's name exactly.
        for app in apps where !AppCatalog.isKnown(app.id) {
            guard let term = app.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                  let results = try? await query("search?term=\(term)&entity=software&limit=10"),
                  let match = results.first(where: { baseName($0.string("trackName") ?? "") == baseName(app.name) }),
                  let url = artworkURL(match) else { continue }
            artwork[app.id] = url
        }

        return await withTaskGroup(of: (String, Data?).self) { group in
            for (appID, url) in artwork {
                group.addTask { (appID, try? await URLSession.shared.data(from: url).0) }
            }
            var icons: [String: Data] = [:]
            for await (appID, data) in group {
                if let data, !data.isEmpty { icons[appID] = data }
            }
            return icons
        }
    }

    private static func query(_ path: String) async throws -> [JSON] {
        guard let url = URL(string: "https://itunes.apple.com/\(path)") else { return [] }
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8))
        return (try JSONSerialization.jsonObject(with: data) as? JSON)?["results"] as? [JSON] ?? []
    }

    /// Store titles carry taglines ("Spotify: Music and Podcasts"); compare what comes before them.
    private static func baseName(_ title: String) -> String {
        var head = title
        for separator in [":", " - ", " – ", " | "] {
            head = head.components(separatedBy: separator).first ?? head
        }
        return head.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "+" }
    }

    private static func artworkURL(_ result: JSON) -> URL? {
        guard let string = result.string("artworkUrl512") else { return nil }
        return URL(string: string.replacingOccurrences(of: "512x512bb", with: "256x256bb"))
    }
}
