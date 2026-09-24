using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace AesPicker
{
    /// <summary>One UTF-8 catalog.tsv row.  Sequence is intentionally kept as a .NET string without normalization.</summary>
    public sealed class CatalogEntry
    {
        public CatalogEntry(string id, string sequence, string nameZh, string nameEn,
            string groupZh, string version, string keywords, string previewKind)
        {
            Id = id ?? String.Empty;
            Sequence = sequence ?? String.Empty;
            NameZh = nameZh ?? String.Empty;
            NameEn = nameEn ?? String.Empty;
            GroupZh = groupZh ?? String.Empty;
            Version = version ?? String.Empty;
            Keywords = keywords ?? String.Empty;
            PreviewKind = previewKind ?? String.Empty;
            SearchIndex = BuildSearchIndex();
            CodePoints = BuildCodePoints(Sequence);
        }

        public string Id { get; private set; }
        public string Sequence { get; private set; }
        public string NameZh { get; private set; }
        public string NameEn { get; private set; }
        public string GroupZh { get; private set; }
        public string Version { get; private set; }
        public string Keywords { get; private set; }
        public string PreviewKind { get; private set; }
        public string CodePoints { get; private set; }
        internal string SearchIndex { get; private set; }

        public string DisplayName
        {
            get
            {
                if (!String.IsNullOrEmpty(NameZh) && !String.IsNullOrEmpty(NameEn)) return NameZh + " / " + NameEn;
                if (!String.IsNullOrEmpty(NameZh)) return NameZh;
                if (!String.IsNullOrEmpty(NameEn)) return NameEn;
                return Id;
            }
        }

        private string BuildSearchIndex()
        {
            return Catalog.Fold(Id + " " + Sequence + " " + NameZh + " " + NameEn + " " +
                GroupZh + " " + Version + " " + Keywords + " " + BuildCodePoints(Sequence));
        }

        internal static string BuildCodePoints(string value)
        {
            if (String.IsNullOrEmpty(value)) return String.Empty;
            StringBuilder result = new StringBuilder();
            for (int i = 0; i < value.Length; i++)
            {
                int codePoint;
                if (Char.IsHighSurrogate(value[i]) && i + 1 < value.Length && Char.IsLowSurrogate(value[i + 1]))
                {
                    codePoint = Char.ConvertToUtf32(value[i], value[i + 1]);
                    i++;
                }
                else
                {
                    codePoint = value[i];
                }
                if (result.Length > 0) result.Append(' ');
                result.Append("U+");
                result.Append(codePoint.ToString("X"));
            }
            return result.ToString();
        }
    }

    /// <summary>Loads and searches the tab-separated, UTF-8 catalog supplied with the panel package.</summary>
    public sealed class Catalog
    {
        private readonly List<CatalogEntry> _entries;
        private readonly Dictionary<string, CatalogEntry> _byId;
        private readonly List<string> _groups;
        private readonly string _latestVersion;

        private Catalog(List<CatalogEntry> entries)
        {
            _entries = entries;
            _byId = new Dictionary<string, CatalogEntry>(StringComparer.Ordinal);
            _groups = new List<string>();
            foreach (CatalogEntry entry in entries)
            {
                _byId.Add(entry.Id, entry);
                if (!String.IsNullOrEmpty(entry.GroupZh) && !_groups.Contains(entry.GroupZh)) _groups.Add(entry.GroupZh);
            }
            _latestVersion = FindLatestVersion(entries);
        }

        public IList<CatalogEntry> Entries { get { return _entries.AsReadOnly(); } }
        public IList<string> Groups { get { return _groups.AsReadOnly(); } }
        public string LatestVersion { get { return _latestVersion; } }

        public static Catalog Load(string dataRoot)
        {
            if (String.IsNullOrEmpty(dataRoot)) throw new ArgumentException("缺少面板数据目录。", "dataRoot");
            string path = Path.Combine(dataRoot, "catalog.tsv");
            if (!File.Exists(path)) throw new FileNotFoundException("未找到表情目录 catalog.tsv。", path);
            List<string> lines = new List<string>();
            using (StreamReader reader = new StreamReader(path, new UTF8Encoding(false, true), true))
            {
                string line;
                while ((line = reader.ReadLine()) != null) lines.Add(line);
            }
            return FromLines(lines);
        }

        public static Catalog FromLines(IEnumerable<string> lines)
        {
            if (lines == null) throw new ArgumentNullException("lines");
            List<CatalogEntry> entries = new List<CatalogEntry>();
            HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
            int lineNumber = 0;
            foreach (string raw in lines)
            {
                lineNumber++;
                if (String.IsNullOrEmpty(raw)) continue;
                string[] values = raw.Split('\t');
                if (values.Length != 8) throw new InvalidDataException("catalog.tsv 第 " + lineNumber + " 行必须包含 8 列。");
                for (int i = 0; i < values.Length; i++)
                {
                    if (values[i].IndexOf('\0') >= 0) throw new InvalidDataException("catalog.tsv 第 " + lineNumber + " 行包含无效字符。");
                }
                if (String.IsNullOrEmpty(values[0]) || String.IsNullOrEmpty(values[1]))
                {
                    throw new InvalidDataException("catalog.tsv 第 " + lineNumber + " 行缺少 id 或 Unicode 序列。");
                }
                if (!seen.Add(values[0])) throw new InvalidDataException("catalog.tsv 存在重复 id：" + values[0]);
                entries.Add(new CatalogEntry(values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7]));
            }
            if (entries.Count == 0) throw new InvalidDataException("catalog.tsv 没有可用表情条目。");
            return new Catalog(entries);
        }

        /// <summary>
        /// Multiple query words are an AND query.  It searches Chinese and English labels, keywords,
        /// literal emoji, ids, and U+ / bare hexadecimal code points.  category accepts 全部, 最新,
        /// 最近, or an exact Chinese group name.
        /// </summary>
        public IList<CatalogEntry> Search(string query, string category, IEnumerable<string> recentIds)
        {
            List<string> terms = SplitTerms(query);
            bool recentOnly = String.Equals(category, "最近", StringComparison.Ordinal);
            List<CatalogEntry> candidates = new List<CatalogEntry>();
            if (recentOnly)
            {
                if (recentIds != null)
                {
                    HashSet<string> added = new HashSet<string>(StringComparer.Ordinal);
                    foreach (string id in recentIds)
                    {
                        CatalogEntry entry;
                        if (id != null && added.Add(id) && _byId.TryGetValue(id, out entry)) candidates.Add(entry);
                    }
                }
            }
            else
            {
                candidates.AddRange(_entries);
            }

            List<CatalogEntry> result = new List<CatalogEntry>();
            foreach (CatalogEntry entry in candidates)
            {
                if (!MatchesCategory(entry, category, recentOnly)) continue;
                bool matches = true;
                foreach (string term in terms)
                {
                    if (entry.SearchIndex.IndexOf(term, StringComparison.Ordinal) < 0)
                    {
                        matches = false;
                        break;
                    }
                }
                if (matches) result.Add(entry);
            }
            return result;
        }

        private bool MatchesCategory(CatalogEntry entry, string category, bool recentOnly)
        {
            if (recentOnly || String.IsNullOrEmpty(category) || category == "全部" || category == "All") return true;
            if (category == "最新") return String.Equals(entry.Version, _latestVersion, StringComparison.Ordinal);
            return String.Equals(entry.GroupZh, category, StringComparison.Ordinal);
        }

        private static List<string> SplitTerms(string query)
        {
            List<string> terms = new List<string>();
            if (String.IsNullOrEmpty(query)) return terms;
            StringBuilder current = new StringBuilder();
            string folded = Fold(query);
            for (int i = 0; i < folded.Length; i++)
            {
                char c = folded[i];
                if (Char.IsWhiteSpace(c) || c == ',' || c == '，' || c == ';' || c == '；')
                {
                    AddTerm(terms, current);
                }
                else
                {
                    current.Append(c);
                }
            }
            AddTerm(terms, current);
            return terms;
        }

        private static void AddTerm(List<string> terms, StringBuilder value)
        {
            if (value.Length == 0) return;
            string term = value.ToString();
            value.Length = 0;
            if (term.StartsWith("u+", StringComparison.Ordinal)) term = term.Substring(2);
            if (term.Length > 0) terms.Add(term);
        }

        internal static string Fold(string value)
        {
            return (value ?? String.Empty).ToLowerInvariant();
        }

        private static string FindLatestVersion(IEnumerable<CatalogEntry> entries)
        {
            string latest = String.Empty;
            foreach (CatalogEntry entry in entries)
            {
                if (CompareVersions(entry.Version, latest) > 0) latest = entry.Version;
            }
            return latest;
        }

        private static int CompareVersions(string left, string right)
        {
            if (String.IsNullOrEmpty(left)) return String.IsNullOrEmpty(right) ? 0 : -1;
            if (String.IsNullOrEmpty(right)) return 1;
            string[] a = left.Split('.');
            string[] b = right.Split('.');
            int length = Math.Max(a.Length, b.Length);
            for (int i = 0; i < length; i++)
            {
                int av = i < a.Length ? ParseVersionPart(a[i]) : 0;
                int bv = i < b.Length ? ParseVersionPart(b[i]) : 0;
                if (av != bv) return av.CompareTo(bv);
            }
            return String.Compare(left, right, StringComparison.Ordinal);
        }

        private static int ParseVersionPart(string value)
        {
            int number = 0;
            bool found = false;
            foreach (char c in value)
            {
                if (c < '0' || c > '9') break;
                found = true;
                if (number <= 214748364) number = number * 10 + (c - '0');
            }
            return found ? number : 0;
        }
    }

    /// <summary>Entry point consumed by the lifecycle host.  It owns the message loop but not installation or persistence.</summary>
    public static class PanelApplication
    {
        public static void Run(string dataRoot, EventWaitHandle stopEvent, EventWaitHandle readyEvent, bool showImmediately)
        {
            if (readyEvent == null) throw new ArgumentNullException("readyEvent");
            Catalog catalog = Catalog.Load(dataRoot);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            using (PickerForm form = new PickerForm(catalog, dataRoot, stopEvent))
            using (KeyboardInterceptor hook = new KeyboardInterceptor())
            {
                form.AttachHook(hook);
                IntPtr ignored = form.Handle; // Create the handle before hook callbacks can request BeginInvoke.
                form.StartStopWatch();
                if (showImmediately) form.QueueShow(NativeInput.CaptureForegroundWindow());
                readyEvent.Set(); // Catalog and keyboard hook both succeeded.
                Application.Run(new ApplicationContext(form));
            }
        }
    }

    internal sealed class PickerForm : Form
    {
        private const int TileWidth = 106;
        private const int TileHeight = 94;
        private const int TilesPerPage = 240;
        private readonly Catalog _catalog;
        private readonly string _dataRoot;
        private readonly EventWaitHandle _stopEvent;
        private readonly TextBox _search;
        private readonly FlowLayoutPanel _categories;
        private readonly FlowLayoutPanel _grid;
        private readonly ToolTip _toolTip;
        private readonly Label _notice;
        private readonly Label _details;
        private readonly FlowLayoutPanel _commands;
        private readonly Button _copy;
        private readonly Button _native;
        private readonly Button _previousPage;
        private readonly Button _nextPage;
        private readonly NotifyIcon _tray;
        private readonly List<string> _recentIds = new List<string>();
        private readonly List<EmojiTileButton> _tiles = new List<EmojiTileButton>();
        private readonly System.Windows.Forms.Timer _releaseTimer;
        private readonly System.Windows.Forms.Timer _stopTimer;
        private readonly System.Windows.Forms.Timer _showTimer;
        private readonly EventWaitHandle _showEvent;
        private string _category = "全部";
        private int _selectedIndex = -1;
        private int _page;
        private IntPtr _targetWindow = IntPtr.Zero;
        private uint _targetProcessId;
        private IntPtr _pendingTarget = IntPtr.Zero;
        private uint _pendingTargetProcessId;
        private bool _exitRequested;
        private bool _controlsInitialized;
        private bool _copyStyleKnown;
        private bool _copyStyleEnabled;

        internal PickerForm(Catalog catalog, string dataRoot, EventWaitHandle stopEvent)
        {
            _catalog = catalog;
            _dataRoot = dataRoot;
            _stopEvent = stopEvent;
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
            Text = "Apple Emoji Switcher · 最新 Emoji";
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(610, 420);
            Size = new Size(790, 610);
            KeyPreview = true;
            ShowInTaskbar = false;
            Font = new Font("Microsoft YaHei UI", 9F);
            BackColor = PickerTheme.Surface;
            ForeColor = PickerTheme.Text;

            TableLayoutPanel layout = new TableLayoutPanel();
            layout.Dock = DockStyle.Fill;
            layout.Padding = new Padding(12, 10, 12, 10);
            layout.ColumnCount = 1;
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            layout.RowCount = 6;
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            Controls.Add(layout);

            TableLayoutPanel header = new TableLayoutPanel();
            header.AutoSize = true;
            header.Dock = DockStyle.Fill;
            header.ColumnCount = 2;
            header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            header.Margin = new Padding(0, 0, 0, 6);
            Label title = new Label();
            title.AutoSize = true;
            title.Text = "表情面板";
            title.Font = new Font("Microsoft YaHei UI", 11.5f, FontStyle.Bold);
            title.ForeColor = PickerTheme.Text;
            Label hints = new Label();
            hints.AutoSize = true;
            hints.Text = "Enter 输入 · Ctrl+C 复制 · Esc 收起";
            hints.ForeColor = PickerTheme.TextMuted;
            hints.Anchor = AnchorStyles.Right | AnchorStyles.Bottom;
            hints.Margin = new Padding(12, 0, 0, 3);
            header.Controls.Add(title, 0, 0);
            header.Controls.Add(hints, 1, 0);
            layout.Controls.Add(header, 0, 0);

            Panel searchBox = new Panel();
            searchBox.AutoSize = true;
            searchBox.Dock = DockStyle.Fill;
            searchBox.BackColor = PickerTheme.SurfaceRaised;
            searchBox.BorderStyle = BorderStyle.FixedSingle;
            searchBox.Padding = new Padding(8, 5, 8, 5);
            searchBox.Margin = new Padding(0, 0, 0, 8);
            _search = new TextBox();
            _search.Dock = DockStyle.Top;
            _search.BorderStyle = BorderStyle.None;
            _search.BackColor = PickerTheme.SurfaceRaised;
            _search.ForeColor = PickerTheme.Text;
            _search.Font = new Font("Microsoft YaHei UI", 11.0f);
            _search.PlaceholderTextCompat("搜索中文、英文、关键词或码位（多个词同时匹配）");
            _search.TextChanged += delegate { _page = 0; RebuildGrid(); };
            searchBox.Controls.Add(_search);
            layout.Controls.Add(searchBox, 0, 1);

            _categories = new FlowLayoutPanel();
            _categories.AutoSize = true;
            _categories.WrapContents = true;
            _categories.Dock = DockStyle.Top;
            _categories.Padding = new Padding(0, 2, 0, 0);
            _categories.Margin = new Padding(0, 0, 0, 6);
            layout.Controls.Add(_categories, 0, 2);
            BuildCategories();

            _notice = new Label();
            _notice.AutoSize = true;
            _notice.MaximumSize = new Size(740, 0);
            _notice.ForeColor = PickerTheme.TextMuted;
            _notice.Padding = new Padding(2, 0, 2, 2);
            _notice.Text = "输入后如显示为方框，说明目标应用当前字体未覆盖该表情。";
            layout.Controls.Add(_notice, 0, 3);

            _grid = new FlowLayoutPanel();
            _grid.Dock = DockStyle.Fill;
            _grid.AutoScroll = true;
            _grid.WrapContents = true;
            _grid.Padding = new Padding(6);
            _grid.BorderStyle = BorderStyle.FixedSingle;
            _grid.BackColor = PickerTheme.SurfaceRaised;
            _grid.Margin = new Padding(0, 2, 0, 2);
            _grid.Resize += delegate { RefreshSelection(); };
            layout.Controls.Add(_grid, 0, 4);

            TableLayoutPanel footer = new TableLayoutPanel();
            footer.AutoSize = true;
            footer.Dock = DockStyle.Fill;
            footer.ColumnCount = 1;
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            footer.RowCount = 2;
            footer.RowStyles.Add(new RowStyle(SizeType.Absolute, 26));
            footer.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            footer.Margin = new Padding(0, 6, 0, 0);

            _details = new Label();
            _details.AutoSize = false;
            _details.AutoEllipsis = true;
            _details.Dock = DockStyle.Fill;
            _details.Name = "selectionDetails";
            _details.ForeColor = PickerTheme.TextMuted;
            _details.Margin = new Padding(2, 2, 2, 2);
            footer.Controls.Add(_details, 0, 0);

            _commands = new FlowLayoutPanel();
            _commands.AutoSize = true;
            _commands.Dock = DockStyle.Fill;
            _commands.WrapContents = false;
            _commands.FlowDirection = FlowDirection.RightToLeft;
            _commands.Margin = new Padding(0);
            Button close = new Button();
            close.Text = "关闭 (Esc)";
            close.AutoSize = true;
            PickerTheme.StyleCommandButton(close);
            close.Click += delegate { HidePanel(); };
            _commands.Controls.Add(close);
            _native = new Button();
            _native.Text = "返回原生面板";
            _native.AutoSize = true;
            PickerTheme.StyleCommandButton(_native);
            _native.Click += delegate { ReturnToNativePanel(); };
            _commands.Controls.Add(_native);
            _nextPage = new Button();
            _nextPage.Text = "下一页";
            _nextPage.AutoSize = true;
            PickerTheme.StyleCommandButton(_nextPage);
            _nextPage.Click += delegate { _page++; RebuildGrid(); };
            _commands.Controls.Add(_nextPage);
            _previousPage = new Button();
            _previousPage.Text = "上一页";
            _previousPage.AutoSize = true;
            PickerTheme.StyleCommandButton(_previousPage);
            _previousPage.Click += delegate { if (_page > 0) { _page--; RebuildGrid(); } };
            _commands.Controls.Add(_previousPage);
            _copy = new Button();
            _copy.Text = "复制";
            _copy.AutoSize = true;
            PickerTheme.StylePrimaryButton(_copy, false);
            _copy.Click += delegate { CopySelected(); };
            _commands.Controls.Add(_copy);
            footer.Controls.Add(_commands, 0, 1);
            layout.Controls.Add(footer, 0, 5);
            layout.SizeChanged += delegate
            {
                int contentWidth = Math.Max(300, layout.ClientSize.Width - layout.Padding.Horizontal - 8);
                _categories.MaximumSize = new Size(contentWidth, 0);
                _notice.MaximumSize = new Size(contentWidth, 0);
            };

            _toolTip = new ToolTip();
            _releaseTimer = new System.Windows.Forms.Timer();
            _releaseTimer.Interval = 20;
            _releaseTimer.Tick += ReleaseTimerTick;
            _stopTimer = new System.Windows.Forms.Timer();
            _stopTimer.Interval = 250;
            _stopTimer.Tick += StopTimerTick;
            _showEvent = Lifecycle.TryOpenShowEvent();
            _showTimer = new System.Windows.Forms.Timer();
            _showTimer.Interval = 120;
            _showTimer.Tick += ShowTimerTick;
            _tray = CreateTrayIcon();
            FormClosing += FormClosingHandler;
            KeyDown += PickerKeyDown;
            _controlsInitialized = true;
            RebuildGrid();
        }

        internal void AttachHook(KeyboardInterceptor hook)
        {
            hook.HotkeyPressed += HookHotkeyPressed;
        }

        internal void StartStopWatch()
        {
            if (_stopEvent != null) _stopTimer.Start();
            if (_showEvent != null) _showTimer.Start();
        }

        internal void QueueShow(IntPtr target)
        {
            if (IsDisposed) return;
            if (InvokeRequired)
            {
                BeginInvoke(new Action<IntPtr>(QueueShow), target);
                return;
            }
            _pendingTarget = IntPtr.Zero;
            _pendingTargetProcessId = 0;
            if (target != IntPtr.Zero && target != Handle)
            {
                uint processId = NativeInput.GetWindowProcessId(target);
                if (processId != 0)
                {
                    _pendingTarget = target;
                    _pendingTargetProcessId = processId;
                }
            }
            _releaseTimer.Start();
        }

        private void HookHotkeyPressed(object sender, HotkeyPressedEventArgs e)
        {
            QueueShow(e.TargetWindow);
        }

        private void ReleaseTimerTick(object sender, EventArgs e)
        {
            if (NativeInput.AreWindowsKeysDown()) return;
            _releaseTimer.Stop();
            if (_pendingTarget != IntPtr.Zero && _pendingTargetProcessId != 0)
            {
                _targetWindow = _pendingTarget;
                _targetProcessId = _pendingTargetProcessId;
            }
            else
            {
                _targetWindow = IntPtr.Zero;
                _targetProcessId = 0;
            }
            _pendingTarget = IntPtr.Zero;
            _pendingTargetProcessId = 0;
            ShowPanel();
        }

        private void StopTimerTick(object sender, EventArgs e)
        {
            if (_stopEvent != null && _stopEvent.WaitOne(0))
            {
                _exitRequested = true;
                Close();
            }
        }

        private void ShowTimerTick(object sender, EventArgs e)
        {
            if (_showEvent != null && _showEvent.WaitOne(0)) QueueShow(NativeInput.CaptureForegroundWindow());
        }

        private void ShowPanel()
        {
            ShowInTaskbar = true;
            if (!Visible) Show();
            Activate();
            _search.Focus();
            _search.SelectAll();
            RefreshSelection();
        }

        private void HidePanel()
        {
            _releaseTimer.Stop();
            Hide();
            ShowInTaskbar = false;
        }

        private void BuildCategories()
        {
            AddCategory("全部");
            AddCategory("最新");
            AddCategory("最近");
            foreach (string group in _catalog.Groups) AddCategory(group);
        }

        private void AddCategory(string name)
        {
            Button button = new Button();
            button.Text = name;
            button.AutoSize = true;
            button.Tag = name;
            button.Margin = new Padding(0, 0, 6, 4);
            PickerTheme.StyleCategoryButton(button, String.Equals(name, _category, StringComparison.Ordinal));
            button.Click += delegate(object sender, EventArgs args)
            {
                _category = (string)((Button)sender).Tag;
                _page = 0;
                RebuildGrid();
            };
            _categories.Controls.Add(button);
        }

        private void RebuildGrid()
        {
            if (!_controlsInitialized || _grid == null || _search == null || _toolTip == null ||
                _notice == null || _previousPage == null || _nextPage == null) return;
            _tiles.Clear();
            _grid.SuspendLayout();
            try
            {
                while (_grid.Controls.Count > 0)
                {
                    Control old = _grid.Controls[0];
                    _grid.Controls.RemoveAt(0);
                    old.Dispose();
                }
                IList<CatalogEntry> entries = _catalog.Search(_search.Text, _category, _recentIds);
                int pageCount = Math.Max(1, (entries.Count + TilesPerPage - 1) / TilesPerPage);
                if (_page >= pageCount) _page = pageCount - 1;
                int start = _page * TilesPerPage;
                int end = Math.Min(entries.Count, start + TilesPerPage);
                for (int entryIndex = start; entryIndex < end; entryIndex++)
                {
                    CatalogEntry entry = entries[entryIndex];
                    EmojiTileButton tile = new EmojiTileButton(entry, LoadPreview(entry));
                    tile.Click += TileClick;
                    tile.Enter += TileEnter;
                    _toolTip.SetToolTip(tile, entry.DisplayName + "\r\n" + entry.CodePoints);
                    _tiles.Add(tile);
                    _grid.Controls.Add(tile);
                }
                _selectedIndex = _tiles.Count == 0 ? -1 : 0;
                if (_tiles.Count == 0)
                {
                    string query = _search.Text.Trim();
                    if (String.Equals(_category, "最近", StringComparison.Ordinal) && query.Length == 0)
                        _notice.Text = "还没有最近输入过的表情；输入任意表情后会出现在这里。";
                    else if (query.Length > 0)
                        _notice.Text = "没有找到匹配的表情。可减少关键词，或切换到「全部」分类。";
                    else
                        _notice.Text = "这个分类暂时没有可显示的表情。";
                }
                else
                {
                    _notice.Text = "共 " + entries.Count + " 个表情 · 第 " + (_page + 1) + "/" + pageCount + " 页";
                }
                _previousPage.Enabled = _page > 0;
                _nextPage.Enabled = _page + 1 < pageCount;
            }
            finally
            {
                _grid.ResumeLayout();
            }
            UpdateCategoryButtons();
            RefreshSelection();
        }

        private Image LoadPreview(CatalogEntry entry)
        {
            string path = Path.Combine(_dataRoot, "images", entry.Id + ".png");
            if (!File.Exists(path)) return null;
            try
            {
                using (Image image = Image.FromFile(path)) return new Bitmap(image);
            }
            catch (Exception)
            {
                return null;
            }
        }

        private void UpdateCategoryButtons()
        {
            foreach (Control control in _categories.Controls)
            {
                Button button = control as Button;
                if (button == null) continue;
                bool selected = String.Equals((string)button.Tag, _category, StringComparison.Ordinal);
                PickerTheme.StyleCategoryButton(button, selected);
            }
        }

        private void TileClick(object sender, EventArgs e)
        {
            EmojiTileButton tile = sender as EmojiTileButton;
            if (tile == null) return;
            _selectedIndex = _tiles.IndexOf(tile);
            RefreshSelection();
            InsertSelected();
        }

        private void TileEnter(object sender, EventArgs e)
        {
            EmojiTileButton tile = sender as EmojiTileButton;
            if (tile != null) { _selectedIndex = _tiles.IndexOf(tile); RefreshSelection(); }
        }

        private CatalogEntry SelectedEntry
        {
            get { return _selectedIndex >= 0 && _selectedIndex < _tiles.Count ? _tiles[_selectedIndex].Entry : null; }
        }

        private void InsertSelected()
        {
            CatalogEntry entry = SelectedEntry;
            if (entry == null) return;
            string reason;
            bool inserted;
            HidePanel();
            inserted = NativeInput.TryInsertUnicode(_targetWindow, _targetProcessId, entry.Sequence, out reason);
            if (inserted)
            {
                AddRecent(entry.Id);
                return;
            }
            ShowPanel();
            _notice.Text = reason.IndexOf("可能已部分输入", StringComparison.Ordinal) >= 0
                ? "输入未完成：" + reason
                : "未输入：" + reason + " 可点击“复制”后手动粘贴。";
        }

        private void AddRecent(string id)
        {
            _recentIds.Remove(id);
            _recentIds.Insert(0, id);
            if (_recentIds.Count > 36) _recentIds.RemoveAt(_recentIds.Count - 1);
        }

        private void CopySelected()
        {
            CatalogEntry entry = SelectedEntry;
            if (entry == null) return;
            try
            {
                Clipboard.SetText(entry.Sequence, TextDataFormat.UnicodeText);
                _notice.Text = "已复制 " + entry.DisplayName + "。";
            }
            catch (ExternalException)
            {
                _notice.Text = "剪贴板当前被占用；请稍后再试。";
            }
        }

        private void ReturnToNativePanel()
        {
            HidePanel();
            BeginInvoke(new MethodInvoker(delegate
            {
                string reason;
                bool opened;
                bool uncertain;
                opened = NativeInput.OpenNativePanel(_targetWindow, _targetProcessId, out reason, out uncertain);
                if (!opened)
                {
                    if (uncertain)
                    {
                        _tray.ShowBalloonTip(4000, "原生面板", reason, ToolTipIcon.Warning);
                        return;
                    }
                    ShowPanel();
                    _notice.Text = "未能打开原生面板：" + reason;
                }
            }));
        }

        private void PickerKeyDown(object sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                e.SuppressKeyPress = true;
                HidePanel();
                return;
            }
            if (e.KeyCode == Keys.Enter && SelectedEntry != null)
            {
                e.SuppressKeyPress = true;
                InsertSelected();
                return;
            }
            if (e.Control && e.KeyCode == Keys.C && SelectedEntry != null)
            {
                e.SuppressKeyPress = true;
                CopySelected();
                return;
            }
            int offset = 0;
            if (e.KeyCode == Keys.Left) offset = -1;
            else if (e.KeyCode == Keys.Right) offset = 1;
            else if (e.KeyCode == Keys.Up) offset = -ColumnsPerRow();
            else if (e.KeyCode == Keys.Down) offset = ColumnsPerRow();
            if (offset != 0 && _tiles.Count > 0)
            {
                e.SuppressKeyPress = true;
                _selectedIndex = Math.Max(0, Math.Min(_tiles.Count - 1, _selectedIndex + offset));
                RefreshSelection();
            }
        }

        private int ColumnsPerRow()
        {
            if (_tiles.Count == 0) return 1;
            int firstTop = _tiles[0].Top;
            int columns = 1;
            while (columns < _tiles.Count && _tiles[columns].Top == firstTop) columns++;
            return columns;
        }

        private void UpdateCopyStyle()
        {
            if (_copyStyleKnown && _copyStyleEnabled == _copy.Enabled) return;
            _copyStyleKnown = true;
            _copyStyleEnabled = _copy.Enabled;
            PickerTheme.StylePrimaryButton(_copy, _copy.Enabled);
        }

        private void RefreshSelection()
        {
            if (!_controlsInitialized || _copy == null || _native == null || _details == null || _grid == null) return;
            for (int i = 0; i < _tiles.Count; i++) _tiles[i].Selected = i == _selectedIndex;
            CatalogEntry entry = SelectedEntry;
            _copy.Enabled = entry != null;
            UpdateCopyStyle();
            _native.Enabled = _targetWindow != IntPtr.Zero;
            if (entry == null)
            {
                _details.Text = "方向键选择 · Enter 输入 · Ctrl+C 复制 · Esc 收起";
            }
            else
            {
                EmojiTileButton tile = _tiles[_selectedIndex];
                string source = PreviewSourceLabel(entry.PreviewKind);
                _details.Text = "已选择：" + entry.DisplayName;
                string description = entry.CodePoints + "  ·  图案来源：" + source +
                    (tile.HasPngPreview ? "。目标字体缺字时可能显示为方框。" : "。此项预览暂缺，已使用当前字体显示。");
                _toolTip.SetToolTip(_details, entry.DisplayName + "\r\n" + description);
                _details.AccessibleDescription = description;
            }
            if (entry == null) { _toolTip.SetToolTip(_details, null); _details.AccessibleDescription = String.Empty; }
            if (entry != null && _grid.VerticalScroll.Visible) _grid.ScrollControlIntoView(_tiles[_selectedIndex]);
        }

        private static string PreviewSourceLabel(string previewKind)
        {
            if (String.Equals(previewKind, "apple", StringComparison.OrdinalIgnoreCase)) return "Apple Emoji";
            if (String.Equals(previewKind, "noto", StringComparison.OrdinalIgnoreCase)) return "Noto Color Emoji";
            return String.IsNullOrEmpty(previewKind) ? "未知" : previewKind;
        }

        private NotifyIcon CreateTrayIcon()
        {
            ContextMenuStrip menu = new ContextMenuStrip();
            ToolStripMenuItem show = new ToolStripMenuItem("显示表情面板");
            show.Click += delegate { QueueShow(NativeInput.CaptureForegroundWindow()); };
            ToolStripMenuItem native = new ToolStripMenuItem("返回原生面板");
            native.Click += delegate { ReturnToNativePanel(); };
            ToolStripMenuItem exit = new ToolStripMenuItem("退出");
            exit.Click += delegate { _exitRequested = true; Close(); };
            menu.Items.Add(show);
            menu.Items.Add(native);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(exit);
            NotifyIcon tray = new NotifyIcon();
            tray.Text = "Apple Emoji Switcher";
            tray.Icon = SystemIcons.Information;
            tray.Visible = true;
            tray.ContextMenuStrip = menu;
            tray.DoubleClick += delegate { QueueShow(NativeInput.CaptureForegroundWindow()); };
            return tray;
        }

        private void FormClosingHandler(object sender, FormClosingEventArgs e)
        {
            if (!_exitRequested && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                HidePanel();
                return;
            }
            _releaseTimer.Stop();
            _stopTimer.Stop();
            _showTimer.Stop();
            _tray.Visible = false;
            _tray.Dispose();
            if (_showEvent != null) _showEvent.Dispose();
        }
    }

    /// <summary>Calm light-neutral palette (blue #2563EB accent) shared by the picker chrome. Presentation only.</summary>
    internal static class PickerTheme
    {
        internal static readonly Color Accent = Color.FromArgb(37, 99, 235);
        internal static readonly Color AccentHover = Color.FromArgb(29, 78, 216);
        internal static readonly Color AccentSoft = Color.FromArgb(232, 240, 254);
        internal static readonly Color AccentSoftHover = Color.FromArgb(219, 232, 253);
        internal static readonly Color Surface = Color.FromArgb(245, 246, 248);
        internal static readonly Color SurfaceRaised = Color.White;
        internal static readonly Color SurfaceMuted = Color.FromArgb(236, 238, 241);
        internal static readonly Color SurfaceMutedHover = Color.FromArgb(226, 230, 236);
        internal static readonly Color Border = Color.FromArgb(211, 216, 224);
        internal static readonly Color Text = Color.FromArgb(31, 41, 55);
        internal static readonly Color TextMuted = Color.FromArgb(95, 105, 120);

        internal static void StyleCategoryButton(Button button, bool selected)
        {
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderSize = 0;
            button.Padding = new Padding(10, 3, 10, 3);
            if (selected)
            {
                button.BackColor = Accent;
                button.ForeColor = Color.White;
                button.FlatAppearance.MouseOverBackColor = AccentHover;
                button.FlatAppearance.MouseDownBackColor = AccentHover;
            }
            else
            {
                button.BackColor = SurfaceMuted;
                button.ForeColor = Text;
                button.FlatAppearance.MouseOverBackColor = SurfaceMutedHover;
                button.FlatAppearance.MouseDownBackColor = AccentSoft;
            }
        }

        internal static void StyleCommandButton(Button button)
        {
            button.FlatStyle = FlatStyle.Flat;
            button.BackColor = SurfaceRaised;
            button.ForeColor = Text;
            button.FlatAppearance.BorderColor = Border;
            button.FlatAppearance.BorderSize = 1;
            button.FlatAppearance.MouseOverBackColor = AccentSoft;
            button.FlatAppearance.MouseDownBackColor = AccentSoftHover;
            button.Padding = new Padding(10, 3, 10, 3);
        }

        internal static void StylePrimaryButton(Button button, bool enabled)
        {
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderSize = 1;
            button.Padding = new Padding(12, 3, 12, 3);
            if (enabled)
            {
                button.BackColor = Accent;
                button.ForeColor = Color.White;
                button.FlatAppearance.BorderColor = Accent;
                button.FlatAppearance.MouseOverBackColor = AccentHover;
                button.FlatAppearance.MouseDownBackColor = AccentHover;
            }
            else
            {
                // Disabled flat buttons are drawn with GrayText, so keep a quiet neutral surface for contrast.
                button.BackColor = SurfaceMuted;
                button.ForeColor = TextMuted;
                button.FlatAppearance.BorderColor = Border;
                button.FlatAppearance.MouseOverBackColor = SurfaceMuted;
                button.FlatAppearance.MouseDownBackColor = SurfaceMuted;
            }
        }
    }

    internal sealed class EmojiTileButton : Button
    {
        private static readonly Font PreviewFont = new Font("Microsoft YaHei UI", 8.5f, FontStyle.Regular);
        private static readonly Font SequenceFont = new Font("Segoe UI Emoji", 22.0f, FontStyle.Regular);
        private readonly Image _preview;
        private bool _selected;

        internal EmojiTileButton(CatalogEntry entry, Image preview)
        {
            Entry = entry;
            _preview = preview;
            Size = new Size(106, 94);
            Margin = new Padding(3);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 1;
            TextImageRelation = TextImageRelation.ImageAboveText;
            ImageAlign = ContentAlignment.MiddleCenter;
            TextAlign = ContentAlignment.BottomCenter;
            Font = preview == null ? SequenceFont : PreviewFont;
            if (preview != null)
            {
                Image = preview;
                string label = String.IsNullOrEmpty(entry.NameZh) ? entry.NameEn : entry.NameZh;
                Text = label.Length > 8 ? label.Substring(0, 7) + "…" : label;
            }
            else
            {
                Text = entry.Sequence;
            }
            ApplyState(false);
            AccessibleName = entry.DisplayName;
        }

        internal CatalogEntry Entry { get; private set; }
        internal bool HasPngPreview { get { return _preview != null; } }
        internal bool Selected
        {
            get { return _selected; }
            set
            {
                if (_selected == value) return;
                _selected = value;
                ApplyState(value);
            }
        }

        private void ApplyState(bool selected)
        {
            if (selected)
            {
                BackColor = PickerTheme.AccentSoft;
                FlatAppearance.BorderColor = PickerTheme.Accent;
                FlatAppearance.BorderSize = 2;
                FlatAppearance.MouseOverBackColor = PickerTheme.AccentSoft;
                FlatAppearance.MouseDownBackColor = PickerTheme.AccentSoftHover;
            }
            else
            {
                BackColor = PickerTheme.SurfaceRaised;
                FlatAppearance.BorderColor = PickerTheme.Border;
                FlatAppearance.BorderSize = 1;
                FlatAppearance.MouseOverBackColor = PickerTheme.AccentSoft;
                FlatAppearance.MouseDownBackColor = PickerTheme.AccentSoftHover;
            }
            ForeColor = PickerTheme.Text;
            Invalidate();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && _preview != null) _preview.Dispose();
            base.Dispose(disposing);
        }

    }

    internal static class TextBoxCompatibilityExtensions
    {
        // PlaceholderText was introduced after the .NET Framework WinForms target.  A cue banner has no effect on search semantics.
        internal static void PlaceholderTextCompat(this TextBox textBox, string value)
        {
            NativeInput.SetCueBanner(textBox.Handle, value);
        }
    }
}
