import Charts
import SwiftUI

struct ActivityView: View {
    @ObservedObject var tv: TVController
    @ObservedObject var activity: ActivityStore
    @State private var period = 1
    @Environment(\.accent) private var accent

    var body: some View {
        let totals = activity.totals(days: period)
        let total = totals.reduce(0) { $0 + $1.seconds }
        VStack(spacing: 10) {
            SectionLabel(text: "Activity")
            HStack {
                Text("Period").font(.system(size: 12)).foregroundColor(Theme.secondary)
                PillPicker(options: [(1, "Today"), (7, "7 days"), (30, "30 days")], selection: $period)
                Spacer()
            }
            Card(tint: accent) {
                Text("SCREEN TIME")
                    .font(.system(size: 9.5, weight: .bold))
                    .kerning(1)
                    .foregroundColor(Theme.secondary)
                Text(Self.format(total))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(accent)
                Caption("Apps, inputs and Art Mode seen by your Mac")
            }
            if period > 1 {
                Card {
                    CardHeader(symbol: "chart.bar.fill", title: "Per day")
                    Chart(activity.daily(days: period), id: \.date) { day in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Hours", day.seconds / 3600))
                            .foregroundStyle(accent.gradient)
                            .cornerRadius(2)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                            AxisValueLabel { Text("\(value.as(Double.self).map { String(format: "%.0fh", $0) } ?? "")").font(.system(size: 9)) }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: period > 7 ? 7 : 1)) { _ in
                            AxisValueLabel(format: period > 7 ? .dateTime.day().month(.abbreviated) : .dateTime.weekday(.narrow))
                                .font(.system(size: 9))
                        }
                    }
                    .frame(height: 110)
                }
            }
            Card {
                if totals.isEmpty {
                    Text("Nothing yet. Time is counted while this Mac is awake and the TV is on.")
                        .font(.system(size: 11.5))
                        .foregroundColor(Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                } else {
                    let longest = totals.first?.seconds ?? 1
                    ForEach(totals.prefix(12), id: \.key) { entry in
                        row(entry.key, seconds: entry.seconds, longest: longest)
                    }
                }
            }
            Caption("Tracked locally while your Mac is awake and on the same network as the TV.")
                .padding(.horizontal, 2)
        }
    }

    private func row(_ key: String, seconds: Double, longest: Double) -> some View {
        let name = activity.names[key] ?? key
        let color = color(for: key, name: name)
        return VStack(spacing: 5) {
            HStack(spacing: 9) {
                icon(for: key, name: name, color: color)
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Text(Self.format(seconds)).font(.system(size: 11)).foregroundColor(Theme.secondary).monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(color).frame(width: max(4, geometry.size.width * seconds / max(longest, 1)))
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func icon(for key: String, name: String, color: Color) -> some View {
        if key.hasPrefix("app:") {
            let id = String(key.dropFirst(4))
            AppTile(id: id, name: name, icon: tv.icons[id], size: 24)
        } else if key == "art" {
            SymbolTile(symbol: "photo.artframe", color: color, size: 24)
        } else if key.hasPrefix("input:"), let port = Int(key.dropFirst(6)) {
            SymbolTile(symbol: tv.prefs.input(port).symbol, color: color, size: 24)
        } else {
            SymbolTile(symbol: "tv", color: color, size: 24)
        }
    }

    private func color(for key: String, name: String) -> Color {
        if key.hasPrefix("app:") { return AppCatalog.brand(id: String(key.dropFirst(4)), name: name).color }
        if key == "art" { return Theme.art }
        if key.hasPrefix("input:") { return Theme.samsungBlue }
        return Color(hex: 0x8E8E93)
    }

    static func format(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return seconds >= 1 ? "\(Int(seconds)) s" : "0 min" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
