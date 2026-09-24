"""Generate the README's exact Windows/Apple emoji rendering comparison.

The two source fonts are rendered independently by the repository's native
EmojiRender.exe.  The compositor only places those renderer PNGs on a neutral
sheet; it never redraws, recolors, or resizes an emoji glyph.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from typing import Any

from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RENDERER = ROOT / "bin" / "EmojiRender.exe"
DEFAULT_OUTPUT = ROOT / "docs" / "images" / "windows-vs-apple.png"
DEFAULT_PROVENANCE = ROOT / "docs" / "images" / "windows-vs-apple.json"
DEFAULT_LABEL_FONT = Path(r"C:\Windows\Fonts\msyh.ttc")
LOCK_PATH = ROOT / "fonts.lock.json"

# This is the native Windows 11 backup used for the comparison.  Refusing a
# different file makes the checked-in image reproducible rather than silently
# comparing against whichever Segoe copy happens to be installed.
WINDOWS_FONT_SHA256 = "12c5253251f45c57fa57e2a1c748f821d3ca030a3e757e049a5da6316f213bcb"

SAMPLES: tuple[dict[str, Any], ...] = (
    {"id": "face_tears", "name": "喜极而泣", "codepoints": (0x1F602,)},
    {"id": "loudly_crying", "name": "放声大哭", "codepoints": (0x1F62D,)},
    {"id": "pleading", "name": "可怜脸", "codepoints": (0x1F97A,)},
    {"id": "heart_eyes", "name": "爱心眼", "codepoints": (0x1F60D,)},
    {"id": "smirking", "name": "得意脸", "codepoints": (0x1F60F,)},
    {"id": "upside_down", "name": "倒脸", "codepoints": (0x1F643,)},
    {"id": "clown", "name": "小丑", "codepoints": (0x1F921,)},
    {"id": "pile_of_poo", "name": "便便", "codepoints": (0x1F4A9,)},
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def font_version(path: Path) -> str:
    font = TTFont(path, lazy=True)
    try:
        values: list[str] = []
        for record in font["name"].names:
            if record.nameID != 5:
                continue
            try:
                value = record.toUnicode()
            except Exception:
                continue
            if value and value not in values:
                values.append(value)
        if not values:
            raise RuntimeError(f"Font has no name-table version: {path.name}")
        return values[0]
    finally:
        font.close()


def codepoint_tokens(codepoints: tuple[int, ...]) -> str:
    return " ".join(f"{codepoint:X}" for codepoint in codepoints)


def public_codepoints(codepoints: tuple[int, ...]) -> list[str]:
    return [f"U+{codepoint:04X}" for codepoint in codepoints]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--windows-font", required=True, type=Path, help="Native Segoe UI Emoji backup font")
    parser.add_argument("--apple-font", required=True, type=Path, help="Pinned AppleColorEmoji-Windows.ttf")
    parser.add_argument("--renderer", type=Path, default=DEFAULT_RENDERER, help="EmojiRender.exe path")
    parser.add_argument("--label-font", type=Path, default=DEFAULT_LABEL_FONT, help="Chinese label font")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="Comparison PNG path")
    parser.add_argument("--provenance", type=Path, default=DEFAULT_PROVENANCE, help="Public provenance JSON path")
    parser.add_argument("--size", type=int, default=96, help="DirectWrite emoji em size in pixels (default: 96)")
    args = parser.parse_args()
    if not 24 <= args.size <= 256:
        parser.error("--size must be between 24 and 256")
    return args


def require_file(path: Path, description: str) -> Path:
    resolved = path.expanduser().resolve()
    if not resolved.is_file():
        raise RuntimeError(f"{description} does not exist: {resolved}")
    return resolved


def write_requests(path: Path) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as target:
        for sample in SAMPLES:
            target.write(f"{sample['id']}\t{codepoint_tokens(sample['codepoints'])}\n")


def run_renderer(renderer: Path, font: Path, requests: Path, output: Path, size: int) -> dict[str, Any]:
    output.mkdir(parents=True, exist_ok=True)
    command = [
        str(renderer),
        "--font",
        str(font),
        "--requests",
        str(requests),
        "--out",
        str(output),
        "--sizes",
        str(size),
    ]
    result = subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    manifest_path = output / "render.json"
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"EmojiRender failed for {font.name} (exit {result.returncode}): {detail}")
    if not manifest_path.is_file():
        raise RuntimeError(f"EmojiRender did not write render.json for {font.name}")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid EmojiRender manifest for {font.name}: {exc}") from exc
    return manifest


def validate_render(
    manifest: dict[str, Any],
    output: Path,
    font: Path,
    size: int,
) -> dict[str, dict[str, Any]]:
    if manifest.get("schemaVersion") != 1 or manifest.get("status") != "passed":
        raise RuntimeError(f"EmojiRender manifest is not passed for {font.name}")
    if manifest.get("fontMatched") is not True:
        raise RuntimeError(f"EmojiRender did not report an exact font match for {font.name}")
    match = manifest.get("fontmatch")
    if not isinstance(match, dict) or match.get("mode") != "private" or match.get("exact") is not True:
        raise RuntimeError(f"EmojiRender font match was not private/exact for {font.name}")

    items = manifest.get("items")
    if not isinstance(items, list) or len(items) != len(SAMPLES):
        raise RuntimeError(f"EmojiRender returned the wrong item count for {font.name}")
    expected = {sample["id"]: sample for sample in SAMPLES}
    records: dict[str, dict[str, Any]] = {}
    for item in items:
        if not isinstance(item, dict) or item.get("id") not in expected:
            raise RuntimeError(f"Unexpected EmojiRender item for {font.name}")
        sample = expected[item["id"]]
        if item.get("codepoints") != codepoint_tokens(sample["codepoints"]):
            raise RuntimeError(f"Codepoint sequence changed for {font.name}/{sample['id']}")
        images = item.get("images")
        if not isinstance(images, list) or len(images) != 1:
            raise RuntimeError(f"Expected one image for {font.name}/{sample['id']}")
        image_info = images[0]
        if not isinstance(image_info, dict) or round(float(image_info.get("size", -1))) != size:
            raise RuntimeError(f"Unexpected render size for {font.name}/{sample['id']}")
        if int(image_info.get("inkPixels", 0)) <= 0 or int(image_info.get("colorPixels", 0)) <= 0:
            raise RuntimeError(f"Render lacks alpha/color pixels for {font.name}/{sample['id']}")
        if int(image_info.get("visibleGlyphCount", 0)) <= 0:
            raise RuntimeError(f"Render has no visible glyph for {font.name}/{sample['id']}")

        relative = Path(str(image_info.get("path", "")))
        if relative.is_absolute() or ".." in relative.parts:
            raise RuntimeError(f"Unsafe image path in render manifest for {font.name}/{sample['id']}")
        image_path = output / relative
        if not image_path.is_file():
            raise RuntimeError(f"Missing rendered PNG for {font.name}/{sample['id']}")
        with Image.open(image_path) as image:
            if image.mode != "RGBA":
                raise RuntimeError(f"Rendered PNG is not RGBA for {font.name}/{sample['id']}")
            if image.width <= 0 or image.height <= 0:
                raise RuntimeError(f"Rendered PNG has no dimensions for {font.name}/{sample['id']}")
            alpha = image.getchannel("A")
            if alpha.getbbox() is None:
                raise RuntimeError(f"Rendered PNG is fully transparent for {font.name}/{sample['id']}")
            records[sample["id"]] = {
                "path": image_path,
                "width": image.width,
                "height": image.height,
                "alphaPixels": sum(alpha.histogram()[1:]),
                "imageInfo": image_info,
            }
    if set(records) != set(expected):
        raise RuntimeError(f"EmojiRender returned duplicate or missing samples for {font.name}")
    return records


def load_font(path: Path, size: int) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(str(path), size=size, index=0)
    except OSError as exc:
        raise RuntimeError(f"Cannot load label font {path}: {exc}") from exc


def centered_text(draw: ImageDraw.ImageDraw, center: tuple[float, float], text: str, font: ImageFont.FreeTypeFont, fill: tuple[int, ...]) -> None:
    bbox = draw.textbbox((0, 0), text, font=font)
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    x, y = center
    draw.text((x - width / 2 - bbox[0], y - height / 2 - bbox[1]), text, font=font, fill=fill)


def compose_sheet(
    windows: dict[str, dict[str, Any]],
    apple: dict[str, dict[str, Any]],
    label_font_path: Path,
    size: int,
    output: Path,
) -> None:
    # A fixed square preserves the renderer's native pixels and makes the two
    # rows comparable even when a font's tight alpha bounds differ.
    label_width = 82
    cell_width = size + 40
    row_height = size + 46
    header_height = 56
    margin_x = 24
    margin_top = 18
    title_height = 32
    subtitle_height = 26
    grid_left = margin_x + label_width
    grid_top = margin_top + title_height + subtitle_height
    grid_width = cell_width * len(SAMPLES)
    grid_height = header_height + row_height * 2
    width = grid_left + grid_width + margin_x
    height = grid_top + grid_height + 22

    sheet = Image.new("RGBA", (width, height), (246, 248, 251, 255))
    draw = ImageDraw.Draw(sheet)
    title_font = load_font(label_font_path, max(20, round(size * 0.24)))
    subtitle_font = load_font(label_font_path, max(12, round(size * 0.15)))
    column_font = load_font(label_font_path, max(13, round(size * 0.16)))
    codepoint_font = load_font(label_font_path, max(10, round(size * 0.125)))
    row_font = load_font(label_font_path, max(14, round(size * 0.18)))
    title_color = (31, 41, 55, 255)
    muted_color = (93, 105, 119, 255)
    line_color = (218, 224, 232, 255)
    panel_color = (255, 255, 255, 255)

    centered_text(draw, (width / 2, margin_top + title_height / 2), "Windows 与 Apple Emoji 渲染对照", title_font, title_color)
    centered_text(
        draw,
        (width / 2, margin_top + title_height + subtitle_height / 2),
        f"同一 Unicode 字符 · 原始字体直接渲染 · 字号 {size} px",
        subtitle_font,
        muted_color,
    )

    rows = (("Windows", windows), ("Apple", apple))
    # Draw the complete grid before placing any source glyph pixels.
    draw.rectangle((margin_x, grid_top, width - margin_x, grid_top + grid_height), fill=panel_color, outline=line_color, width=1)
    draw.line((grid_left, grid_top, grid_left, grid_top + grid_height), fill=line_color, width=1)
    draw.line((margin_x, grid_top + header_height, width - margin_x, grid_top + header_height), fill=line_color, width=1)
    draw.line((margin_x, grid_top + header_height + row_height, width - margin_x, grid_top + header_height + row_height), fill=line_color, width=1)
    for column in range(len(SAMPLES) + 1):
        x = grid_left + column * cell_width
        draw.line((x, grid_top, x, grid_top + grid_height), fill=line_color, width=1)

    for column, sample in enumerate(SAMPLES):
        center_x = grid_left + column * cell_width + cell_width / 2
        centered_text(draw, (center_x, grid_top + 19), sample["name"], column_font, title_color)
        centered_text(draw, (center_x, grid_top + 41), " ".join(public_codepoints(sample["codepoints"])), codepoint_font, muted_color)

    image_box = size + 20
    for row_index, (row_label, images) in enumerate(rows):
        row_top = grid_top + header_height + row_index * row_height
        center_y = row_top + row_height / 2
        centered_text(draw, (margin_x + label_width / 2, center_y), row_label, row_font, title_color)
        for column, sample in enumerate(SAMPLES):
            record = images[sample["id"]]
            with Image.open(record["path"]) as source:
                if source.mode != "RGBA":
                    raise RuntimeError(f"Cannot place non-RGBA source image: {record['path'].name}")
                glyph = source.copy()
            cell_left = grid_left + column * cell_width
            box_left = cell_left + (cell_width - image_box) // 2
            box_top = row_top + (row_height - image_box) // 2
            x = box_left + (image_box - glyph.width) // 2
            y = box_top + (image_box - glyph.height) // 2
            sheet.alpha_composite(glyph, (x, y))

    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output, format="PNG", optimize=True, compress_level=9)


def load_lock() -> dict[str, Any]:
    try:
        lock = json.loads(LOCK_PATH.read_text(encoding="utf-8-sig"))
        font = lock["font"]
        return font
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Cannot read pinned font lock: {LOCK_PATH}") from exc


def main() -> None:
    args = parse_args()
    windows_font = require_file(args.windows_font, "Windows font")
    apple_font = require_file(args.apple_font, "Apple font")
    renderer = require_file(args.renderer, "EmojiRender")
    label_font = require_file(args.label_font, "Label font")
    if windows_font.suffix.lower() not in {".ttf", ".otf", ".ttc"} or apple_font.suffix.lower() not in {".ttf", ".otf", ".ttc"}:
        raise RuntimeError("Both source fonts must be TrueType/OpenType files")

    windows_hash = sha256(windows_font)
    apple_hash = sha256(apple_font)
    if windows_hash != WINDOWS_FONT_SHA256:
        raise RuntimeError("--windows-font does not match the pinned native backup SHA-256")
    lock_font = load_lock()
    pinned_hash = str(lock_font.get("sha256", "")).lower()
    if apple_hash != pinned_hash:
        raise RuntimeError("--apple-font does not match fonts.lock.json")
    if windows_hash == apple_hash:
        raise RuntimeError("Windows and Apple source fonts must be different files")

    windows_version = font_version(windows_font)
    apple_version = font_version(apple_font)
    with tempfile.TemporaryDirectory(prefix="apple-emoji-readme-") as temp_name:
        temp = Path(temp_name)
        requests = temp / "requests.tsv"
        write_requests(requests)
        manifests: dict[str, dict[str, Any]] = {}
        rendered: dict[str, dict[str, dict[str, Any]]] = {}
        for key, font in (("windows", windows_font), ("apple", apple_font)):
            output = temp / key
            manifests[key] = run_renderer(renderer, font, requests, output, args.size)
            rendered[key] = validate_render(manifests[key], output, font, args.size)
        compose_sheet(rendered["windows"], rendered["apple"], label_font, args.size, args.output)

    image_hash = sha256(args.output)
    image_size = args.output.stat().st_size
    if image_size > 180 * 1024:
        raise RuntimeError(f"Comparison PNG is too large: {image_size} bytes")
    provenance = {
        "schemaVersion": 1,
        "image": {"filename": args.output.name, "sha256": image_hash},
        "renderSizePx": args.size,
        "fonts": {
            "Windows": {
                "filename": windows_font.name,
                "sha256": windows_hash,
                "version": windows_version,
            },
            "Apple": {
                "filename": apple_font.name,
                "sha256": apple_hash,
                "version": apple_version,
                "pinnedVersion": str(lock_font.get("version", "")),
            },
        },
        "samples": [
            {
                "id": sample["id"],
                "name": sample["name"],
                "codepoints": public_codepoints(sample["codepoints"]),
            }
            for sample in SAMPLES
        ],
    }
    args.provenance.parent.mkdir(parents=True, exist_ok=True)
    args.provenance.write_text(json.dumps(provenance, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(json.dumps({"image": str(args.output), "bytes": image_size, "sha256": image_hash}, ensure_ascii=False))


if __name__ == "__main__":
    main()
