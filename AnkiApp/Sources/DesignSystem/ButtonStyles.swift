import SwiftUI

/// Filled, high-emphasis primary action button.
///
/// Stretches to fill its container width and guarantees a >= 44pt tap target.
struct DSPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(DS.Typography.headline)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: DS.minTapTarget)
                .padding(.horizontal, DS.Spacing.l)
                .background(
                    DS.accent.opacity(isEnabled ? 1 : 0.4),
                    in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                )
                .dsPressFeedback(configuration.isPressed, reduceMotion: reduceMotion)
        }
    }
}

/// Bordered, medium-emphasis secondary action button.
struct DSSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
            // Label uses textPrimary, not accent: accent is intentionally dark so
            // white-on-accent passes AA, which makes accent-colored text fail AA
            // against the dark surface. The accent border carries the accent identity.
            configuration.label
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
                .frame(maxWidth: .infinity, minHeight: DS.minTapTarget)
                .padding(.horizontal, DS.Spacing.l)
                .background(DS.surface, in: shape)
                .overlay(shape.strokeBorder(DS.accent, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.5)
                .dsPressFeedback(configuration.isPressed, reduceMotion: reduceMotion)
        }
    }
}

/// Filled review-rating button, tinted by one of the four `DS` rating colors.
/// Used by the reviewer's Again / Hard / Good / Easy row.
struct DSRatingButtonStyle: ButtonStyle {
    let color: Color

    init(_ color: Color) {
        self.color = color
    }

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(color: color, configuration: configuration)
    }

    private struct StyledLabel: View {
        let color: Color
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(DS.Typography.headline)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: DS.minTapTarget)
                .padding(.vertical, DS.Spacing.s)
                .padding(.horizontal, DS.Spacing.xs)
                .background(
                    color,
                    in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                )
                .opacity(isEnabled ? 1 : 0.5)
                .dsPressFeedback(configuration.isPressed, reduceMotion: reduceMotion)
        }
    }
}

// MARK: - Ergonomic accessors

extension ButtonStyle where Self == DSPrimaryButtonStyle {
    /// `.buttonStyle(.dsPrimary)`
    static var dsPrimary: DSPrimaryButtonStyle { DSPrimaryButtonStyle() }
}

extension ButtonStyle where Self == DSSecondaryButtonStyle {
    /// `.buttonStyle(.dsSecondary)`
    static var dsSecondary: DSSecondaryButtonStyle { DSSecondaryButtonStyle() }
}

extension ButtonStyle where Self == DSRatingButtonStyle {
    /// `.buttonStyle(.dsRating(DS.good))`
    static func dsRating(_ color: Color) -> DSRatingButtonStyle { DSRatingButtonStyle(color) }
}

// MARK: - Shared press feedback

private extension View {
    /// Subtle press affordance. Scaling is suppressed when Reduce Motion is on;
    /// the press state then changes instantly with no animation.
    @ViewBuilder
    func dsPressFeedback(_ isPressed: Bool, reduceMotion: Bool) -> some View {
        opacity(isPressed ? 0.9 : 1)
            .scaleEffect(reduceMotion ? 1 : (isPressed ? 0.98 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPressed)
    }
}
