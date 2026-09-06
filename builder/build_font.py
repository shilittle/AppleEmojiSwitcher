"""Build a local Apple-first emoji font, with audited Windows-only additions.

This program never installs fonts or modifies Windows. Only a passed report with
matching input/output hashes can be accepted by the separate system transaction.
"""
from __future__ import annotations

import argparse
import copy
import json
import io
import math
import subprocess
import sys
import traceback
from datetime import datetime, timezone
from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.otlLib.builder import buildLigatureSubstSubtable, buildLookup
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont, newTable
from fontTools.ttLib.tables import otTables
from fontTools.ttLib.tables.BitmapGlyphMetrics import SmallGlyphMetrics
from fontTools.ttLib.tables.C_B_D_T_ import cbdt_bitmap_format_17
from fontTools.ttLib.tables.E_B_L_C_ import eblc_index_sub_table_1
from fontTools.ttLib.tables._c_m_a_p import CmapSubtable
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from font_audit import Entry, FontAudit, sha256, unicode_entries

VERSION = "1.1.0"
COMPATIBILITY_POLICY = "warn-on-local-display-differences-v1"
APPLE_HASH = "18e48f1785564fbf511241e0963b265057bfe742036d8543406c6ce07e48ec0b"


def progress(stage: str, message: str, percent: int):
    print(json.dumps({"stage": stage, "message": message, "percent": percent}, ensure_ascii=False), flush=True)


def write_json(path: Path, value):
    temp = path.with_suffix(path.suffix + ".partial")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    temp.replace(path)


def entry_dict(entry, source, glyph=None):
    return {"codepoints": entry.key, "text": entry.text, "name": entry.name,
            "qualification": entry.qualification, "source": source, "glyph": glyph}


def check_assets(apple: Path, unicode_dir: Path):
    lock_path = Path(__file__).resolve().parents[1] / "fonts.lock.json"
    lock = json.loads(lock_path.read_text(encoding="utf-8-sig"))
    if sha256(apple).lower() != APPLE_HASH or lock["font"]["sha256"].lower() != APPLE_HASH:
        raise ValueError("苹果字体未通过固定版本的 SHA-256 校验。")
    for asset in lock["unicode"]:
        path = unicode_dir / asset["filename"]
        if sha256(path).lower() != asset["sha256"].lower():
            raise ValueError(f"Unicode 数据校验失败：{path.name}")


def add_glyph(font, name, advance=0, lsb=0):
    # Decompile indexed metric tables BEFORE changing maxp.numGlyphs. Otherwise
    # an untouched raw vmtx table can be saved with too few entries: HarfBuzz
    # still shapes but DirectWrite then refuses the newly added outlines.
    vertical = font["vmtx"].metrics if "vmtx" in font else None
    order = font.getGlyphOrder()
    if name not in order:
        order.append(name)
        if len(order) >= 65535:
            raise ValueError("候选字体字形数超过安全上限。")
        font.setGlyphOrder(order)
        font["hmtx"].metrics[name] = (max(0, round(advance)), round(lsb))
        if vertical is not None:
            vertical[name] = (font["head"].unitsPerEm, 0)
        font["maxp"].numGlyphs = len(order)
    return name


def set_codepoint(font, cp, name):
    for table in font["cmap"].tables:
        if table.isUnicode() and table.format in (4, 12):
            if cp <= 0xFFFF or table.format == 12:
                table.cmap[cp] = name


def input_names(font, points):
    cmap = font.getBestCmap()
    names = []
    for cp in points:
        if cp not in cmap:
            name = add_glyph(font, f"aes.component.{cp:X}")
            set_codepoint(font, cp, name)
            cmap[cp] = name
        names.append(cmap[cp])
    return tuple(names)


def remap_lookup_references(node, delta, seen=None):
    """Inserting a lookup must also shift references from contextual lookups."""
    if seen is None:
        seen = set()
    if isinstance(node, (str, bytes, int, float, bool, type(None))):
        return
    if id(node) in seen:
        return
    seen.add(id(node))
    if isinstance(node, dict):
        children = node.values()
    elif isinstance(node, (list, tuple)):
        children = node
    elif hasattr(node, "__dict__"):
        for name, value in list(vars(node).items()):
            if name == "LookupListIndex":
                setattr(node, name, [x + delta for x in value] if isinstance(value, list) else value + delta)
        children = vars(node).values()
    else:
        return
    for child in children:
        remap_lookup_references(child, delta, seen)


def prepend_sequence_rules(font, mapping):
    if not mapping:
        return
    mapping = dict(sorted(mapping.items(), key=lambda pair: (-len(pair[0]), pair[0])))
    table = font["GSUB"].table
    remap_lookup_references(table, 1)
    table.LookupList.Lookup.insert(0, buildLookup([buildLigatureSubstSubtable(mapping)]))
    table.LookupList.LookupCount = len(table.LookupList.Lookup)
    ccmp = [r for r in table.FeatureList.FeatureRecord if r.FeatureTag == "ccmp"]
    if not ccmp:
        raise ValueError("上游字体缺少预期的 ccmp 序列特性。")
    for record in ccmp:
        record.Feature.LookupListIndex.insert(0, 0)
        record.Feature.LookupCount = len(record.Feature.LookupListIndex)


def run_renderer(renderer, font_path, entries, destination, sizes):
    destination.mkdir(parents=True, exist_ok=True)
    requests = destination / "requests.tsv"
    requests.write_text("".join(f"e{i}\t{entry.key}\n" for i, entry in enumerate(entries)), encoding="utf-8")
    command = [str(renderer), "--font", str(font_path), "--requests", str(requests),
               "--out", str(destination), "--sizes", ",".join(map(str, sizes))]
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace",
                            timeout=max(180, len(entries) * len(sizes) * 3),
                            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    manifest_path = destination / "render.json"
    if result.returncode != 0 or not manifest_path.is_file():
        raise ValueError("Windows 彩色渲染检查失败：" + (result.stderr or result.stdout)[-2500:])
    manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    if manifest.get("status") != "passed":
        raise ValueError("Windows 彩色渲染器未确认成功。")
    items = {item["id"]: item for item in manifest["items"]}
    mapped = {}
    for i, entry in enumerate(entries):
        item = items[f"e{i}"]
        images = {int(image["size"]): image for image in item["images"]}
        if set(images) != set(sizes):
            raise ValueError(f"渲染尺寸不完整：{entry.key}")
        for size, image in images.items():
            if image.get("fontMatched") is False or item.get("fontMatched") is False:
                raise ValueError(f"渲染时使用了非指定字体：{entry.key}")
            if image["inkPixels"] <= 0:
                raise ValueError(f"表情渲染为空：{entry.key}")
            path = Path(image["path"])
            if not path.is_absolute():
                path = destination / path
            if destination.resolve() not in path.resolve().parents:
                raise ValueError("渲染结果路径越界。")
            image["path"] = str(path.resolve())
        mapped[entry.points] = images
    return mapped


def append_bitmaps(font, name, images):
    for index, strike in enumerate(font["CBLC"].strikes):
        size = strike.bitmapSizeTable.ppemY
        image = images[size]
        png = Path(image["path"])
        with Image.open(png) as picture:
            if picture.mode != "RGBA":
                raise ValueError("补齐图像必须为透明 RGBA PNG。")
            width, height = picture.size
        metrics = SmallGlyphMetrics()
        metrics.width, metrics.height = width, height
        metrics.BearingX, metrics.BearingY = round(image["offsetX"]), round(image["offsetY"])
        metrics.Advance = round(image["advance"])
        if not (0 < width <= 255 and 0 < height <= 255 and 0 <= metrics.Advance <= 255
                and -128 <= metrics.BearingX <= 127 and -128 <= metrics.BearingY <= 127):
            raise ValueError(f"补齐字形度量超出 CBDT 格式范围：{name}/{size}")
        bitmap = cbdt_bitmap_format_17(None, font)
        bitmap.metrics, bitmap.imageData = metrics, png.read_bytes()
        font["CBDT"].strikeData[index][name] = bitmap


def repair_apple_strikes(font):
    """Fill upstream holes from its largest available Apple image, not a donor."""
    strikes, maps = font["CBLC"].strikes, font["CBDT"].strikeData
    names = set.union(*(set(data) for data in maps))
    best = {}
    for i in sorted(range(len(strikes)), key=lambda i: strikes[i].bitmapSizeTable.ppemY):
        for name in maps[i]:
            best[name] = i
    repaired = 0
    for i, data in enumerate(maps):
        target_size = strikes[i].bitmapSizeTable.ppemY
        for name in sorted(names.difference(data)):
            source_index = best[name]
            source = maps[source_index][name]
            if source.getFormat() != 17:
                raise ValueError("上游位图格式不支持尺寸修复。")
            factor = target_size / strikes[source_index].bitmapSizeTable.ppemY
            metrics = SmallGlyphMetrics()
            for field in ("width", "height", "BearingX", "BearingY", "Advance"):
                value = round(getattr(source.metrics, field) * factor)
                if field in ("width", "height"):
                    value = max(1, value)
                setattr(metrics, field, value)
            image = Image.open(io.BytesIO(source.imageData)).convert("RGBA")
            image = image.resize((metrics.width, metrics.height), Image.Resampling.LANCZOS)
            buffer = io.BytesIO()
            image.save(buffer, format="PNG")
            glyph = cbdt_bitmap_format_17(None, font)
            glyph.metrics, glyph.imageData = metrics, buffer.getvalue()
            data[name] = glyph
            repaired += 1
    return repaired


def rebuild_bitmap_indices(font):
    for strike, data in zip(font["CBLC"].strikes, font["CBDT"].strikeData):
        # A single index-format-1 table supports sparse glyph IDs through offsets.
        if any(bitmap.getFormat() != 17 for bitmap in data.values()):
            raise ValueError("上游字体包含未审计的 CBDT 图像格式。")
        subtable = eblc_index_sub_table_1(None, font)
        subtable.indexFormat, subtable.imageFormat = 1, 17
        subtable.imageDataOffset = 0
        subtable.names = sorted(data, key=font.getGlyphID)
        strike.indexSubTables = [subtable]


def copy_text_outlines(font, windows_audit, entries, windows_support):
    """Map VS15 to outline-only glyphs, never to a colored bitmap glyph."""
    # Decompile original outlines while maxp still describes the original IDs.
    outlines = {name: font["glyf"][name] for name in font.getGlyphOrder()} if "glyf" in font else {}
    source_glyphs = windows_audit.tt.getGlyphSet()
    factor = font["head"].unitsPerEm / windows_audit.tt["head"].unitsPerEm
    copied, new_outlines, mappings = {}, {}, []
    base_cmap = font.getBestCmap()
    for entry in entries:
        supported, source_name = windows_support[entry.points]
        if not supported:
            continue
        if len(entry.points) != 2 or entry.points[1] != 0xFE0E:
            raise ValueError(f"未识别的文字呈现序列：{entry.key}")
        if source_name not in copied:
            destination_name = f"aes.text.{len(copied)}"
            recording = DecomposingRecordingPen(source_glyphs)
            source_glyphs[source_name].draw(recording)
            pen = TTGlyphPen(None)
            recording.replay(TransformPen(pen, (factor, 0, 0, factor, 0, 0)))
            glyph = pen.glyph()
            if glyph.numberOfContours == 0:
                raise ValueError(f"无法保留原生文字轮廓：{entry.key}")
            width, lsb = windows_audit.tt["hmtx"].metrics[source_name]
            add_glyph(font, destination_name, width * factor, lsb * factor)
            new_outlines[destination_name] = glyph
            copied[source_name] = destination_name
        mappings.append((entry.points[0], copied[source_name]))
        # Windows TextLayout may request the default monochrome presentation
        # without a selector (for example plain copyright). The bitmap remains
        # available to FE0F; also retain a real outline on the base glyph so
        # ordinary text does not disappear when the layout omits color drawing.
        base_name = base_cmap.get(entry.points[0])
        if base_name and (base_name not in outlines or outlines[base_name].numberOfContours == 0):
            outlines[base_name] = copy.deepcopy(new_outlines[copied[source_name]])
    for name in font.getGlyphOrder():
        outlines.setdefault(name, TTGlyphPen(None).glyph())
    outlines.update(new_outlines)
    builder = FontBuilder(font=font)
    builder.setupGlyf(outlines)
    builder.setupMaxp()
    variants = next((table for table in font["cmap"].tables if table.format == 14), None)
    if variants is None:
        variants = CmapSubtable.newSubtable(14)
        variants.platformID, variants.platEncID, variants.language = 0, 5, 0
        variants.cmap, variants.uvsDict = {}, {}
        font["cmap"].tables.append(variants)
    old = dict(variants.uvsDict.get(0xFE0E, []))
    old.update(mappings)
    variants.uvsDict[0xFE0E] = sorted(old.items())
    return len(mappings)


def smoke_entries(entries, apple_support, windows_support):
    desired = ["1F600", "1FAE8", "1F1E8 1F1F3", "1F468 1F3FD 200D 1F4BB",
               "1F469 200D 2764 FE0F 200D 1F48B 200D 1F468", "0023 FE0F 20E3",
               "1F3F4 E0067 E0062 E0065 E006E E0067 E007F", "2764 FE0F", "2764 FE0E",
               "2665 FE0F", "2665 FE0E", "00A9 FE0F", "00A9 FE0E"]
    by_key = {entry.key: entry for entry in entries}
    return [by_key[key] for key in desired if key in by_key
            and (apple_support[by_key[key].points][0] or windows_support[by_key[key].points][0])]


def make_preview(output, entries, rendered, report):
    import html
    cards = []
    for entry in entries:
        image = rendered[entry.points][32]
        relative = Path(image["path"]).relative_to(output).as_posix()
        cards.append(f'<div class="card"><img src="{html.escape(relative)}"><code>{entry.key}</code></div>')
    counts = report["counts"]
    page = f'''<!doctype html><meta charset="utf-8"><title>Emoji 字体验证</title>
<style>body{{font:16px "Segoe UI","Microsoft YaHei",sans-serif;max-width:1000px;margin:40px auto;background:#f5f6fa;color:#253047}}
h1{{font-size:26px}}.grid{{display:grid;grid-template-columns:repeat(4,1fr);gap:14px}}.card{{background:white;border-radius:12px;padding:18px;display:flex;align-items:center;gap:12px}}img{{width:auto;height:32px}}code{{font-size:11px;word-break:break-all}}p{{line-height:1.8}}</style>
<h1>苹果 Emoji 候选字体验证</h1><p>这些图片由 Windows 私有加载候选字体后实际渲染。是否允许替换以完整报告中的检查结果为准；系统替换仍需重启后确认。</p>
<p>实际组合显示检查：{html.escape(str(report['checks'].get('nativeSequenceRegression', '尚未完成')))}。
不一致项目：{html.escape('；'.join(item['codepoints'] for item in report.get('nativeSequenceMismatches', [])) or '无')}。</p>
<p>苹果覆盖：{counts['apple']}　原生补齐：{counts['native']}　双方缺失：{counts['missing']}　保留文字形态：{counts['textPreserved']}</p>
<div class="grid">{''.join(cards)}</div><p>完整列表见 <a href="coverage.json">表情覆盖报告</a>。</p>'''
    (output / "preview.html").write_text(page, encoding="utf-8")


def build(args):
    apple_path, windows_path = Path(args.apple).resolve(), Path(args.windows).resolve()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {"schemaVersion": 1, "builderVersion": VERSION, "status": "building", "unicodeVersion": "17.0",
              "createdUtc": datetime.now(timezone.utc).isoformat(), "sourceAppleSha256": sha256(apple_path),
              "compatibilityPolicy": COMPATIBILITY_POLICY, "warnings": [],
              "sourceWindowsSha256": sha256(windows_path), "checks": {}, "entries": [], "errors": []}
    report_path = output / "coverage.json"
    write_json(report_path, report)
    try:
        progress("audit", "校验固定字体与 Unicode 数据", 3)
        check_assets(apple_path, Path(args.unicode_dir))
        entries = unicode_entries(Path(args.unicode_dir))
        apple, windows = FontAudit(apple_path), FontAudit(windows_path)
        if apple.tt["name"].getDebugName(1) != "Segoe UI Emoji":
            raise ValueError("不是预期的 Windows 适配字体。")
        if not apple.bitmap_names:
            raise ValueError("上游字体没有完整的彩色位图。")
        progress("audit", "逐条检查表情与组合的实际成形", 12)
        a_support, w_support = apple.classify(entries), windows.classify(entries)
        additions, text_entries = [], []
        for entry in entries:
            a_ok, a_name = a_support[entry.points]
            w_ok, w_name = w_support[entry.points]
            if entry.is_text:
                text_entries.append(entry)
                source, glyph = ("native-text", w_name) if w_ok else (("apple-text", a_name) if a_ok else ("missing", None))
            elif a_ok:
                source, glyph = "apple", a_name
            elif w_ok:
                source, glyph = "native", w_name
                additions.append(entry)
            else:
                source, glyph = "missing", None
            report["entries"].append(entry_dict(entry, source, glyph))
        report["counts"] = {"total": len(entries), "apple": sum(e["source"] == "apple" for e in report["entries"]),
                            "native": len(additions), "missing": sum(e["source"] == "missing" for e in report["entries"]),
                            "textPreserved": sum(w_support[e.points][0] or a_support[e.points][0] for e in text_entries)}
        rgi_entries = [entry for entry in entries if entry.qualification in ("fully-qualified", "component")]
        report["counts"]["rgiTotal"] = len(rgi_entries)
        report["counts"]["rgiMissing"] = sum(not a_support[e.points][0] and not w_support[e.points][0] for e in rgi_entries)
        report["notes"] = [
            "统计单位为完整 Unicode 字符串；包含不同呈现方式，不等于独立图案数。",
            "数字、井号、星号单独加 FE0F 的变体可能没有独立彩色图案；完整键帽组合另行检查。"
        ]
        report["checks"]["inputSequenceAudit"] = "passed"
        write_json(report_path, report)
        if args.audit_only:
            report["status"] = "audit_only"
            write_json(report_path, report)
            progress("audit", "覆盖检查完成，尚未构建或安装字体", 100)
            return report
        font = apple.tt
        progress("repair", "补齐苹果字体内部缺少的图像尺寸", 20)
        report["checks"]["appleBitmapSizesRepaired"] = repair_apple_strikes(font)
        sizes = [strike.bitmapSizeTable.ppemY for strike in font["CBLC"].strikes]
        if any(strike.bitmapSizeTable.ppemX != strike.bitmapSizeTable.ppemY for strike in font["CBLC"].strikes):
            raise ValueError("上游字体位图比例未通过检查。")
        progress("render", f"生成 {len(additions)} 个原生补齐项", 25)
        native_images = run_renderer(Path(args.renderer), windows_path, additions, output / "native", sizes) if additions else {}
        mapping = {}
        # Include existing Apple long sequences, so a Windows-only prefix cannot
        # consume them before the original Apple GSUB table has a chance to run.
        for entry in entries:
            supported, name = a_support[entry.points]
            if supported and not entry.is_text and len(entry.points) > 1:
                names = input_names(font, entry.points)
                mapping.setdefault(names, name)
        for index, entry in enumerate(additions):
            images = native_images[entry.points]
            sample_size = max(sizes)
            advance = images[sample_size]["advance"] / sample_size * font["head"].unitsPerEm
            if (len(entry.points) == 1 or (len(entry.points) == 2 and entry.points[1] == 0xFE0F)) and entry.points[0] in font.getBestCmap():
                name = font.getBestCmap()[entry.points[0]]
                if name in apple.bitmap_names:
                    raise ValueError("补齐项将覆盖苹果已有图案。")
                font["hmtx"].metrics[name] = (round(advance), 0)
            else:
                name = add_glyph(font, f"aes.native.{index}", advance)
            append_bitmaps(font, name, images)
            if len(entry.points) == 1:
                set_codepoint(font, entry.points[0], name)
            else:
                mapping[input_names(font, entry.points)] = name
        if additions:
            prepend_sequence_rules(font, mapping)
        rebuild_bitmap_indices(font)
        progress("text", "保留原生文字呈现与单色轮廓", 48)
        copied_text = copy_text_outlines(font, windows, text_entries, w_support)
        report["checks"]["textOutlinesCopied"] = copied_text
        for tag in ("DSIG",):
            if tag in font:
                del font[tag]
        font["name"].setName(f"Version 1.000; AppleEmojiSwitcher {VERSION}; local hybrid", 5, 3, 1, 0x409)
        font.recalcTimestamp = False
        candidate = output / "hybrid.ttf.partial"
        font.save(candidate)
        progress("validate", "回读候选字体并检查所有表情组合", 65)
        built = FontAudit(candidate, strict_strikes=True)
        out_support = built.classify(entries)
        errors = []
        for entry in entries:
            a_ok, a_name = a_support[entry.points]
            w_ok, _ = w_support[entry.points]
            result_ok, result_name = out_support[entry.points]
            if (a_ok or w_ok) and not result_ok:
                errors.append(f"覆盖回退：{entry.key}")
            if a_ok and not entry.is_text and result_name != a_name:
                errors.append(f"苹果图案改变：{entry.key}")
            if entry.is_text and (a_ok or w_ok) and result_name in built.color_names:
                errors.append(f"文字呈现被着色：{entry.key}")
        if errors:
            report["errors"].extend(errors)
            raise ValueError(f"候选字体有 {len(errors)} 个序列未通过回归，保留原系统。")
        formats = {table.format for table in built.tt["cmap"].tables}
        if not {4, 12, 14}.issubset(formats) or len(built.order) >= 65535:
            raise ValueError("候选字体的映射或字形数量检查失败。")
        for entry in additions:
            name = out_support[entry.points][1]
            if name not in built.bitmap_names:
                raise ValueError(f"补齐项的位图尺寸不完整：{entry.key}")
        report["checks"].update({"sequenceRegression": "passed", "textPresentation": "passed", "fontStructure": "passed",
                                  "glyphCount": len(built.order), "bitmapSizes": sizes})
        if "vmtx" in built.tt and set(built.order) != set(built.tt["vmtx"].metrics):
            raise ValueError("纵向字形度量不完整，不能安装候选字体。")
        report["checks"]["indexedMetrics"] = "passed"
        progress("render", "用 Windows 实际绘制候选字体进行验收", 85)
        samples = smoke_entries(entries, a_support, w_support)
        for extra in additions[:3]:
            if extra not in samples:
                samples.append(extra)
        rendered = run_renderer(Path(args.renderer), candidate, samples, output / "smoke", [16, 32, 64])
        # Confirm the actual native shaper agrees with the sequence audit. Empty
        # fallback glyphs can be included by DirectWrite and are reported separately.
        smoke_warnings = []
        for entry in samples:
            image = rendered[entry.points][32]
            if image.get("visibleGlyphCount", image["glyphCount"]) != 1:
                smoke_warnings.append(f"Windows 将完整表情拆开了：{entry.key}")
            if entry.is_text and image["colorPixels"] != 0:
                smoke_warnings.append(f"Windows 的文字形态有颜色差异：{entry.key}")
            if entry.points in ((0x1F600,), (0x1F1E8, 0x1F1F3), (0x2764, 0xFE0F)) and image["colorPixels"] == 0:
                smoke_warnings.append(f"Windows 丢失了表情颜色：{entry.key}")
        report["warnings"].extend(smoke_warnings)
        report["checks"]["nativeRenderSmoke"] = "warning" if smoke_warnings else "passed"
        # Inspect the glyph runs that TextLayout ACTUALLY draws. A separate call
        # to a shaping API is insufficient: on this Windows build, tag flags
        # shape correctly in isolation but TextLayout paints only a black flag.
        progress("render", "核对全部完整序列的 Windows 实际绘制字形", 90)
        render_entries = [entry for entry in entries if out_support[entry.points][0]]
        actual = run_renderer(Path(args.renderer), candidate, render_entries, output / "sequence-render", [32])
        mismatches = []
        for entry in render_entries:
            image = actual[entry.points][32]
            expected = [glyph["id"] for glyph in built.shape(entry.points)]
            observed = image["glyphIndices"]
            if (len(expected) != 1 or expected[0] not in observed
                    or image.get("visibleGlyphCount", image["glyphCount"]) != 1
                    or (entry.is_text and image["colorPixels"] != 0)):
                mismatches.append({"codepoints": entry.key, "name": entry.name,
                                   "expectedGlyphIds": expected, "actualGlyphIds": observed})
        report["nativeSequenceMismatches"] = mismatches
        report["checks"]["nativeRenderedSequenceCount"] = len(render_entries)
        report["checks"]["nativeMatchingSequenceCount"] = len(render_entries) - len(mismatches)
        report["checks"]["nativeSequenceRegression"] = "warning" if mismatches else "passed"
        make_preview(output, samples, rendered, report)
        if mismatches:
            tag_flags = {
                "1F3F4 E0067 E0062 E0065 E006E E0067 E007F": "英格兰旗",
                "1F3F4 E0067 E0062 E0073 E0063 E0074 E007F": "苏格兰旗",
                "1F3F4 E0067 E0062 E0077 E006C E0073 E007F": "威尔士旗",
            }
            if all(item["codepoints"] in tag_flags for item in mismatches):
                names = "、".join(tag_flags[item["codepoints"]] for item in mismatches)
                report["warnings"].append(f"{names}在本机显示为黑旗；按默认兼容性规则继续替换。")
            else:
                report["warnings"].append(f"Windows 有 {len(mismatches)} 个组合显示差异；按默认兼容性规则继续替换，详见明细。")
            progress("compatibility", report["warnings"][-1], 95)
        built.close()
        apple.close()
        windows.close()
        final = output / "hybrid.ttf"
        candidate.replace(final)
        report["outputSha256"] = sha256(final)
        report["outputPath"] = str(final)
        report["status"] = "passed_with_warnings" if report["warnings"] else "passed"
        write_json(report_path, report)
        make_preview(output, samples, rendered, report)
        progress("complete", "候选字体已通过检查，可以安排系统替换", 100)
        return report
    except Exception as exc:
        report["status"] = "failed"
        report["errors"].append(str(exc))
        for audit_name in ("built", "apple", "windows"):
            audit = locals().get(audit_name)
            if audit is not None:
                audit.close()
        candidate = locals().get("candidate")
        if candidate is not None and candidate.is_file():
            try:
                candidate.unlink()
                report["failedCandidateRemoved"] = True
            except OSError as cleanup_error:
                report["cleanupWarning"] = str(cleanup_error)
        write_json(report_path, report)
        raise


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apple", required=True)
    parser.add_argument("--windows", required=True)
    parser.add_argument("--unicode-dir", required=True)
    parser.add_argument("--renderer", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--audit-only", action="store_true")
    args = parser.parse_args()
    try:
        build(args)
    except Exception as exc:
        progress("failed", str(exc), 0)
        traceback.print_exc(file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
