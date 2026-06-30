import Foundation

/// Pure, in-memory edits to a `Notetype` proto, mirroring libanki's notetype
/// mutators (`add_field`, `reposition_field`, `add_template`, …). They are the
/// building blocks the Fields / Card Template editors and their atomic backend
/// wrappers share, kept apart from any RPC so the field/template/sort-field math
/// is easy to unit-test in isolation.
///
/// The key invariant: every existing field/template keeps its original `ord`, so
/// when the mutated note type is saved via `updateNotetype` the engine can remap
/// each note's stored field values and cards. A *new* field/template is appended
/// with its `ord` cleared, which the engine reads as "add this".
public extension Anki_Notetypes_Notetype {
    /// Whether this is a cloze note type (cards come from `{{c1::…}}` deletions,
    /// not from per-card templates), so template add/remove/reorder don't apply.
    var isCloze: Bool { config.kind == .cloze }

    /// Field names in field order (aligns with a note's `fields`).
    var fieldNames: [String] { fields.map(\.name) }

    /// Card-template names in template order.
    var templateNames: [String] { templates.map(\.name) }

    /// A throwaway note for previewing this note type's cards: each field is
    /// filled with `(FieldName)` so the layout is legible, and a cloze note type
    /// gets a real `{{c1::…}}` in its first field so the cloze actually renders.
    /// Mirrors what desktop's Card Layout shows for a fresh note.
    func sampleNote() -> Anki_Notes_Note {
        var note = Anki_Notes_Note()
        note.notetypeID = id
        var values = fields.map { "(\($0.name))" }
        if isCloze, let firstName = fields.first?.name, !values.isEmpty {
            values[0] = "{{c1::\(firstName)}}"
        }
        note.fields = values
        return note
    }

    // MARK: - Fields

    /// Appends a new field. The field has no `ord` (so the engine treats it as a
    /// new field added to every note) and a default config.
    mutating func addField(named name: String) {
        var field = Anki_Notetypes_Notetype.Field()
        field.name = name
        field.clearOrd()
        field.config = Anki_Notetypes_Notetype.Field.Config()
        fields.append(field)
    }

    /// Renames the field at `index` (a no-op for an out-of-range index).
    mutating func renameField(at index: Int, to name: String) {
        guard fields.indices.contains(index) else { return }
        fields[index].name = name
    }

    /// Moves the field at `source` to `destination`.
    ///
    /// The sort field is left untouched: on save the engine treats
    /// `config.sort_field_idx` as the *ord* of the sort field and remaps it to the
    /// field's new index (`reposition_sort_idx`), so reordering the array — which
    /// keeps each field's `ord` — automatically keeps the sort field tracking the
    /// same field.
    mutating func moveField(from source: Int, to destination: Int) {
        guard fields.indices.contains(source) else { return }
        let clampedDestination = min(max(destination, 0), fields.count - 1)
        guard source != clampedDestination else { return }
        let field = fields.remove(at: source)
        fields.insert(field, at: clampedDestination)
    }

    /// Removes the field at `index`, refusing to drop the last field (a note type
    /// needs ≥1 field). `config.sort_field_idx` holds the sort field's ord, so it
    /// is left as-is when another field is removed (the engine remaps it); if the
    /// sort field itself is removed, it falls back to the first remaining field.
    mutating func removeField(at index: Int) {
        guard fields.count > 1, fields.indices.contains(index) else { return }
        let removedIsSortField = fields[index].hasOrd && fields[index].ord.val == config.sortFieldIdx
        fields.remove(at: index)
        if removedIsSortField {
            config.sortFieldIdx = fields.first.map { $0.hasOrd ? $0.ord.val : 0 } ?? 0
        }
    }

    /// Marks the field at `index` as the sort field. Stored as the field's `ord`
    /// (which the engine maps to the field's current index on save).
    mutating func setSortField(at index: Int) {
        guard fields.indices.contains(index) else { return }
        config.sortFieldIdx = fields[index].hasOrd ? fields[index].ord.val : UInt32(index)
    }

    // MARK: - Templates

    /// Sets the question/answer format of the template at `ord`.
    mutating func setTemplate(at ord: Int, front: String, back: String) {
        guard templates.indices.contains(ord) else { return }
        templates[ord].config.qFormat = front
        templates[ord].config.aFormat = back
    }

    /// Sets the shared styling (CSS) applied to every card of the note type.
    mutating func setCSS(_ css: String) {
        config.css = css
    }

    /// Appends a new card template seeded with a usable, *distinct* front/back so
    /// it passes the engine's validation on save: the front must contain a field
    /// replacement and must not be identical to an existing template's front. The
    /// seed shows the second field on the front (a "reverse"-style card) and the
    /// first field on the back, which differs from a typical first template. The
    /// user can then edit it freely before saving.
    mutating func addTemplate(named name: String) {
        var template = Anki_Notetypes_Notetype.Template()
        template.name = name
        template.clearOrd()
        var templateConfig = Anki_Notetypes_Notetype.Template.Config()
        let firstField = fields.first?.name ?? "Front"
        let secondField = fields.count > 1 ? fields[1].name : firstField
        templateConfig.qFormat = "{{\(secondField)}}"
        templateConfig.aFormat = "{{FrontSide}}\n\n<hr id=answer>\n\n{{\(firstField)}}"
        template.config = templateConfig
        templates.append(template)
    }

    /// Renames the template at `ord`.
    mutating func renameTemplate(at ord: Int, to name: String) {
        guard templates.indices.contains(ord) else { return }
        templates[ord].name = name
    }

    /// Moves the template at `source` to `destination`.
    mutating func moveTemplate(from source: Int, to destination: Int) {
        guard templates.indices.contains(source) else { return }
        let clampedDestination = min(max(destination, 0), templates.count - 1)
        guard source != clampedDestination else { return }
        let template = templates.remove(at: source)
        templates.insert(template, at: clampedDestination)
    }

    /// Removes the template at `ord`, refusing to drop the last template (a normal
    /// note type needs ≥1 card type). The engine separately refuses a removal
    /// that would orphan notes.
    mutating func removeTemplate(at ord: Int) {
        guard templates.count > 1, templates.indices.contains(ord) else { return }
        templates.remove(at: ord)
    }
}
