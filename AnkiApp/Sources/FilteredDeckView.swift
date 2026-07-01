import SwiftUI
import AnkiKit

/// New Filtered Deck — a native clone of AnkiDroid's create-filtered-deck
/// screen.
///
/// Configure a filtered deck from one or two search filters — each with its own
/// search, gather order, and card limit, as in Anki's filtered-deck dialog —
/// plus the reschedule flag, then create it. The engine builds the deck
/// immediately (`add_or_update_filtered_deck`), pulling in matching cards; it
/// refuses to create one whose filters match nothing, which is surfaced as an
/// error.
///
/// The second filter is optional (off by default); a blank second search is
/// ignored. Rebuild / empty are offered from the deck's row on Home once it
/// exists. Presented as a sheet from Home.
@MainActor
struct FilteredDeckView: View {
    @ObservedObject var store: AnkiStore
    /// Invoked with the new deck id after a successful create.
    var onCreated: (Int64) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var name = "Filtered Deck"
    // Filter 1 (always present).
    @State private var search1 = "is:due"
    @State private var order1: FilteredDeckOrder = .orderDue
    @State private var limit1 = 100
    // Filter 2 (optional second filter, like Anki's filtered-deck dialog).
    @State private var addSecondFilter = false
    @State private var search2 = ""
    @State private var order2: FilteredDeckOrder = .orderDue
    @State private var limit2 = 100
    @State private var reschedule = true
    @State private var errorMessage: String?
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                filterSection(
                    title: "Filter 1",
                    search: $search1, order: $order1, limit: $limit1,
                    footer: "Cards matching this Anki search are pulled into the deck (suspended and buried cards are skipped)."
                )
                secondFilterSection
                optionsSection
            }
            .scrollContentBackground(.hidden)
            .background(DS.background.ignoresSafeArea())
            .tint(DS.accent)
            .navigationTitle("New Filtered Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc.tr("actions-cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Loc.tr("decks-build")) { create() }
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
            .onAppear {
                #if DEBUG
                // Screenshot hook: open with the second filter already enabled.
                if ProcessInfo.processInfo.arguments.contains("-demoFilteredDeckTwoFilters") {
                    addSecondFilter = true
                    if search2.isEmpty {
                        search2 = "is:new"
                        order2 = .orderAdded
                    }
                }
                #endif
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

    /// One filter row group: its search, gather order, and card limit. Anki's
    /// filtered decks carry up to two of these, each independent.
    private func filterSection(
        title: String,
        search: Binding<String>,
        order: Binding<FilteredDeckOrder>,
        limit: Binding<Int>,
        footer: String?
    ) -> some View {
        Section {
            TextField("e.g. is:due, deck:Biology, tag:hard", text: search, axis: .vertical)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .lineLimit(1...3)

            Picker(selection: order) {
                ForEach(FilteredDeckOrder.allCases) { option in
                    Text(option.label).tag(option)
                }
            } label: {
                rowLabel(Loc.tr("scheduling-order"))
            }

            Stepper(value: limit, in: 1...9999) {
                HStack {
                    rowLabel("Card limit")
                    Spacer()
                    Text("\(limit.wrappedValue)")
                        .font(DS.Typography.body)
                        .monospacedDigit()
                        .foregroundStyle(DS.textSecondary)
                }
            }
        } header: {
            sectionHeader(title)
        } footer: {
            if let footer { sectionFooter(footer) }
        }
    }

    @ViewBuilder
    private var secondFilterSection: some View {
        Section {
            Toggle(isOn: $addSecondFilter.animation()) {
                rowLabel("Add a second filter")
            }
            .tint(DS.accent)
        } footer: {
            sectionFooter("A filtered deck can gather cards from up to two searches, each with its own order and limit.")
        }

        if addSecondFilter {
            filterSection(
                title: "Filter 2",
                search: $search2, order: $order2, limit: $limit2,
                footer: "Leave the search blank to ignore this filter."
            )
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle(isOn: $reschedule) {
                rowLabel(Loc.tr("browsing-reschedule"))
            }
            .tint(DS.accent)
        } header: {
            sectionHeader(Loc.tr("actions-options"))
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
        // Always include filter 1; include filter 2 only when enabled with a
        // non-blank search (the engine wrapper also drops empty searches).
        var terms = [FilteredSearchTermInput(
            search: search1.trimmingCharacters(in: .whitespacesAndNewlines),
            limit: limit1, order: order1
        )]
        if addSecondFilter {
            let s2 = search2.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s2.isEmpty {
                terms.append(FilteredSearchTermInput(search: s2, limit: limit2, order: order2))
            }
        }
        creating = true
        // Build off the main actor so the gather doesn't hang the UI; `creating`
        // stays true for the duration so the Build button shows as busy.
        Task { @MainActor in
            defer { creating = false }
            do {
                let result = try await store.createFilteredDeck(
                    name: deckName, terms: terms, reschedule: reschedule
                )
                onCreated(result.deckID)
                dismiss()
            } catch {
                errorMessage = describe(error)
            }
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
