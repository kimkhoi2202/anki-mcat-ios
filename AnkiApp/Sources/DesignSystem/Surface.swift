import SwiftUI

/// Wraps content in a rounded `DS.surface` card with padding and a hairline border.
struct DSCardModifier: ViewModifier {
    var padding: CGFloat = DS.Spacing.l

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
        content
            .padding(padding)
            .background(DS.surface, in: shape)
            .overlay(shape.strokeBorder(DS.separator, lineWidth: 1))
    }
}

extension View {
    /// Presents the view as a card: padded `DS.surface` background with rounded
    /// corners and a hairline separator border.
    func dsCard(padding: CGFloat = DS.Spacing.l) -> some View {
        modifier(DSCardModifier(padding: padding))
    }
}
