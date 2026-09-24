"""Deterministic and source-backed tests for the Emoji 18.0 picker catalog."""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "picker" / "data"
SOURCES = ROOT / "picker" / "sources"
CATALOG = DATA / "catalog.tsv"
REPORT = DATA / "catalog-report.json"
MANIFEST = DATA / "sources.json"

spec = importlib.util.spec_from_file_location("picker_catalog_generator", ROOT / "scripts" / "generate-picker-catalog.py")
generator = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(generator)


def read_catalog() -> list[list[str]]:
    raw = CATALOG.read_bytes()
    if b"\r" in raw:
        raise AssertionError("catalog.tsv must use LF only")
    return [line.split("\t") for line in raw.decode("utf-8").splitlines()]


class PickerCatalog(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.rows = read_catalog()
        cls.report = json.loads(REPORT.read_text(encoding="utf-8"))
        cls.manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        cls.by_id = {row[0]: row for row in cls.rows}

    def test_full_fully_qualified_count_and_scope(self) -> None:
        self.assertEqual(len(self.rows), 3963)
        self.assertEqual(self.report["counts"]["fullyQualified"], 3963)
        self.assertEqual(self.report["counts"]["componentRowsExcluded"], 9)
        self.assertEqual(self.report["counts"]["broadEmojiTotalIncludingComponents"], 3972)
        self.assertIn("fully-qualified only", self.report["catalogScope"])

    def test_tsv_schema_is_headerless_and_control_free(self) -> None:
        for row in self.rows:
            self.assertEqual(len(row), 8)
            self.assertTrue(row[0])
            self.assertNotIn("\t", "".join(row))
            self.assertNotIn("\r", "".join(row))
            self.assertNotIn("\n", "".join(row))
            self.assertNotEqual(row[0].lower(), "id")
            self.assertIn(row[7], {"system", "apple", "noto"})
            self.assertTrue(row[6])

    def test_ids_and_sequences_are_unique_and_lossless(self) -> None:
        ids = [row[0] for row in self.rows]
        sequences = [row[1] for row in self.rows]
        self.assertEqual(len(set(ids)), len(ids))
        self.assertEqual(len(set(sequences)), len(sequences))
        for identifier, sequence in zip(ids, sequences):
            codepoints = tuple(int(value, 16) for value in identifier.split("-"))
            self.assertEqual("".join(chr(value) for value in codepoints), sequence)
            self.assertEqual(identifier, identifier.upper())
            self.assertTrue(all(0 <= value <= 0x10FFFF for value in codepoints))

    def test_unicode_and_cldr_pins_match_checked_in_sources(self) -> None:
        unicode_pin = self.manifest["unicode"]
        unicode_path = DATA / unicode_pin["file"]
        self.assertTrue(unicode_path.is_file())
        self.assertEqual(unicode_path.stat().st_size, unicode_pin["size"])
        self.assertEqual(generator.sha256(unicode_path), unicode_pin["sha256"])
        for key, pin in self.manifest["cldr"]["files"].items():
            path = DATA / pin["file"]
            self.assertTrue(path.is_file(), key)
            self.assertEqual(path.stat().st_size, pin["size"], key)
            self.assertEqual(generator.sha256(path), pin["sha256"], key)
        self.assertEqual(self.manifest["unicode"]["version"], "18.0")
        self.assertEqual(self.manifest["cldr"]["version"], "49.0.0-ALPHA2")
        self.assertEqual(self.manifest["cldr"]["status"], "prerelease")

    def test_names_are_cldr_backed_and_latest_19_are_from_source(self) -> None:
        source_version, source_entries = generator.parse_emoji_test(SOURCES / "emoji-test-18.0.0.txt")
        self.assertEqual(source_version, "18.0")
        latest = {entry["id"] for entry in source_entries if entry["version"] == "18.0"}
        catalog_latest = {row[0] for row in self.rows if row[5] == "18.0"}
        self.assertEqual(len(latest), 19)
        self.assertEqual(catalog_latest, latest)
        self.assertEqual(self.report["latest"], [
            {
                "id": row[0],
                "sequence": row[1],
                "nameZh": row[2],
                "nameEn": row[3],
            }
            for row in self.rows
            if row[5] == "18.0"
        ])
        self.assertEqual(self.report["missingLabels"], {"zh": [], "en": []})
        for row in self.rows:
            self.assertTrue(row[2])
            self.assertTrue(row[3])

    def test_chinese_search_labels_and_codepoint_keywords(self) -> None:
        cracking = self.by_id["1FAEB"]
        self.assertEqual(cracking[2], "裂开")
        self.assertEqual(cracking[3], "cracking face")
        self.assertIn("裂开", cracking[6].split())
        self.assertIn("cracking", cracking[6].split())
        self.assertIn("1FAEB", cracking[6].split())
        self.assertIn("U+1FAEB", cracking[6].split())
        self.assertEqual(cracking[4], "笑脸与情感")

    def test_zwj_variation_selector_and_skin_tone_sequences_are_preserved(self) -> None:
        for identifier in (
            "2764-FE0F",
            "1F3F3-FE0F-200D-1F308",
            "1FAF9-1F3FB",
            "1FAF9-1F3FF",
        ):
            self.assertIn(identifier, self.by_id)
            row = self.by_id[identifier]
            expected = "".join(chr(int(value, 16)) for value in identifier.split("-"))
            self.assertEqual(row[1], expected)
        self.assertEqual(sum(row[0].startswith("1FAF9-") for row in self.rows), 5)
        self.assertEqual(sum(row[0].startswith("1FAFA-") for row in self.rows), 5)

    def test_preview_report_is_restored_without_changing_sequence_order(self) -> None:
        self.assertEqual(self.report["preview"]["report"], "picker/data/preview-report.json")
        self.assertEqual(self.report["counts"]["previewKinds"], {"apple": 3941, "noto": 22, "system": 0})
        preview = json.loads((DATA / "preview-report.json").read_text(encoding="utf-8"))
        self.assertEqual(preview["total"], 3963)
        self.assertEqual(preview["apple"], 3941)
        self.assertEqual(preview["noto"], 22)
        self.assertEqual(len(preview["images"]), 3963)
        self.assertTrue(all(item["id"] in self.by_id for item in preview["images"]))

    def test_corrupted_source_pin_is_rejected(self) -> None:
        pin = self.manifest["unicode"]
        original = (DATA / pin["file"]).read_bytes()
        with tempfile.TemporaryDirectory(prefix="AES-PickerPin-") as temporary:
            path = Path(temporary) / "emoji-test.txt"
            path.write_bytes(original + b"\n")
            with self.assertRaises(generator.CatalogError):
                generator.verify_source_file(path, pin, "emoji-test.txt")

    def test_missing_cldr_label_falls_back_to_english_and_is_reported(self) -> None:
        empty_path = Path("picker") / "sources" / "emoji-test-18.0.0.txt"
        labels = {
            "zh": {"direct": {}, "derived": {}, "path": empty_path},
            "en": {"direct": {}, "derived": {}, "path": empty_path},
        }
        entries = [{
            "codepoints": (0x1FAEB,),
            "sequence": "🫫",
            "id": "1FAEB",
            "version": "18.0",
            "sourceNameEn": "cracking face",
            "group": "Objects",
            "subgroup": "computer",
            "sourceLine": 1,
        }]
        catalog, report = generator.build_catalog(entries, labels)
        self.assertEqual(catalog[0]["nameZh"], "cracking face")
        self.assertEqual(catalog[0]["nameEn"], "cracking face")
        self.assertEqual(report["missingLabels"], {"zh": ["1FAEB"], "en": ["1FAEB"]})

    def test_regeneration_is_byte_deterministic_with_preview_report(self) -> None:
        with tempfile.TemporaryDirectory(prefix="AES-PickerCatalog-") as temporary:
            output_root = Path(temporary)
            shutil.copy2(DATA / "preview-report.json", output_root / "preview-report.json")
            first_catalog = output_root / "catalog.tsv"
            first_report = output_root / "catalog-report.json"
            args = [
                "--source-manifest", str(MANIFEST),
                "--output", str(first_catalog),
                "--report", str(first_report),
            ]
            self.assertEqual(generator.main(args), 0)
            first_catalog_bytes = first_catalog.read_bytes()
            first_report_bytes = first_report.read_bytes()
            self.assertEqual(generator.main(args), 0)
            self.assertEqual(first_catalog_bytes, first_catalog.read_bytes())
            self.assertEqual(first_report_bytes, first_report.read_bytes())
            self.assertEqual(first_catalog_bytes, CATALOG.read_bytes())

    def test_report_catalog_hash_matches_tsv(self) -> None:
        digest = hashlib.sha256(CATALOG.read_bytes()).hexdigest()
        self.assertEqual(self.report["catalog"]["sha256"], digest)
        self.assertEqual(self.report["catalog"]["size"], CATALOG.stat().st_size)


if __name__ == "__main__":
    unittest.main(verbosity=2)
