using System;
using System.Collections.Generic;
using System.IO;
using System.Drawing;
using System.Reflection;
using System.Windows.Forms;
using AesPicker;

namespace AesPicker.Tests
{
    /// <summary>Pure catalog and UTF-16 checks. The build host can compile this with the picker sources and call RunAll.</summary>
    public static class PickerUiTests
    {
        public static void RunAll()
        {
            Utf16SequenceIsLossless();
            SearchUsesAndAcrossChineseEnglishAndCodePoints();
            CategoriesNewestAndRecentWork();
            PickerFormConstructsAndDisposesWithoutHook();
            PickerLayoutAndArrowNavigationFollowVisibleRows();
        }

        private static void Utf16SequenceIsLossless()
        {
            // Woman technologist plus VS16 exercises a surrogate pair, ZWJ, a second pair, and a variation selector.
            string sequence = "\uD83D\uDC69\u200D\uD83D\uDCBB\uFE0F";
            ushort[] units = NativeInput.ToUtf16Units(sequence);
            Equal(sequence.Length, units.Length, "UTF-16 单元数量");
            Equal((ushort)0xD83D, units[0], "首个高代理项");
            Equal((ushort)0xDC69, units[1], "首个低代理项");
            Equal((ushort)0x200D, units[2], "ZWJ");
            Equal((ushort)0xFE0F, units[5], "VS16");
            Equal(sequence, NativeInput.FromUtf16Units(units), "代理对/ZWJ/变体选择符往返");
        }

        private static void SearchUsesAndAcrossChineseEnglishAndCodePoints()
        {
            Catalog catalog = SampleCatalog();
            Equal(1, catalog.Search("女 technologist", "全部", null).Count, "中英文多个词 AND");
            Equal(1, catalog.Search("U+1F469 1F4BB", "全部", null).Count, "U+ 码位 AND");
            Equal(0, catalog.Search("女 飞机", "全部", null).Count, "不相交关键词应为空");
            Equal(0, catalog.Search("女 airplane", "全部", null).Count, "不同条目不能拼接满足 AND");
        }

        private static void CategoriesNewestAndRecentWork()
        {
            Catalog catalog = SampleCatalog();
            Equal("17.0", catalog.LatestVersion, "最新版本");
            Equal(2, catalog.Search("", "最新", null).Count, "最新分类");
            Equal(1, catalog.Search("", "人物", null).Count, "中文分组");
            IList<CatalogEntry> recent = catalog.Search("", "最近", new string[] { "plane", "woman-tech" });
            Equal(2, recent.Count, "最近分类数");
            Equal("plane", recent[0].Id, "最近顺序");
        }

        private static Catalog SampleCatalog()
        {
            return Catalog.FromLines(new string[] {
                "woman-tech\t\uD83D\uDC69\u200D\uD83D\uDCBB\uFE0F\t女程序员\twoman technologist\t人物\t17.0\t女 技术 程序员 developer\tapple",
                "plane\t\u2708\uFE0F\t飞机\tairplane\t旅行\t16.0\t飞行 travel\tnoto",
                "face\t\uD83E\uDEE9\t黑眼圈脸\tface with bags under eyes\t笑脸\t17.0\t脸 tired\tapple"
            });
        }

        private static void PickerFormConstructsAndDisposesWithoutHook()
        {
            PickerForm form = null;
            try
            {
                form = new PickerForm(SampleCatalog(), Path.GetTempPath(), null);
                form.CreateControl();
            }
            finally
            {
                if (form != null) form.Dispose();
            }
        }

        private static void Equal<T>(T expected, T actual, string name)
        {
            if (!Object.Equals(expected, actual)) throw new InvalidOperationException(name + "：期望 " + expected + "，实际 " + actual);
        }

        private static void PickerLayoutAndArrowNavigationFollowVisibleRows()
        {
            List<string> rows = new List<string>();
            for (int i = 0; i < 30; i++) rows.Add("item" + i + "\tA\t测试条目\ttest entry\t人物\t18.0\tkeyword\tapple");
            BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
            using (PickerForm form = new PickerForm(Catalog.FromLines(rows), Path.GetTempPath(), null))
            {
                NotifyIcon tray = (NotifyIcon)typeof(PickerForm).GetField("_tray", flags).GetValue(form);
                try
                {
                    tray.Visible = false;
                    form.StartPosition = FormStartPosition.Manual;
                    form.Location = new Point(-20000, -20000);
                    form.ShowInTaskbar = false;
                    form.Show();
                    foreach (int width in new int[] { 610, 640, 710, 790 })
                    {
                        form.Size = new Size(width, 420);
                        typeof(PickerForm).GetMethod("RebuildGrid", flags).Invoke(form, null);
                        form.PerformLayout();
                        Application.DoEvents();
                        FlowLayoutPanel grid = (FlowLayoutPanel)typeof(PickerForm).GetField("_grid", flags).GetValue(form);
                        Control first = grid.Controls[0];
                        typeof(PickerForm).GetMethod("PickerKeyDown", flags).Invoke(form, new object[] { form, new KeyEventArgs(Keys.Down) });
                        int selected = (int)typeof(PickerForm).GetField("_selectedIndex", flags).GetValue(form);
                        Control below = grid.Controls[selected];
                        Equal(first.Left, below.Left, "下方向键保持同一列");
                        if (below.Top <= first.Top) throw new InvalidOperationException("下方向键未移到下一行");
                        foreach (string field in new string[] { "_copy", "_native", "_previousPage", "_nextPage", "_details" })
                        {
                            Control control = (Control)typeof(PickerForm).GetField(field, flags).GetValue(form);
                            Rectangle bounds = form.RectangleToClient(control.RectangleToScreen(control.ClientRectangle));
                            if (!form.ClientRectangle.Contains(bounds)) throw new InvalidOperationException("最小窗口裁切控件：" + field);
                        }
                        Label details = (Label)typeof(PickerForm).GetField("_details", flags).GetValue(form);
                        if (details.Width < grid.Width - 10 || String.IsNullOrEmpty(details.AccessibleDescription))
                            throw new InvalidOperationException("选中项详情没有完整行或可访问描述");
                    }
                }
                finally { tray.Dispose(); form.Hide(); }
            }
        }
    }
}
