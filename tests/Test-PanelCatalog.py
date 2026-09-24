"""Tests for the checked-in Emoji 17.0 panel catalog.

The tests only exercise data generation and serialization.  They do not load a
font, start an input host, or change Windows state.
"""
from __future__ import annotations

import importlib.util
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "native" / "panel" / "data"
CATALOG_PATH = DATA / "emoji17-catalog.json"
HEADER_PATH = DATA / "Emoji17Catalog.h"
LABEL_SOURCE = DATA / "emoji17-labels.cldr48.json"
MANIFEST = DATA / "emoji17-sources.json"

spec = importlib.util.spec_from_file_location("panel_catalog_generator", ROOT / "scripts" / "generate-panel-catalog.py")
generator = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(generator)


def load_catalog() -> dict:
    return json.loads(CATALOG_PATH.read_text(encoding="utf-8"))


def points(item: dict) -> tuple[int, ...]:
    return tuple(item["codepoints"])


class PanelCatalog(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.catalog = load_catalog()
        cls.entries = cls.catalog["entries"]
        cls.aliases = cls.catalog["aliases"]
        cls.by_points = {points(item): item for item in cls.entries}

    def test_counts_and_provenance(self) -> None:
        self.assertEqual(self.catalog["schemaVersion"], 1)
        self.assertEqual(self.catalog["unicodeVersion"], "17.0")
        self.assertEqual(self.catalog["entryCount"], 163)
        self.assertEqual(self.catalog["aliasCount"], 20)
        self.assertEqual(len(self.entries), 163)
        self.assertEqual(len(self.aliases), 20)
        self.assertEqual(self.catalog["provenance"]["cldr"]["tag"], "48.0.0")
        self.assertEqual(
            self.catalog["provenance"]["cldr"]["commit"],
            "4d06be52b51bb2f75688d0abe55c52a66afed790",
        )

    def test_eight_new_base_sequences_and_ballet_skin_tones(self) -> None:
        bases = {
            (0x1FAEA,),
            (0x1FAEF,),
            (0x1FAC8,),
            (0x1F9D1, 0x200D, 0x1FA70),
            (0x1FACD,),
            (0x1F6D8,),
            (0x1FA8A,),
            (0x1FA8E,),
        }
        self.assertTrue(bases.issubset(self.by_points))
        self.assertEqual(self.by_points[(0x1FAEA,)]["nameZh"], "变形的脸")
        self.assertEqual(self.by_points[(0x1FAEF,)]["nameZh"], "打斗云团")
        self.assertEqual(self.by_points[(0x1FAC8,)]["nameZh"], "毛怪")
        self.assertEqual(self.by_points[(0x1FACD,)]["nameZh"], "虎鲸")
        self.assertEqual(self.by_points[(0x1F6D8,)]["nameZh"], "山体滑坡")
        self.assertEqual(self.by_points[(0x1FA8A,)]["nameZh"], "长号")
        self.assertEqual(self.by_points[(0x1FA8E,)]["nameZh"], "宝箱")
        self.assertEqual(self.by_points[(0x1F9D1, 0x200D, 0x1FA70)]["nameZh"], "芭蕾舞者")
        for tone in range(0x1F3FB, 0x1F400):
            self.assertIn((0x1F9D1, tone, 0x200D, 0x1FA70), self.by_points)

    def test_bunny_and_wrestling_variants_are_complete(self) -> None:
        for base in (0x1F46F, 0x1F93C):
            for tone in range(0x1F3FB, 0x1F400):
                self.assertIn((base, tone), self.by_points)
                self.assertIn((base, tone, 0x200D, 0x2642, 0xFE0F), self.by_points)
                self.assertIn((base, tone, 0x200D, 0x2640, 0xFE0F), self.by_points)
        # Emoji 17 added all 20 skin-tone pair combinations for the new
        # neutral-person forms of bunny ears and the fight cloud.
        for marker in (0x1F430, 0x1FAEF):
            for person in (0x1F9D1, 0x1F468, 0x1F469):
                pairs = [
                    item for item in self.entries
                    if points(item)[0] == person
                    and marker in points(item)
                    and points(item).count(0x200D) == 2
                ]
                self.assertEqual(len(pairs), 20)

    def test_aliases_are_only_minimally_qualified_and_not_visible_duplicates(self) -> None:
        visible = {points(item) for item in self.entries}
        aliases = {points(item) for item in self.aliases}
        self.assertEqual(len(visible), 163)
        self.assertEqual(len(aliases), 20)
        self.assertTrue(visible.isdisjoint(aliases))
        for alias in self.aliases:
            canonical = self.entries[alias["canonicalIndex"]]
            self.assertEqual(
                tuple(value for value in points(canonical) if value != 0xFE0F),
                points(alias),
            )
            self.assertNotEqual(points(canonical), points(alias))

    def test_codepoint_order_and_sequence_round_trip(self) -> None:
        for item in [*self.entries, *self.aliases]:
            values = points(item)
            self.assertTrue(values)
            self.assertTrue(all(0 <= value <= 0x10FFFF for value in values))
            self.assertEqual("".join(chr(value) for value in values), item["sequence"])
        self.assertEqual([item["index"] for item in self.entries], list(range(163)))
        self.assertEqual([item["index"] for item in self.aliases], list(range(20)))

    def test_header_declares_the_same_static_sizes(self) -> None:
        header = HEADER_PATH.read_text(encoding="utf-8")
        self.assertIn("std::array<Emoji17Entry, 163>", header)
        self.assertIn("std::array<Emoji17Alias, 20>", header)
        self.assertIn("kEmoji17KeywordSeparator", header)
        self.assertIn("kEmoji17EntryCount = 163", header)
        self.assertIn("kEmoji17AliasCount = 20", header)

    def test_cldr_label_source_is_fixed_and_covers_every_visible_entry(self) -> None:
        source = json.loads(LABEL_SOURCE.read_text(encoding="utf-8"))
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        self.assertEqual(source["source"], manifest["cldr"])
        self.assertEqual(len(source["labels"]["zh"]), 163)
        self.assertEqual(len(source["labels"]["en"]), 163)
        for item in self.entries:
            key = " ".join(f"{value:X}" for value in points(item) if value != 0xFE0F)
            self.assertIn(key, source["labels"]["zh"])
            self.assertIn(key, source["labels"]["en"])

    def test_regeneration_is_byte_deterministic_when_pinned_cache_is_available(self) -> None:
        local_app_data = os.environ.get("LOCALAPPDATA")
        if not local_app_data:
            self.skipTest("LOCALAPPDATA 不存在，无法定位已校验的 Unicode 缓存")
        emoji_test = Path(local_app_data) / "AppleEmojiSwitcher" / "cache" / "unicode" / "emoji-test.txt"
        if not emoji_test.is_file():
            self.skipTest("未准备已校验的 emoji-test.txt 缓存")
        with tempfile.TemporaryDirectory(prefix="AES-PanelCatalog-") as temporary:
            output = Path(temporary)
            arguments = [
                "--emoji-test", str(emoji_test),
                "--lock", str(ROOT / "fonts.lock.json"),
                "--source-manifest", str(MANIFEST),
                "--label-source", str(LABEL_SOURCE),
                "--json-out", str(output / "catalog.json"),
                "--header-out", str(output / "catalog.h"),
            ]
            self.assertEqual(generator.main(arguments), 0)
            first_json = (output / "catalog.json").read_bytes()
            first_header = (output / "catalog.h").read_bytes()
            self.assertEqual(generator.main(arguments), 0)
            self.assertEqual(first_json, (output / "catalog.json").read_bytes())
            self.assertEqual(first_header, (output / "catalog.h").read_bytes())
            self.assertEqual(first_json, CATALOG_PATH.read_bytes())
            self.assertEqual(first_header, HEADER_PATH.read_bytes())

    def test_changed_unicode_input_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="AES-UnicodePin-") as temporary:
            path = Path(temporary) / "emoji-test.txt"
            original = b"pinned input"
            pin = {"emojiTest": {"size": len(original), "sha256": hashlib.sha256(original).hexdigest()}}
            path.write_bytes(original)
            self.assertTrue(generator.verify_pinned_unicode(path, pin)["pinned"])
            for changed in (b"P" + original[1:], original + b"\n"):
                path.write_bytes(changed)
                with self.assertRaises(generator.CatalogError):
                    generator.verify_pinned_unicode(path, pin)

    def test_changed_cldr_inputs_are_rejected_before_extraction(self) -> None:
        with tempfile.TemporaryDirectory(prefix="AES-CldrPin-") as temporary:
            paths, pins, originals = {}, {}, {}
            for key in ("zh", "en", "zh-derived", "en-derived"):
                root_key = "annotationsDerived" if key.endswith("-derived") else "annotations"
                content = json.dumps({root_key: {"annotations": {}}}).encode()
                path = Path(temporary) / (key + ".json")
                path.write_bytes(content)
                paths[key], originals[key] = path, content
                pins[key] = {"size": len(content), "sha256": hashlib.sha256(content).hexdigest()}
            manifest = {"cldr": {"files": pins}}
            self.assertEqual(generator.extract_label_source([], manifest, paths)["labels"], {"zh": {}, "en": {}})
            for key, path in paths.items():
                original = originals[key]
                for changed in (b" " + original[1:], original + b"\n"):
                    path.write_bytes(changed)
                    with self.subTest(key=key, size=len(changed)):
                        with self.assertRaisesRegex(generator.CatalogError, "SHA-256"):
                            generator.extract_label_source([], manifest, paths)
                path.write_bytes(original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
