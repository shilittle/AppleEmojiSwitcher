"""Generate the offline Emoji 18.0 picker catalog.

The picker deliberately consumes checked-in Unicode and CLDR source snapshots.
No network access is performed by this script.  The source manifest pins every
input by byte length and SHA-256 so a catalog can be rebuilt on an offline
machine and produce the same UTF-8/LF TSV.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import unicodedata
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
DATA_ROOT = ROOT / "picker" / "data"
SOURCE_ROOT = ROOT / "picker" / "sources"
DEFAULT_MANIFEST = DATA_ROOT / "sources.json"
DEFAULT_OUTPUT = DATA_ROOT / "catalog.tsv"
DEFAULT_REPORT = DATA_ROOT / "catalog-report.json"
GENERATOR_VERSION = "1"
EXPECTED_UNICODE_VERSION = "18.0"
EXPECTED_FULLY_QUALIFIED_COUNT = 3963
EXPECTED_NEW_COUNT = 19

# emoji-test.txt defines these category names in English.  Unicode does not
# publish a separate official Chinese category-name file.  These stable UI
# translations are therefore recorded as local translations in the report;
# they are never presented as CLDR data.
GROUP_ZH = {
    "Smileys & Emotion": "笑脸与情感",
    "People & Body": "人物与身体",
    "Component": "组件",
    "Animals & Nature": "动物与自然",
    "Food & Drink": "食物与饮料",
    "Travel & Places": "旅行与地点",
    "Activities": "活动",
    "Objects": "物品",
    "Symbols": "符号",
    "Flags": "旗帜",
}
VALID_PREVIEW_KINDS = {"system", "apple", "noto"}


class CatalogError(ValueError):
    """Raised when pinned picker input is missing or inconsistent."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=False) + "\n").encode("utf-8")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(json_bytes(value))


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise CatalogError(f"无法读取 JSON 输入：{path}: {exc}") from exc


def clean_text(value: Any, field: str = "text") -> str:
    """Normalize a label and remove all C0/C1 control characters.

    The TSV contract forbids tabs and line breaks.  Whitespace controls are
    converted to ordinary spaces before collapsing whitespace; all remaining
    Unicode control characters are discarded.  ZWJ/variation selectors are
    intentionally not passed through this function because the sequence field
    must preserve them byte-for-byte as Unicode scalar values.
    """

    if not isinstance(value, str):
        raise CatalogError(f"{field} 必须是字符串")
    normalized = unicodedata.normalize("NFC", value)
    chars: list[str] = []
    for char in normalized:
        category = unicodedata.category(char)
        if category == "Cc":
            if char in "\t\n\r\f\v":
                chars.append(" ")
            continue
        chars.append(char)
    return " ".join("".join(chars).split())


def parse_codepoints(text: str) -> tuple[int, ...]:
    values: list[int] = []
    for token in text.split():
        try:
            value = int(token, 16)
        except ValueError as exc:
            raise CatalogError(f"Unicode codepoint 无效：{text}") from exc
        if not 0 <= value <= 0x10FFFF:
            raise CatalogError(f"Unicode codepoint 超出范围：{text}")
        values.append(value)
    if not values:
        raise CatalogError("Unicode codepoint 序列为空")
    return tuple(values)


def format_id(codepoints: Iterable[int]) -> str:
    return "-".join(f"{value:X}" for value in codepoints)


def sequence_for(codepoints: Iterable[int]) -> str:
    return "".join(chr(value) for value in codepoints)


def load_source_manifest(path: Path) -> dict[str, Any]:
    manifest = read_json(path)
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != 1:
        raise CatalogError("sources.json 的 schemaVersion 必须为 1")
    unicode_source = manifest.get("unicode")
    cldr_source = manifest.get("cldr")
    if not isinstance(unicode_source, dict) or not isinstance(cldr_source, dict):
        raise CatalogError("sources.json 缺少 unicode 或 cldr provenance")
    if unicode_source.get("version") != EXPECTED_UNICODE_VERSION:
        raise CatalogError("sources.json 的 Unicode 版本必须为 18.0")
    if cldr_source.get("version") != "49.0.0-ALPHA2":
        raise CatalogError("sources.json 的 CLDR 版本必须为 49.0.0-ALPHA2")
    files = cldr_source.get("files")
    if not isinstance(files, dict) or set(files) != {"zh", "en", "zh-derived", "en-derived"}:
        raise CatalogError("sources.json 必须固定 zh/en 及 derived 四个 CLDR 文件")
    for key, item in files.items():
        if not isinstance(item, dict) or not item.get("file") or not item.get("sha256") or not item.get("size"):
            raise CatalogError(f"sources.json 缺少 CLDR {key} 文件固定校验值")
    if not unicode_source.get("file") or not unicode_source.get("sha256") or not unicode_source.get("size"):
        raise CatalogError("sources.json 缺少 emoji-test.txt 固定校验值")
    return manifest


def resolve_source_path(manifest_path: Path, source: dict[str, Any], override: Path | None = None) -> Path:
    if override is not None:
        return override
    value = source.get("file")
    if not isinstance(value, str):
        raise CatalogError("来源文件路径必须是字符串")
    return (manifest_path.parent / value).resolve()


def verify_source_file(path: Path, pin: dict[str, Any], label: str) -> dict[str, Any]:
    if not path.is_file():
        raise CatalogError(f"找不到固定来源 {label}：{path}")
    expected_size = pin.get("size")
    expected_hash = pin.get("sha256")
    if not isinstance(expected_size, int) or not isinstance(expected_hash, str):
        raise CatalogError(f"固定来源 {label} 缺少 size/SHA-256")
    actual_size = path.stat().st_size
    actual_hash = sha256(path)
    if actual_size != expected_size or actual_hash != expected_hash:
        raise CatalogError(
            f"固定来源 {label} 未通过校验：size={actual_size}/{expected_size}, sha256={actual_hash}/{expected_hash}"
        )
    return {
        "file": str(path),
        "size": actual_size,
        "sha256": actual_hash,
        "url": pin.get("url"),
        "verified": True,
    }


def report_path(path: Path) -> str:
    """Return a stable repository-relative path for generated provenance."""

    try:
        return str(path.resolve().relative_to(ROOT)).replace("\\", "/")
    except ValueError:
        return path.name


def parse_emoji_test(path: Path) -> tuple[str, list[dict[str, Any]]]:
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except (OSError, UnicodeError) as exc:
        raise CatalogError(f"无法读取 emoji-test.txt：{path}: {exc}") from exc

    version = ""
    group = ""
    subgroup = ""
    entries: list[dict[str, Any]] = []
    for line_number, line in enumerate(lines, 1):
        if line.startswith("# Version:"):
            version = line.split(":", 1)[1].strip()
        elif line.startswith("# group:"):
            group = clean_text(line.split(":", 1)[1].strip(), "group")
            subgroup = ""
        elif line.startswith("# subgroup:"):
            subgroup = clean_text(line.split(":", 1)[1].strip(), "subgroup")
        if "#" not in line or ";" not in line:
            continue
        left, comment = line.split("#", 1)
        fields = left.strip().split(";")
        if len(fields) != 2 or fields[1].strip() != "fully-qualified":
            continue
        match = re.search(r"\sE(?P<age>[0-9]+(?:\.[0-9]+)?)\s+(?P<name>.+?)\s*$", comment.strip())
        if not match:
            raise CatalogError(f"emoji-test.txt 第 {line_number} 行缺少 E 版本或名称")
        codepoints = parse_codepoints(fields[0].strip())
        if not group or not subgroup:
            raise CatalogError(f"emoji-test.txt 第 {line_number} 行缺少 group/subgroup")
        entries.append(
            {
                "codepoints": codepoints,
                "sequence": sequence_for(codepoints),
                "id": format_id(codepoints),
                "version": match.group("age"),
                "sourceNameEn": clean_text(match.group("name"), "Unicode name"),
                "group": group,
                "subgroup": subgroup,
                "sourceLine": line_number,
            }
        )

    if version != EXPECTED_UNICODE_VERSION:
        raise CatalogError(f"emoji-test.txt 版本为 {version!r}，要求 18.0")
    if len(entries) != EXPECTED_FULLY_QUALIFIED_COUNT:
        raise CatalogError(
            f"Emoji 18.0 fully-qualified 条目数为 {len(entries)}，要求 {EXPECTED_FULLY_QUALIFIED_COUNT}"
        )
    if len({item["codepoints"] for item in entries}) != len(entries):
        raise CatalogError("fully-qualified 条目存在重复 Unicode 序列")
    new_entries = [item for item in entries if item["version"] == EXPECTED_UNICODE_VERSION]
    if len(new_entries) != EXPECTED_NEW_COUNT:
        raise CatalogError(f"Emoji 18.0 新增条目数为 {len(new_entries)}，要求 {EXPECTED_NEW_COUNT}")
    return version, entries


def count_component_rows(path: Path) -> int:
    """Count the nine non-fully-qualified skin/hair component rows.

    Unicode's broad Emoji Counts total includes these component rows, while
    this picker contract explicitly asks for the fully-qualified repertoire.
    Keeping the count in the report prevents the two valid totals from being
    mistaken for one another.
    """

    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except (OSError, UnicodeError) as exc:
        raise CatalogError(f"无法读取 emoji-test.txt：{path}: {exc}") from exc
    count = 0
    for line in lines:
        if ";" not in line:
            continue
        fields = line.split("#", 1)[0].strip().split(";")
        if len(fields) == 2 and fields[1].strip() == "component":
            count += 1
    return count


def annotation_map(path: Path, root_key: str) -> dict[str, dict[str, Any]]:
    data = read_json(path)
    try:
        value = data[root_key]["annotations"]
    except (KeyError, TypeError) as exc:
        raise CatalogError(f"CLDR 文件缺少 {root_key}.annotations：{path}") from exc
    if not isinstance(value, dict):
        raise CatalogError(f"CLDR annotations 不是对象：{path}")
    return value


def annotation_value(value: Any, path: Path, key: str) -> dict[str, Any] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise CatalogError(f"CLDR 条目不是对象：{path} / {key}")
    tts = value.get("tts")
    defaults = value.get("default", [])
    if not isinstance(tts, list) or not tts or not isinstance(tts[0], str):
        return None
    if not isinstance(defaults, list) or not all(isinstance(item, str) for item in defaults):
        raise CatalogError(f"CLDR 条目 default 无效：{path} / {key}")
    keywords = list(dict.fromkeys(clean_text(item, "CLDR keyword") for item in defaults if clean_text(item, "CLDR keyword")))
    return {"name": clean_text(tts[0], "CLDR tts"), "keywords": keywords}


def find_annotation(
    codepoints: Iterable[int],
    direct: dict[str, dict[str, Any]],
    derived: dict[str, dict[str, Any]],
    path: Path,
) -> tuple[dict[str, Any] | None, str | None]:
    sequence = sequence_for(codepoints)
    candidates = (sequence, sequence.replace("\ufe0f", ""))
    for candidate in candidates:
        if candidate in direct:
            return annotation_value(direct[candidate], path, candidate), "direct"
    for candidate in candidates:
        if candidate in derived:
            return annotation_value(derived[candidate], path, candidate), "derived"
    return None, None


def keyword_tokens(values: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        cleaned = clean_text(value, "keyword")
        for token in cleaned.split(" "):
            if token and token not in seen:
                seen.add(token)
                result.append(token)
    return result


def load_preview_report(output_path: Path) -> tuple[dict[str, str], Path | None]:
    report_path = output_path.parent / "preview-report.json"
    if not report_path.is_file():
        return {}, None
    data = read_json(report_path)
    images = data.get("images") if isinstance(data, dict) else None
    if not isinstance(images, list):
        raise CatalogError(f"preview-report.json 缺少 images 数组：{report_path}")
    result: dict[str, str] = {}
    for item in images:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not isinstance(item.get("source"), str):
            raise CatalogError(f"preview-report.json 条目缺少 id/source：{report_path}")
        identifier = item["id"]
        source = item["source"]
        if source not in {"apple", "noto", "system"}:
            raise CatalogError(f"preview-report.json source 无效：{source}")
        if identifier in result and result[identifier] != source:
            raise CatalogError(f"preview-report.json 存在重复且冲突的 id：{identifier}")
        result[identifier] = source
    return result, report_path


def build_catalog(
    entries: list[dict[str, Any]],
    labels: dict[str, dict[str, Any]],
    preview_sources: dict[str, str] | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    direct_zh, derived_zh = labels["zh"]["direct"], labels["zh"]["derived"]
    direct_en, derived_en = labels["en"]["direct"], labels["en"]["derived"]
    preview_sources = preview_sources or {}
    result: list[dict[str, Any]] = []
    missing_zh: list[str] = []
    missing_en: list[str] = []
    annotation_source_counts = {"zh-direct": 0, "zh-derived": 0, "en-direct": 0, "en-derived": 0}
    for item in entries:
        zh, zh_source = find_annotation(item["codepoints"], direct_zh, derived_zh, labels["zh"]["path"])
        en, en_source = find_annotation(item["codepoints"], direct_en, derived_en, labels["en"]["path"])
        if zh is None:
            missing_zh.append(item["id"])
        if en is None:
            missing_en.append(item["id"])
        if zh_source:
            annotation_source_counts[f"zh-{zh_source}"] += 1
        if en_source:
            annotation_source_counts[f"en-{en_source}"] += 1

        name_en = en["name"] if en else item["sourceNameEn"]
        name_zh = zh["name"] if zh else name_en
        group_zh = GROUP_ZH.get(item["group"], item["group"])
        preview_kind = preview_sources.get(item["id"], "system")
        if preview_kind not in VALID_PREVIEW_KINDS:
            raise CatalogError(f"previewKind 无效：{item['id']}={preview_kind}")
        keywords = keyword_tokens(
            [
                name_zh,
                name_en,
                item["sourceNameEn"],
                group_zh,
                item["group"],
                item["subgroup"],
                item["id"],
                *(f"{value:X}" for value in item["codepoints"]),
                *(f"U+{value:X}" for value in item["codepoints"]),
                *(zh["keywords"] if zh else []),
                *(en["keywords"] if en else []),
            ]
        )
        result.append(
            {
                "id": item["id"],
                "sequence": item["sequence"],
                "nameZh": name_zh,
                "nameEn": name_en,
                "groupZh": group_zh,
                "version": item["version"],
                "keywords": keywords,
                "previewKind": preview_kind,
                "codepoints": item["codepoints"],
                "group": item["group"],
                "subgroup": item["subgroup"],
                "sourceLine": item["sourceLine"],
            }
        )
    return result, {
        "missingLabels": {"zh": missing_zh, "en": missing_en},
        "annotationSourceCounts": annotation_source_counts,
    }


def render_catalog(catalog: Iterable[dict[str, Any]]) -> bytes:
    fields = ("id", "sequence", "nameZh", "nameEn", "groupZh", "version", "keywords", "previewKind")
    lines: list[str] = []
    for item in catalog:
        values = [
            item["id"],
            item["sequence"],
            item["nameZh"],
            item["nameEn"],
            item["groupZh"],
            item["version"],
            " ".join(item["keywords"]),
            item["previewKind"],
        ]
        if len(values) != len(fields) or any("\t" in value or "\r" in value or "\n" in value for value in values):
            raise CatalogError(f"目录字段含有非法 tab/newline：{item['id']}")
        lines.append("\t".join(values))
    return ("\n".join(lines) + "\n").encode("utf-8")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--emoji-test", type=Path)
    parser.add_argument("--cldr-zh", type=Path)
    parser.add_argument("--cldr-en", type=Path)
    parser.add_argument("--cldr-derived-zh", type=Path)
    parser.add_argument("--cldr-derived-en", type=Path)
    parser.add_argument("--output", "--catalog-out", dest="output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    manifest_path = args.source_manifest.resolve()
    manifest = load_source_manifest(manifest_path)
    unicode_pin = manifest["unicode"]
    cldr_pin = manifest["cldr"]["files"]
    emoji_path = resolve_source_path(manifest_path, unicode_pin, args.emoji_test)
    source_provenance = {"unicode": verify_source_file(emoji_path, unicode_pin, "emoji-test.txt")}
    source_provenance["unicode"]["file"] = report_path(emoji_path)
    cldr_paths = {
        "zh": resolve_source_path(manifest_path, cldr_pin["zh"], args.cldr_zh),
        "en": resolve_source_path(manifest_path, cldr_pin["en"], args.cldr_en),
        "zh-derived": resolve_source_path(manifest_path, cldr_pin["zh-derived"], args.cldr_derived_zh),
        "en-derived": resolve_source_path(manifest_path, cldr_pin["en-derived"], args.cldr_derived_en),
    }
    source_provenance["cldr"] = {
        key: verify_source_file(cldr_paths[key], cldr_pin[key], f"CLDR {key}") for key in cldr_paths
    }
    for item in source_provenance["cldr"].values():
        item["file"] = report_path(Path(item["file"]))

    version, entries = parse_emoji_test(emoji_path)
    component_count = count_component_rows(emoji_path)
    labels = {
        "zh": {
            "direct": annotation_map(cldr_paths["zh"], "annotations"),
            "derived": annotation_map(cldr_paths["zh-derived"], "annotationsDerived"),
            "path": cldr_paths["zh"],
        },
        "en": {
            "direct": annotation_map(cldr_paths["en"], "annotations"),
            "derived": annotation_map(cldr_paths["en-derived"], "annotationsDerived"),
            "path": cldr_paths["en"],
        },
    }
    preview_sources, preview_report_path = load_preview_report(args.output.resolve())
    catalog, build_report = build_catalog(entries, labels, preview_sources)
    output_bytes = render_catalog(catalog)
    output_path = args.output.resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(output_bytes)

    preview_counts = {kind: sum(item["previewKind"] == kind for item in catalog) for kind in sorted(VALID_PREVIEW_KINDS)}
    latest = [
        {
            "id": item["id"],
            "sequence": item["sequence"],
            "nameZh": item["nameZh"],
            "nameEn": item["nameEn"],
        }
        for item in catalog
        if item["version"] == EXPECTED_UNICODE_VERSION
    ]
    if preview_report_path:
        try:
            preview_report_name = str(preview_report_path.relative_to(ROOT)).replace("\\", "/")
        except ValueError:
            preview_report_name = str(preview_report_path)
    else:
        preview_report_name = None
    report = {
        "schemaVersion": 1,
        "generator": {"path": "scripts/generate-picker-catalog.py", "version": GENERATOR_VERSION},
        "unicodeVersion": version,
        "sourceManifest": "picker/data/sources.json",
        "sources": source_provenance,
        "catalog": {
            "path": "picker/data/catalog.tsv",
            "sha256": hashlib.sha256(output_bytes).hexdigest(),
            "size": len(output_bytes),
            "encoding": "UTF-8",
            "newline": "LF",
            "header": False,
            "columns": ["id", "sequence", "nameZh", "nameEn", "groupZh", "version", "keywords", "previewKind"],
        },
        "counts": {
            "fullyQualified": len(catalog),
            "newInVersion": len(latest),
            "groups": len({item["group"] for item in catalog}),
            "componentRowsExcluded": component_count,
            "broadEmojiTotalIncludingComponents": len(catalog) + component_count,
            "previewKinds": preview_counts,
        },
        "catalogScope": "fully-qualified only; component rows are excluded by contract",
        "latest": latest,
        "missingLabels": build_report["missingLabels"],
        "annotationSourceCounts": build_report["annotationSourceCounts"],
        "localTranslations": {"groupZh": GROUP_ZH, "source": "local-ui-translation; not CLDR official data"},
        "preview": {
            "report": preview_report_name,
            "restored": sum(item["previewKind"] != "system" for item in catalog),
            "default": "system",
        },
        "validation": {
            "idsUnique": len({item["id"] for item in catalog}) == len(catalog),
            "sequencesUnique": len({item["sequence"] for item in catalog}) == len(catalog),
            "latestCountMatchesUnicode": len(latest) == EXPECTED_NEW_COUNT,
            "allFieldsControlFree": all(
                not any(char in "\t\r\n" for char in field)
                for item in catalog
                for field in (
                    item["id"], item["sequence"], item["nameZh"], item["nameEn"], item["groupZh"],
                    item["version"], " ".join(item["keywords"]), item["previewKind"],
                )
            ),
        },
    }
    write_json(args.report.resolve(), report)
    print(json.dumps({"entries": len(catalog), "latest": len(latest), "output": str(output_path), "report": str(args.report.resolve())}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CatalogError as exc:
        raise SystemExit(f"错误：{exc}")
