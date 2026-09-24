> 历史原生组件调查，未用于 v1.3.0 增强面板；当前实现不调用这里的内部 ABI。

# 原生面板数据契约：离线证据

本记录只整理 Windows 11 23H2 当前组件的静态符号、反汇编和 ABI
边界；不构成面板功能已经可用的证明。没有注入 `TextInputHost`、没有
启动项或后台注册，也没有调用未公开的运行时对象。

## 固定样本

| 项目 | 值 |
| --- | --- |
| 系统组件 | `WindowsInternal.ComposableShell.Experiences.SuggestionUIUndocked.dll` |
| 文件版本 | `2125.25200.0.0` |
| SHA-256 | `d9d5cd9605d38a45ab8fcd256a65068b530215eb4924fac11cd709377e108c42` |
| PDB | `{4057BC4F-574F-4744-B6EB-32BF750C0E25}`, age `1` |
| PDB 来源 | Microsoft 公共符号服务器的匹配记录 |

后续实现必须同时校验文件版本和 SHA-256；任一项不同即禁用，不能沿用
这里的 RVA。

## 可确认的 ABI 边界

下面的 `HSTRING` 是 C++/CX `Platform::String^` 在 ABI 边界的等价表示。
声明仅适用于此表所列的固定样本和 x64 Windows 调用约定。

```cpp
using GetCategoriesInfoAbi = HRESULT(__fastcall*)(
    void* native_bridge, std::uint32_t item_type, HSTRING* result);

using GetItemsAbi = HRESULT(__fastcall*)(
    void* native_bridge, std::uint32_t item_type,
    HSTRING category, HSTRING* result);

using UpdateSearchResults = void(__fastcall*)(
    void* search_data_source, std::uint32_t item_type,
    HSTRING query, HSTRING result_json);
```

| 作用 | RVA | 静态证据 |
| --- | ---: | --- |
| 分类 ABI 包装器 | `0x1392A0` | DIA 给出 `HRESULT(type, Platform::String^*)`；包装器将 `*result` 清零后调用内部目标。它没有把 `RAX` 写回结果指针，因此不能把其内部投影名称当作普通 `HSTRING` 返回函数调用。 |
| 分类条目 ABI 包装器 | `0x0F2FC` | DIA 给出 `HRESULT(type, Platform::String^, Platform::String^*)`；包装器清零 `*result`，调用 `LayoutDataAdapter::GetItemsOfType`，然后将所得字符串交给调用方。 |
| 搜索结果更新 | `0xD6980` | DIA 给出 `void(type, Platform::String^ query, Platform::String^ json)`。函数序言分别保存 `EDX`、`R8`、`R9`。 |
| 分组搜索结果更新 | `0xD6BF8` | DIA 给出同一组参数、返回 `void`，用于 array 结果。 |
| 单次搜索请求 | `0xD6230` | DIA 给出 `void(type, query, limit)`；静态分支对非零 `type` 走 `E_NOTIMPL`，所以单次请求路径只接受数值 `0`。该数值的用户可见分类名称仍须面板实测确认。 |

`UpdateSearchResults` 在进入时对 `R9` 做 C++/CX 字符串引用复制，并在
结束前对这份复制调用 `WindowsDeleteString`。这证明传入 JSON 是调用期间
借用的输入值：钩子若创建替换字符串，应在调用原函数后释放**自己创建的**
`HSTRING`，不得释放原调用方传入的 `R9`。

## 已观察到的搜索结果形状

`GetExpressiveTextDataItemCollectionJson`（RVA `0xD54A4`）构建单组搜索
结果；`GetExpressiveTextDataItemCollectionArrayJson`（RVA `0xD4E90`）构建
多组结果。反汇编显示前者把候选项目放进外层的 `items` 数组。每个候选
对象已直接观察到以下写入：

```json
{
  "font": "Segoe UI",
  "value": "<候选项文本>",
  "matchType": 0
}
```

这里 `font` 的值来自组件的 UTF-16 常量 `Segoe UI`；`value` 和
`matchType` 分别取自 `TextSuggestionCandidate`。`matchType` 的枚举数字
含义尚未由面板实测确认，不能凭静态结果编造值。

搜索更新函数不会把主结果 JSON 直接作为通知参数重建。它把 JSON 缓存在
按 `itemType` 索引的字符串表中，然后构造一个通知对象，已观察到通知对象
包含：

```json
{
  "itemType": 0,
  "queryText": "<原查询>"
}
```

因此若将来改写搜索结果，必须改写的是原始结果 JSON，并保留原有数组／对象
形状；不能把上面的通知对象误作搜索结果。二进制附近还能找到
`versionAdded`、`neutralSkintonePresentation`、`requireEmojiPresentation`
等字符串，但尚未证明它们是此版本结果对象的必需字段，所以没有把它们列入
可生成的契约。

## 实现边界与待验收项

静态证据支持在分类、分类条目和搜索结果的返回／输入边界做字符串层变换，
但尚未取得真实宿主发出的分类 JSON 或条目 JSON。实现前必须在隔离的面板
验收中记录一次原始分类、一个分类条目和中英文搜索结果，再以原样结构追加
Emoji 17.0 条目。

点击路径已有独立 `NativeBridge::HandleExpressiveTextSelection` 符号；为
保持系统插入链路，首版不应钩住或伪造该调用，而应只让系统读取追加后的
候选 `value`。这一点以及分类显示、中文／英文搜索和点击插入，均仍是待做的
实机面板验收。

## 可复核的离线材料

以下材料在 `native/panel/.analysis/bridge/`，已由 `.gitignore` 排除，不会
进入发布包：

* `LookupDia.cpp` 与 `LookupDia.exe`：DIA 按 RVA 查到的符号核验工具；
* `items-abi-disasm.txt`、`categories-abi-disasm.txt`：两个 ABI 包装器；
* `search-serializer-disasm.txt`、`search-array-serializer-disasm.txt`：JSON
  序列化路径；
* `search-update-disasm.txt`、`search-update-array-disasm.txt`：搜索缓存与
  通知路径。

分析中没有生成注入 DLL、修改系统文件或启动输入宿主。
