#!/usr/bin/env python3
"""Generate ftl_index.json: Fluent key -> [module_index, message_index].

The engine translates strings by numeric index (`translate_string(module,
message)`), where the indices come from the generated `_KEYS_BY_MODULE` ordering
compiled into the engine. This script parses that generated `strings.rs`
(produced by the anki_i18n build script when we build the xcframework) and emits
a compact key->[module, message] map the iOS app bundles, so native SwiftUI
strings can pull from Anki's own translation catalog — the same mechanism Anki
Desktop and AnkiDroid use.

Re-run after upgrading the engine (indices can shift when strings are added):

    python3 tools/gen_ftl_index.py
"""
import json
import re
import sys
from pathlib import Path


def find_strings_rs(root: Path) -> Path:
    # Prefer a release build (matches what the shipping app links); fall back to
    # any build. All targets share identical indices (same ftl source).
    patterns = [
        "AnkiCore/target/**/release/build/anki_i18n-*/out/strings.rs",
        "AnkiCore/target/**/build/anki_i18n-*/out/strings.rs",
    ]
    for pattern in patterns:
        matches = sorted(root.glob(pattern))
        if matches:
            return matches[0]
    sys.exit("strings.rs not found — build the engine first (AnkiCore/build-xcframework.sh)")


def main() -> None:
    root = Path(__file__).resolve().parent.parent  # anki-ios/
    src = find_strings_rs(root)
    text = src.read_text()

    # Each module's ordered keys: `pub(crate) const NAME_KEYS: [&str; N] = [ "k", ... ];`
    module_keys: dict[str, list[str]] = {}
    for match in re.finditer(
        r"pub\(crate\) const (\w+): \[&str; \d+\] = \[(.*?)\];", text, re.DOTALL
    ):
        module_keys[match.group(1)] = re.findall(r'"([^"]+)"', match.group(2))

    # Module order: `_KEYS_BY_MODULE: [&[&str]; N] = [ &ABOUT_KEYS, ... ];`
    by_module = re.search(
        r"_KEYS_BY_MODULE: \[&\[&str\]; \d+\] = \[(.*?)\];", text, re.DOTALL
    )
    if not by_module:
        sys.exit("_KEYS_BY_MODULE not found in strings.rs")
    module_order = re.findall(r"&(\w+)", by_module.group(1))

    index: dict[str, list[int]] = {}
    for module_idx, module_name in enumerate(module_order):
        for message_idx, key in enumerate(module_keys[module_name]):
            index[key] = [module_idx, message_idx]

    out = root / "AnkiApp" / "Resources" / "ftl_index.json"
    out.write_text(json.dumps(index, separators=(",", ":"), sort_keys=True) + "\n")
    print(f"wrote {len(index)} keys from {len(module_order)} modules -> {out.relative_to(root)}")


if __name__ == "__main__":
    main()
