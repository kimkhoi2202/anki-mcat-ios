import SwiftUI
import AnkiKit

/// "Controls / Gestures" settings, cloning AnkiDroid's gesture settings.
///
/// Lists every recognizable reviewer gesture — the nine tap zones (AnkiDroid's
/// 3×3 grid), four swipes, long-press, and double-tap — each with a menu
/// `Picker` to choose the
/// `ViewerCommand` it triggers, plus a "Reset to defaults". Edits mutate
/// `store.gestureConfig`, which persists immediately (JSON in `UserDefaults`)
/// and is read live by the reviewer's gesture dispatcher.
///
/// The picker offers the full AnkiDroid-style command set (reveal/grade, note &
/// card actions, flags, replay, card info, whiteboard, exit). Grading commands
/// only ever fire while the answer is shown — enforced by the reviewer, not
/// here — so binding an edge tap/swipe to a rating can't accidentally grade a
/// question.
struct ControlsSettingsView: View {
    @ObservedObject var store: AnkiStore

    var body: some View {
        Form {
            tapZonesSection
            swipesSection
            otherGesturesSection
            resetSection
        }
        .scrollContentBackground(.hidden)
        .background(DS.background.ignoresSafeArea())
        .tint(DS.accent)
        .navigationTitle("Gestures")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    /// Tap zones, laid out in reading order to mirror AnkiDroid's 3×3 grid
    /// (top row, middle row, bottom row).
    private var tapZonesSection: some View {
        Section {
            gestureRow(.tapTopLeft)
            gestureRow(.tapTop)
            gestureRow(.tapTopRight)
            gestureRow(.tapLeft)
            gestureRow(.tapCenter)
            gestureRow(.tapRight)
            gestureRow(.tapBottomLeft)
            gestureRow(.tapBottom)
            gestureRow(.tapBottomRight)
        } header: {
            sectionHeader("Tap zones")
        } footer: {
            sectionFooter("The card is split into a 3×3 grid of nine tap zones, like AnkiDroid. Tapping a zone runs its action. Rating actions only apply once the answer is shown.")
        }
    }

    private var swipesSection: some View {
        Section {
            gestureRow(.swipeUp)
            gestureRow(.swipeDown)
            gestureRow(.swipeLeft)
            gestureRow(.swipeRight)
        } header: {
            sectionHeader("Swipes")
        } footer: {
            sectionFooter("Up/down swipes are ignored while a long card is scrolling, so scrolling never grades a card.")
        }
    }

    private var otherGesturesSection: some View {
        Section {
            gestureRow(.longPress)
            gestureRow(.doubleTap)
        } header: {
            sectionHeader("Other gestures")
        } footer: {
            sectionFooter("Long press and double tap are unbound unless you assign them an action here.")
        }
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                store.resetGestureConfig()
            } label: {
                Label("Reset to defaults", systemImage: "arrow.counterclockwise")
            }
            .disabled(store.gestureConfig.isDefault)
            .accessibilityIdentifier("resetGestures")
        } footer: {
            sectionFooter("Restores the default gesture mapping: tap center reveals/flips, edges and swipes grade (left = Again, right = Easy, up = Good, down = Hard), and long press edits the note.")
        }
    }

    // MARK: - Rows

    /// One gesture row: its name and a menu picker of every available command.
    private func gestureRow(_ gesture: ReviewerGesture) -> some View {
        Picker(selection: commandBinding(gesture)) {
            ForEach(ViewerCommand.menuOrder) { command in
                Label(command.title, systemImage: command.systemImage)
                    .tag(command)
            }
        } label: {
            Text(gesture.title)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
        }
        .pickerStyle(.menu)
        .tint(DS.textSecondary)
        .accessibilityIdentifier("gesture_\(gesture.rawValue)")
    }

    // MARK: - Helpers

    /// A binding that reads/writes a single gesture's command on the store's
    /// published `gestureConfig` (which persists the change on mutation).
    private func commandBinding(_ gesture: ReviewerGesture) -> Binding<ViewerCommand> {
        Binding(
            get: { store.gestureConfig.command(for: gesture) },
            set: { store.gestureConfig.set($0, for: gesture) }
        )
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
