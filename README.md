# Apple Emoji Switcher

面向 Windows 10/11 x64 的中文便携工具，支持 Apple Emoji 替换、取消待重启操作及离线恢复。GUI 与极简 CLI 共用下载校验和系统事务代码。

## 下载

从 [v1.2.1 预览版](https://github.com/shilittle/AppleEmojiSwitcher/releases/tag/v1.2.1) 下载对应 ZIP 及 SHA-256。发布包不内置字体或 Python 运行时。

| 版本 | 特点 | 启动 |
| --- | --- | --- |
| GUI 完整版 | 图形界面、原生缺项补齐、字号和文字形态修补、实际绘制检查 | `启动.vbs` |
| CLI 极简版 | 直接安装固定苹果字体，无 Python、WPF 或渲染组件 | `aes.cmd` |

CLI 无参数提供中文菜单，也支持 `install`、`restore`、`cancel`、`status`、`verify`、`help` 命令，详见 [CLI 使用说明](docs/CLI.md)。`verify` 只核验文件、备份与权限，不代表绘制验收。

## GUI 使用

1. 解压完整发布包，双击 `启动.vbs`。
2. 点击“一键替换”，等待资源检查、字体构建和 Windows 实际绘制检查完成。
3. 在 UAC 提示中允许管理员操作；界面显示“待重启”后，保存工作并重启电脑。
4. 重启后重新打开工具验证显示，并用随包的 `应用显示验收.html` 在 Edge、记事本和 Win＋句号输入后的正文中核对效果。

工具不会自动重启。重启前可点击“取消待重启操作”；已经替换后可点击“恢复原生”，然后再次重启。恢复流程使用本机备份，可离线执行。

两版共用约 245 MiB 的字体缓存；GUI 另准备私有 Python 和固定依赖。缓存位于 `%LOCALAPPDATA%\AppleEmojiSwitcher\cache`，原始备份和事务资料位于 `%ProgramData%\AppleEmojiSwitcher`。工具不修改全局 Python、PATH 或系统代理。

CLI 能恢复 GUI 已安装的字体，重复安装不会替换现有模式。切换完整／极简模式时，先恢复原生并重启。

如果旧版首次运行出现 `ExternalDrift`，更新后重新运行 `aes.cmd status`：v1.2.1 修复了原生字体注册为完整路径或可展开路径时的误报。若仍提示外部改动，请保留原始备份并提供完整状态输出；Windows 更新、其他字体工具改动或安装记录缺失需要按实际哈希判断，不能通过删除备份消除报错。

## 兼容性说明

GUI 使用 Apple 优先规则，补齐本机原生支持的缺项，检查 Unicode Emoji 17.0 的肤色、国旗、键帽、性别和 ZWJ 组合。CLI 直接使用上游原版字体，不进行这些加工。

本机对英格兰、苏格兰、威尔士三面地区旗存在 Windows 布局差异，可能显示为黑旗。该局部差异只产生警告，默认不阻止替换。字体损坏、校验失败、备份失败或事务无法恢复时仍会停止。

应用自己附带的表情图片不受系统字体替换影响；不同应用的字体引擎也可能造成显示差异。详细数字、证据和限制见 [VALIDATION.md](VALIDATION.md)，固定来源见 [SOURCES.md](SOURCES.md)，第三方组件说明见 [THIRD_PARTY.md](THIRD_PARTY.md)。

## 目录

- `AppleEmojiSwitcher.ps1`、`启动.vbs`：GUI 入口；`aes.cmd`：CLI 入口
- `builder`、`lib`、`native`：字体构建、系统事务和 Windows 渲染代码
- `tests`：自动化测试
- `docs`：公开验证摘要
- `scripts/package.py`：运行 `python scripts/package.py --variant all` 生成两版 ZIP 及 SHA-256

本工具只面向 Windows 10/11 x64。请保留发布包的目录结构，并在修改系统字体前保存未完成的工作。
