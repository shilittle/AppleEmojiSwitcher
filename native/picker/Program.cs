using System;
using System.Threading;

namespace AesPicker
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            string command = "status";
            bool json = false;
            bool background = false;
            int cleanupParentProcessId = 0;
            string cleanupToken = null;
            int i;

            if (args != null && args.Length > 0 && !args[0].StartsWith("--", StringComparison.Ordinal))
            {
                command = args[0].ToLowerInvariant();
                i = 1;
            }
            else
            {
                i = 0;
            }

            for (; args != null && i < args.Length; i++)
            {
                if (string.Equals(args[i], "--json", StringComparison.OrdinalIgnoreCase))
                {
                    json = true;
                }
                else if (string.Equals(args[i], "--background", StringComparison.OrdinalIgnoreCase))
                {
                    background = true;
                }
                else if (string.Equals(command, "cleanup", StringComparison.OrdinalIgnoreCase) && string.Equals(args[i], "--cleanup-parent", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    i++;
                    if (!int.TryParse(args[i], out cleanupParentProcessId) || cleanupParentProcessId <= 0)
                    {
                        return WriteFailure(command, json, "invalid_argument", "清理进程参数无效。 ");
                    }
                }
                else if (string.Equals(command, "cleanup", StringComparison.OrdinalIgnoreCase) && string.Equals(args[i], "--cleanup-token", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    cleanupToken = args[++i];
                }
                else
                {
                    return WriteFailure(command, json, "invalid_argument", "不支持的参数：" + args[i]);
                }
            }

            if (string.Equals(command, "run", StringComparison.OrdinalIgnoreCase))
            {
                return RunPanel(false, background, json);
            }
            if (string.Equals(command, "show", StringComparison.OrdinalIgnoreCase))
            {
                return RunPanel(true, false, json);
            }
            if (string.Equals(command, "cleanup", StringComparison.OrdinalIgnoreCase))
            {
                ControllerResult cleanup = Lifecycle.CleanupAfterParentExit(cleanupParentProcessId, cleanupToken);
                if (json) { Console.Out.WriteLine(cleanup.ToJson()); }
                return cleanup.Success ? 0 : 1;
            }

            ControllerResult result;
            if (string.Equals(command, "enable", StringComparison.OrdinalIgnoreCase))
            {
                result = Lifecycle.Enable();
            }
            else if (string.Equals(command, "disable", StringComparison.OrdinalIgnoreCase))
            {
                result = Lifecycle.Disable();
            }
            else if (string.Equals(command, "status", StringComparison.OrdinalIgnoreCase))
            {
                result = Lifecycle.Status();
            }
            else if (string.Equals(command, "uninstall", StringComparison.OrdinalIgnoreCase))
            {
                result = Lifecycle.Uninstall();
            }
            else
            {
                return WriteFailure(command, json, "invalid_command", "支持的命令：enable、disable、status、uninstall、run、show。");
            }

            if (json)
            {
                Console.Out.WriteLine(result.ToJson());
            }
            else
            {
                if (result.Success)
                {
                    Console.Out.WriteLine(result.Message);
                }
                else
                {
                    Console.Error.WriteLine(result.Message + "（" + result.FailureReason + "）");
                }
            }
            return result.Success ? 0 : 1;
        }

        private static int RunPanel(bool showImmediately, bool background, bool json)
        {
            try
            {
                if (background)
                {
                    Lifecycle.HideConsoleWindow();
                }

                PanelRuntime runtime = Lifecycle.TryAcquireRuntime();
                if (runtime == null)
                {
                    bool showSignaled = true;
                    if (showImmediately)
                    {
                        showSignaled = Lifecycle.SignalShow();
                    }
                    if (json)
                    {
                        Console.Out.WriteLine(ControllerResult.Create(showSignaled, showImmediately ? "show" : "run", showImmediately ? (showSignaled ? "show_signaled" : "failed") : "already_running", showImmediately ? (showSignaled ? "已请求显示当前会话的面板窗口。" : "面板实例已退出，未显示窗口。") : "面板后台已在当前会话中运行。", Lifecycle.IsInstalled(), Lifecycle.IsEnabled(), showSignaled ? "" : "show_target_exited").ToJson());
                    }
                    else if (showImmediately && !showSignaled)
                    {
                        System.Windows.Forms.MessageBox.Show("面板实例已退出，未显示窗口。", "Apple Emoji Switcher", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Warning);
                    }
                    return showSignaled ? 0 : 1;
                }

                using (runtime)
                {
                    runtime.StopEvent.Reset();
                    runtime.ReadyEvent.Reset();
                    PanelApplication.Run(Lifecycle.GetInstalledDataRootOrCurrent(), runtime.StopEvent, runtime.ReadyEvent, showImmediately);
                }
                return 0;
            }
            catch (Exception ex)
            {
                string reason = Lifecycle.GetFailureReason(ex);
                if (json)
                {
                    Console.Out.WriteLine(ControllerResult.Create(false, showImmediately ? "show" : "run", "failed", "面板后台启动失败。", Lifecycle.IsInstalled(), Lifecycle.IsEnabled(), reason).ToJson());
                }
                else if (!background)
                {
                    if (showImmediately)
                    {
                        System.Windows.Forms.MessageBox.Show("面板无法启动：" + ex.Message, "Apple Emoji Switcher", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Error);
                    }
                    else
                    {
                        Console.Error.WriteLine("面板后台启动失败：" + ex.Message);
                    }
                }
                else
                {
                    Lifecycle.WriteStartupFailureLog(ex);
                }
                return 1;
            }
        }

        private static int WriteFailure(string command, bool json, string reason, string message)
        {
            ControllerResult result = ControllerResult.Create(false, command, "failed", message, Lifecycle.IsInstalled(), Lifecycle.IsEnabled(), reason);
            if (json)
            {
                Console.Out.WriteLine(result.ToJson());
            }
            else
            {
                Console.Error.WriteLine(message);
            }
            return 1;
        }
    }
}
