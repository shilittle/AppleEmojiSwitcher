# Apple Emoji Switcher

面向 Windows 10/11 x64 的中文便携工具，用经过校验的 Apple Emoji 字体替换系统 Segoe UI Emoji，并在替换前补齐本机原生支持的项目。

## 下载

从 [Releases](https://github.com/shilittle/AppleEmojiSwitcher/releases/tag/v1.1.1) 下载当前的 v1.1.1 预览版。源码、构建脚本、测试和校验报告都在仓库中；发布包不内置 Apple 字体或 Python 运行时。

## 使用

1. 解压完整发布包，双击 `启动.vbs`。
2. 点击“一键替换”，等待资源检查、字体构建和 Windows 实际绘制检查完成。
3. 在 UAC 提示中允许管理员操作；界面显示“待重启”后，保存工作并重启电脑。
4. 重启后重新打开工具验证显示，并用随包的 `应用显示验收.html` 在 Edge、记事本和 Win＋句号输入后的正文中核对效果。

工具不会自动重启。重启前可点击“取消待重启操作”；已经替换后可点击“恢复原生”，然后再次重启。恢复流程使用本机备份，可离线执行。

首次运行会下载约 245 MiB 的字体，另准备私有 Python 和固定版本依赖。资源会缓存到 `%LOCALAPPDATA%\AppleEmojiSwitcher`，系统字体备份和事务资料位于 `%ProgramData%\AppleEmojiSwitcher`。工具不修改全局 Python、PATH 或系统代理。

## 兼容性说明

Apple 优先；Apple 没有而 Windows 原生支持的表情会用原生图案补齐。检查覆盖 Unicode Emoji 17.0 的肤色、国旗、键帽、性别和 ZWJ 组合。

本机对英格兰、苏格兰、威尔士三面地区旗存在 Windows 布局差异，可能显示为黑旗。该局部差异只产生警告，默认不阻止替换。字体损坏、校验失败、备份失败或事务无法恢复时仍会停止。

应用自己附带的表情图片不受系统字体替换影响；不同应用的字体引擎也可能造成显示差异。详细数字、证据和限制见 [VALIDATION.md](VALIDATION.md)，固定来源见 [SOURCES.md](SOURCES.md)，第三方组件说明见 [THIRD_PARTY.md](THIRD_PARTY.md)。

## 目录

- `AppleEmojiSwitcher.ps1`、`启动.vbs`：可视化入口
- `builder`、`lib`、`native`：字体构建、系统事务和 Windows 渲染代码
- `tests`：自动化测试
- `docs`：公开验证摘要
- `scripts/package.py`：运行 `python scripts/package.py` 生成便携 ZIP 及 SHA-256 文件

本工具只面向 Windows 10/11 x64。请保留发布包的目录结构，并在修改系统字体前保存未完成的工作。
