import SwiftUI
import AnkiKit

/// Basic deck options — a native SwiftUI clone of the new-cards/day and
/// maximum-reviews/day controls from AnkiDroid's deck options.
///
/// Scope (T2.3): just the two daily limits. The full FSRS deck-options page
/// (presets, steps, retention, …) is intentionally out of scope; this edits the
/// deck's per-deck limit overrides via `setDeckLimits`.
@MainActor
struct DeckOptionsView: View {
    @ObservedObject var store: AnkiStore
    let deck: DeckTreeEntry
    /// Invoked after a successful save so the presenting screen can refresh.
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var newPerDay = Backend.defaultNewCardsPerDay
    @State private var reviewsPerDay = Backend.defaultReviewsPerDay
    @State private var errorMessage: String?
    @State private var didLoad = false

    /// The engine clamps daily limits to 0…9999; mirror that in the steppers.
    private let limitRange = 0...9999

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    limitRow(
                        "New cards/day",
                        value: $newPerDay,
                        accessibilityLabel: "New cards per day"
                    )
                    limitRow(
                        "Maximum reviews/day",
                        value: $reviewsPerDay,
                        accessibilityLabel: "Maximum reviews per day"
                    )
                } header: {
                    sectionHeader("Daily limits")
                } footer: {
                    sectionFooter("Caps how many new cards and reviews this deck shows each day.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.background.ignoresSafeArea())
            .tint(DS.accent)
            .navigationTitle(deck.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!didLoad)
                }
            }
            .alert(
                "Can’t save options",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task { loadIfNeeded() }
        }
    }

    // MARK: - Loading & saving

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if let limits = store.deckLimits(forDeck: deck.id) {
            newPerDay = limits.newPerDay
            reviewsPerDay = limits.reviewsPerDay
        }
    }

    private func save() {
        do {
            try store.setDeckLimits(
                forDeck: deck.id,
                newPerDay: newPerDay,
                reviewsPerDay: reviewsPerDay
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Extracts a human-readable message from a thrown error, decoding the
    /// engine's protobuf `BackendError` when present.
    private func describe(_ error: Error) -> String {
        if case let AnkiError.backendError(data) = error,
           let backendError = try? Anki_Backend_BackendError(serializedBytes: data),
           !backendError.message.isEmpty {
            return backendError.message
        }
        return error.localizedDescription
    }

    // MARK: - Small view helpers

    /// One limit row: a label, a direct numeric entry field, and a stepper for
    /// fine adjustment — all native controls, bound to the same value.
    private func limitRow(
        _ label: String,
        value: Binding<Int>,
        accessibilityLabel: String
    ) -> some View {
        HStack(spacing: DS.Spacing.m) {
            Text(label)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
            Spacer(minLength: DS.Spacing.s)
            TextField("", value: value, format: .number)
                .font(DS.Typography.body.monospacedDigit())
                .foregroundStyle(DS.textPrimary)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .accessibilityLabel(accessibilityLabel)
            Stepper(label, value: value, in: limitRange)
                .labelsHidden()
                .accessibilityLabel(accessibilityLabel)
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(DS.Typography.caption.weight(.semibold))
            .foregroundStyle(DS.textSecondary)
    }

    private func sectionFooter(_ text: String) -> some View {
        Text(text)
            .font(DS.Typography.caption)
            .foregroundStyle(DS.textSecondary)
    }
}
