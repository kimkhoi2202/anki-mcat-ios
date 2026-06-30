import SwiftUI
import AnkiKit

/// Custom Study — a native clone of AnkiDroid's `CustomStudyDialog`.
///
/// Anki's Custom Study is a preset menu that, under the hood, either extends a
/// deck's daily new/review limits or builds a temporary "Custom Study Session"
/// filtered deck (the engine's `customStudy` RPC, prefilled by
/// `getCustomStudyDefaults`). This shows the six standard options as a menu
/// (AnkiDroid's `buildContextMenu`); picking one pushes a small input screen
/// (`buildInputDialog`) to enter the amount — and, for "Study by card state or
/// tag", the card state plus a tag include/exclude picker.
///
/// Applying a choice calls `customStudy`: limit extensions just bump the deck's
/// limits in place, while the other options build the session deck — in which
/// case `onStartedSession` fires so the presenter can jump into the reviewer for
/// it (mirroring AnkiDroid's `CustomStudyAction` handling in DeckPicker).
///
/// Presented as a sheet from the deck overview and the deck context menu.
@MainActor
struct CustomStudyView: View {
    @ObservedObject var store: AnkiStore
    let deckID: Int64
    /// Invoked once a "Custom Study Session" deck has been built and selected as
    /// current, so the presenter can navigate into the reviewer for it.
    var onStartedSession: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    /// Engine prefill (today's extend defaults, available counts, tags); nil
    /// until loaded (or if it couldn't be read — inputs then use fallbacks).
    @State private var defaults: CustomStudyDefaults?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(CustomStudyOption.allCases) { option in
                        NavigationLink {
                            CustomStudyOptionDetail(
                                store: store, deckID: deckID, option: option,
                                defaults: defaults, complete: { complete($0) }
                            )
                        } label: {
                            Label(option.title, systemImage: option.systemImage)
                                .font(DS.Typography.body)
                                .foregroundStyle(DS.textPrimary)
                        }
                    }
                } footer: {
                    sectionFooter("Study past your daily limit, review ahead or forgotten cards, or build a one-off filtered deck. Anki keeps sessions in a temporary “Custom Study Session” deck.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.background.ignoresSafeArea())
            .tint(DS.accent)
            .navigationTitle("Custom study")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                // Prefill values: today's extend defaults, available counts, tags.
                defaults = await store.customStudyDefaults(forDeck: deckID)
            }
        }
    }

    /// Completion from the detail screen: dismiss the whole sheet, and if a
    /// session deck was built (and already selected by the store), tell the
    /// presenter to study it.
    private func complete(_ outcome: CustomStudyOutcome) {
        if case .builtSession = outcome { onStartedSession() }
        dismiss()
    }

    private func sectionFooter(_ text: String) -> some View {
        Text(text)
            .font(DS.Typography.caption)
            .foregroundStyle(DS.textSecondary)
    }
}

/// The six Custom Study presets shown in the menu, in AnkiDroid's
/// `ContextMenuOption` order. Labels match desktop Anki's `custom_study_*`
/// strings.
enum CustomStudyOption: Int, CaseIterable, Identifiable {
    case extendNew
    case extendReview
    case reviewForgotten
    case reviewAhead
    case previewNew
    case cardStateOrTag

    var id: Int { rawValue }

    /// Menu row label.
    var title: String {
        switch self {
        case .extendNew: return "Increase today's new card limit"
        case .extendReview: return "Increase today's review card limit"
        case .reviewForgotten: return "Review forgotten cards"
        case .reviewAhead: return "Review ahead"
        case .previewNew: return "Preview new cards"
        case .cardStateOrTag: return "Study by card state or tag"
        }
    }

    var systemImage: String {
        switch self {
        case .extendNew: return "plus.circle"
        case .extendReview: return "arrow.clockwise.circle"
        case .reviewForgotten: return "exclamationmark.arrow.circlepath"
        case .reviewAhead: return "forward.circle"
        case .previewNew: return "eye.circle"
        case .cardStateOrTag: return "tag.circle"
        }
    }

    /// Label shown before the number input (desktop's `preSpin`).
    var inputLabel: String {
        switch self {
        case .extendNew: return "Increase today's new card limit by"
        case .extendReview: return "Increase today's review limit by"
        case .reviewForgotten: return "Review cards forgotten in last"
        case .reviewAhead: return "Review ahead by"
        case .previewNew: return "Preview new cards added in the last"
        case .cardStateOrTag: return "Select"
        }
    }

    /// Units shown after the number input (desktop's `postSpin`).
    var units: String {
        switch self {
        case .extendNew, .extendReview: return "cards"
        case .reviewForgotten, .reviewAhead, .previewNew: return "days"
        case .cardStateOrTag: return "cards from the deck"
        }
    }

    /// Allowed input range, matching desktop's spinner bounds (extend allows
    /// reducing the limit; "forgotten" is capped at 30 days).
    var range: ClosedRange<Int> {
        switch self {
        case .extendNew, .extendReview: return -9999...9999
        case .reviewForgotten: return 1...30
        case .reviewAhead, .previewNew, .cardStateOrTag: return 1...9999
        }
    }

    /// Whether negative values make sense (only the limit extensions).
    var allowsNegative: Bool {
        self == .extendNew || self == .extendReview
    }
}

/// The amount-input screen for one Custom Study option (AnkiDroid's
/// `buildInputDialog`): a labelled number field, plus — for "Study by card state
/// or tag" — a card-state picker and a per-tag include/exclude list.
private struct CustomStudyOptionDetail: View {
    @ObservedObject var store: AnkiStore
    let deckID: Int64
    let option: CustomStudyOption
    let defaults: CustomStudyDefaults?
    /// Called with the engine outcome once the choice is applied.
    let complete: (CustomStudyOutcome) -> Void

    @State private var amount = 1
    @State private var cramKind: CustomStudyCramKind = .newCardsOnly
    /// Per-tag include/exclude selection for "study by card state or tag".
    @State private var tagSelections: [String: TagSelection] = [:]
    @State private var applying = false
    @State private var errorMessage: String?
    @State private var didPrefill = false

    var body: some View {
        Form {
            if let hint = availabilityHint {
                Section {
                    Text(hint)
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.textSecondary)
                }
            }

            amountSection

            if option == .cardStateOrTag {
                cardStateSection
                tagsSection
            }

            applySection
        }
        .scrollContentBackground(.hidden)
        .background(DS.background.ignoresSafeArea())
        .tint(DS.accent)
        .navigationTitle(option.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: prefillIfNeeded)
        .alert(
            "Can’t custom study",
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

    // MARK: - Sections

    private var amountSection: some View {
        Section {
            HStack(spacing: DS.Spacing.m) {
                Text(option.inputLabel)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
                Spacer(minLength: DS.Spacing.s)
                TextField("", value: $amount, format: .number)
                    .keyboardType(option.allowsNegative ? .numbersAndPunctuation : .numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 56, maxWidth: 88)
                    .font(DS.Typography.body.monospacedDigit())
                Stepper("", value: $amount, in: option.range)
                    .labelsHidden()
            }
        } footer: {
            sectionFooter(option.units)
        }
    }

    private var cardStateSection: some View {
        Section {
            Picker(selection: $cramKind) {
                ForEach(CustomStudyCramKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            } label: {
                rowLabel("Cards")
            }
        } header: {
            sectionHeader("Card state")
        }
    }

    @ViewBuilder
    private var tagsSection: some View {
        Section {
            let tags = defaults?.tags ?? []
            if tags.isEmpty {
                Text("No tags in this deck")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textSecondary)
            } else {
                ForEach(tags) { tag in
                    Picker(selection: tagBinding(tag.name)) {
                        Text("Ignore").tag(TagSelection.ignore)
                        Text("Require").tag(TagSelection.include)
                        Text("Exclude").tag(TagSelection.exclude)
                    } label: {
                        rowLabel(tag.name)
                    }
                    .pickerStyle(.menu)
                }
            }
        } header: {
            sectionHeader("Limit to tags")
        } footer: {
            sectionFooter("“Require” keeps only cards with one of those tags; “Exclude” drops cards with the tag.")
        }
    }

    private var applySection: some View {
        Section {
            Button {
                apply()
            } label: {
                Text(applying ? "Working…" : "OK")
            }
            .buttonStyle(.dsPrimary)
            .disabled(applying || clampedAmount == 0)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Prefill

    /// Seeds the inputs from the engine defaults / saved values, once.
    private func prefillIfNeeded() {
        guard !didPrefill else { return }
        didPrefill = true
        amount = defaultAmount()
        if option == .cardStateOrTag {
            var selections: [String: TagSelection] = [:]
            for tag in defaults?.tags ?? [] {
                if tag.include {
                    selections[tag.name] = .include
                } else if tag.exclude {
                    selections[tag.name] = .exclude
                }
            }
            tagSelections = selections
        }
    }

    /// The initial value shown in the number field. Extend options use the
    /// engine's `extend_*` default; the session options reuse the last value the
    /// user entered (persisted, like AnkiDroid), falling back to Anki's defaults.
    private func defaultAmount() -> Int {
        switch option {
        case .extendNew: return defaults?.extendNew ?? 0
        case .extendReview: return defaults?.extendReview ?? 0
        case .reviewForgotten: return savedAmount(Self.forgottenDaysKey, fallback: 1)
        case .reviewAhead: return savedAmount(Self.aheadDaysKey, fallback: 1)
        case .previewNew: return savedAmount(Self.previewDaysKey, fallback: 1)
        case .cardStateOrTag: return savedAmount(Self.amountOfCardsKey, fallback: 100)
        }
    }

    // MARK: - Apply

    private var clampedAmount: Int {
        min(max(amount, option.range.lowerBound), option.range.upperBound)
    }

    private func apply() {
        applying = true
        Task { @MainActor in
            defer { applying = false }
            do {
                let outcome = try await store.applyCustomStudy(forDeck: deckID, choice: buildChoice())
                persistAmount()
                complete(outcome)
            } catch {
                errorMessage = describe(error)
            }
        }
    }

    /// Maps the screen's inputs to the AnkiKit `CustomStudyChoice` (and so the
    /// engine `CustomStudyRequest` oneof).
    private func buildChoice() -> CustomStudyChoice {
        let value = clampedAmount
        switch option {
        case .extendNew: return .extendNew(delta: value)
        case .extendReview: return .extendReview(delta: value)
        case .reviewForgotten: return .reviewForgotten(days: value)
        case .reviewAhead: return .reviewAhead(days: value)
        case .previewNew: return .previewNew(days: value)
        case .cardStateOrTag:
            let include = tagSelections.filter { $0.value == .include }.map(\.key).sorted()
            let exclude = tagSelections.filter { $0.value == .exclude }.map(\.key).sorted()
            return .cardStateOrTag(CustomStudyCram(
                kind: cramKind, cardLimit: value,
                tagsToInclude: include, tagsToExclude: exclude
            ))
        }
    }

    /// The "available cards" hint shown above the extend inputs, with the
    /// subdeck breakdown when present (desktop's `count_with_children`).
    private var availabilityHint: String? {
        guard let defaults else { return nil }
        switch option {
        case .extendNew:
            return "Available new cards: \(countString(defaults.availableNew, defaults.availableNewInChildren))"
        case .extendReview:
            return "Available review cards: \(countString(defaults.availableReview, defaults.availableReviewInChildren))"
        default:
            return nil
        }
    }

    private func countString(_ parent: Int, _ children: Int) -> String {
        children > 0 ? "\(parent) (\(children) in subdecks)" : "\(parent)"
    }

    // MARK: - Persisted defaults (faithful to AnkiDroid saving last-used values)

    private static let forgottenDaysKey = "customStudyForgottenDays"
    private static let aheadDaysKey = "customStudyAheadDays"
    private static let previewDaysKey = "customStudyPreviewDays"
    private static let amountOfCardsKey = "customStudyAmountOfCards"

    private func savedAmount(_ key: String, fallback: Int) -> Int {
        let stored = UserDefaults.standard.object(forKey: key) as? Int
        return stored ?? fallback
    }

    private func persistAmount() {
        let value = clampedAmount
        switch option {
        case .reviewForgotten: UserDefaults.standard.set(value, forKey: Self.forgottenDaysKey)
        case .reviewAhead: UserDefaults.standard.set(value, forKey: Self.aheadDaysKey)
        case .previewNew: UserDefaults.standard.set(value, forKey: Self.previewDaysKey)
        case .cardStateOrTag: UserDefaults.standard.set(value, forKey: Self.amountOfCardsKey)
        case .extendNew, .extendReview:
            // The engine provides the extend default; nothing to persist locally.
            break
        }
    }

    // MARK: - Helpers

    private func tagBinding(_ name: String) -> Binding<TagSelection> {
        Binding(
            get: { tagSelections[name] ?? .ignore },
            set: { tagSelections[name] = ($0 == .ignore) ? nil : $0 }
        )
    }

    private func describe(_ error: Error) -> String {
        if case let AnkiError.backendError(data) = error,
           let backendError = try? Anki_Backend_BackendError(serializedBytes: data),
           !backendError.message.isEmpty {
            return backendError.message
        }
        return error.localizedDescription
    }

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

/// Per-tag selection in the "study by card state or tag" tag picker.
private enum TagSelection: Hashable {
    case ignore
    case include
    case exclude
}
