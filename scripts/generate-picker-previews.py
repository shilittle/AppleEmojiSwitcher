"""Build offline picker thumbnails from pinned Apple-first / Noto fonts.

This reads fonts only; it never installs or changes system fonts. It extracts
the bitmap selected by HarfBuzz rather than relying on the OS emoji repertoire.
Run with the existing private Python (fontTools, uharfbuzz and Pillow).
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "builder"))
from font_audit import FontAudit
from PIL import Image

NOTO_COMMIT = "06121655d0e82f9cae6e7ba6feed4fa6fdbfc2a4"
NOTO_BASE = "https://raw.githubusercontent.com/googlefonts/noto-emoji/" + NOTO_COMMIT
NOTO_SHA256 = "2c7ede2f5438f9c1da098778bd681535933a345334008bb03fc51119f6b1cd72"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def download(url, destination):
    proxies = urllib.request.getproxies()
    if os.name == "nt" and "https" not in proxies:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Internet Settings") as key:
            if winreg.QueryValueEx(key, "ProxyEnable")[0]:
                server = winreg.QueryValueEx(key, "ProxyServer")[0]
                if "=" not in server:
                    proxies["https"] = "http://" + server
    opener = urllib.request.build_opener(urllib.request.ProxyHandler(proxies))
    with opener.open(url, timeout=90) as response:
        data = response.read()
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)


def bitmap(audit, sequence):
    points = tuple(map(ord, sequence))
    shaped = audit.shape(points)
    if len(shaped) != 1 or shaped[0]["id"] == 0:
        return None
    if any(0xE0020 <= cp <= 0xE007F for cp in points):
        if audit.shape(tuple(cp for cp in points if not 0xE0020 <= cp <= 0xE007F)) == shaped:
            return None
    name = shaped[0]["name"]
    if "CBDT" not in audit.tt:
        return None
    strikes = audit.tt["CBDT"].strikeData
    sizes = audit.tt["CBLC"].strikes
    order = sorted(range(len(strikes)), key=lambda i: abs(sizes[i].bitmapSizeTable.ppemY - 72))
    for i in order:
        if name in strikes[i]:
            glyph = strikes[i][name]
            try:
                return Image.open(io.BytesIO(glyph.imageData)).convert("RGBA")
            except (AttributeError, OSError):
                continue
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=ROOT / "picker/data")
    parser.add_argument("--apple-font", type=Path, default=Path(os.environ.get("LOCALAPPDATA", ".")) / "AppleEmojiSwitcher/cache/font/AppleColorEmoji-Windows.ttf")
    parser.add_argument("--noto-font", type=Path, default=ROOT / ".build/preview-font/NotoColorEmoji.ttf")
    args = parser.parse_args()
    lock = json.loads((ROOT / "fonts.lock.json").read_text(encoding="utf-8-sig"))["font"]
    if sha(args.apple_font) != lock["sha256"]:
        raise ValueError("Apple font does not match fonts.lock.json")
    noto_url = NOTO_BASE + "/2D/fonts/NotoColorEmoji_WindowsCompatible.ttf"
    if not args.noto_font.exists():
        download(noto_url, args.noto_font)
    if sha(args.noto_font) != NOTO_SHA256:
        raise ValueError("Noto preview font checksum mismatch")
    license_path = args.data_dir / "NOTO-LICENSE.txt"
    if not license_path.exists():
        download(NOTO_BASE + "/LICENSE", license_path)
    apple, noto = FontAudit(args.apple_font), FontAudit(args.noto_font)
    images = args.data_dir / "images"
    images.mkdir(parents=True, exist_ok=True)
    records = []
    rows = [line.split("\t") for line in (args.data_dir / "catalog.tsv").read_text(encoding="utf-8-sig").splitlines()]
    for row in rows:
        img = bitmap(apple, row[1])
        kind = "apple"
        if img is None:
            img = bitmap(noto, row[1])
            kind = "noto"
        if img is None or img.getbbox() is None:
            raise ValueError("No complete preview for " + row[0])
        img = img.crop(img.getbbox())
        img.thumbnail((64, 64), Image.Resampling.LANCZOS)
        tile = Image.new("RGBA", (72, 72))
        tile.alpha_composite(img, ((72 - img.width) // 2, (72 - img.height) // 2))
        path = images / (row[0] + ".png")
        tile.save(path, optimize=True)
        row[7] = kind
        records.append({"id": row[0], "source": kind, "sha256": sha(path)})
    apple.close()
    noto.close()
    (args.data_dir / "catalog.tsv").write_text("\n".join("\t".join(row) for row in rows) + "\n", encoding="utf-8", newline="\n")
    report = {"schemaVersion": 1, "appleFontSha256": sha(args.apple_font),
              "notoFont": {"url": noto_url, "commit": NOTO_COMMIT, "sha256": sha(args.noto_font)},
              "total": len(records), "apple": sum(r["source"] == "apple" for r in records),
              "noto": sum(r["source"] == "noto" for r in records), "images": records}
    (args.data_dir / "preview-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in report.items() if k != "images"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
