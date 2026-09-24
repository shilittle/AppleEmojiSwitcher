"""Generate the Emoji 17.0 panel catalog and its C++ embedding.

The generator intentionally consumes the already pinned Unicode emoji-test.txt
from the local AppleEmojiSwitcher cache.  CLDR labels are kept in a compact,
checked-in extraction whose provenance points at the official CLDR 48 source.
No font, renderer, or Windows component is needed to run this generator.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
DATA_ROOT = ROOT / "native" / "panel" / "data"
DEFAULT_LABEL_SOURCE = DATA_ROOT / "emoji17-labels.cldr48.json"
DEFAULT_SOURCE_MANIFEST = DATA_ROOT / "emoji17-sources.json"
DEFAULT_JSON = DATA_ROOT / "emoji17-catalog.json"
DEFAULT_HEADER = DATA_ROOT / "Emoji17Catalog.h"
GENERATOR_VERSION = "1"

EXPECTED_CLDR = {
    "tag": "48.0.0",
    "commit": "4d06be52b51bb2f75688d0abe55c52a66afed790",
    "archiveSha256": "25ab2651a1a874dd62a727d3c213d7c6bf0fc269b09d2937f0499b82d99fa58e",
}


class CatalogError(ValueError):
    """Raised when a pinned catalog input is missing or inconsistent."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(json_bytes(value))


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CatalogError(f"无法读取 JSON 输入：{path}: {exc}") from exc


def load_source_manifest(path: Path) -> dict[str, Any]:
    manifest = read_json(path)
    if manifest.get("schemaVersion") != 1:
        raise CatalogError("emoji17-sources.json 的 schemaVersion 必须为 1")
    cldr = manifest.get("cldr")
    if not isinstance(cldr, dict):
        raise CatalogError("emoji17-sources.json 缺少 cldr provenance")
    for key, expected in EXPECTED_CLDR.items():
        if cldr.get(key) != expected:
            raise CatalogError(f"CLDR provenance {key} 不符合固定 CLDR 48.0.0 来源")
    return manifest


def load_lock(lock_path: Path) -> dict[str, Any]:
    lock = read_json(lock_path)
    if lock.get("version") != 1:
        raise CatalogError("fonts.lock.json 的版本不受支持")
    unicode_items = {item.get("filename"): item for item in lock.get("unicode", [])}
    item = unicode_items.get("emoji-test.txt")
    if not item or not item.get("sha256") or not item.get("size"):
        raise CatalogError("fonts.lock.json 缺少 emoji-test.txt 固定校验值")
    return {"lock": lock, "emojiTest": item}


def verify_pinned_unicode(path: Path, lock_info: dict[str, Any]) -> dict[str, Any]:
    if not path.is_file():
        raise CatalogError(f"找不到 Unicode 输入：{path}")
    item = lock_info["emojiTest"]
    actual_size = path.stat().st_size
    actual_hash = sha256(path)
    if actual_size != item["size"] or actual_hash != item["sha256"]:
        raise CatalogError("emoji-test.txt 未通过 fonts.lock.json 校验")
    return {
        "filename": "emoji-test.txt",
        "url": item.get("url"),
        "sha256": actual_hash,
        "size": actual_size,
        "pinned": actual_size == item["size"] and actual_hash == item["sha256"],
    }


def parse_codepoints(text: str) -> tuple[int, ...]:
    try:
        return tuple(int(value, 16) for value in text.split())
    except ValueError as exc:
        raise CatalogError(f"Unicode codepoint 列表无效：{text}") from exc


def codepoint_key(codepoints: Iterable[int]) -> str:
    return " ".join(f"{value:X}" for value in codepoints if value != 0xFE0F)


def parse_emoji_test(path: Path) -> tuple[str, list[dict[str, Any]], list[dict[str, Any]]]:
    lines = path.read_text(encoding="utf-8-sig").splitlines()
    version = ""
    group = ""
    subgroup = ""
    full: list[dict[str, Any]] = []
    aliases: list[dict[str, Any]] = []
    for line_number, line in enumerate(lines, 1):
        if line.startswith("# Version:"):
            version = line.split(":", 1)[1].strip()
        elif line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
        elif line.startswith("# subgroup:"):
            subgroup = line.split(":", 1)[1].strip()
        if "#" not in line or ";" not in line:
            continue
        left, comment = line.split("#", 1)
        fields = left.strip().split(";")
        if len(fields) != 2:
            continue
        qualification = fields[1].strip()
        if qualification not in ("fully-qualified", "minimally-qualified"):
            continue
        # emoji-test comments are ``<sample> E<age> <Unicode name>``.  Keep
        # the sample out of the label and preserve the name exactly as the
        # Unicode source provides it.
        match = re.search(r"\sE(?P<age>[0-9]+(?:\.[0-9]+)?)\s+(?P<name>.+?)\s*$", comment.strip())
        if not match or match.group("age") != "17.0":
            continue
        codepoints = parse_codepoints(fields[0].strip())
        record = {
            "codepoints": list(codepoints),
            "sequence": "".join(chr(value) for value in codepoints),
            "unicodeNameEn": match.group("name"),
            "qualification": qualification,
            "group": group,
            "subgroup": subgroup,
            "sourceLine": line_number,
        }
        (full if qualification == "fully-qualified" else aliases).append(record)
    if version != "17.0":
        raise CatalogError(f"emoji-test.txt 版本为 {version!r}，要求 17.0")
    if len(full) != 163 or len(aliases) != 20:
        raise CatalogError(f"Emoji 17.0 条目数量不符合固定预期：fully-qualified={len(full)}, minimally-qualified={len(aliases)}")
    if len({tuple(item["codepoints"]) for item in full}) != len(full):
        raise CatalogError("fully-qualified 条目存在重复序列")
    if len({tuple(item["codepoints"]) for item in aliases}) != len(aliases):
        raise CatalogError("minimally-qualified 条目存在重复序列")
    return version, full, aliases


def cldr_annotations(path: Path, root_key: str) -> dict[str, dict[str, list[str]]]:
    data = read_json(path)
    try:
        value = data[root_key]["annotations"]
    except (KeyError, TypeError) as exc:
        raise CatalogError(f"CLDR 文件缺少 {root_key}.annotations：{path}") from exc
    if not isinstance(value, dict):
        raise CatalogError(f"CLDR annotations 不是对象：{path}")
    return value


def normalize_annotation(value: Any, path: Path, key: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CatalogError(f"CLDR 条目不是对象：{path} / {key}")
    name_values = value.get("tts")
    keywords = value.get("default", [])
    if not isinstance(name_values, list) or not name_values or not isinstance(name_values[0], str):
        raise CatalogError(f"CLDR 条目缺少 tts：{path} / {key}")
    if not isinstance(keywords, list) or not all(isinstance(item, str) for item in keywords):
        raise CatalogError(f"CLDR 条目 default 无效：{path} / {key}")
    ordered_keywords = list(dict.fromkeys([item for item in keywords if item]))
    return {"name": name_values[0], "keywords": ordered_keywords}


def find_annotation(
    codepoints: Iterable[int],
    direct: dict[str, dict[str, list[str]]],
    derived: dict[str, dict[str, list[str]]],
    path: Path,
) -> dict[str, Any]:
    sequence = "".join(chr(value) for value in codepoints)
    variants = (sequence, sequence.replace("\ufe0f", ""))
    for candidate in variants:
        if candidate in direct:
            return normalize_annotation(direct[candidate], path, candidate)
        if candidate in derived:
            return normalize_annotation(derived[candidate], path, candidate)
    raise CatalogError(f"CLDR 缺少 Emoji 17.0 条目：{codepoint_key(codepoints)}")


def extract_label_source(
    full: list[dict[str, Any]],
    source_manifest: dict[str, Any],
    cldr_paths: dict[str, Path],
) -> dict[str, Any]:
    for key in ("zh", "en", "zh-derived", "en-derived"):
        pinned = source_manifest["cldr"]["files"][key]
        path = cldr_paths[key]
        if not path.is_file() or path.stat().st_size != pinned["size"] or sha256(path) != pinned["sha256"]:
            raise CatalogError(f"CLDR {key} 未通过固定大小和 SHA-256 校验：{path}")
    labels: dict[str, dict[str, Any]] = {}
    for language in ("zh", "en"):
        direct = cldr_annotations(cldr_paths[language], "annotations")
        derived = cldr_annotations(cldr_paths[f"{language}-derived"], "annotationsDerived")
        labels[language] = {}
        for item in full:
            key = codepoint_key(item["codepoints"])
            labels[language][key] = find_annotation(
                item["codepoints"], direct, derived, cldr_paths[language]
            )
    return {
        "schemaVersion": 1,
        "source": source_manifest["cldr"],
        "normalization": "CLDR lookup tries the source sequence and then the same sequence without FE0F; generated output always preserves emoji-test codepoint order.",
        "labels": labels,
    }


def load_label_source(path: Path, source_manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    source = read_json(path)
    if source.get("schemaVersion") != 1:
        raise CatalogError("Emoji 17 label source schemaVersion 必须为 1")
    if source.get("source") != source_manifest["cldr"]:
        raise CatalogError("Emoji 17 label source 的 CLDR provenance 与固定来源不一致")
    labels = source.get("labels")
    if not isinstance(labels, dict) or not isinstance(labels.get("zh"), dict) or not isinstance(labels.get("en"), dict):
        raise CatalogError("Emoji 17 label source 缺少 zh/en labels")
    return labels


def build_catalog(
    version: str,
    full: list[dict[str, Any]],
    aliases: list[dict[str, Any]],
    labels: dict[str, dict[str, Any]],
    unicode_provenance: dict[str, Any],
    source_manifest: dict[str, Any],
) -> dict[str, Any]:
    entries: list[dict[str, Any]] = []
    index_by_key: dict[str, int] = {}
    for index, item in enumerate(full):
        key = codepoint_key(item["codepoints"])
        if key in index_by_key:
            raise CatalogError(f"Emoji 17 label key 重复：{key}")
        index_by_key[key] = index
        try:
            zh = labels["zh"][key]
            en = labels["en"][key]
        except KeyError as exc:
            raise CatalogError(f"Emoji 17 CLDR label source 缺少：{key}") from exc
        entry = {
            "index": index,
            **item,
            "nameEn": en["name"],
            "nameZh": zh["name"],
            "keywordsEn": en["keywords"],
            "keywordsZh": zh["keywords"],
        }
        entries.append(entry)

    alias_output: list[dict[str, Any]] = []
    for alias in aliases:
        key = codepoint_key(alias["codepoints"])
        canonical_index = index_by_key.get(key)
        if canonical_index is None:
            raise CatalogError(f"minimally-qualified 序列找不到对应 fully-qualified 条目：{key}")
        canonical = entries[canonical_index]
        alias_output.append(
            {
                "index": len(alias_output),
                **alias,
                "canonicalIndex": canonical_index,
                "nameEn": canonical["nameEn"],
                "nameZh": canonical["nameZh"],
                "keywordsEn": canonical["keywordsEn"],
                "keywordsZh": canonical["keywordsZh"],
            }
        )
    if {tuple(item["codepoints"]) for item in entries} & {tuple(item["codepoints"]) for item in alias_output}:
        raise CatalogError("alias 与 visible entry 发生重复")
    return {
        "schemaVersion": 1,
        "unicodeVersion": version,
        "entryCount": len(entries),
        "aliasCount": len(alias_output),
        "provenance": {
            "generator": "scripts/generate-panel-catalog.py",
            "generatorVersion": GENERATOR_VERSION,
            "unicode": unicode_provenance,
            "cldr": source_manifest["cldr"],
            "normalization": "Visible entries and aliases preserve emoji-test codepoint order. FE0F is removed only for CLDR label lookup and never from output sequences.",
        },
        "entries": entries,
        "aliases": alias_output,
    }


def c_literal(value: str) -> str:
    encoded = value.encode("utf-8")
    return '"' + "".join(f"\\x{byte:02X}" for byte in encoded) + '"'


def keyword_literal(values: Iterable[str]) -> str:
    return c_literal("\x1f".join(values))


def render_header(catalog: dict[str, Any]) -> str:
    entries = catalog["entries"]
    aliases = catalog["aliases"]
    lines = [
        "// Generated by scripts/generate-panel-catalog.py; do not edit.",
        "// UTF-8 strings are emitted as byte escapes for C++17 source portability.",
        "#pragma once",
        "",
        "#include <array>",
        "#include <cstdint>",
        "",
        "namespace aes::panel {",
        "",
        "inline constexpr char kEmoji17KeywordSeparator = '\\x1F';",
        "",
        "struct Emoji17Entry {",
        "    std::uint16_t index;",
        "    const char* sequence_utf8;",
        "    const char* name_en;",
        "    const char* name_zh;",
        "    const char* keywords_en;",
        "    const char* keywords_zh;",
        "    const char* group;",
        "    const char* subgroup;",
        "    std::uint8_t codepoint_count;",
        "};",
        "",
        "struct Emoji17Alias {",
        "    std::uint16_t index;",
        "    std::uint16_t canonical_index;",
        "    const char* sequence_utf8;",
        "    std::uint8_t codepoint_count;",
        "};",
        "",
        f"inline constexpr std::array<Emoji17Entry, {len(entries)}> kEmoji17Entries = {{{{",
    ]
    for item in entries:
        lines.append(
            "    {"
            + ", ".join(
                (
                    str(item["index"]),
                    c_literal(item["sequence"]),
                    c_literal(item["nameEn"]),
                    c_literal(item["nameZh"]),
                    keyword_literal(item["keywordsEn"]),
                    keyword_literal(item["keywordsZh"]),
                    c_literal(item["group"]),
                    c_literal(item["subgroup"]),
                    str(len(item["codepoints"])),
                )
            )
            + "},"
        )
    lines.extend(["}};", "", f"inline constexpr std::array<Emoji17Alias, {len(aliases)}> kEmoji17Aliases = {{{{" ])
    for item in aliases:
        lines.append(
            f"    {{{item['index']}, {item['canonicalIndex']}, {c_literal(item['sequence'])}, {len(item['codepoints'])}}},"
        )
    lines.extend(
        [
            "}};",
            "",
            f"inline constexpr char kEmoji17UnicodeVersion[] = {c_literal(catalog['unicodeVersion'])};",
            f"inline constexpr std::uint16_t kEmoji17EntryCount = {len(entries)};",
            f"inline constexpr std::uint16_t kEmoji17AliasCount = {len(aliases)};",
            "",
            "}  // namespace aes::panel",
            "",
        ]
    )
    return "\n".join(lines)


def default_unicode_path() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        return Path(local_app_data) / "AppleEmojiSwitcher" / "cache" / "unicode" / "emoji-test.txt"
    return ROOT / ".cache" / "unicode" / "emoji-test.txt"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emoji-test", type=Path, default=default_unicode_path())
    parser.add_argument("--lock", type=Path, default=ROOT / "fonts.lock.json")
    parser.add_argument("--source-manifest", type=Path, default=DEFAULT_SOURCE_MANIFEST)
    parser.add_argument("--label-source", type=Path, default=DEFAULT_LABEL_SOURCE)
    parser.add_argument("--cldr-zh", type=Path)
    parser.add_argument("--cldr-en", type=Path)
    parser.add_argument("--cldr-derived-zh", type=Path)
    parser.add_argument("--cldr-derived-en", type=Path)
    parser.add_argument("--label-source-out", type=Path)
    parser.add_argument("--json-out", type=Path, default=DEFAULT_JSON)
    parser.add_argument("--header-out", type=Path, default=DEFAULT_HEADER)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    source_manifest = load_source_manifest(args.source_manifest)
    lock_info = load_lock(args.lock)
    unicode_provenance = verify_pinned_unicode(args.emoji_test, lock_info)
    version, full, aliases = parse_emoji_test(args.emoji_test)

    cldr_values = (args.cldr_zh, args.cldr_en, args.cldr_derived_zh, args.cldr_derived_en)
    if any(value is not None for value in cldr_values):
        if not all(value is not None for value in cldr_values):
            raise CatalogError("使用完整 CLDR 输入时必须同时提供 zh/en 及 derived 四个文件")
        label_source = extract_label_source(
            full,
            source_manifest,
            {
                "zh": args.cldr_zh,
                "en": args.cldr_en,
                "zh-derived": args.cldr_derived_zh,
                "en-derived": args.cldr_derived_en,
            },
        )
        if args.label_source_out:
            write_json(args.label_source_out, label_source)
    else:
        label_source = {"labels": load_label_source(args.label_source, source_manifest)}

    catalog = build_catalog(
        version,
        full,
        aliases,
        label_source["labels"],
        unicode_provenance,
        source_manifest,
    )
    args.json_out.parent.mkdir(parents=True, exist_ok=True)
    args.json_out.write_bytes(json_bytes(catalog))
    args.header_out.parent.mkdir(parents=True, exist_ok=True)
    args.header_out.write_text(render_header(catalog), encoding="utf-8", newline="\n")
    print(json.dumps({"entries": len(full), "aliases": len(aliases), "json": str(args.json_out), "header": str(args.header_out)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CatalogError as exc:
        raise SystemExit(f"错误：{exc}")
