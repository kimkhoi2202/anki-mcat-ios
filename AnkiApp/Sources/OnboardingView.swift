import SwiftUI

/// What the user chose to do when finishing the onboarding flow, so the host can
/// optionally chain into a first action (mirrors AnkiDroid's IntroductionActivity,
/// whose "Get started" lands on the deck picker and whose secondary action links
/// onward — here to "Add note" or "Get shared decks").
enum OnboardingCompletion {
    /// Land on the deck list (Skip / Get Started).
    case getStarted
    /// Land on the deck list, then open the note editor.
    case addNote
    /// Land on the deck list, then open the AnkiWeb shared-decks browser.
    case getSharedDecks
}

/// First-launch welcome flow, cloning AnkiDroid's `IntroductionActivity`.
///
/// A few paged screens introduce Anki (what it is → how reviewing works → how to
/// fill a collection), ending on a "Get Started" call to action plus an optional
/// "Browse shared decks" shortcut. Shown once, gated by
/// `@AppStorage(Onboarding.storageKey)` (AnkiDroid's `IntroductionSlidesShown`).
///
/// The copy on the first slide is lifted from AnkiDroid's intro strings
/// (`intro_ankidroid_tagline_one/two`, `intro_short_ankidroid_explanation`) to
/// stay faithful; the remaining slides expand on reviewing and deck sources.
struct OnboardingView: View {
    /// Called when the flow finishes (finish or skip), carrying the chosen
    /// follow-up action. The host persists the "shown" flag and dismisses.
    let onComplete: (OnboardingCompletion) -> Void

    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(onComplete: @escaping (OnboardingCompletion) -> Void) {
        self.onComplete = onComplete
        #if DEBUG
        // Screenshot hook: `-onboardingPage N` opens on a specific slide (e.g.
        // the final slide with its CTAs) without needing to tap through.
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-onboardingPage"),
           idx + 1 < args.count, let start = Int(args[idx + 1]) {
            _page = State(initialValue: start)
        }
        #endif
    }

    private var slides: [OnboardingSlide] { OnboardingSlide.all }
    private var isLastPage: Bool { page >= slides.count - 1 }

    var body: some View {
        ZStack {
            DS.background.ignoresSafeArea()

            VStack(spacing: 0) {
                skipBar
                pager
                controls
            }
        }
    }

    // MARK: - Skip

    /// Top "Skip" affordance, hidden on the last page where "Get Started" is the
    /// primary action (matching AnkiDroid, which offers no skip once the final
    /// choice is presented).
    private var skipBar: some View {
        HStack {
            Spacer()
            if !isLastPage {
                Button("Skip") { onComplete(.getStarted) }
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundStyle(DS.textSecondary)
                    .padding(.horizontal, DS.Spacing.l)
                    .frame(minHeight: DS.minTapTarget)
                    .accessibilityLabel("Skip introduction")
            }
        }
        .frame(height: DS.minTapTarget)
        .padding(.top, DS.Spacing.s)
    }

    // MARK: - Pager

    private var pager: some View {
        TabView(selection: $page) {
            ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                OnboardingSlideView(slide: slide)
                    .tag(index)
                    .padding(.horizontal, DS.Spacing.xl)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(reduceMotion ? nil : .easeInOut, value: page)
    }

    // MARK: - Controls (dots + buttons)

    private var controls: some View {
        VStack(spacing: DS.Spacing.l) {
            pageDots

            Button {
                advance()
            } label: {
                Text(isLastPage ? "Get Started" : "Next")
            }
            .buttonStyle(.dsPrimary)
            .accessibilityIdentifier("onboardingPrimary")

            // On the final slide, offer the same "download a deck" shortcut the
            // slide describes, so a brand-new user can go straight to content.
            if isLastPage {
                Button {
                    onComplete(.getSharedDecks)
                } label: {
                    Label("Browse shared decks", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.dsSecondary)
                .accessibilityIdentifier("onboardingSharedDecks")
            }
        }
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.bottom, DS.Spacing.xl)
        .padding(.top, DS.Spacing.m)
    }

    /// Custom page indicator so the dots use `DS` colors (the system page-control
    /// dots wash out against the app background).
    private var pageDots: some View {
        HStack(spacing: DS.Spacing.s) {
            ForEach(slides.indices, id: \.self) { index in
                Capsule()
                    .fill(index == page ? DS.accent : DS.separator)
                    .frame(width: index == page ? 22 : 8, height: 8)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: page)
            }
        }
        .accessibilityHidden(true)
    }

    /// Advances to the next slide, or finishes on the last one.
    private func advance() {
        if isLastPage {
            onComplete(.getStarted)
        } else {
            withAnimation(reduceMotion ? nil : .easeInOut) { page += 1 }
        }
    }
}

// MARK: - Slide model + view

/// One onboarding page: a tinted symbol, a title, a supporting message, and an
/// optional "rating chips" illustration used on the reviewing slide.
private struct OnboardingSlide: Identifiable {
    let id: Int
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    /// Show the Again/Hard/Good/Easy rating chips beneath the copy.
    var showsRatingChips = false

    static var all: [OnboardingSlide] {
        [
            OnboardingSlide(
                id: 0,
                symbol: "brain.head.profile",
                tint: DS.accent,
                title: "Study less.\nRemember more.",
                // AnkiDroid `intro_short_ankidroid_explanation`.
                message: "Anki’s card scheduler saves time by strengthening your weakest memories and preserving your strongest."
            ),
            OnboardingSlide(
                id: 1,
                symbol: "rectangle.on.rectangle.angled",
                tint: DS.good,
                title: "A little every day",
                message: "Flip a card, then rate how well you knew it. Anki brings each card back right before you’d forget it.",
                showsRatingChips: true
            ),
            OnboardingSlide(
                id: 2,
                symbol: "square.and.arrow.down",
                tint: DS.accent,
                title: "Fill it with knowledge",
                message: "Create your own notes, or download from thousands of free shared decks on AnkiWeb."
            ),
        ]
    }
}

/// Renders a single onboarding slide: centered illustration, title, and message.
private struct OnboardingSlideView: View {
    let slide: OnboardingSlide

    var body: some View {
        VStack(spacing: DS.Spacing.xl) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(slide.tint.opacity(0.12))
                    .frame(width: 148, height: 148)
                Image(systemName: slide.symbol)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(slide.tint)
            }
            .accessibilityHidden(true)

            VStack(spacing: DS.Spacing.m) {
                Text(slide.title)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(DS.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(slide.message)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if slide.showsRatingChips { ratingChips }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// The four reviewer ratings as colored chips, echoing the reviewer's answer
    /// row so the "rate how well you knew it" copy has a concrete anchor.
    private var ratingChips: some View {
        HStack(spacing: DS.Spacing.s) {
            ratingChip("Again", DS.again)
            ratingChip("Hard", DS.hard)
            ratingChip("Good", DS.good)
            ratingChip("Easy", DS.easy)
        }
        .accessibilityHidden(true)
    }

    private func ratingChip(_ title: String, _ color: Color) -> some View {
        Text(title)
            .font(DS.Typography.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, DS.Spacing.s)
            .frame(maxWidth: .infinity)
            .background(color, in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
    }
}

#Preview {
    OnboardingView { _ in }
}
