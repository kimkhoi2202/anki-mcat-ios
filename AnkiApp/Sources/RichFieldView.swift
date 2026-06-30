import SwiftUI
import UIKit

// MARK: - Field formatting model

/// The inline formatting actions the editor toolbar can apply to a field,
/// mirroring AnkiDroid's NoteEditor formatting toolbar. Each one inserts plain
/// HTML / cloze / MathJax markup into the field text — Anki fields *store* HTML,
/// so formatting is text insertion, not a separate WYSIWYG mode.
enum FieldFormat: Int, CaseIterable {
    case bold, italic, underline, sup, sub, clear, cloze, clozeSame, mathInline, mathBlock
}

#if DEBUG
/// Constants for the debug-only screenshot/automation hook that scripts a
/// bold + cloze demo in the first field, mirroring the app's other `-startIn…`
/// verification hooks. Compiled out of release builds.
enum FieldFormattingDemo {
    static let sentence = "Paris is the capital of France"
}
#endif

/// Pure, UI-independent text transforms behind the formatting toolbar. Kept apart
/// from the view so the wrapping / cloze-numbering rules are easy to reason about
/// in isolation. All ranges are UTF-16 (`NSRange`), matching `UITextView`.
enum FieldFormatter {
    /// A transform's output: the field's new full text and the selection to
    /// restore afterwards.
    struct Result: Equatable {
        let text: String
        let selection: NSRange
    }

    /// Wraps `range` of `text` in `prefix`/`suffix`. With an empty selection the
    /// caret is placed between the inserted tags (so the user types inside them);
    /// with a non-empty selection the whole wrapped span is reselected, matching
    /// AnkiDroid's `Toolbar.TextWrapper`.
    static func wrap(_ text: NSString, range: NSRange, prefix: String, suffix: String) -> Result {
        let safe = clamp(range, to: text.length)
        let selected = text.substring(with: safe)
        let replacement = prefix + selected + suffix
        let newText = text.replacingCharacters(in: safe, with: replacement)
        let prefixLength = (prefix as NSString).length
        let selection: NSRange
        if safe.length == 0 {
            selection = NSRange(location: safe.location + prefixLength, length: 0)
        } else {
            selection = NSRange(location: safe.location, length: (replacement as NSString).length)
        }
        return Result(text: newText, selection: selection)
    }

    /// Removes the inline formatting tags this toolbar inserts — `<b> <i> <u>
    /// <sup> <sub>` and their closings, case-insensitively — from within `range`.
    /// A no-op when the selection is empty (there is nothing scoped to clear).
    static func clearFormatting(_ text: NSString, range: NSRange) -> Result {
        let safe = clamp(range, to: text.length)
        guard safe.length > 0 else { return Result(text: text as String, selection: safe) }
        let selected = text.substring(with: safe)
        let cleaned = selected.replacingOccurrences(
            of: "</?(?:b|i|u|sup|sub)>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let newText = text.replacingCharacters(in: safe, with: cleaned)
        let selection = NSRange(location: safe.location, length: (cleaned as NSString).length)
        return Result(text: newText, selection: selection)
    }

    /// The cloze number for a *new* deletion: one more than the highest
    /// `{{c<k>::` across every field of the note, defaulting to 1. Matches Anki's
    /// "Cloze deletion" (Ctrl+Shift+C) and AnkiDroid's `getNextClozeIndex`.
    static func nextClozeNumber(in fields: [String]) -> Int {
        highestClozeNumber(in: fields) + 1
    }

    /// The cloze number for a deletion that *reuses* the current group (AnkiDroid's
    /// long-press "same number"): the current highest, or 1 when there are none.
    static func sameClozeNumber(in fields: [String]) -> Int {
        max(1, highestClozeNumber(in: fields))
    }

    /// The literal markup a format wraps a selection in, or `nil` for `clear`
    /// (which strips rather than inserts). Cloze numbers are resolved lazily from
    /// `fields` so the count spans the whole note at the moment of insertion.
    static func affixes(for format: FieldFormat, fields: () -> [String]) -> (prefix: String, suffix: String)? {
        switch format {
        case .bold: return ("<b>", "</b>")
        case .italic: return ("<i>", "</i>")
        case .underline: return ("<u>", "</u>")
        case .sup: return ("<sup>", "</sup>")
        case .sub: return ("<sub>", "</sub>")
        case .mathInline: return ("\\(", "\\)")
        case .mathBlock: return ("\\[", "\\]")
        case .cloze: return ("{{c\(nextClozeNumber(in: fields()))::", "}}")
        case .clozeSame: return ("{{c\(sameClozeNumber(in: fields()))::", "}}")
        case .clear: return nil
        }
    }

    private static let clozePattern = try! NSRegularExpression(pattern: "\\{\\{c(\\d+)::")

    private static func highestClozeNumber(in fields: [String]) -> Int {
        var highest = 0
        for field in fields {
            let ns = field as NSString
            clozePattern.enumerateMatches(in: field, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let number = Int(ns.substring(with: match.range(at: 1))) ?? 0
                if number > highest { highest = number }
            }
        }
        return highest
    }

    /// Clamps a range into `[0, length]` so a stale selection can never read out
    /// of bounds (the same defensive posture as the field/value alignment).
    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let extent = min(max(range.length, 0), length - location)
        return NSRange(location: location, length: extent)
    }
}

// MARK: - Editable HTML field

/// A `UITextView`-backed, multi-line editable field that two-way binds to a note
/// field's raw HTML string and hosts the formatting toolbar (as the keyboard's
/// `inputAccessoryView`). Replaces the per-field plain `TextField` so the toolbar
/// can wrap / insert markup around the live selection.
///
/// The toolbar lives on each field's own text view, so its buttons act on
/// whichever field is first responder by construction — no shared focus plumbing
/// is needed for the toolbar itself. The field self-sizes with its content (up to
/// ~6 lines, then scrolls), matching the previous `.lineLimit(1...6)`.
struct RichFieldView: UIViewRepresentable {
    /// Placeholder shown while empty (the field's name, as the old `TextField`).
    let placeholder: String
    /// The field's HTML, two-way bound to the editor's `fieldValues[index]`.
    @Binding var text: String
    /// Self-sizing height, reported back so the SwiftUI row grows with content.
    @Binding var height: CGFloat
    /// Whether this field should hold keyboard focus. Drives programmatic focus —
    /// e.g. focusing the first field when a save is rejected for being empty.
    let isFocused: Bool
    /// Snapshot of every field's value, read lazily when inserting a cloze so the
    /// next number spans the whole note (not just this field).
    let allFieldValues: () -> [String]
    /// Reports begin/end editing so the editor can track the focused field.
    var onFocusChange: (Bool) -> Void = { _ in }

    /// One line of body text plus insets — the collapsed height.
    static let minHeight: CGFloat = 38
    /// ~6 lines — matches the old `.lineLimit(1...6)` before scrolling kicks in.
    static let maxHeight: CGFloat = 150

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = UIColor(DS.textPrimary)
        textView.backgroundColor = .clear
        // Align text with the surrounding labels: no horizontal padding, modest
        // vertical breathing room.
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.inputAccessoryView = context.coordinator.makeAccessoryView()
        context.coordinator.textView = textView

        // Placeholder overlay, shown only while the field is empty (UITextView has
        // no native placeholder).
        let placeholderLabel = UILabel()
        placeholderLabel.font = textView.font
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.text = placeholder
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
        ])
        context.coordinator.placeholderLabel = placeholderLabel

        textView.text = text
        context.coordinator.updatePlaceholderVisibility()
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.placeholderLabel?.text = placeholder
        // Only overwrite when the bound value actually diverged (e.g. a reset or
        // an external edit), so we don't clobber the caret while typing.
        if uiView.text != text {
            uiView.text = text
        }
        context.coordinator.updatePlaceholderVisibility()
        context.coordinator.recalculateHeight()
        if isFocused, !uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichFieldView
        weak var textView: UITextView?
        weak var placeholderLabel: UILabel?

        init(_ parent: RichFieldView) { self.parent = parent }

        // MARK: Delegate

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            updatePlaceholderVisibility()
            recalculateHeight()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChange(true)
            #if DEBUG
            runFormattingDemoIfRequested()
            #endif
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChange(false)
        }

        // MARK: Layout

        func updatePlaceholderVisibility() {
            placeholderLabel?.isHidden = !(textView?.text.isEmpty ?? true)
        }

        /// Re-measures the content and publishes the clamped height; enables inner
        /// scrolling only once the content would exceed `maxHeight`.
        func recalculateHeight() {
            guard let textView else { return }
            let width = textView.bounds.width > 0
                ? textView.bounds.width
                : UIScreen.main.bounds.width - 40
            let fitted = textView.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            let clamped = min(max(fitted, RichFieldView.minHeight), RichFieldView.maxHeight)
            textView.isScrollEnabled = fitted > RichFieldView.maxHeight
            if abs(parent.height - clamped) > 0.5 {
                DispatchQueue.main.async { [weak self] in self?.parent.height = clamped }
            }
        }

        // MARK: Formatting actions

        @objc func formatButtonTapped(_ sender: UIButton) {
            guard let format = FieldFormat(rawValue: sender.tag) else { return }
            apply(format)
        }

        @objc func clozeSameLongPressed(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began { apply(.clozeSame) }
        }

        /// Applies a format to the focused text view's current selection, writes
        /// the result back through the binding, and restores the new selection.
        func apply(_ format: FieldFormat) {
            guard let textView else { return }
            let text = textView.text as NSString
            let range = textView.selectedRange
            let result: FieldFormatter.Result
            if format == .clear {
                result = FieldFormatter.clearFormatting(text, range: range)
            } else if let affixes = FieldFormatter.affixes(for: format, fields: parent.allFieldValues) {
                result = FieldFormatter.wrap(text, range: range, prefix: affixes.prefix, suffix: affixes.suffix)
            } else {
                return
            }
            // Setting `.text` directly doesn't fire `textViewDidChange`, so push the
            // value through the binding ourselves and refresh derived UI.
            textView.text = result.text
            textView.selectedRange = result.selection
            parent.text = result.text
            updatePlaceholderVisibility()
            recalculateHeight()
            textView.scrollRangeToVisible(result.selection)
        }

        #if DEBUG
        private var didRunFormattingDemo = false

        /// Debug screenshot hook: once the first field gains focus under
        /// `-demoFormatting`, script a real bold-of-a-selection then a real cloze
        /// insertion so a screenshot shows the toolbar acting on the field. Runs
        /// through the same `apply(_:)` path the buttons use.
        private func runFormattingDemoIfRequested() {
            guard !didRunFormattingDemo,
                  ProcessInfo.processInfo.arguments.contains("-demoFormatting"),
                  let textView else { return }
            didRunFormattingDemo = true
            // Seed the field here (rather than from the view) so the demo is robust
            // against the note type's onChange resetting field values.
            let sentence = FieldFormattingDemo.sentence
            textView.text = sentence
            parent.text = sentence
            if let boldRange = range(of: "Paris", in: textView.text) {
                textView.selectedRange = boldRange
                apply(.bold)
            }
            if let clozeRange = range(of: "the capital", in: textView.text) {
                textView.selectedRange = clozeRange
                apply(.cloze)
            }
            textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
        }

        private func range(of needle: String, in haystack: String) -> NSRange? {
            let found = (haystack as NSString).range(of: needle)
            return found.location == NSNotFound ? nil : found
        }
        #endif

        // MARK: Toolbar (inputAccessoryView)

        /// One toolbar button: an SF Symbol (with a text fallback for OS versions
        /// that lack the symbol) bound to a format action.
        private struct ButtonSpec {
            let format: FieldFormat
            let symbol: String
            let fallback: String
            let label: String
        }

        private var buttonSpecs: [ButtonSpec] {
            [
                ButtonSpec(format: .bold, symbol: "bold", fallback: "B", label: "Bold"),
                ButtonSpec(format: .italic, symbol: "italic", fallback: "I", label: "Italic"),
                ButtonSpec(format: .underline, symbol: "underline", fallback: "U", label: "Underline"),
                ButtonSpec(format: .sup, symbol: "textformat.superscript", fallback: "x²", label: "Superscript"),
                ButtonSpec(format: .sub, symbol: "textformat.subscript", fallback: "x₂", label: "Subscript"),
                ButtonSpec(format: .clear, symbol: "eraser", fallback: "Clear", label: "Clear formatting"),
                ButtonSpec(format: .cloze, symbol: "curlybraces", fallback: "{{c}}", label: "Cloze deletion (long-press: same number)"),
                ButtonSpec(format: .mathInline, symbol: "function", fallback: "\\( \\)", label: "MathJax (inline)"),
                ButtonSpec(format: .mathBlock, symbol: "sum", fallback: "\\[ \\]", label: "MathJax (block)"),
            ]
        }

        func makeAccessoryView() -> UIView {
            let bar = UIView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 48))
            bar.autoresizingMask = .flexibleWidth
            bar.backgroundColor = UIColor.secondarySystemBackground

            let separator = UIView()
            separator.backgroundColor = UIColor.separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(separator)

            let scrollView = UIScrollView()
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.alwaysBounceHorizontal = true
            scrollView.keyboardDismissMode = .none
            bar.addSubview(scrollView)

            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 2
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(stack)

            for spec in buttonSpecs { stack.addArrangedSubview(makeButton(spec)) }

            NSLayoutConstraint.activate([
                separator.topAnchor.constraint(equalTo: bar.topAnchor),
                separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

                scrollView.topAnchor.constraint(equalTo: bar.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.leadingAnchor, constant: 8),
                scrollView.trailingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.trailingAnchor, constant: -8),

                stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            ])
            return bar
        }

        private func makeButton(_ spec: ButtonSpec) -> UIButton {
            let button = UIButton(type: .system)
            if let image = UIImage(systemName: spec.symbol) {
                button.setImage(image, for: .normal)
            } else {
                button.setTitle(spec.fallback, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
            }
            button.tag = spec.format.rawValue
            button.tintColor = UIColor(DS.accent)
            button.accessibilityLabel = spec.label
            button.addTarget(self, action: #selector(formatButtonTapped(_:)), for: .touchUpInside)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            if spec.format == .cloze {
                button.addGestureRecognizer(
                    UILongPressGestureRecognizer(target: self, action: #selector(clozeSameLongPressed(_:)))
                )
            }
            return button
        }
    }
}
