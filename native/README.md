# EmojiRender

`EmojiRender.exe` opens exactly one font face: `--font FILE` creates a private DirectWrite collection containing that file alone, and installs an empty fallback object on every text format. `--font @system` is only for post-reboot verification of the system `Segoe UI Emoji` face. A shaped glyph index of zero (`.notdef`) or a transparent render fails the command.

The renderer uses DirectWrite shaping and Direct2D `ID2D1DeviceContext4::DrawTextLayout` with `D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT`, rendered to a transparent BGRA Direct3D target and encoded by WIC as PNG. It therefore exercises Windows' COLR/CPAL and CBDT/CBLC rendering paths. A shaped `.notdef` glyph or a fully transparent result fails. `colorPixels` is recorded for the caller's known-color smoke assertions, because a valid emoji bitmap or symbol can be grayscale. `glyphIndices` and metrics come from the actual `IDWriteTextLayout::Draw` glyph runs before Direct2D color expansion; a run from another font face fails. `--diagnose` also prints the actual layout run and a standalone `IDWriteTextAnalyzer` run so a shaping discrepancy is visible without changing normal rendering.

Metric convention at 96 DPI: `size` is the DirectWrite font em size in pixels; `advance` is the sum of DirectWrite natural x-advances before crop; `offsetX` is the tight-alpha-box left edge minus the glyph-run origin (the left bearing); `offsetY` is the baseline minus the tight-alpha-box top edge, positive above baseline. PNG images are tightly alpha-cropped and use premultiplied BGRA WIC pixels. `glyphIndices` are captured from DirectWrite shaping before COLR expansion.

Build on a machine with Visual Studio 2022 Professional and Windows SDK:

```cmd
cd native
build-EmojiRender.cmd
```
