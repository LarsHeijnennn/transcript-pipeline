import SwiftUI

enum AppStyle {
    static let compactRadius: CGFloat = 12
    static let cardRadius: CGFloat = 18
    static let floatingRadius: CGFloat = 22
    static let pageWidth: CGFloat = 920
    static let controlSpacing: CGFloat = 10
}

struct AppCanvas: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [Color.accentColor.opacity(0.10), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 680
            )
            RadialGradient(
                colors: [Color.purple.opacity(0.055), .clear],
                center: .bottomLeading,
                startRadius: 30,
                endRadius: 620
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    @ViewBuilder
    func functionalGlass(
        cornerRadius: CGFloat = AppStyle.floatingRadius,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                .regular.tint(tint).interactive(interactive),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.08), radius: 16, y: 7)
        }
    }

    func contentSurface(
        cornerRadius: CGFloat = AppStyle.cardRadius,
        tint: Color? = nil
    ) -> some View {
        self
            .background {
                ZStack {
                    Color(nsColor: .controlBackgroundColor).opacity(0.76)
                    if let tint { tint.opacity(0.055) }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.075), lineWidth: 0.7)
            }
    }

    @ViewBuilder
    func liquidGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    func glassControlPlate(
        cornerRadius: CGFloat = AppStyle.compactRadius,
        tint: Color? = nil,
        horizontalPadding: CGFloat = 8,
        verticalPadding: CGFloat = 5
    ) -> some View {
        if #available(macOS 26.0, *) {
            self
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .glassEffect(
                    .clear.tint(tint).interactive(),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            self
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.13), lineWidth: 0.6)
                }
        }
    }
}

struct LiquidGlassGroup<Content: View>: View {
    let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = AppStyle.controlSpacing, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

struct StatusPill: View {
    let title: String
    let symbol: String
    var color: Color = .secondary

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .functionalGlass(cornerRadius: 99, tint: color.opacity(0.14))
            .accessibilityElement(children: .combine)
    }
}

struct SymbolBadge: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.31, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct ModernSectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
