import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

enum Theme {
    static let background = Color(hex: 0x161618)
    static let card = Color.white.opacity(0.055)
    static let cardStroke = Color.white.opacity(0.07)
    static let control = Color.white.opacity(0.08)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.36)
    static let samsungBlue = Color(hex: 0x3D6BFF)
    static let art = Color(hex: 0xD6A35C)
    static let online = Color(hex: 0x34C759)
    static let warning = Color(hex: 0xFF9F0A)
}

struct AppBrand {
    let name: String
    let color: Color
    /// Short text shown on the tile when no icon is available.
    let mark: String
    /// The same app on Apple's App Store, used to fetch its icon.
    var appStoreID: Int? = nil
}

enum AppCatalog {
    private static let brands: [String: AppBrand] = [
        "111299001912": AppBrand(name: "YouTube", color: Color(hex: 0xFF0033), mark: "▶", appStoreID: 544007664),
        "3201907018807": AppBrand(name: "Netflix", color: Color(hex: 0xE50914), mark: "N", appStoreID: 363590051),
        "11101200001": AppBrand(name: "Netflix", color: Color(hex: 0xE50914), mark: "N", appStoreID: 363590051),
        "3201910019365": AppBrand(name: "Prime Video", color: Color(hex: 0x1A98FF), mark: "prime", appStoreID: 545519333),
        "3201512006785": AppBrand(name: "Prime Video", color: Color(hex: 0x1A98FF), mark: "prime", appStoreID: 545519333),
        "3201901017640": AppBrand(name: "Disney+", color: Color(hex: 0x1F5BFF), mark: "D+", appStoreID: 1446075923),
        "3201807016597": AppBrand(name: "Apple TV", color: Color(hex: 0x8E8E93), mark: "tv", appStoreID: 1174078549),
        "3201606009684": AppBrand(name: "Spotify", color: Color(hex: 0x1ED760), mark: "♫", appStoreID: 324684580),
        "3201512006963": AppBrand(name: "Plex", color: Color(hex: 0xE5A00D), mark: "▸", appStoreID: 383457673),
        // Found by scanning store ids on a 2022 Frame in India; JioHotstar is the renamed Disney+ Hotstar app.
        "3201711015117": AppBrand(name: "JioHotstar", color: Color(hex: 0x1F80E0), mark: "JH", appStoreID: 934459219),
        "3201709014748": AppBrand(name: "Sony LIV", color: Color(hex: 0x1A1A1A), mark: "LIV", appStoreID: 587794258),
        // Not in the store; sideloaded builds of jellyfin-tizen keep the id from its config.xml.
        "AprZAARz4r.Jellyfin": AppBrand(name: "Jellyfin", color: Color(hex: 0xAA5CC3), mark: "J", appStoreID: 1480192618),
        "3201601007625": AppBrand(name: "Hulu", color: Color(hex: 0x1CE783), mark: "hulu", appStoreID: 376510438),
        "3201601007230": AppBrand(name: "Max", color: Color(hex: 0x2B4BFF), mark: "max", appStoreID: 1666653815),
        "3201710015037": AppBrand(name: "Gallery", color: Color(hex: 0x3D6BFF), mark: "▦"),
        "org.tizen.browser": AppBrand(name: "Internet", color: Color(hex: 0x7B61FF), mark: "www"),
        "3202010022079": AppBrand(name: "Browser", color: Color(hex: 0x7B61FF), mark: "www"),
    ]

    /// Preferred order when picking default favorites from what's installed.
    static let popular = [
        "111299001912", "3201907018807", "3201910019365", "3201901017640",
        "3201807016597", "3201606009684", "3201512006963", "3201601007625",
    ]

    /// App ids probed over REST when the TV won't list its apps. Ids that aren't installed answer 404.
    static let candidates = popular + [
        "11101200001", "3201512006785", "3201601007230", "3201710015037", "org.tizen.browser",
        "3201611010983", "3201909019175", "3201804016269", "3201908019041", "3202010022079",
        "3201608010191", "3201802015295", "3201505002690", "3201907018784", "3201810017091",
        "AprZAARz4r.Jellyfin", "3201711015117", "3201709014748",
    ] + KnownApps.ids

    static func isKnown(_ id: String) -> Bool { brands[id] != nil }

    static func appStoreID(_ id: String) -> Int? { brands[id]?.appStoreID }

    static func brand(id: String, name: String) -> AppBrand {
        if let brand = brands[id] { return brand }
        let palette: [UInt32] = [0x5E5CE6, 0xFF375F, 0x30B0C7, 0xFF9F0A, 0x64D2FF, 0xBF5AF2, 0x32D74B]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let words = name.split(separator: " ").prefix(2)
        let mark = words.count > 1 ? words.compactMap(\.first).map(String.init).joined() : String(name.prefix(2))
        return AppBrand(name: name, color: Color(hex: palette[hash % palette.count]), mark: mark.uppercased())
    }
}

enum ArtCatalog {
    /// Used until the TV reports its own lists.
    static let matteTypes = ["none", "modernthin", "modern", "modernwide", "flexible", "shadowbox", "panoramic", "triptych", "mix", "squares"]
    static let matteColors = ["black", "neutral", "antique", "warm", "polar", "sand", "seafoam", "sage", "burgandy", "navy", "apricot", "byzantine", "lavender", "redorange", "skyblue", "turqoise"]

    static func title(_ raw: String) -> String {
        let names = [
            "none": "None", "modernthin": "Modern Thin", "modernwide": "Modern Wide", "shadowbox": "Shadow Box",
            "redorange": "Red Orange", "skyblue": "Sky Blue", "turqoise": "Turquoise", "burgandy": "Burgundy",
        ]
        return names[raw] ?? raw.prefix(1).uppercased() + raw.dropFirst()
    }

    static func split(_ matteID: String?) -> (type: String, color: String) {
        guard let matteID, matteID != "none" else { return ("none", "polar") }
        let parts = matteID.split(separator: "_", maxSplits: 1).map(String.init)
        return (parts.first ?? "none", parts.count > 1 ? parts[1] : "polar")
    }
}

struct InputConfig: Codable, Identifiable, Hashable {
    var port: Int
    var name: String
    var visible: Bool

    var id: Int { port }
    var label: String { "HDMI \(port)" }
    /// Named in Settings; only these get a tile next to the apps, like sources on the TV's home screen.
    var isNamed: Bool { name != label }

    var symbol: String {
        let lower = name.lowercased()
        if ["ps", "playstation", "xbox", "switch", "nintendo", "game", "console"].contains(where: lower.contains) { return "gamecontroller.fill" }
        if ["apple tv", "chromecast", "fire", "roku", "shield", "box"].contains(where: lower.contains) { return "tv.and.mediabox.fill" }
        if ["mac", "pc", "computer", "laptop"].contains(where: lower.contains) { return "desktopcomputer" }
        if ["sound", "bar", "receiver", "av"].contains(where: lower.contains) { return "hifispeaker.fill" }
        return "cable.connector.horizontal"
    }
}
