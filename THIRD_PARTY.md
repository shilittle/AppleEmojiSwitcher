# 第三方组件与权利说明

Apple Emoji 字体、Windows Segoe UI Emoji 以及其中的图案和数据归各自权利人所有。字体安装包不附带 Apple 或 Microsoft 字体；增强面板包包含从固定字体生成的候选预览图片。README 另提供八组字体实际渲染对比，来源与校验值记录在 `docs/images/windows-vs-apple.json`。Apple 字体在首次运行时按固定来源下载，原生补齐内容和恢复备份取自使用者本机。字体和依赖的许可独立于本工具源码。

运行时和构建依赖如下：

- **CPython 3.13.15**：Python Software Foundation License；随运行时提供其许可证文件。
- **FontTools 4.64.0**：MIT；许可证随 wheel 提供。
- **uharfbuzz 0.56.1**：MIT；其 HarfBuzz 部分遵循对应上游许可证。
- **Pillow 12.3.0**：HPND；许可证和依赖说明随 wheel 提供。
- **EmojiRender**：源码随仓库提供，调用 Windows 自带 DirectWrite、Direct2D、D3D11 和 WIC；使用静态链接的 C++ 运行库，不要求另装 Visual C++ 运行库。
- **Unicode Emoji 17.0 / CLDR 48.0.0**：历史面板目录及中英文检索词来自 Unicode 官方数据，遵循 Unicode License V3；许可原文见 [`native/panel/data/LICENSE.md`](https://github.com/shilittle/AppleEmojiSwitcher/blob/v1.3.0/native/panel/data/LICENSE.md)，固定来源与校验值见同目录的 `emoji17-sources.json`。
- **MinHook 1.3.4**：固定提交 `c3fcafdc10146beb5919319d0683e44e3c30d537`，仅保留历史开发源码，不参与当前面板构建；上游许可及反汇编组件声明见 [`native/panel/vendor/minhook/LICENSE.txt`](https://github.com/shilittle/AppleEmojiSwitcher/blob/v1.3.0/native/panel/vendor/minhook/LICENSE.txt)。

固定下载地址、版本、大小和校验值见 [`fonts.lock.json`](https://github.com/shilittle/AppleEmojiSwitcher/blob/v1.3.0/fonts.lock.json)，来源链接见 [`SOURCES.md`](https://github.com/shilittle/AppleEmojiSwitcher/blob/v1.3.0/SOURCES.md)。

## v1.3.0 增强面板

- 以下数据文件在源码中的目录为 `picker/data/`，解压后的 GUI 和 Panel 包中目录均为 `bin/picker-data/`。
- Unicode Emoji 18.0 与 CLDR 中英文名称：来源版本、SHA-256、预发布标记见该目录下的 `sources.json`，许可原文见 `LICENSE.txt`。
- Apple 预览图由 `fonts.lock.json` 指定的字体提取，Apple 图案权利仍属 Apple；不将图案误标成 Noto。
- Noto 回退预览由 Google Noto Emoji commit `06121655d0e82f9cae6e7ba6feed4fa6fdbfc2a4` 的 Windows Compatible 字体生成。字体使用 SIL OFL 1.1，见同目录下的 `NOTO-LICENSE.txt`。具体源文件 SHA-256 和每张预览图校验值见 `preview-report.json`。
- 增强面板使用 Windows 自带 .NET Framework、WinForms 和 Win32 API。没有第三方输入宿主注入依赖；MinHook 仅存在于未启用的历史研究源码。
