import SwiftUI

/// The EKI family look (same palette as STEMEKI).
enum Theme {
    static let bg = Color(red: 0.055, green: 0.058, blue: 0.072)
    static let panel = Color(red: 0.085, green: 0.089, blue: 0.108)
    static let panel2 = Color(red: 0.115, green: 0.12, blue: 0.145)
    static let line = Color.white.opacity(0.07)
    static let text = Color(red: 0.86, green: 0.87, blue: 0.92)
    static let dim = Color(red: 0.52, green: 0.54, blue: 0.62)
    static let loop = Color(red: 1.0, green: 0.84, blue: 0.04)
    static let accent = Color(red: 0.27, green: 0.85, blue: 0.98)
    /// The glowing blue of the active side of a mode switch.
    static let active = Color(red: 0.16, green: 0.47, blue: 1.0)

    static let pink = Color(red: 1.0, green: 0.36, blue: 0.54)
    static let orange = Color(red: 1.0, green: 0.66, blue: 0.13)
    static let green = Color(red: 0.24, green: 0.86, blue: 0.59)
    static let blue = Color(red: 0.36, green: 0.66, blue: 1.0)
    static let violet = Color(red: 0.62, green: 0.49, blue: 1.0)

    static let bands = [pink, orange, green, blue]

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// A clearly different colour for each chord root.
    static func chordColor(_ root: Int?) -> Color {
        guard let root else { return dim.opacity(0.4) }
        let hue = (Double(root) / 12.0 + 0.97).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: 0.6, brightness: 0.97)
    }
}

func formatTime(_ t: Double, hundredths: Bool = true) -> String {
    let t = max(0, t)
    let m = Int(t) / 60
    let s = t - Double(m * 60)
    return hundredths ? String(format: "%d:%05.2f", m, s) : String(format: "%d:%02d", m, Int(s))
}

func formatBPM(_ bpm: Double) -> String {
    abs(bpm - bpm.rounded()) < 0.05 ? String(format: "%.0f", bpm) : String(format: "%.1f", bpm)
}

// MARK: - Shared controls

struct PillButtonStyle: ButtonStyle {
    var color: Color = Theme.text
    var filled = false
    var active = false
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: small ? 10.5 : 11.5, weight: .bold))
            .foregroundColor(filled || active ? .black : color)
            .padding(.horizontal, small ? 7 : 11)
            .frame(minHeight: small ? 22 : 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(filled || active ? color : Theme.panel2)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(filled || active ? 0 : 0.07)))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

struct DisabledDim: ViewModifier {
    @Environment(\.isEnabled) var enabled
    func body(content: Content) -> some View { content.opacity(enabled ? 1 : 0.35) }
}

struct Card<Content: View>: View {
    let title: String
    var accent: Color = Theme.dim
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 9.5, weight: .heavy)).tracking(1.2).foregroundColor(accent).fixedSize()
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(Theme.mono(9.5, .semibold)).foregroundColor(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.13)))
    }
}

/// "BPM 125" in the header: small label, coloured mono value.
struct Stat: View {
    let label: String
    let value: String
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9.5, weight: .heavy)).tracking(0.8).foregroundColor(Theme.dim)
            Text(value).font(Theme.mono(12, .semibold)).foregroundColor(color)
        }
        .fixedSize()
    }
}

/// The rainbow progress bar of the EKI apps.
struct BandProgress: View {
    let fraction: Double
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(LinearGradient(colors: Theme.bands, startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width * CGFloat(max(0, min(1, fraction))))
            }
        }
        .frame(height: height)
    }
}
