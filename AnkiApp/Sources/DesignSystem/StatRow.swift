import SwiftUI

/// A title-on-the-left, value-on-the-right row for displaying a single statistic.
///
/// The value uses `.monospacedDigit()` so that changing numbers (e.g. live review
/// counts) never shift the layout horizontally.
struct DSStatRow: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Text(title)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textSecondary)
            Spacer(minLength: DS.Spacing.s)
            Text(value)
                .font(DS.Typography.body)
                .monospacedDigit()
                .foregroundStyle(DS.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}
