import SwiftUI
import AnkiKit

/// New Filtered Deck — a native clone of AnkiDroid's create-filtered-deck
/// (custom study) screen.
///
/// Configure a filtered deck from a single search query, a card limit, and a
/// gather order, then create it. The engine builds the deck immediately
/// (`add_or_update_filtered_deck`), pulling in matching cards; it refuses to
/// create one whose search matches nothing, which is surfaced as an error.
///
/// Scope (T3.3): one filter term + the basic options (limit, order, reschedule).
/// Rebuild / empty are offered from the deck's row on Home once it exists.
/// Presented as a sheet from Home.
@MainActor
struct FilteredDeckView: View {
    @ObservedObject var store: AnkiStore
    /// Invoked with the new deck id after a successful create.
    var onCreated: (Int64) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var name = "Filtered Deck"
    @State private var search = "is:due"
    @State private var limit = 100
    @State private var order: FilteredDeckOrder = .orderDue
    @State private var reschedule = true
    @State private var errorMessage: String?
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                searchSection
                optionsSection
            }
            .scrollContentBackground(.hidden)
            .background(DS.background.ignoresSafeArea())
            .tint(DS.accent)
            .navigationTitle("New Filtered Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Build") { create() }
                        .fontWeight(.semibold)
                        .disabled(creating || trimmedName.isEmpty)
                }
            }
            .alert(
                "Can’t build filtered deck",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section {
            TextField("Deck name", text: $name)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
                .autocorrectionDisabled()
        } header: {
            sectionHeader("Name")
        }
    }

    private var searchSection: some View {
        Section {
            TextField("e.g. is:due, deck:Biology, tag:hard", text: $search, axis: .vertical)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .lineLimit(1...3)
        } header: {
            sectionHeader("Search")
        } footer: {
            sectionFooter("Cards matching this Anki search are pulled into the deck (suspended and buried cards are skipped).")
        }
    }

    private var optionsSection: some View {
        Section {
            Stepper(value: $limit, in: 1...9999) {
                HStack {
                    rowLabel("Card limit")
                    Spacer()
                    Text("\(limit)")
                        .font(DS.Typography.body)
                        .monospacedDigit()
                        .foregroundStyle(DS.textSecondary)
                }
            }

            Picker(selection: $order) {
                ForEach(FilteredDeckOrder.allCases) { option in
                    Text(option.label).tag(option)
                }
            } label: {
                rowLabel("Order")
            }

            Toggle(isOn: $reschedule) {
                rowLabel("Reschedule")
            }
            .tint(DS.accent)
        } header: {
            sectionHeader("Options")
        } footer: {
            sectionFooter("Reschedule lets answers affect the cards’ due dates, like normal review.")
        }
    }

    // MARK: - Actions

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        let deckName = trimmedName
        guard !deckName.isEmpty else { return }
        creating = true
        defer { creating = false }
        do {
            let result = try store.createFilteredDeck(
                name: deckName,
                search: search.trimmingCharacters(in: .whitespacesAndNewlines),
                limit: limit,
                order: order,
                reschedule: reschedule
            )
            onCreated(result.deckID)
            dismiss()
        } catch {
            errorMessage = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        if case let AnkiError.backendError(data) = error,
           let backendError = try? Anki_Backend_BackendError(serializedBytes: data),
           !backendError.message.isEmpty {
            return backendError.message
        }
        return error.localizedDescription
    }

    // MARK: - Small view helpers

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(DS.Typography.body)
            .foregroundStyle(DS.textPrimary)
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
