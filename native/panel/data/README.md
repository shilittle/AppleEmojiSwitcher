# Emoji 17.0 面板目录数据

本目录保存供后续原生面板组件使用的静态目录数据：163 个 Emoji 17.0
fully-qualified 序列和 20 个 minimally-qualified 别名。可见条目保留
Unicode `emoji-test.txt` 的 codepoint 顺序；别名只用于匹配，不作为重复的
可见条目。

这里的文件只提供目录、名称、搜索关键词和 C++ 静态嵌入数据。它不表示
Windows `TextInputHost`、`Win + .` 面板或其他原生输入组件已经支持、已经
注入、已经启用或已经完成实机验收。

## 文件

- `emoji17-catalog.json`：UTF-8 目录输出，包含序列、Unicode 名称、CLDR
  中英文显示名称、搜索关键词、分组和来源行号。
- `Emoji17Catalog.h`：由生成器产生的 C++17 静态数组；关键词使用
  `kEmoji17KeywordSeparator`（ASCII `US`, `0x1F`）分隔。
- `emoji17-labels.cldr48.json`：从固定 CLDR 48.0.0 官方文件提取的最小
  标签输入，不包含字体或 Windows 组件。
- `emoji17-sources.json`：Unicode 与 CLDR 的固定版本、URL、大小和
  SHA-256 provenance。
- `LICENSE.md`：Unicode License V3 和上游许可证来源。

## 固定来源

Unicode Emoji 17.0 的输入是：

<https://unicode.org/Public/17.0.0/emoji/emoji-test.txt>

其 SHA-256 是
`1d8a944f88d7952f7ef7c5167fef3c67995bcae24543949710231b03a201acda`，大小
为 `669326` 字节。生成器默认要求它与仓库 `fonts.lock.json` 一致。

中英文名称和搜索关键词来自 Unicode CLDR JSON 版本 `48.0.0`，对应提交
`4d06be52b51bb2f75688d0abe55c52a66afed790`。完整来源文件及校验值见
`emoji17-sources.json`；CLDR 归档 SHA-256 为
`25ab2651a1a874dd62a727d3c213d7c6bf0fc269b09d2937f0499b82d99fa58e`。

生成器仅在查找 CLDR 标签时尝试去除 `FE0F`；写入 JSON 和 C++ 头文件时
始终保留 Unicode 输入的完整序列。

## 生成

使用本机已校验的嵌入式 Python 和 Unicode 缓存，可直接从已提取的固定
CLDR 标签重建两个输出：

```powershell
$py = Join-Path $env:LOCALAPPDATA 'AppleEmojiSwitcher\runtime\python.exe'
& $py -I -B scripts\generate-panel-catalog.py `
  --emoji-test "$env:LOCALAPPDATA\AppleEmojiSwitcher\cache\unicode\emoji-test.txt" `
  --lock fonts.lock.json `
  --source-manifest native\panel\data\emoji17-sources.json `
  --label-source native\panel\data\emoji17-labels.cldr48.json `
  --json-out native\panel\data\emoji17-catalog.json `
  --header-out native\panel\data\Emoji17Catalog.h
```

如果要从 CLDR 48.0.0 完整 JSON 重新提取标签，额外提供 `--cldr-zh`、
`--cldr-en`、`--cldr-derived-zh`、`--cldr-derived-en` 四个文件，并使用
`--label-source-out native\panel\data\emoji17-labels.cldr48.json`。生成器
会先校验 Unicode 和四个 CLDR 输入的大小、SHA-256 及固定来源，再写出确定性的 UTF-8
结果。

许可证说明见 [`LICENSE.md`](LICENSE.md)。
