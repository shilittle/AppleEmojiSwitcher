# 固定来源

发布包使用 `fonts.lock.json` 固定版本、下载地址、文件大小和 SHA-256。工具不会自动跟随上游新版本。

## 字体

- [samuelngs/apple-emoji-ttf Windows 构建](https://github.com/samuelngs/apple-emoji-ttf/releases/tag/macos-26-20260722-484daf4e)
- 固定文件：`AppleColorEmoji-Windows.ttf`
- 版本标签：`macos-26-20260722-484daf4e`
- SHA-256：`18e48f1785564fbf511241e0963b265057bfe742036d8543406c6ce07e48ec0b`

本工具以该字体为底稿，并根据本机 Segoe UI Emoji 的可用项目补齐少量内容；没有直接运行上游安装脚本。

## 运行时与数据

- [Python 3.13.15 Windows x64 嵌入式包](https://www.python.org/downloads/release/python-31315/)
- [Unicode Emoji 17.0 数据目录](https://www.unicode.org/Public/17.0.0/emoji/)
- [Unicode Emoji 17.0 variation sequences](https://www.unicode.org/Public/17.0.0/ucd/emoji/emoji-variation-sequences.txt)
- [FontTools 文档](https://fonttools.readthedocs.io/)
- [uharfbuzz 项目](https://github.com/harfbuzz/uharfbuzz)
- [Pillow 文档](https://pillow.readthedocs.io/)

## Windows 技术文档

- [Microsoft DirectWrite 彩色字体](https://learn.microsoft.com/en-us/windows/win32/directwrite/color-fonts)
- [Microsoft MoveFileExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw)
- [OpenType cmap](https://learn.microsoft.com/en-us/typography/opentype/spec/cmap)
- [OpenType CBDT/CBLC](https://learn.microsoft.com/en-us/typography/opentype/spec/cbdt)

所有可复现下载项的版本和哈希以 `fonts.lock.json` 为准。
