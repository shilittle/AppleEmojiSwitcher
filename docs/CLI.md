# Apple Emoji Switcher CLI

Windows 10/11 x64 的极简便携版，与 [GUI 版](https://github.com/shilittle/AppleEmojiSwitcher) 共用字体下载校验、系统事务和原始备份。

解压后双击 `aes.cmd`，按中文数字菜单操作；也可以在终端运行：

```bat
aes.cmd install
aes.cmd restore
aes.cmd cancel
aes.cmd status
aes.cmd verify
aes.cmd help
```

`install` 安装固定版本的原版苹果字体；`restore` 安排恢复原生；`cancel` 取消本工具的待重启操作。`status` 查看状态，`verify` 核对文件、备份和权限，**不检查实际表情绘制**。

CLI 不包含 Python、WPF、字体构建器或渲染组件，不补齐缺项、字号或文字形态。需要这些功能时使用 GUI 版。

首次字体下载约 **245 MiB**，固定为 `macos-26-20260722-484daf4e` Windows 构建，并按 SHA-256 和大小校验。优先复用 `%LOCALAPPDATA%\AppleEmojiSwitcher\cache`，原始备份位于 `%ProgramData%\AppleEmojiSwitcher`。工具不修改全局 Python、PATH 或代理。

只有修改系统时才请求管理员权限。显示“待重启”后，保存工作并重启；工具不会自动重启。再次运行 `verify` 检查结果。`restore`、`cancel`、`status`、`verify` 均不下载资源，恢复可离线执行。

两版共用原始备份，CLI 可恢复 GUI 安装的字体。已有本工具字体时 `install` 不重复安装；切换完整／极简模式，先 `restore` 并重启，再安装另一模式。不要删除 ProgramData 中的备份。

退出码：`0` 成功或无需操作；`3010` 已安排、需要重启；`1223` 管理员授权取消；`1` 其他失败。无参数运行进入菜单，有参数运行结束后直接返回。

部分应用使用自己的表情图片，不受系统字体替换影响。Apple 与 Microsoft 字体及图案归相应权利人所有，发布包不附带字体。固定资源见 `fonts.lock.json`；源码、第三方说明及验证范围见 [项目仓库](https://github.com/shilittle/AppleEmojiSwitcher)。
