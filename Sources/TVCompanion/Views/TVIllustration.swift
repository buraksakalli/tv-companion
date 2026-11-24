import SwiftUI

/// Stylised 65" OLED on a low pedestal stand, drawn in code so it can reflect live state.
struct TVIllustration<ScreenOverlay: View>: View {
    enum Look: Equatable { case on, screenOff, off }
    let look: Look
    var width: CGFloat = 280
    @ViewBuilder var screenOverlay: () -> ScreenOverlay

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var screenSize: CGSize { CGSize(width: width, height: width * 9 / 16) }

    var body: some View {
        VStack(spacing: 0) {
            panel
            stand
        }
        .background(alignment: .center) { ambientGlow }
        .animation(.easeInOut(duration: 0.6), value: look)
        .accessibilityElement()
        .accessibilityLabel(look == .on ? "TV on" : look == .screenOff ? "TV screen off" : "TV off")
    }

    // MARK: Panel

    private var panel: some View {
        ZStack {
            // Near-invisible OLED bezel with a metallic edge highlight.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(white: 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.12), Color(white: 0.22)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
                )

            screen
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .padding(2)
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .shadow(color: .black.opacity(0.6), radius: 14, y: 8)
    }

    @ViewBuilder
    private var screen: some View {
        ZStack {
            Color.black
            if look == .on {
                aurora.transition(.opacity)
            }
            if look == .screenOff {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.18))
                    .transition(.opacity)
            }
            // Glass reflection, strongest when the panel is dark.
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(look == .on ? 0.05 : 0.16), location: 0),
                    .init(color: .white.opacity(look == .on ? 0.0 : 0.03), location: 0.38),
                    .init(color: .white.opacity(0.0), location: 0.39),
                    .init(color: .white.opacity(0.0), location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            .blendMode(.screen)
            screenOverlay()
        }
    }

    /// Slow-drifting colour field — reads as "OLED on" without pretending to show content.
    private var aurora: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [Color(red: 0.03, green: 0.02, blue: 0.08), .black]),
                                               startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
                ctx.addFilter(.blur(radius: size.width * 0.09))
                let blobs: [(Color, Double, Double, Double)] = [
                    (Color(red: 0.45, green: 0.22, blue: 0.95), 0.30, 0.45, 0.00),
                    (Color(red: 0.95, green: 0.25, blue: 0.55), 0.68, 0.35, 2.10),
                    (Color(red: 0.10, green: 0.70, blue: 0.85), 0.55, 0.75, 4.20),
                ]
                for (color, bx, by, phase) in blobs {
                    let x = size.width * (bx + 0.10 * sin(t * 0.21 + phase))
                    let y = size.height * (by + 0.12 * cos(t * 0.17 + phase))
                    let r = size.width * 0.26
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r * 0.8, width: r * 2, height: r * 1.6)),
                             with: .color(color.opacity(0.85)))
                }
            }
        }
    }

    // MARK: Stand + glow

    private var stand: some View {
        VStack(spacing: 0) {
            // Neck
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.10)], startPoint: .top, endPoint: .bottom)
                .frame(width: width * 0.07, height: 10)
            // Low pedestal base
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                .frame(width: width * 0.34, height: 6)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        }
    }

    /// Soft light spill behind the panel; the gradient fades out well inside its frame,
    /// so there's never a visible edge.
    private var ambientGlow: some View {
        Circle()
            .fill(RadialGradient(
                stops: [
                    .init(color: Color(red: 0.55, green: 0.32, blue: 0.95).opacity(0.38), location: 0),
                    .init(color: Color(red: 0.75, green: 0.3, blue: 0.7).opacity(0.14), location: 0.45),
                    .init(color: .clear, location: 1),
                ],
                center: .center, startRadius: 0, endRadius: width * 0.62))
            .frame(width: width * 1.24, height: width * 1.24)
            .scaleEffect(x: 1, y: 0.5)
            .offset(y: width * 0.04)
            .opacity(look == .on ? 1 : 0)
            .allowsHitTesting(false)
    }
}

extension TVIllustration where ScreenOverlay == EmptyView {
    init(look: Look, width: CGFloat = 280) {
        self.init(look: look, width: width) { EmptyView() }
    }
}
