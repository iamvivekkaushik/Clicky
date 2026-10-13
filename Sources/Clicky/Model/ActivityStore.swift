import Foundation

/// Screen time as observed by this Mac: seconds per day per thing on screen.
/// Keys are "art", "tv", "app:<appId>" or "input:<port>".
@MainActor
final class ActivityStore: ObservableObject {
    private struct Snapshot: Codable {
        var days: [String: [String: Double]]
        var names: [String: String]
    }

    @Published private(set) var days: [String: [String: Double]] = [:]
    @Published private(set) var names: [String: String] = [:]

    private let url: URL
    private var saveTask: Task<Void, Never>?

    init(url: URL = ActivityStore.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            days = snapshot.days
            names = snapshot.names
        }
    }

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clicky", isDirectory: true).appendingPathComponent("activity.json")
    }

    func add(key: String, name: String, seconds: Double, at date: Date = Date()) {
        guard seconds > 0 else { return }
        days[Self.dayKey(date), default: [:]][key, default: 0] += seconds
        if names[key] != name { names[key] = name }
        scheduleSave()
    }

    /// Totals per key over the last `count` days including today, largest first.
    func totals(days count: Int, now: Date = Date()) -> [(key: String, seconds: Double)] {
        var sums: [String: Double] = [:]
        for day in Self.dayKeys(count, now: now) {
            for (key, seconds) in days[day] ?? [:] { sums[key, default: 0] += seconds }
        }
        return sums.map { ($0.key, $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    func daily(days count: Int, now: Date = Date()) -> [(date: Date, seconds: Double)] {
        let calendar = Calendar.current
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) else { return nil }
            return (date, (days[Self.dayKey(date)] ?? [:]).values.reduce(0, +))
        }
    }

    func flush() {
        saveTask?.cancel()
        write()
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(seconds: 60)
            self?.write()
            self?.saveTask = nil
        }
    }

    private func write() {
        let cutoff = Self.dayKey(Calendar.current.date(byAdding: .day, value: -60, to: Date()) ?? Date())
        days = days.filter { $0.key >= cutoff }
        guard let data = try? JSONEncoder().encode(Snapshot(days: days, names: names)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func dayKeys(_ count: Int, now: Date) -> [String] {
        (0..<count).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: now).map(dayKey) }
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
