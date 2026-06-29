#if DEBUG
import SwiftUI

/// Visual gallery that exercises every design-system token and component so the
/// palette, button styles, card, and stat rows can be verified in Xcode's canvas.
private struct DesignSystemGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                Text("Design System")
                    .font(DS.Typography.title)
                    .foregroundStyle(DS.textPrimary)

                VStack(spacing: DS.Spacing.s) {
                    Button("Primary action") {}
                        .buttonStyle(.dsPrimary)
                    Button("Secondary action") {}
                        .buttonStyle(.dsSecondary)
                }

                HStack(spacing: DS.Spacing.s) {
                    Button("Again") {}.buttonStyle(.dsRating(DS.again))
                    Button("Hard") {}.buttonStyle(.dsRating(DS.hard))
                    Button("Good") {}.buttonStyle(.dsRating(DS.good))
                    Button("Easy") {}.buttonStyle(.dsRating(DS.easy))
                }

                VStack(spacing: DS.Spacing.xs) {
                    DSStatRow("New", value: "12")
                    DSStatRow("Learning", value: "3")
                    DSStatRow("Review", value: "108")
                }
                .dsCard()
            }
            .padding(DS.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.background)
    }
}

#Preview("Light") {
    DesignSystemGallery()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DesignSystemGallery()
        .preferredColorScheme(.dark)
}
#endif
