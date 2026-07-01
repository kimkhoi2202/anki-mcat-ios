import Foundation

public extension Backend {
    /// Translates a string from Anki's shared Fluent catalog by its (module,
    /// message) index — the same `translate_string` mechanism Anki Desktop and
    /// AnkiDroid use through their generated accessors.
    ///
    /// The indices come from the engine's generated `_KEYS_BY_MODULE` ordering
    /// (mapped from Fluent keys by `tools/gen_ftl_index.py` into the bundled
    /// `ftl_index.json`). The result is in the collection's configured language
    /// (set via `preferredLangs` when the collection is opened), falling back to
    /// English, and finally to the key name if the index is out of range.
    ///
    /// `args` supplies string substitutions for `{$var}` placeholders; numeric
    /// substitutions (used by some plural forms) use `numericArgs`.
    func translateString(
        module: UInt32,
        message: UInt32,
        args: [String: String] = [:],
        numericArgs: [String: Double] = [:]
    ) throws -> String {
        var request = Anki_I18n_TranslateStringRequest()
        request.moduleIndex = module
        request.messageIndex = message
        for (key, value) in args {
            var arg = Anki_I18n_TranslateArgValue()
            arg.str = value
            request.args[key] = arg
        }
        for (key, value) in numericArgs {
            var arg = Anki_I18n_TranslateArgValue()
            arg.number = value
            request.args[key] = arg
        }
        return try run(
            service: 35, method: 0, request, returning: Anki_Generic_String.self
        ).val
    }
}
