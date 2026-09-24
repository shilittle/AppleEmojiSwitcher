# v1.3.0 验证记录

验证日期：2026-09-20。系统：Windows 11 23H2 x64，22631.6199。未升级 Windows，未重装或修改系统字体。

## 已通过

| 范围 | 证据 |
| --- | --- |
| 完整候选目录 | Unicode 18.0 官方 emoji-test 的 3,963 个 fully-qualified 序列，唯一且无损；19 项为 Emoji 18 新增。另有 9 个 component 未作为独立候选 |
| 中文与英文名称 | 固定 CLDR 49.0.0-ALPHA2 快照，来源明确标记 prerelease；Unicode 标准数据为正式版 |
| 离线预览 | 3,963 张均通过 SHA-256 与非空像素检查；3,941 张 Apple，22 张 Noto。最新 19 项已逐一查看 |
| 目录测试 | `python tests/Test-PickerCatalog.py`，12 项通过，含损坏来源拒绝、序列保真和确定性再生成 |
| UI 与输入编码 | `powershell -Sta -File tests/Test-PickerUi.ps1` 通过：UTF-16 代理对、ZWJ、VS16、搜索、分类、最新、最近及实际窗体构造/释放 |
| 实际点击输入 | 在专用 WinForms 测试输入框，点击增强面板“裂开”，接收到精确 `U+1FAEB`；证据见 [输入验证数据](https://github.com/shilittle/AppleEmojiSwitcher/blob/v1.3.0/docs/picker-input-validation.json) |
| 安装和启停 | `tests/Test-PickerLifecycle.ps1` 隔离测试通过，含启动失败回滚、自卸载、用户数据保留、重解析点拒绝；测试信号与生产信号已隔离 |
| 本机后台 | 实际 enable 与重复 enable 成功；status 的 installed/running/ready/startupRegistered 均为 true；HKCU Run 指向当前用户安装目录 |
| 前端与便携包 | 前端成功/失败解析、PowerShell 5.1 语法、独立面板包及字体 GUI/CLI 共用文件校验通过 |
| 中文状态协议 | `tests/Test-PickerProtocol.ps1` 通过：中文和 Emoji 在 CP936、CP1252、UTF-8 重定向中均无损；中文及空格目录解压运行通过 |
| 字体回归 | 原有字体构建 10 项、旧目录 10 项和共用资源/事务/CLI/Bootstrap/失败处理测试通过；本机 CLI verify 仍为 Built，备份与权限通过 |

## 实际边界

- 本版是独立增强面板接管 Win + . / Win + ;，不向 Windows 原生面板注入条目。
- 尚未得到真人物理 Win + . / Win + ;、左右 Win、不同松键顺序、长按和开始菜单行为的最终反馈；不将代码检查或 show 命令代替实键验收。
- 实际点击输入已在专用 WinForms 输入框验证；浏览器、Office、管理员应用和特殊编辑器未逐一实测。UTF-16/ZWJ/肤色编码另有自动测试。
- 目标字体可能尚无 Emoji 18 图案；面板能选择并发送字符不等于所有目标应用已能显示。
- 登录启动项和当前运行进程已核验，未为验证而注销或重启电脑。
- 自卸载先报告 uninstall_scheduled，随后由临时 helper 清理；需用 status 确认完成。helper 可能留在临时目录，卸载失败会保留可重试状态和诊断日志。

## 2026-09-22 界面增补验证

- 字体管理窗口按状态、字体操作、面板管理和进度分组；小窗口可滚动，覆盖率与日志入口固定在底部。管理窗口 XAML 独立加载，不执行真实系统操作。
- 表情面板统一分类、选中、悬停和复制按钮样式；选中项独占一行，完整码位与来源可通过悬停和辅助功能描述读取。方向键依据实际网格行移动。
- `tests/Test-UiLayout.ps1` 通过：默认及最小窗口、待重启按钮、长路径和长状态文本、全部操作可滚动访问、底部入口可见。
- `tests/Test-PickerUi.ps1` 通过：保留原搜索、分类、最近使用和 UTF-16 检查，增加 610 / 640 / 710 / 790 像素宽度下的控件边界与下方向键同列移动检查。
- 管理窗口和表情面板已渲染检查，覆盖默认、最小窗口、空结果及缩放模拟。缩放模拟不替代跨显示器实测；此次未重新执行真实输入、安装、注销或重启验收。
- `tests/Test-UiTransactionStatus.ps1`、`tests/Test-PanelFrontend.ps1`、`tests/Test-PickerProtocol.ps1` 回归通过。此次界面调整保持字体事务、输入发送、生命周期、目录和预览资源不变；不增加运行框架或系统依赖。面板包仍包含离线预览图片。
- `PanelController.exe` 为 61,440 字节，比改动前增加 2,560 字节；Windows 自带 .NET Framework 运行方式不变。

## 构建与重现

2026-09-24 发布前复核：11 组 PowerShell 测试通过，包括隔离安装/启停/卸载与窗口布局；字体构建、历史面板目录、Emoji 18 目录共 32 项 Python 测试通过。此次没有为发布而更改系统字体、注册生产启动项或重启电脑；较早的实际输入与本机运行证据见上文日期。

Windows 自带 .NET Framework 4.x 即可运行，无需 .NET SDK、Python 或联网。源码构建：`native/picker/build-picker.cmd`；目录和预览的生成脚本仅为开发工具。面板包包括目录、图片和许可；GUI 包另附源代码及可复现的 Unicode/CLDR 输入。

构建后运行 `python scripts/package.py --variant all` 生成 GUI、CLI 和 Panel ZIP，各包都有逐文件清单和 ZIP SHA-256。
