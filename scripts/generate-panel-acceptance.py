"""Generate the offline Emoji 17.0 native-panel acceptance worksheet.

This tool only turns the checked-in catalog into a local HTML worksheet.  It
does not load TextInputHost, inject a DLL, write the clipboard, or make any
claim about the native Win+. panel.  All observations in the generated page
start empty and must be entered by a person who has just used the native
panel.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CATALOG = ROOT / "native" / "panel" / "data" / "emoji17-catalog.json"
DEFAULT_OUTPUT = ROOT / "docs" / "面板验收.html"
PLANNED_VERSION = "1.3.0"
LIFECYCLE_STATUS = "development-manual-pending"
GENERATOR_VERSION = "1"


class AcceptanceCatalogError(ValueError):
    """Raised when the checked-in catalog cannot be used for acceptance."""


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise AcceptanceCatalogError(f"无法读取目录：{path}: {exc}") from exc
    if not isinstance(value, dict):
        raise AcceptanceCatalogError(f"目录根节点不是对象：{path}")
    return value


def sequence_from_codepoints(codepoints: list[int]) -> str:
    try:
        return "".join(chr(value) for value in codepoints)
    except (TypeError, ValueError) as exc:
        raise AcceptanceCatalogError(f"目录包含无效 Unicode codepoint：{codepoints!r}") from exc


def validate_item(item: dict[str, Any], expected_index: int, kind: str) -> None:
    if item.get("index") != expected_index:
        raise AcceptanceCatalogError(f"{kind} index 不连续：期望 {expected_index}，得到 {item.get('index')}")
    points = item.get("codepoints")
    if not isinstance(points, list) or not points:
        raise AcceptanceCatalogError(f"{kind} {expected_index} 缺少 codepoints")
    if sequence_from_codepoints(points) != item.get("sequence"):
        raise AcceptanceCatalogError(f"{kind} {expected_index} 的 sequence 与 codepoints 不一致")
    for key in ("nameEn", "nameZh", "group", "subgroup"):
        if not isinstance(item.get(key), str) or not item[key]:
            raise AcceptanceCatalogError(f"{kind} {expected_index} 缺少 {key}")
    for key in ("keywordsEn", "keywordsZh"):
        values = item.get(key)
        if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
            raise AcceptanceCatalogError(f"{kind} {expected_index} 的 {key} 无效")


def load_catalog(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    catalog = read_json(path)
    if catalog.get("schemaVersion") != 1 or catalog.get("unicodeVersion") != "17.0":
        raise AcceptanceCatalogError("只接受 schemaVersion 1 的 Emoji 17.0 目录")
    entries = catalog.get("entries")
    aliases = catalog.get("aliases")
    if not isinstance(entries, list) or not isinstance(aliases, list):
        raise AcceptanceCatalogError("目录缺少 entries 或 aliases")
    if len(entries) != 163 or len(aliases) != 20:
        raise AcceptanceCatalogError(
            f"目录数量不符合面板验收固定预期：entries={len(entries)}，aliases={len(aliases)}"
        )
    if catalog.get("entryCount") != 163 or catalog.get("aliasCount") != 20:
        raise AcceptanceCatalogError("目录的 entryCount/aliasCount 与内容不一致")

    canonical_sequences: set[str] = set()
    for index, item in enumerate(entries):
        if not isinstance(item, dict):
            raise AcceptanceCatalogError(f"正式序列 {index} 不是对象")
        validate_item(item, index, "正式序列")
        if item["sequence"] in canonical_sequences:
            raise AcceptanceCatalogError(f"正式序列重复：{item['sequence']!r}")
        canonical_sequences.add(item["sequence"])

    alias_sequences: set[str] = set()
    for index, item in enumerate(aliases):
        if not isinstance(item, dict):
            raise AcceptanceCatalogError(f"简化序列 {index} 不是对象")
        validate_item(item, index, "简化序列")
        canonical_index = item.get("canonicalIndex")
        if not isinstance(canonical_index, int) or not 0 <= canonical_index < len(entries):
            raise AcceptanceCatalogError(f"简化序列 {index} 的 canonicalIndex 无效")
        expected_alias = entries[canonical_index]["sequence"].replace("\ufe0f", "")
        if item["sequence"] != expected_alias:
            raise AcceptanceCatalogError(f"简化序列 {index} 没有对应的 FE0F 简化形式")
        if item["sequence"] in canonical_sequences or item["sequence"] in alias_sequences:
            raise AcceptanceCatalogError(f"简化序列重复或与正式序列重复：{item['sequence']!r}")
        alias_sequences.add(item["sequence"])

    rows: list[dict[str, Any]] = []
    for item in entries:
        rows.append(make_row(item, "canonical", "正式序列", item["index"]))
    for item in aliases:
        rows.append(make_row(item, "alias", "简化序列", item["canonicalIndex"]))
    return catalog, rows


def make_row(item: dict[str, Any], kind: str, kind_zh: str, canonical_index: int) -> dict[str, Any]:
    codepoints = item["codepoints"]
    return {
        "id": f"{'C' if kind == 'canonical' else 'A'}-{item['index']:03d}",
        "kind": kind,
        "kindZh": kind_zh,
        "index": item["index"],
        "canonicalIndex": canonical_index,
        "codepoints": codepoints,
        "codepointText": " ".join(f"U+{value:04X}" for value in codepoints),
        "sequence": item["sequence"],
        "nameEn": item["nameEn"],
        "nameZh": item["nameZh"],
        "keywordsEn": item["keywordsEn"],
        "keywordsZh": item["keywordsZh"],
        "group": item["group"],
        "subgroup": item["subgroup"],
    }


def js_payload(catalog: dict[str, Any], rows: list[dict[str, Any]]) -> str:
    payload = {
        "schemaVersion": 1,
        "plannedVersion": PLANNED_VERSION,
        "lifecycleStatus": LIFECYCLE_STATUS,
        "generatorVersion": GENERATOR_VERSION,
        "unicodeVersion": catalog["unicodeVersion"],
        "canonicalCount": len(catalog["entries"]),
        "aliasCount": len(catalog["aliases"]),
        "provenance": catalog.get("provenance", {}),
        "rows": rows,
    }
    # The payload is placed in a JavaScript literal.  Escape characters that
    # could terminate a script element even though current catalog labels do
    # not contain them.
    return (
        json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("&", "\\u0026")
        .replace("\u2028", "\\u2028")
        .replace("\u2029", "\\u2029")
    )


HTML_TEMPLATE = r'''<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>AppleEmojiSwitcher Emoji 17.0 面板验收</title>
  <style>
    :root { color-scheme: light; font-family: "Microsoft YaHei UI", "Segoe UI", sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; color: #182230; background: #f4f7fb; line-height: 1.5; }
    header { padding: 28px 5vw 22px; color: #fff; background: #1d3557; }
    header h1 { margin: 0 0 6px; font-size: 26px; }
    header p { margin: 4px 0; color: #dbe9fa; }
    main { width: min(1600px, 94vw); margin: 18px auto 60px; }
    section, .toolbar { margin: 14px 0; padding: 16px 18px; background: #fff; border: 1px solid #d9e2ee; border-radius: 10px; box-shadow: 0 2px 8px #19324a0c; }
    h2 { margin: 0 0 8px; font-size: 19px; }
    h3 { margin: 12px 0 4px; font-size: 16px; }
    .warning { padding: 10px 12px; color: #6b3b00; background: #fff7e5; border-left: 4px solid #e0a329; }
    .status { display: flex; flex-wrap: wrap; gap: 9px; margin-top: 12px; }
    .status span { padding: 5px 10px; border-radius: 999px; background: #eaf1fb; }
    .status .pending { color: #7a4100; background: #fff1d1; }
    .instructions ol { margin: 6px 0 0 24px; padding: 0; }
    code, .mono { font-family: Consolas, "Cascadia Mono", monospace; }
    .toolbar { display: flex; align-items: center; flex-wrap: wrap; gap: 9px; position: sticky; top: 0; z-index: 2; }
    .toolbar input, .toolbar select, button, .gate input[type="text"] { min-height: 34px; border: 1px solid #bac8d8; border-radius: 6px; padding: 6px 9px; background: #fff; font: inherit; }
    .toolbar input { min-width: 260px; flex: 1; }
    button { cursor: pointer; color: #fff; background: #1d5e9f; border-color: #1d5e9f; }
    button.secondary { color: #1d3557; background: #edf3fa; border-color: #b8c9dc; }
    button:focus-visible, input:focus-visible, select:focus-visible { outline: 3px solid #8cc8ff; outline-offset: 1px; }
    .table-wrap { overflow: auto; max-height: 70vh; border: 1px solid #d9e2ee; }
    table { width: 100%; min-width: 1180px; border-collapse: collapse; font-size: 13px; }
    th, td { padding: 8px 9px; vertical-align: top; text-align: left; border-bottom: 1px solid #e3e9f1; }
    th { position: sticky; top: 0; z-index: 1; color: #243b55; background: #eef4fb; }
    tbody tr:hover { background: #f7fbff; }
    .glyph { display: inline-block; min-width: 38px; font-size: 31px; line-height: 1.1; text-align: center; }
    .kind { display: inline-block; padding: 2px 6px; border-radius: 4px; font-size: 12px; background: #e6f3ed; color: #23633e; }
    .kind.alias { background: #f1eafb; color: #68409c; }
    .small { display: block; color: #62748a; font-size: 11px; }
    .names { min-width: 240px; }
    .names strong { display: block; }
    .names .en { color: #52677e; }
    .actual { width: 190px; min-height: 36px; font-size: 24px; border: 1px solid #aebfd1; border-radius: 5px; padding: 2px 6px; }
    .actual.match { border-color: #25834a; background: #effaf3; }
    .actual.mismatch { border-color: #ba4a4a; background: #fff5f5; }
    .checks { min-width: 210px; }
    .checks label { display: block; white-space: nowrap; margin: 3px 0; }
    .checks input { margin-right: 5px; }
    .result { min-width: 125px; font-weight: 600; }
    .result.ok { color: #18723b; }
    .result.todo { color: #8a5b00; }
    .gate-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 10px; }
    .gate { padding: 11px 12px; border: 1px solid #d6e0eb; border-radius: 8px; background: #fbfdff; }
    .gate label { display: block; font-weight: 600; }
    .gate input[type="text"] { width: 100%; margin-top: 7px; }
    .gate .small { margin-top: 4px; }
    .export-note { color: #53677d; }
    footer { color: #62748a; font-size: 12px; }
    @media (max-width: 680px) { header { padding: 20px 4vw; } main { width: 96vw; } section, .toolbar { padding: 12px; } }
  </style>
</head>
<body>
  <header>
    <p>历史开发验收页：此页对应已停止的原生面板扩展路线。v1.3.0 独立增强面板请参阅 <a href="PANEL-ACCEPTANCE.md" style="color:inherit">当前验收说明</a>。</p>
    <h1>AppleEmojiSwitcher · Emoji 17.0 原生面板验收</h1>
    <p>计划版本：<span id="planned-version">1.3.0</span>（开发中） · 状态：<span id="lifecycle-status">development-manual-pending</span></p>
    <p>本页只记录你在 Windows 原生 Win＋句号面板中亲自看到、搜索和点击输入的结果。</p>
  </header>
  <main>
    <section class="warning">
      <strong>边界：</strong>这是离线验收工作表，不是表情输入器、复制工具或面板替代品。
      页面不会访问网络、写入剪贴板、请求权限或自动勾选任何观察结果。字体能显示表情、目录中有名称，均不能单独证明原生面板支持。
      当前原生注入控制器和登录激活尚未可用；<code>panel.cmd</code> 命令是后续接入约定，不能据此声称面板已扩展。
    </section>

    <section class="instructions">
      <h2>使用顺序</h2>
      <ol>
        <li>控制器接入后，在仓库目录按需运行 <code>panel.cmd status</code>；准备验收时运行 <code>panel.cmd enable</code>。当前命令仅为待接入约定。</li>
        <li>打开 Windows 原生面板：按 <span class="mono">Win＋.</span>。逐条按分类、中文搜索、英文搜索和点选输入检查。</li>
        <li>点选后，把原生面板实际输入到记事本或 Edge 的字符手动粘贴到对应“实际输入”框。页面只比较完整 Unicode 字符串，不会替你复制。</li>
        <li>只有亲自看到分类或搜索结果时，才勾选对应证据框；未勾选表示没有记录，不等同于“确认不支持”。正式序列和简化序列必须分别记录。</li>
        <li>完成下方整体验收门后，勾选“我确认本报告来自本机原生面板”，再导出 JSON。默认状态永远是待验收。</li>
      </ol>
      <div class="status" id="summary" aria-live="polite"></div>
    </section>

    <div class="toolbar">
      <label for="filter">本地筛选（只缩小本页列表，不代表面板搜索）：</label>
      <input id="filter" type="search" placeholder="中文名、英文名、关键词或 U+ 编码">
      <select id="kind-filter" aria-label="序列类型">
        <option value="all">全部 183 条</option>
        <option value="canonical">正式序列 163 条</option>
        <option value="alias">简化序列 20 条</option>
      </select>
      <button id="export" type="button">导出验收 JSON</button>
      <button id="save" type="button" class="secondary">保存本页记录</button>
    </div>

    <section>
      <h2>逐条面板记录</h2>
      <p class="export-note">“分类可见 / 中文搜索 / 英文搜索”三个框均须人工观察后逐项勾选。实际输入必须与期望序列完全一致；肤色、性别、多人组合和 FE0F 变体不能只看起来相同。</p>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>类型 / 编号</th>
              <th>期望图形 / Unicode</th>
              <th>名称与搜索词</th>
              <th>实际输入（手动粘贴）</th>
              <th>面板观察证据</th>
              <th>精确比较</th>
            </tr>
          </thead>
          <tbody id="rows"></tbody>
        </table>
      </div>
    </section>

    <section>
      <h2>整体验收门</h2>
      <p class="export-note">每一项都需要你在本机完成后再勾选；证据说明栏可写日期、应用窗口或失败原因。空白项目会以 pending 导出。</p>
      <div class="gate-grid" id="gates"></div>
      <label style="display:block;margin-top:14px;font-weight:700">
        <input id="manual-confirmation" type="checkbox">
        我确认本报告中的勾选来自本机 Windows 原生 Win＋句号面板的实际观察
      </label>
    </section>

    <section>
      <h2>停用与卸载命令</h2>
      <p>控制器接入并完成验收后，可按需运行 <code>panel.cmd disable</code> 停用，或运行 <code>panel.cmd uninstall</code> 清理面板扩展及登录项。<code>panel.cmd status</code> 仅查看状态。当前这些命令尚未构成可用控制器；字体安装、原始备份和恢复事务按各自说明处理。</p>
      <p class="export-note">本页记录保存在当前浏览器的本地存储中，键名带有计划版本；不会上传。导出 JSON 由浏览器下载到本地下载目录。</p>
    </section>

    <footer>AppleEmojiSwitcher · 离线验收页生成器版本 <span id="generator-version">1</span> · Emoji 17.0 · 默认不代表通过</footer>
  </main>
  <script>
  "use strict";
  const PAYLOAD = __AES_CATALOG_PAYLOAD__;
  const STORAGE_KEY = "AppleEmojiSwitcher.panel.acceptance.v" + PAYLOAD.plannedVersion;
  const GATES = [
    { id: "notepad", title: "记事本收到准确字符", detail: "在记事本中用 Win＋句号点选至少一条新增正式序列，核对完整序列。" },
    { id: "edge", title: "Edge 收到准确字符", detail: "在 Edge 可编辑区域重复输入，并核对没有被替换、拆分或丢失。" },
    { id: "skinToneMultiPerson", title: "肤色与多人组合", detail: "分别验证肤色职业、性别和多人组合；记录实际输入行。" },
    { id: "hostRestarts10", title: "输入宿主重启至少 10 次", detail: "记录 10 次 TextInputHost 重启后的分类、搜索和点击输入状态。" },
    { id: "legacyImeWinV", title: "旧表情、中文输入法和 Win＋V 回归", detail: "确认旧表情、中文输入法切换和剪贴板历史 Win＋V 仍可用。" },
    { id: "enableDisableUninstall", title: "启用、停用、卸载闭环", detail: "逐项执行 panel.cmd enable / disable / uninstall 并记录结果。" },
    { id: "loginStartup", title: "登录启动", detail: "注销并重新登录后，确认扩展按约定加载；失败时写明原因。" }
  ];
  const rowsById = Object.fromEntries(PAYLOAD.rows.map(row => [row.id, row]));
  let state = { version: PAYLOAD.plannedVersion, rows: {}, gates: {}, manualConfirmation: false };

  function loadState() {
    try {
      const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || "null");
      if (!saved || saved.version !== PAYLOAD.plannedVersion) return;
      state = {
        version: PAYLOAD.plannedVersion,
        rows: saved.rows && typeof saved.rows === "object" ? saved.rows : {},
        gates: saved.gates && typeof saved.gates === "object" ? saved.gates : {},
        manualConfirmation: saved.manualConfirmation === true
      };
    } catch (_) {
      // Local storage is optional.  A private browsing window simply starts blank.
    }
  }

  function saveState(showMessage) {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(state)); }
    catch (_) { /* Export still works when local storage is unavailable. */ }
    if (showMessage) flash(showMessage);
  }

  function flash(message) {
    const summary = document.getElementById("summary");
    const item = document.createElement("span");
    item.textContent = message;
    item.className = "pending";
    summary.appendChild(item);
    setTimeout(() => item.remove(), 2600);
  }

  function escapeHtml(value) {
    return String(value).replace(/[&<>"']/g, character => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[character]));
  }

  function escapeAttribute(value) { return escapeHtml(value).replace(/\r?\n/g, "&#10;"); }

  function rowState(row) {
    const value = state.rows[row.id];
    return {
      actual: value && typeof value.actual === "string" ? value.actual : "",
      category: value && value.category === true,
      zhSearch: value && value.zhSearch === true,
      enSearch: value && value.enSearch === true
    };
  }

  function renderRows() {
    const query = document.getElementById("filter").value.trim().toLocaleLowerCase();
    const kind = document.getElementById("kind-filter").value;
    const target = document.getElementById("rows");
    const visible = PAYLOAD.rows.filter(row => {
      if (kind !== "all" && row.kind !== kind) return false;
      if (!query) return true;
      const haystack = [row.nameZh, row.nameEn, row.group, row.subgroup, row.codepointText, ...row.keywordsZh, ...row.keywordsEn].join(" ").toLocaleLowerCase();
      return haystack.includes(query);
    });
    target.innerHTML = visible.map(row => {
      const current = rowState(row);
      const isAlias = row.kind === "alias";
      const expected = escapeHtml(row.sequence);
      const canonicalText = isAlias ? `对应正式序列 C-${String(row.canonicalIndex).padStart(3, "0")}` : "";
      return `<tr data-row-id="${row.id}">
        <td><span class="kind${isAlias ? " alias" : ""}">${row.kindZh}</span><span class="small mono">${row.id} / ${row.index}</span><span class="small">${canonicalText}</span></td>
        <td><span class="glyph" aria-label="期望表情">${expected}</span><span class="small mono">${escapeHtml(row.codepointText)}</span></td>
        <td class="names"><strong>${escapeHtml(row.nameZh)}</strong><span class="en">${escapeHtml(row.nameEn)}</span><span class="small">${escapeHtml(row.keywordsZh.join("、"))}</span><span class="small">${escapeHtml(row.keywordsEn.join(", "))}</span></td>
        <td><input class="actual${current.actual ? (current.actual === row.sequence ? " match" : " mismatch") : ""}" data-field="actual" aria-label="${row.id} 实际输入" placeholder="手动粘贴" value="${escapeAttribute(current.actual)}"></td>
        <td class="checks">
          <label><input type="checkbox" data-field="category"${current.category ? " checked" : ""}>分类可见</label>
          <label><input type="checkbox" data-field="zhSearch"${current.zhSearch ? " checked" : ""}>中文搜索可见</label>
          <label><input type="checkbox" data-field="enSearch"${current.enSearch ? " checked" : ""}>英文搜索可见</label>
          <span class="small">未勾选＝没有记录，不代表确认不支持</span>
        </td>
        <td class="result ${current.actual === row.sequence ? "ok" : "todo"}">${current.actual ? (current.actual === row.sequence ? "完全一致" : "不一致") : "未输入"}</td>
      </tr>`;
    }).join("");
    updateSummary();
  }

  function renderGates() {
    const target = document.getElementById("gates");
    target.innerHTML = GATES.map(gate => {
      const current = state.gates[gate.id] || {};
      return `<div class="gate"><label><input type="checkbox" data-gate="${gate.id}"${current.checked === true ? " checked" : ""}>${escapeHtml(gate.title)}</label><span class="small">${escapeHtml(gate.detail)}</span><input type="text" data-gate-note="${gate.id}" placeholder="证据说明（可选）" value="${escapeAttribute(typeof current.note === "string" ? current.note : "")}"></div>`;
    }).join("");
    document.getElementById("manual-confirmation").checked = state.manualConfirmation === true;
  }

  function updateSummary() {
    const exact = PAYLOAD.rows.filter(row => rowState(row).actual === row.sequence).length;
    const entered = PAYLOAD.rows.filter(row => rowState(row).actual !== "").length;
    const category = PAYLOAD.rows.filter(row => rowState(row).category).length;
    const zhSearch = PAYLOAD.rows.filter(row => rowState(row).zhSearch).length;
    const enSearch = PAYLOAD.rows.filter(row => rowState(row).enSearch).length;
    const gates = GATES.filter(gate => state.gates[gate.id] && state.gates[gate.id].checked === true).length;
    const final = state.manualConfirmation === true;
    const summary = document.getElementById("summary");
    summary.innerHTML = `<span>目录：${PAYLOAD.canonicalCount} 正式 + ${PAYLOAD.aliasCount} 简化</span><span>实际输入：${entered}/${PAYLOAD.rows.length}，完全一致：${exact}/${PAYLOAD.rows.length}</span><span>分类证据：${category}/${PAYLOAD.rows.length}</span><span>中文搜索：${zhSearch}/${PAYLOAD.rows.length}</span><span>英文搜索：${enSearch}/${PAYLOAD.rows.length}</span><span>整体验收门：${gates}/${GATES.length}</span><span class="pending">${final ? "已作人工确认声明，仍请以导出报告审核" : "待人工验收，默认不代表通过"}</span>`;
  }

  function collectReport() {
    const reportRows = PAYLOAD.rows.map(row => {
      const current = rowState(row);
      return {
        id: row.id,
        kind: row.kind,
        kindZh: row.kindZh,
        index: row.index,
        canonicalIndex: row.canonicalIndex,
        expectedSequence: row.sequence,
        expectedCodepoints: row.codepoints,
        actualSequence: current.actual,
        actualCodepoints: Array.from(current.actual).map(character => character.codePointAt(0)),
        exactMatch: current.actual !== "" && current.actual === row.sequence,
        observationEvidence: {
          categoryVisible: current.category,
          zhSearch: current.zhSearch,
          enSearch: current.enSearch
        }
      };
    });
    const reportGates = Object.fromEntries(GATES.map(gate => {
      const current = state.gates[gate.id] || {};
      return [gate.id, { checked: current.checked === true, note: typeof current.note === "string" ? current.note : "" }];
    }));
    const reasons = [];
    if (!state.manualConfirmation) reasons.push("missing_manual_confirmation");
    if (reportRows.some(row => !row.exactMatch)) reasons.push("some_rows_are_not_exactly_verified");
    if (reportRows.some(row => !Object.values(row.observationEvidence).every(value => value === true))) reasons.push("some_panel_observations_are_pending");
    if (Object.values(reportGates).some(gate => !gate.checked)) reasons.push("some_manual_gates_are_pending");
    return {
      schemaVersion: 1,
      plannedVersion: PAYLOAD.plannedVersion,
      lifecycleStatus: PAYLOAD.lifecycleStatus,
      status: reasons.length === 0 ? "manual-confirmed" : "pending",
      statusReasons: reasons,
      exportedAt: new Date().toISOString(),
      source: { unicodeVersion: PAYLOAD.unicodeVersion, canonicalCount: PAYLOAD.canonicalCount, aliasCount: PAYLOAD.aliasCount, generatorVersion: PAYLOAD.generatorVersion },
      rows: reportRows,
      manualGates: reportGates,
      manualConfirmation: state.manualConfirmation === true,
      notice: "此报告只记录人工在本机原生 Win＋句号面板中的观察；未勾选或未输入的项目不表示已经确认不支持。"
    };
  }

  function exportReport() {
    const report = collectReport();
    const blob = new Blob([JSON.stringify(report, null, 2) + "\n"], { type: "application/json;charset=utf-8" });
    const link = document.createElement("a");
    const stamp = new Date().toISOString().replace(/[.:]/g, "-");
    link.href = URL.createObjectURL(blob);
    link.download = `AppleEmojiSwitcher-PanelAcceptance-${stamp}.json`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(link.href), 1000);
    flash(report.status === "pending" ? "已导出：仍为 pending，未宣称通过" : "已导出：包含人工确认声明");
  }

  document.getElementById("planned-version").textContent = PAYLOAD.plannedVersion + "（手工验收待完成）";
  document.getElementById("lifecycle-status").textContent = PAYLOAD.lifecycleStatus;
  document.getElementById("generator-version").textContent = PAYLOAD.generatorVersion;
  loadState();
  renderGates();
  renderRows();
  document.getElementById("filter").addEventListener("input", renderRows);
  document.getElementById("kind-filter").addEventListener("change", renderRows);
  document.getElementById("export").addEventListener("click", exportReport);
  document.getElementById("save").addEventListener("click", () => { saveState("已保存到当前浏览器本地存储"); updateSummary(); });
  document.getElementById("manual-confirmation").addEventListener("change", event => { state.manualConfirmation = event.target.checked; saveState(false); updateSummary(); });
  document.getElementById("rows").addEventListener("input", event => {
    const rowElement = event.target.closest("tr[data-row-id]");
    if (!rowElement) return;
    const row = rowsById[rowElement.dataset.rowId];
    const current = rowState(row);
    current[event.target.dataset.field] = event.target.type === "checkbox" ? event.target.checked : event.target.value;
    state.rows[row.id] = current;
    if (event.target.dataset.field === "actual") {
      event.target.classList.toggle("match", current.actual !== "" && current.actual === row.sequence);
      event.target.classList.toggle("mismatch", current.actual !== "" && current.actual !== row.sequence);
      const result = rowElement.querySelector(".result");
      result.className = "result " + (current.actual === row.sequence ? "ok" : "todo");
      result.textContent = current.actual ? (current.actual === row.sequence ? "完全一致" : "不一致") : "未输入";
    }
    saveState(false);
    updateSummary();
  });
  document.getElementById("rows").addEventListener("change", event => {
    if (event.target.type !== "checkbox") return;
    const rowElement = event.target.closest("tr[data-row-id]");
    if (!rowElement) return;
    const row = rowsById[rowElement.dataset.rowId];
    const current = rowState(row);
    current[event.target.dataset.field] = event.target.checked;
    state.rows[row.id] = current;
    saveState(false);
    updateSummary();
  });
  document.getElementById("gates").addEventListener("change", event => {
    const gateId = event.target.dataset.gate || event.target.dataset.gateNote;
    if (!gateId) return;
    const current = state.gates[gateId] || {};
    if (event.target.dataset.gate) current.checked = event.target.checked;
    if (event.target.dataset.gateNote) current.note = event.target.value;
    state.gates[gateId] = current;
    saveState(false);
    updateSummary();
  });
  </script>
</body>
</html>
'''


def render_html(catalog: dict[str, Any], rows: list[dict[str, Any]]) -> str:
    return HTML_TEMPLATE.replace("__AES_CATALOG_PAYLOAD__", js_payload(catalog, rows))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true", help="只校验目录并输出 163/20 计数，不写 HTML")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    catalog, rows = load_catalog(args.catalog)
    if args.check:
        print(json.dumps({"canonical": 163, "aliases": 20, "rows": len(rows), "valid": True}, ensure_ascii=False))
        return 0
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render_html(catalog, rows), encoding="utf-8", newline="\n")
    print(json.dumps({"canonical": 163, "aliases": 20, "rows": len(rows), "html": str(output)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AcceptanceCatalogError as exc:
        raise SystemExit(f"错误：{exc}")
