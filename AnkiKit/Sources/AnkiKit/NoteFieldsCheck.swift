import Foundation

/// A user-facing warning derived from the engine's `note_fields_check` state —
/// the editor's live duplicate / empty / cloze notice, mirroring AnkiDroid's
/// `NoteEditor` (which red-highlights a duplicate first field and surfaces the
/// empty / cloze problems). Kept as a pure value type, decoupled from the
/// generated `NoteFieldsCheckResponse.State`, so the state→warning mapping and
/// its wording are easy to unit-test in isolation.
public enum NoteFieldsWarning: Equatable, Sendable {
    /// The first field duplicates an existing note of the same type (Anki warns
    /// but still allows the add).
    case duplicate
    /// The first field is empty (Anki refuses to add a note with an empty first
    /// field).
    case emptyFirstField
    /// A cloze note type with no `{{cN::…}}` deletions in any field.
    case missingCloze
    /// A `{{cN::…}}` deletion used in a non-cloze note type.
    case clozeOutsideClozeNotetype
    /// A `{{cN::…}}` deletion in a field that doesn't use the `cloze:` filter.
    case clozeInNonClozeField

    /// The user-facing message, matching Anki's `adding.ftl` / `browsing.ftl`
    /// wording so the notice reads exactly as it does on desktop / AnkiDroid.
    public var message: String {
        switch self {
        case .duplicate:
            return "Duplicate"
        case .emptyFirstField:
            return "The first field is empty."
        case .missingCloze:
            return "You have a cloze note type but have not made any cloze deletions."
        case .clozeOutsideClozeNotetype:
            return "Cloze deletion can only be used on cloze note types."
        case .clozeInNonClozeField:
            return "Cloze deletion can only be used in fields which use the 'cloze:' filter. "
                + "This is typically the first field."
        }
    }

    /// Whether this warrants AnkiDroid's red first-field highlight. Only the
    /// duplicate state highlights the field (its `setDupeStyle()`); the rest are
    /// gentle inline notices, matching `setDuplicateFieldStyles` which only
    /// restyles the first field for `DUPLICATE`.
    public var highlightsFirstField: Bool {
        self == .duplicate
    }
}

public extension Anki_Notes_NoteFieldsCheckResponse.State {
    /// Maps the engine's fields-check state to an editor warning, or `nil` for a
    /// clean note (`NORMAL`, or an unknown future state). The single source of
    /// truth behind the editor's live warning — see AnkiDroid's
    /// `checkNoteFieldsResponse`, which switches on the same enum.
    var editorWarning: NoteFieldsWarning? {
        switch self {
        case .normal:
            return nil
        case .duplicate:
            return .duplicate
        case .empty:
            return .emptyFirstField
        case .missingCloze:
            return .missingCloze
        case .notetypeNotCloze:
            return .clozeOutsideClozeNotetype
        case .fieldNotCloze:
            return .clozeInNonClozeField
        case .UNRECOGNIZED:
            return nil
        }
    }
}
