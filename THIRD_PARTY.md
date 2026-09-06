# 第三方组件与权利说明

Apple Emoji 字体、Windows Segoe UI Emoji 以及其中的图案和数据归各自权利人所有。发布包不附带 Apple 或 Microsoft 字体；Apple 字体在首次运行时按固定来源下载，原生补齐内容和恢复备份取自使用者本机。字体和依赖的许可独立于本工具源码。

运行时和构建依赖如下：

- **CPython 3.13.15**：Python Software Foundation License；随运行时提供其许可证文件。
- **FontTools 4.64.0**：MIT；许可证随 wheel 提供。
- **uharfbuzz 0.56.1**：MIT；其 HarfBuzz 部分遵循对应上游许可证。
- **Pillow 12.3.0**：HPND；许可证和依赖说明随 wheel 提供。
- **EmojiRender**：源码随仓库提供，调用 Windows 自带 DirectWrite、Direct2D、D3D11 和 WIC；使用静态链接的 C++ 运行库，不要求另装 Visual C++ 运行库。

固定下载地址、版本、大小和校验值见 [`fonts.lock.json`](fonts.lock.json)，来源链接见 [`SOURCES.md`](SOURCES.md)。
