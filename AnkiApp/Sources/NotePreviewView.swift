import SwiftUI
import AnkiKit

/// Previews the current, *uncommitted* note's card(s) — the note editor's
/// "Preview" affordance, mirroring AnkiDroid's NoteEditor Preview. Renders each
/// card the note would generate via the engine's `render_uncommitted_card` (so
/// unsaved field edits show immediately), letting the user flip Front/Back and,
/// for multi-template (or multi-cloze) note types, pick which card to view.
///
/// The card itself is drawn by the reviewer's `CardWebView`, so the preview gets
/// the exact same rendering — notetype CSS, media (`<img>` / `[sound:]`), and the
/// bundled MathJax / Image-Occlusion runtime — as it will under review.
/// Presented as a sheet.
@MainActor
struct NotePreviewView: View {
    @ObservedObject var store: AnkiStore
    let notetypeID: Int64
    let fields: [String]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var cards: [EditorCardPreview] = []
    @State private var selection = 0
    @State private var side: Side = .front
    @State private var didLoad = false

    private enum Side: String, CaseIterable, Identifiable {
        case front = "Front", back = "Back"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let card = currentCard {
                    VStack(spacing: 0) {
                        controls(card)
                        Divider().overlay(DS.separator)
                        CardWebView(
                            html: side == .front ? card.question : card.answer,
                            css: card.css,
                            ordinal: card.ordinal,
                            isDark: colorScheme == .dark,
                            mediaFolder: store.mediaFolderURL
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if didLoad {
                    emptyState
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(DS.background.ignoresSafeArea())
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .tint(DS.accent)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard !didLoad else { return }
                cards = await store.renderUncommittedNoteCards(notetypeID: notetypeID, fields: fields)
                selection = min(selection, max(0, cards.count - 1))
                didLoad = true
            }
        }
    }

    /// Shown when the note generates no previewable cards (e.g. every field empty).
    private var emptyState: some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: "eye.slash")
                .font(.system(size: 44))
                .foregroundStyle(DS.textSecondary)
            Text("Nothing to preview")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
            Text("Fill in the note's fields to preview its cards.")
                .font(DS.Typography.body)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentCard: EditorCardPreview? {
        cards.indices.contains(selection) ? cards[selection] : nil
    }

    @ViewBuilder
    private func controls(_ card: EditorCardPreview) -> some View {
        VStack(spacing: DS.Spacing.s) {
            // Card picker only when there's more than one card to choose from.
            if cards.count > 1 {
                Picker("Card", selection: $selection) {
                    ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                        Text(card.label).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .tint(DS.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker("Side", selection: $side) {
                ForEach(Side.allCases) { side in Text(side.rawValue).tag(side) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
    }
}
