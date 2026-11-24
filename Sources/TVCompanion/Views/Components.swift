import AppKit
import SwiftUI

enum Theme {
    static let background = Color(red: 0.03, green: 0.028, blue: 0.04)
    static let surface = Color.white.opacity(0.05)
    static let surfaceHover = Color.white.opacity(0.085)
    static let hairline = Color.white.opacity(0.07)
    static let primary = Color.white.opacity(0.95)
    static let secondary = Color.white.opacity(0.5)
    static let tertiary = Color.white.opacity(0.26)
    static let live = Color(red: 0.36, green: 0.88, blue: 0.58)
    static let warn = Color(red: 1.0, green: 0.45, blue: 0.4)
    static let spring = Animation.spring(duration: 0.45, bounce: 0.2)

    static let violet = Color(red: 0.56, green: 0.38, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.36, blue: 0.62)
    static let amber = Color(red: 1.0, green: 0.64, blue: 0.32)
    static let accent = LinearGradient(colors: [violet, pink, amber], startPoint: .leading, endPoint: .trailing)

    static func number(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
}

/// Subtle press feedback used by every custom control.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}

struct CardBackground: ViewModifier {
    var radius: CGFloat = 16
    var highlighted = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hovering ? Theme.surfaceHover : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(highlighted ? AnyShapeStyle(Theme.accent.opacity(0.7)) : AnyShapeStyle(Theme.hairline),
                                  lineWidth: highlighted ? 1.2 : 1)
            )
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

extension View {
    func card(radius: CGFloat = 16, highlighted: Bool = false) -> some View {
        modifier(CardBackground(radius: radius, highlighted: highlighted))
    }
}

struct CircleIconButton: View {
    let systemImage: String
    var size: CGFloat = 40
    var tint: Color = Theme.primary
    var glow: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(hovering ? Theme.surfaceHover : Theme.surface))
                .overlay(Circle().strokeBorder(glow?.opacity(0.6) ?? Theme.hairline, lineWidth: glow == nil ? 1 : 1.5))
                .shadow(color: glow?.opacity(0.4) ?? .clear, radius: 10)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

// MARK: - Volume dial

/// 270° arc dial. Two-finger scroll or vertical drag changes the value; tap the centre to mute.
struct VolumeDial: View {
    let value: Int?          // nil = unknown/external speaker
    let muted: Bool
    let enabled: Bool
    let onChange: (Int) -> Void
    let onToggleMute: () -> Void

    @State private var hovering = false
    @State private var dragStart: Int?
    @State private var scrollRemainder: Double = 0
    @State private var monitor: Any?
    // The event monitor closure outlives this struct value, so it reads live values from @State.
    @State private var liveValue: Int?
    @State private var liveEnabled = false

    private let start = 135.0, sweep = 270.0
    private var fraction: Double { Double(value ?? 0) / 100 }

    var body: some View {
        ZStack {
            // Ticks
            ForEach(0..<28) { i in
                let angle = start + sweep * Double(i) / 27
                let lit = Double(i) / 27 <= fraction && value != nil && !muted && enabled
                Capsule()
                    .fill(lit ? Color.white.opacity(0.5) : Color.white.opacity(0.1))
                    .frame(width: 1.5, height: i % 3 == 0 ? 7 : 4)
                    .offset(y: -76)
                    .rotationEffect(.degrees(angle + 90))
            }
            // Track
            Circle()
                .trim(from: 0, to: sweep / 360)
                .stroke(Color.white.opacity(0.07), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(start))
                .frame(width: 128, height: 128)
            // Fill
            Circle()
                .trim(from: 0, to: sweep / 360 * fraction)
                .stroke(
                    AngularGradient(colors: [Theme.violet, Theme.pink, Theme.amber],
                                    center: .center, startAngle: .degrees(0), endAngle: .degrees(sweep)),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(start))
                .frame(width: 128, height: 128)
                .saturation(muted || !enabled ? 0 : 1)
                .opacity(muted || !enabled ? 0.35 : 1)
                .shadow(color: Theme.pink.opacity(muted || !enabled ? 0 : 0.45), radius: 8)
            // Centre
            Button(action: onToggleMute) {
                VStack(spacing: 0) {
                    Text(centerText)
                        .font(Theme.number(value == nil || !enabled ? 26 : 40))
                        .monospacedDigit()
                        .foregroundStyle(muted ? Theme.tertiary : Theme.primary)
                        .contentTransition(.numericText(value: Double(value ?? 0)))
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(muted ? Theme.warn : Theme.secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 96, height: 96)
                .background(Circle().fill(hovering ? Theme.surfaceHover : Theme.surface))
                .overlay(Circle().strokeBorder(Theme.hairline))
                .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help(muted ? "Unmute" : "Mute")
        }
        .frame(width: 168, height: 168)
        .contentShape(Circle())
        .animation(.snappy(duration: 0.18), value: value)
        .animation(Theme.spring, value: muted)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { g in
                    guard enabled, let v = value else { return }
                    if dragStart == nil { dragStart = v }
                    onChange(min(max((dragStart ?? v) + Int(-g.translation.height / 2.5), 0), 100))
                }
                .onEnded { _ in dragStart = nil }
        )
        .onAppear { liveValue = value; liveEnabled = enabled; installScrollMonitor() }
        .onChange(of: value) { _, v in liveValue = v }
        .onChange(of: enabled) { _, e in liveEnabled = e }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        .opacity(enabled ? 1 : 0.5)
    }

    private var centerText: String {
        guard enabled else { return "Off" }
        return value.map(String.init) ?? "Ext"
    }

    /// Two-finger scroll over the dial changes volume (fingers up = louder, either scroll direction setting).
    private func installScrollMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard hovering, liveEnabled, let v = liveValue else { return event }
            let raw = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            scrollRemainder += event.hasPreciseScrollingDeltas ? raw / 6 : raw
            let steps = Int(scrollRemainder.rounded(.towardZero))
            if steps != 0 {
                scrollRemainder -= Double(steps)
                let next = min(max(v + steps, 0), 100)
                liveValue = next
                onChange(next)
            }
            return nil
        }
    }
}

// MARK: - Action row + chips

struct ActionRow: View {
    let systemImage: String
    let title: String
    let trailing: String?
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.secondary))
                    .frame(width: 18)
                    .symbolEffect(.bounce, value: active)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.tertiary)
                }
                Circle()
                    .fill(active ? Theme.live : Color.white.opacity(0.14))
                    .frame(width: 6, height: 6)
                    .shadow(color: active ? Theme.live : .clear, radius: 4)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .card(radius: 13, highlighted: active)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct InputChip: View {
    let label: String
    let selected: Bool
    let isMac: Bool
    let connected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isMac { Image(systemName: "laptopcomputer").font(.system(size: 10, weight: .semibold)) }
                Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(selected ? Color.black.opacity(0.85) : (connected ? Theme.primary : Theme.tertiary))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                if selected {
                    Capsule().fill(Theme.accent)
                } else {
                    Capsule().fill(hovering ? Theme.surfaceHover : Theme.surface)
                }
            }
            .overlay(Capsule().strokeBorder(selected ? .clear : Theme.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}
