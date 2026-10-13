import SwiftUI

private struct AccentKey: EnvironmentKey {
    static let defaultValue = Theme.samsungBlue
}

extension EnvironmentValues {
    var accent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.map { $0.opacity(0.12) } ?? Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.map { $0.opacity(0.18) } ?? Theme.cardStroke)
            )
    }
}

struct CardHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            trailing
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(symbol: String, title: String) {
        self.init(symbol: symbol, title: title) { EmptyView() }
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .kerning(1.1)
            .foregroundColor(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 2)
    }
}

struct Caption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundColor(Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Plain button with a hover/press highlight, used everywhere instead of the system bezel.
struct PadButtonStyle: ButtonStyle {
    var shape: AnyShape = AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    var fill: Color = Theme.control

    func makeBody(configuration: Configuration) -> some View {
        PadButton(configuration: configuration, shape: shape, fill: fill)
    }

    private struct PadButton: View {
        let configuration: Configuration
        let shape: AnyShape
        let fill: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .contentShape(shape)
                .background(shape.fill(fill))
                .overlay(shape.fill(Color.white.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0)).allowsHitTesting(false))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 34
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(PadButtonStyle(shape: AnyShape(Circle())))
        .help(help)
    }
}

struct WideButton: View {
    let symbol: String
    let title: String
    var prominent = false
    let action: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(prominent ? .white : .primary)
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(PadButtonStyle(fill: prominent ? accent.opacity(0.85) : Theme.control))
    }
}

/// Accent-filled slider in the style of the TV's own OSD.
struct AccentSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var step: Double = 1
    var onCommit: (Double) -> Void = { _ in }
    @Environment(\.accent) private var accent
    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? CGFloat((value - range.lowerBound) / span) : 0
            let knob: CGFloat = 14
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 4)
                Capsule().fill(accent).frame(width: max(knob / 2, fraction * width), height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .scaleEffect(dragging ? 1.15 : 1)
                    .offset(x: min(max(0, fraction * width - knob / 2), width - knob))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        let raw = range.lowerBound + Double(min(max(0, drag.location.x / width), 1)) * span
                        let stepped = (raw / step).rounded() * step
                        if stepped != value {
                            value = stepped
                            onCommit(stepped)
                        }
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.1), value: dragging)
    }
}

/// Segmented control with a filled accent pill.
struct PillPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? .white : Theme.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(selected ? accent.opacity(0.9) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.control))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// App icon from the TV when available, otherwise a brand-colored tile.
struct AppTile: View {
    let id: String
    let name: String
    var icon: NSImage?
    var size: CGFloat = 44

    var body: some View {
        let brand = AppCatalog.brand(id: id, name: name)
        ZStack {
            if let icon {
                Image(nsImage: icon).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(LinearGradient(colors: [brand.color, brand.color.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(brand.mark)
                    .font(.system(size: size * (brand.mark.count > 3 ? 0.24 : brand.mark.count > 1 ? 0.3 : 0.42), weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.5)
                    .padding(4)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }
}

struct SymbolTile: View {
    let symbol: String
    var color: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundColor(color)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(color.opacity(0.16)))
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 6

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: 3)
    }
}

/// Switch tinted with the app's accent. Native switches turn gray here because the
/// menu bar popover never belongs to the active app.
struct AccentSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentSwitch(configuration: configuration)
    }

    private struct AccentSwitch: View {
        let configuration: Configuration
        @Environment(\.accent) private var accent
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            HStack(spacing: 8) {
                configuration.label
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? accent : Color.white.opacity(0.16))
                    Circle()
                        .fill(Color.white)
                        .padding(2)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                }
                .frame(width: 32, height: 19)
                .contentShape(Capsule())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
                }
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(configuration.isOn ? "On" : "Off")
            }
            .opacity(enabled ? 1 : 0.4)
        }
    }
}

struct AccentCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentCheckbox(configuration: configuration)
    }

    private struct AccentCheckbox: View {
        let configuration: Configuration
        @Environment(\.accent) private var accent
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(configuration.isOn ? accent : Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color.white.opacity(configuration.isOn ? 0 : 0.25))
                        )
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .opacity(configuration.isOn ? 1 : 0)
                        )
                        .frame(width: 14, height: 14)
                    configuration.label
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.4)
        }
    }
}
