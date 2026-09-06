"""Sequence-aware font inspection. No installed-font or registry mutations."""
from __future__ import annotations

import hashlib
from pathlib import Path
from dataclasses import dataclass

import uharfbuzz as hb
from fontTools.ttLib import TTFont


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


@dataclass(frozen=True)
class Entry:
    points: tuple[int, ...]
    name: str = ""
    qualification: str = ""

    @property
    def key(self) -> str:
        return " ".join(f"{cp:04X}" for cp in self.points)

    @property
    def text(self) -> str:
        return "".join(chr(cp) for cp in self.points)

    @property
    def is_text(self) -> bool:
        return 0xFE0E in self.points


def unicode_entries(directory: Path) -> list[Entry]:
    entries = {}
    for filename in ("emoji-test.txt", "emoji-sequences.txt", "emoji-zwj-sequences.txt", "emoji-variation-sequences.txt"):
        path = directory / filename
        if not path.is_file():
            raise ValueError(f"Missing pinned Unicode data: {filename}")
        for line in path.read_text(encoding="utf-8-sig").splitlines():
            raw, _, note = line.partition("#")
            if ";" not in raw:
                continue
            fields = raw.split(";")
            points, qualification = fields[0].strip(), fields[1].strip()
            name = fields[2].strip() if len(fields) > 2 else note.strip()
            if ".." in points:
                start, end = points.split("..")
                sequences = [(cp,) for cp in range(int(start, 16), int(end, 16) + 1)]
            else:
                sequences = [tuple(int(cp, 16) for cp in points.split())]
            for sequence in sequences:
                entries.setdefault(sequence, Entry(sequence, name, qualification))
    return sorted(entries.values(), key=lambda entry: entry.points)


class FontAudit:
    def __init__(self, path: Path, strict_strikes=False):
        self.path = Path(path)
        self.data = self.path.read_bytes()
        self.face = hb.Face(self.data)
        self.hb_font = hb.Font(self.face)
        hb.ot_font_set_funcs(self.hb_font)
        self.hb_font.scale = (self.face.upem, self.face.upem)
        self.tt = TTFont(self.path, lazy=True, recalcTimestamp=False)
        self.order = self.tt.getGlyphOrder()
        self.cmap = self.tt.getBestCmap() or {}
        self.bitmap_names = set()
        if "CBDT" in self.tt and "CBLC" in self.tt:
            # The upstream font has real Apple art missing at some sizes. Source
            # audit uses the union; the builder repairs those strikes from Apple
            # pixels. Output audit requires every size, never substitutes Windows
            # artwork merely because an Apple bitmap size is missing.
            maps = self.tt["CBDT"].strikeData
            if maps:
                operation = set.intersection if strict_strikes else set.union
                self.bitmap_names = operation(*(set(strike) for strike in maps))
        self.color_names = set(self.bitmap_names)
        if "COLR" in self.tt:
            colr = self.tt["COLR"]
            self.color_names.update(getattr(colr, "ColorLayers", {}) or {})
            root = getattr(colr, "table", None)
            bases = getattr(root, "BaseGlyphList", None)
            if bases:
                self.color_names.update(rec.BaseGlyph for rec in bases.BaseGlyphPaintRecord)
            old_bases = getattr(root, "BaseGlyphRecordArray", None)
            if old_bases:
                self.color_names.update(rec.BaseGlyph for rec in old_bases.BaseGlyphRecord)
        self._shape_cache = {}
        self._outline_cache = {}

    def close(self):
        self.tt.close()

    def has_outline(self, name):
        if name not in self._outline_cache:
            self._outline_cache[name] = bool("glyf" in self.tt and name in self.tt["glyf"] and self.tt["glyf"][name].numberOfContours != 0)
        return self._outline_cache[name]

    def shape(self, points: tuple[int, ...], features=None):
        cache_key = (points, None if features is None else tuple(sorted(features.items())))
        if cache_key in self._shape_cache:
            return self._shape_cache[cache_key]
        buf = hb.Buffer()
        buf.add_codepoints(list(points))
        buf.guess_segment_properties()
        buf.direction = "ltr"
        buf.language = "und"
        hb.shape(self.hb_font, buf, features)
        glyphs = []
        for info, position in zip(buf.glyph_infos, buf.glyph_positions):
            name = self.order[info.codepoint] if info.codepoint < len(self.order) else ".notdef"
            # HarfBuzz can leave invisible selectors/joiners as zero-advance spaces.
            visible = name in self.color_names or self.has_outline(name)
            if not visible and position.x_advance == 0 and position.y_advance == 0:
                continue
            glyphs.append({"id": info.codepoint, "name": name, "advance": position.x_advance, "cluster": info.cluster})
        self._shape_cache[cache_key] = glyphs
        return glyphs

    def support(self, entry: Entry) -> tuple[bool, str | None]:
        glyphs = self.shape(entry.points)
        if len(glyphs) != 1 or glyphs[0]["id"] == 0:
            return False, None
        name = glyphs[0]["name"]
        # Tag characters are default-ignorable. A font without the complete
        # subdivision flag ligature can silently return just the black flag.
        # One visible glyph alone therefore does not prove sequence coverage.
        if any(0xE0020 <= cp <= 0xE007F for cp in entry.points):
            base = tuple(cp for cp in entry.points if not 0xE0020 <= cp <= 0xE007F)
            if self.shape(base) == glyphs:
                return False, None
        if entry.is_text:
            return self.has_outline(name), name
        return name in self.color_names, name

    def classify(self, entries: list[Entry]) -> dict[tuple[int, ...], tuple[bool, str | None]]:
        return {entry.points: self.support(entry) for entry in entries}
