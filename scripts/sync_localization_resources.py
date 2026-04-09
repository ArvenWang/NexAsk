#!/usr/bin/env python3
from __future__ import annotations

import argparse
import difflib
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]
SOURCE_DIRS = [
    ROOT_DIR / "Sources",
]
RESOURCE_DIR = ROOT_DIR / "Sources" / "NexShared" / "LocalizationResources"
CATALOG_PATHS = {
    "zh-Hans": RESOURCE_DIR / "zh-Hans.json",
    "en": RESOURCE_DIR / "en.json",
}
CALL_PATTERN = re.compile(r"\b(?:L10n\.(?:text|format)|localizedContentText|localized)\s*\(")
STRING_ARGUMENT_PATTERNS = {
    name: re.compile(rf"\b{name}\s*:\s*\"((?:[^\"\\]|\\.)*)\"", re.DOTALL)
    for name in ("key", "zhHans", "en")
}


@dataclass(frozen=True)
class LocalizationEntry:
    key: str
    zh_hans: str
    en: str
    source: str


def automatic_key(zh_hans: str, en: str) -> str:
    value = 0xCBF29CE484222325
    payload = f"{zh_hans}\0{en}".encode("utf-8")
    for byte in payload:
        value ^= byte
        value = (value * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"auto.{value:016x}"


def decode_swift_string(raw: str) -> str:
    decoded: list[str] = []
    index = 0
    while index < len(raw):
        character = raw[index]
        if character != "\\":
            decoded.append(character)
            index += 1
            continue

        index += 1
        if index >= len(raw):
            decoded.append("\\")
            break

        escape = raw[index]
        index += 1
        if escape == "n":
            decoded.append("\n")
        elif escape == "r":
            decoded.append("\r")
        elif escape == "t":
            decoded.append("\t")
        elif escape == '"':
            decoded.append('"')
        elif escape == "\\":
            decoded.append("\\")
        elif escape == "u" and index < len(raw) and raw[index] == "{":
            end_index = raw.find("}", index + 1)
            if end_index == -1:
                raise ValueError(f"Invalid unicode escape: \\u{raw[index:]}")
            decoded.append(chr(int(raw[index + 1:end_index], 16)))
            index = end_index + 1
        elif escape == "(":
            raise ValueError("String interpolation is not supported in localized string literals")
        else:
            decoded.append(escape)
    return "".join(decoded)


def extract_named_string(arguments: str, name: str) -> str | None:
    match = STRING_ARGUMENT_PATTERNS[name].search(arguments)
    if match is None:
        return None
    return decode_swift_string(match.group(1))


def find_matching_paren(text: str, open_index: int) -> int:
    depth = 0
    index = open_index
    in_string = False
    escaped = False

    while index < len(text):
        character = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            index += 1
            continue

        if character == '"':
            in_string = True
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return index
        index += 1

    raise ValueError("Unbalanced parentheses in localized call")


def iter_entries(path: Path) -> list[LocalizationEntry]:
    text = path.read_text()
    entries: list[LocalizationEntry] = []

    for match in CALL_PATTERN.finditer(text):
        open_index = text.find("(", match.start())
        close_index = find_matching_paren(text, open_index)
        arguments = text[open_index + 1:close_index]
        zh_hans = extract_named_string(arguments, "zhHans")
        en = extract_named_string(arguments, "en")
        if zh_hans is None or en is None:
            continue

        explicit_key = extract_named_string(arguments, "key")
        key = explicit_key or automatic_key(zh_hans, en)
        source = f"{path.relative_to(ROOT_DIR)}:{text.count(chr(10), 0, match.start()) + 1}"
        entries.append(LocalizationEntry(key=key, zh_hans=zh_hans, en=en, source=source))

    return entries


def collect_entries() -> dict[str, LocalizationEntry]:
    collected: dict[str, LocalizationEntry] = {}
    conflicts: list[str] = []

    for source_dir in SOURCE_DIRS:
        for path in sorted(source_dir.rglob("*.swift")):
            for entry in iter_entries(path):
                existing = collected.get(entry.key)
                if existing is None:
                    collected[entry.key] = entry
                    continue
                if existing.zh_hans != entry.zh_hans or existing.en != entry.en:
                    conflicts.append(
                        f"Key {entry.key} has conflicting values:\n"
                        f"  {existing.source}: zh-Hans={existing.zh_hans!r} en={existing.en!r}\n"
                        f"  {entry.source}: zh-Hans={entry.zh_hans!r} en={entry.en!r}"
                    )

    if conflicts:
        raise ValueError("\n\n".join(conflicts))

    return collected


def build_catalogs(entries: dict[str, LocalizationEntry]) -> dict[str, dict[str, str]]:
    explicit_entries = {key: entry for key, entry in entries.items() if not key.startswith("auto.")}
    auto_entries = {key: entry for key, entry in entries.items() if key.startswith("auto.")}

    catalogs: dict[str, dict[str, str]] = {}
    for language, path in CATALOG_PATHS.items():
        existing = json.loads(path.read_text())
        merged = {
            key: value
            for key, value in existing.items()
            if key not in explicit_entries and not key.startswith("auto.")
        }

        for key, entry in explicit_entries.items():
            merged[key] = entry.zh_hans if language == "zh-Hans" else entry.en
        for key, entry in auto_entries.items():
            merged[key] = entry.zh_hans if language == "zh-Hans" else entry.en

        catalogs[language] = dict(sorted(merged.items()))
    return catalogs


def format_json(payload: dict[str, str]) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Sync Swift localization literals into bundled JSON catalogs.")
    parser.add_argument("--check", action="store_true", help="Validate catalogs without writing files.")
    args = parser.parse_args()

    try:
        entries = collect_entries()
        catalogs = build_catalogs(entries)
    except ValueError as error:
        print(f"Localization sync failed:\n{error}", file=sys.stderr)
        return 1

    has_diff = False
    for language, path in CATALOG_PATHS.items():
        rendered = format_json(catalogs[language])
        current = path.read_text()
        if current == rendered:
            continue

        has_diff = True
        if args.check:
            diff = difflib.unified_diff(
                current.splitlines(),
                rendered.splitlines(),
                fromfile=str(path),
                tofile=str(path),
                lineterm="",
            )
            print("\n".join(diff))
        else:
            path.write_text(rendered)
            print(f"Updated {path.relative_to(ROOT_DIR)}")

    if args.check and has_diff:
        print("Localization resources are out of sync. Run scripts/sync_localization_resources.py.", file=sys.stderr)
        return 1

    if not has_diff:
        print(f"Localization resources are in sync ({len(entries)} entries).")
    elif not args.check:
        print(f"Localization resources synced ({len(entries)} entries).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
