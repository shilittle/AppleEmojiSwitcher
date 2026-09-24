// Local integration target. Records only text typed into this test window.
using System;
using System.IO;
using System.Text;
using System.Windows.Forms;
using System.Drawing;

internal static class PickerInputTarget
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (args.Length > 1) throw new ArgumentException("Expected at most one output path");
        string output = args.Length == 1 ? Path.GetFullPath(args[0]) : Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "input-result.txt");
        Application.EnableVisualStyles();
        Form form = new Form { Text = "Emoji input verification", Width = 800, Height = 380 };
        TextBox field = new TextBox { Multiline = true, Dock = DockStyle.Fill, Font = new Font("Segoe UI Emoji", 28), AccessibleName = "Emoji test input" };
        Label info = new Label { Dock = DockStyle.Bottom, Height = 50, Text = "Only this test input is recorded. Close when validation is complete.", AutoSize = false };
        field.TextChanged += delegate { File.WriteAllText(output, field.Text, new UTF8Encoding(false)); };
        form.Controls.Add(field);
        form.Controls.Add(info);
        form.Shown += delegate { field.Focus(); };
        Application.Run(form);
    }
}
