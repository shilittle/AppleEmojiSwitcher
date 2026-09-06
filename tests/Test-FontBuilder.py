"""Independent unit tests for the Apple-first font builder helpers.

The fixtures are deliberately tiny.  They exercise shaping and color-bitmap
table behavior without downloading or changing the pinned production assets.
Run with the private embedded interpreter, for example::

    python -I -B tests/Test-FontBuilder.py
"""
from __future__ import annotations

import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


HERE = Path(__file__).resolve()
PACKAGE_ROOT = HERE.parents[1]
BUILDER_ROOT = PACKAGE_ROOT / "builder"
sys.path.insert(0, str(BUILDER_ROOT))

from fontTools.fontBuilder import FontBuilder
from fontTools.feaLib.builder import addOpenTypeFeatures
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont, newTable
from fontTools.ttLib.tables.BitmapGlyphMetrics import SmallGlyphMetrics
from fontTools.ttLib.tables.C_B_D_T_ import cbdt_bitmap_format_17
from fontTools.ttLib.tables.E_B_L_C_ import (
    SbitLineMetrics,
    Strike,
    eblc_index_sub_table_1,
)
from PIL import Image

import build_font
from font_audit import Entry, FontAudit, sha256


TEST_ROOT = Path(tempfile.gettempdir()) / "AppleEmojiSwitcher-font-tests"


def _blank_glyph():
    return TTGlyphPen(None).glyph()


def _box_glyph():
    pen = TTGlyphPen(None)
    pen.moveTo((100, 100))
    pen.lineTo((900, 100))
    pen.lineTo((900, 700))
    pen.lineTo((100, 700))
    pen.closePath()
    return pen.glyph()


def _base_font(glyph_order, cmap, outlines=None, family="Segoe UI Emoji"):
    """Create a small valid TTF with glyph outlines and a Unicode cmap."""
    outlines = outlines or {}
    fb = FontBuilder(unitsPerEm=1000, isTTF=True)
    fb.setupGlyphOrder(glyph_order)
    fb.setupCharacterMap(cmap)
    fb.setupGlyf({name: outlines.get(name, _blank_glyph()) for name in glyph_order})
    fb.setupHorizontalMetrics({name: (600, 0) for name in glyph_order})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupVerticalMetrics({name: (1000, 0) for name in glyph_order})
    fb.setupVerticalHeader(ascent=800, descent=-200)
    fb.setupOS2(
        sTypoAscender=800,
        sTypoDescender=-200,
        usWinAscent=800,
        usWinDescent=200,
    )
    fb.setupNameTable(
        {
            "familyName": family,
            "styleName": "Regular",
            "uniqueFontIdentifier": f"{family}; Regular",
            "fullName": family,
            "psName": family.replace(" ", ""),
            "version": "Version 1.000",
        }
    )
    fb.setupPost()
    fb.setupMaxp()
    return fb.font


def _line_metrics():
    metrics = SbitLineMetrics()
    for field, value in {
        "ascender": 1,
        "descender": -1,
        "widthMax": 8,
        "caretSlopeNumerator": 1,
        "caretSlopeDenominator": 1,
        "caretOffset": 0,
        "minOriginSB": 0,
        "minAdvanceSB": 0,
        "maxBeforeBL": 8,
        "minAfterBL": 0,
        "pad1": 0,
        "pad2": 0,
    }.items():
        setattr(metrics, field, value)
    return metrics


def _png(color, size):
    image = Image.new("RGBA", (size, size), color)
    stream = io.BytesIO()
    image.save(stream, format="PNG")
    return stream.getvalue()


def _add_cbdt(font, strikes):
    """Attach CBDT/CBLC format-17 strikes to a FontBuilder-created font.

    ``strikes`` is a list of ``(ppem, {glyph_name: rgba_tuple})`` mappings.
    Every strike has at least one glyph so that its index subtable is legal;
    a deliberately missing glyph is represented by a different filler glyph.
    """
    cbdt = newTable("CBDT")
    cbdt.version = 3.0
    cbdt.strikeData = []
    cblc = newTable("CBLC")
    cblc.version = 3.0
    cblc.strikes = []

    for ppem, glyph_colors in strikes:
        strike = Strike()
        size = strike.bitmapSizeTable
        size.hori = _line_metrics()
        size.vert = _line_metrics()
        size.ppemX = ppem
        size.ppemY = ppem
        size.bitDepth = 32
        size.flags = 1
        size.colorRef = 0

        names = sorted(glyph_colors, key=font.getGlyphID)
        index = eblc_index_sub_table_1(None, font)
        index.indexFormat = 1
        index.imageFormat = 17
        index.imageDataOffset = 0
        index.names = names
        index.locations = []
        strike.indexSubTables = [index]
        cblc.strikes.append(strike)

        data = {}
        for name, color in glyph_colors.items():
            bitmap = cbdt_bitmap_format_17(None, font)
            metrics = SmallGlyphMetrics()
            metrics.width = ppem
            metrics.height = ppem
            metrics.BearingX = 0
            metrics.BearingY = ppem
            metrics.Advance = ppem
            bitmap.metrics = metrics
            bitmap.imageData = _png(color, ppem)
            data[name] = bitmap
        cbdt.strikeData.append(data)

    font["CBLC"] = cblc
    font["CBDT"] = cbdt
    return font


def _save_color_font(path, cmap, strikes, outlines=None):
    glyphs = [".notdef"] + list(dict.fromkeys(cmap.values()))
    font = _base_font(glyphs, cmap, outlines=outlines)
    _add_cbdt(font, strikes)
    font.recalcTimestamp = False
    font.save(path)


def _shape_names(path, points):
    audit = FontAudit(path)
    try:
        return [item["name"] for item in audit.shape(points)]
    finally:
        audit.close()


def _find_windows_emoji_font():
    """Find the local Windows emoji font without embedding a machine path."""
    candidates = []
    if os.environ.get("AES_TEST_WINDOWS_FONT"):
        candidates.append(Path(os.environ["AES_TEST_WINDOWS_FONT"]))
    if os.environ.get("ProgramData"):
        candidates.append(Path(os.environ["ProgramData"]) / "AppleEmojiSwitcher/backup/seguiemj.ttf")
    for path in candidates:
        if path.is_file():
            return path
    windir = os.environ.get("WINDIR")
    if not windir:
        return None
    for filename in ("seguiemj.ttf", "SegoeUIEmoji.ttf"):
        path = Path(windir) / "Fonts" / filename
        if path.is_file():
            return path
    return None


class FontBuilderFixtures(unittest.TestCase):
    def setUp(self):
        TEST_ROOT.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=TEST_ROOT, prefix="run-")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_cmap_components_without_gsub_are_unsupported(self):
        """Two individually mapped color glyphs do not imply a sequence."""
        path = self.root / "components-only.ttf"
        _save_color_font(
            path,
            {0x1F600: "face", 0x1F601: "face2"},
            [(16, {"face": (255, 0, 0, 255), "face2": (0, 0, 255, 255)})],
        )

        audit = FontAudit(path)
        try:
            self.assertTrue(audit.support(Entry((0x1F600,)))[0])
            self.assertTrue(audit.support(Entry((0x1F601,)))[0])
            supported, glyph = audit.support(Entry((0x1F600, 0x1F601)))
            self.assertFalse(supported)
            self.assertIsNone(glyph)
            self.assertEqual([item["name"] for item in audit.shape((0x1F600, 0x1F601))], ["face", "face2"])
        finally:
            audit.close()

    def test_source_audit_union_and_strict_repair(self):
        """Source audit keeps Apple art; repair then satisfies every strike."""
        path = self.root / "sparse-strikes.ttf"
        _save_color_font(
            path,
            {0x2764: "heart", 0x2665: "filler"},
            [
                (16, {"heart": (255, 0, 0, 255)}),
                (32, {"filler": (0, 0, 255, 255)}),
            ],
        )

        source = FontAudit(path)
        strict = FontAudit(path, strict_strikes=True)
        try:
            self.assertTrue(source.support(Entry((0x2764,)))[0])
            self.assertFalse(strict.support(Entry((0x2764,)))[0])
            self.assertIn("heart", source.bitmap_names)
            self.assertNotIn("heart", strict.bitmap_names)
        finally:
            source.close()
            strict.close()

        font = TTFont(path)
        try:
            repaired = build_font.repair_apple_strikes(font)
            self.assertEqual(repaired, 2)
            self.assertIn("heart", font["CBDT"].strikeData[1])
            self.assertIn("filler", font["CBDT"].strikeData[0])
            build_font.rebuild_bitmap_indices(font)
            repaired_path = self.root / "repaired.ttf"
            font.recalcTimestamp = False
            font.save(repaired_path)
        finally:
            font.close()

        audited = FontAudit(repaired_path, strict_strikes=True)
        try:
            self.assertTrue(audited.support(Entry((0x2764,)))[0])
            self.assertTrue(audited.support(Entry((0x2665,)))[0])
            self.assertIn("heart", audited.bitmap_names)
            self.assertIn("filler", audited.bitmap_names)
        finally:
            audited.close()

    def test_prepend_rules_use_longest_sequence_and_keep_original_gsub(self):
        """New ccmp rules win by complete length while an old rule remains."""
        path = self.root / "gsub.ttf"
        cmap = {0x61: "a", 0x62: "b", 0x63: "c"}
        glyphs = [".notdef", "a", "b", "c", "old", "short", "long"]
        font = _base_font(glyphs, cmap, outlines={name: _box_glyph() for name in glyphs})
        feature_path = self.root / "original.fea"
        feature_path.write_text(
            "languagesystem DFLT dflt;\n"
            "feature ccmp { sub b a by old; } ccmp;\n",
            encoding="utf-8",
        )
        addOpenTypeFeatures(font, feature_path)
        before = len(font["GSUB"].table.LookupList.Lookup)
        build_font.prepend_sequence_rules(
            font,
            {
                ("a", "b"): "short",
                ("a", "b", "c"): "long",
            },
        )
        self.assertEqual(len(font["GSUB"].table.LookupList.Lookup), before + 1)
        font.recalcTimestamp = False
        font.save(path)

        self.assertEqual(_shape_names(path, (0x61, 0x62, 0x63)), ["long"])
        self.assertEqual(_shape_names(path, (0x61, 0x62)), ["short"])
        self.assertEqual(_shape_names(path, (0x62, 0x61)), ["old"])

    def test_text_vs15_uses_outline_only_glyph(self):
        """VS15 shaping resolves to copied outline art, never color art."""
        source_path = self.root / "windows-source.ttf"
        source_font = _base_font(
            [".notdef", "heart"],
            {0x2764: "heart"},
            outlines={"heart": _box_glyph()},
            family="Windows Source",
        )
        source_font.recalcTimestamp = False
        source_font.save(source_path)

        target_path = self.root / "apple-target.ttf"
        _save_color_font(
            target_path,
            {0x2764: "heart"},
            [(16, {"heart": (255, 0, 0, 255)})],
        )
        target = TTFont(target_path)
        windows_audit = FontAudit(source_path)
        entry = Entry((0x2764, 0xFE0E), "heart text")
        try:
            copied = build_font.copy_text_outlines(
                target,
                windows_audit,
                [entry],
                {entry.points: (True, "heart")},
            )
            self.assertEqual(copied, 1)
            new_names = [name for name in target.getGlyphOrder() if name.startswith("aes.")]
            self.assertEqual(new_names, ["aes.text.0"])
            self.assertEqual(len(target["vmtx"].metrics), len(target.getGlyphOrder()))
            for name in new_names:
                self.assertIn(name, target["vmtx"].metrics)
            target.recalcTimestamp = False
            output = self.root / "apple-with-text.ttf"
            target.save(output)
        finally:
            windows_audit.close()
            target.close()

        roundtrip = TTFont(output)
        try:
            self.assertEqual(len(roundtrip["vmtx"].metrics), len(roundtrip.getGlyphOrder()))
            for name in roundtrip.getGlyphOrder():
                self.assertIn(name, roundtrip["vmtx"].metrics)
        finally:
            roundtrip.close()

        audit = FontAudit(output)
        try:
            shaped = audit.shape(entry.points)
            self.assertEqual(len(shaped), 1)
            self.assertEqual(shaped[0]["name"], "aes.text.0")
            self.assertTrue(audit.has_outline("aes.text.0"))
            self.assertNotIn("aes.text.0", audit.color_names)
            self.assertEqual(audit.shape((0x2764,))[0]["name"], "heart")
        finally:
            audit.close()

    def test_subdivision_tags_are_not_implied_by_black_flag(self):
        """A black flag alone must not claim a tagged subdivision sequence."""
        path = self.root / "black-flag-only.ttf"
        font = _base_font(
            [".notdef", "blackflag"],
            {0x1F3F4: "blackflag"},
        )
        # Missing tag codepoints become an invisible default glyph in this
        # fixture, so the tagged and untagged shapes are intentionally equal.
        font["hmtx"].metrics[".notdef"] = (0, 0)
        _add_cbdt(font, [(16, {"blackflag": (0, 0, 0, 255)})])
        font.recalcTimestamp = False
        font.save(path)

        tags = (0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F)
        england = Entry((0x1F3F4,) + tags, "England")
        audit = FontAudit(path)
        try:
            self.assertTrue(audit.support(Entry((0x1F3F4,)))[0])
            self.assertEqual(audit.shape(england.points), audit.shape((0x1F3F4,)))
            self.assertFalse(audit.support(england)[0])
            self.assertIsNone(audit.support(england)[1])
        finally:
            audit.close()

    def test_real_england_coverage_differs_between_fixed_apple_and_windows(self):
        """The fixed Apple release covers England; local Segoe UI Emoji does not."""
        england = Entry(
            (0x1F3F4, 0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F),
            "England",
        )
        apple_path = (Path(os.environ["AES_TEST_APPLE_FONT"]) if os.environ.get("AES_TEST_APPLE_FONT")
                      else Path(os.environ.get("LOCALAPPDATA", "")) / "AppleEmojiSwitcher/cache/font/AppleColorEmoji-Windows.ttf")
        if not apple_path.is_file():
            self.skipTest("Fixed Apple cache is not prepared; synthetic tag tests still run")
        apple = FontAudit(apple_path)
        try:
            self.assertTrue(apple.support(england)[0])
        finally:
            apple.close()

        windows_path = _find_windows_emoji_font()
        if windows_path is None or sha256(windows_path) != "12c5253251f45c57fa57e2a1c748f821d3ca030a3e757e049a5da6316f213bcb":
            self.skipTest("The original Windows build fixture is not available on this machine")
        windows = FontAudit(windows_path)
        try:
            self.assertFalse(windows.support(england)[0])
        finally:
            windows.close()

    def test_check_assets_rejects_bad_pinned_unicode_hash(self):
        """A mocked lock is rejected without changing the production lock."""
        apple_path = self.root / "apple.ttf"
        _save_color_font(
            apple_path,
            {0x2764: "heart"},
            [(16, {"heart": (255, 0, 0, 255)})],
        )
        unicode_dir = self.root / "unicode"
        unicode_dir.mkdir()
        filenames = (
            "emoji-test.txt",
            "emoji-sequences.txt",
            "emoji-zwj-sequences.txt",
            "emoji-variation-sequences.txt",
        )
        for filename in filenames:
            (unicode_dir / filename).write_text("fixture\n", encoding="utf-8")

        fake_package = self.root / "package"
        (fake_package / "builder").mkdir(parents=True)
        fake_lock = fake_package / "fonts.lock.json"
        fake_lock.write_text(
            json.dumps(
                {
                    "version": 1,
                    "font": {"sha256": sha256(apple_path)},
                    "unicode": [
                        {"filename": filename, "sha256": "0" * 64}
                        for filename in filenames
                    ],
                }
            ),
            encoding="utf-8",
        )
        fake_module_file = fake_package / "builder" / "build_font.py"
        with mock.patch.object(build_font, "__file__", str(fake_module_file)), mock.patch.object(
            build_font, "APPLE_HASH", sha256(apple_path)
        ):
            with self.assertRaisesRegex(ValueError, "Unicode 数据校验失败"):
                build_font.check_assets(apple_path, unicode_dir)


if __name__ == "__main__":
    unittest.main(verbosity=2)
