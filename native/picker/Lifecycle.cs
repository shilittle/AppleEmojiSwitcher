using Microsoft.Win32;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.Principal;
using System.Text;
using System.Threading;

namespace AesPicker
{
    internal sealed class ControllerResult
    {
        internal bool Success;
        internal string Command;
        internal string State;
        internal string Message;
        internal string ManualAcceptance;
        internal bool Installed;
        internal bool Enabled;
        internal bool Running;
        internal bool Ready;
        internal bool StartupRegistered;
        internal int InjectedCount;
        internal string FailureReason;

        internal static ControllerResult Create(bool success, string command, string state, string message, bool installed, bool enabled, string failureReason)
        {
            ControllerResult result = new ControllerResult();
            result.Success = success;
            result.Command = command;
            result.State = state;
            result.Message = message;
            result.ManualAcceptance = "pending";
            result.Installed = installed;
            result.Enabled = enabled;
            result.Running = false;
            result.Ready = false;
            result.StartupRegistered = enabled;
            result.InjectedCount = 0;
            result.FailureReason = failureReason ?? string.Empty;
            return result;
        }

        internal string ToJson()
        {
            return "{\"success\":" + JsonBoolean(Success)
                + ",\"command\":\"" + JsonString(Command) + "\""
                + ",\"state\":\"" + JsonString(State) + "\""
                + ",\"message\":\"" + JsonString(Message) + "\""
                + ",\"manualAcceptance\":\"" + JsonString(ManualAcceptance) + "\""
                + ",\"installed\":" + JsonBoolean(Installed)
                + ",\"enabled\":" + JsonBoolean(Enabled)
                + ",\"running\":" + JsonBoolean(Running)
                + ",\"ready\":" + JsonBoolean(Ready)
                + ",\"startupRegistered\":" + JsonBoolean(StartupRegistered)
                + ",\"injectedCount\":0"
                + ",\"failureReason\":\"" + JsonString(FailureReason) + "\"}";
        }

        private static string JsonBoolean(bool value)
        {
            return value ? "true" : "false";
        }

        private static string JsonString(string value)
        {
            if (value == null)
            {
                return string.Empty;
            }

            StringBuilder builder = new StringBuilder(value.Length + 16);
            int i;
            for (i = 0; i < value.Length; i++)
            {
                char c = value[i];
                switch (c)
                {
                    case '\\': builder.Append("\\\\"); break;
                    case '\"': builder.Append("\\\""); break;
                    case '\b': builder.Append("\\b"); break;
                    case '\f': builder.Append("\\f"); break;
                    case '\n': builder.Append("\\n"); break;
                    case '\r': builder.Append("\\r"); break;
                    case '\t': builder.Append("\\t"); break;
                    default:
                        // Keep the machine protocol independent of the caller's
                        // OEM/ANSI/UTF-8 code page, including PowerShell redirects.
                        if (c < 0x20 || c > 0x7e)
                        {
                            builder.Append("\\u");
                            builder.Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            builder.Append(c);
                        }
                        break;
                }
            }
            return builder.ToString();
        }
    }

    internal sealed class LifecycleException : Exception
    {
        internal readonly string Reason;

        internal LifecycleException(string reason, string message)
            : base(message)
        {
            Reason = reason;
        }
    }

    internal sealed class PanelRuntime : IDisposable
    {
        internal readonly Mutex InstanceMutex;
        internal readonly EventWaitHandle StopEvent;
        internal readonly EventWaitHandle ReadyEvent;
        internal readonly EventWaitHandle ShowEvent;

        internal PanelRuntime(Mutex instanceMutex, EventWaitHandle stopEvent, EventWaitHandle readyEvent, EventWaitHandle showEvent)
        {
            InstanceMutex = instanceMutex;
            StopEvent = stopEvent;
            ReadyEvent = readyEvent;
            ShowEvent = showEvent;
        }

        public void Dispose()
        {
            try { InstanceMutex.ReleaseMutex(); } catch (ApplicationException) { }
            StopEvent.Close();
            ReadyEvent.Close();
            ShowEvent.Close();
            InstanceMutex.Close();
        }
    }

    internal static class Lifecycle
    {
        private const string ProductDirectoryName = "AppleEmojiSwitcher";
        private const string PanelDirectoryName = "panel";
        private const string ControllerFileName = "PanelController.exe";
        private const string CatalogRelativePath = "picker-data\\catalog.tsv";
        private const string ImagesRelativePath = "picker-data\\images";
        private const string ManifestFileName = "install-manifest.txt";
        private const string RunValueName = "AppleEmojiSwitcher.PanelController";
        private const string UninstallPendingPrefix = "# uninstall-pending:";
        private static readonly string[] OptionalMetadataFiles = new string[] {
            "picker-data\\LICENSE.txt", "picker-data\\NOTO-LICENSE.txt",
            "picker-data\\sources.json", "picker-data\\preview-report.json"
        };
        private const int StopWaitMilliseconds = 8000;
        private const int ReadyWaitMilliseconds = 8000;

        internal static ControllerResult Enable()
        {
            try
            {
                using (AcquireOperationLock())
                {
                    string installRoot = GetInstallRoot();
                    EnsureNoReparsePoints(installRoot);
                    ThrowIfUninstallPending(installRoot);

                    string sourceRoot = GetApplicationBaseDirectory();
                    List<string> sourceFiles = GetSourcePayload(sourceRoot);
                    bool stopped = StopPanelAndWait(GetWaitMilliseconds(StopWaitMilliseconds));
                    if (!stopped)
                    {
                        return Result(false, "enable", "failed", "已有面板后台未在限定时间内停止，未覆盖文件。", "stop_timeout");
                    }

                    if (!PathsEqual(sourceRoot, installRoot))
                    {
                        InstallPayload(sourceRoot, installRoot, sourceFiles);
                    }
                    else
                    {
                        ValidateInstalledPayload(installRoot);
                    }

                    SetStartupRegistration();
                    if (!StartPanelAndWaitForReady())
                    {
                        RemoveOwnedStartupRegistration();
                        return Result(false, "enable", "failed", "面板后台没有在限定时间内就绪，已撤销登录启动项。", "startup_not_ready");
                    }

                    return Result(true, "enable", "enabled", "面板增强已安装并在当前会话启动；仍需完成人工验收。", string.Empty);
                }
            }
            catch (Exception ex)
            {
                return Result(false, "enable", "failed", "无法启用面板增强：" + ex.Message, GetFailureReason(ex));
            }
        }

        internal static ControllerResult Disable()
        {
            try
            {
                using (AcquireOperationLock())
                {
                    RemoveOwnedStartupRegistration();
                    if (!StopPanelAndWait(GetWaitMilliseconds(StopWaitMilliseconds)))
                    {
                        return Result(false, "disable", "failed", "登录启动项已移除，但面板后台没有在限定时间内停止。", "stop_timeout");
                    }
                    return Result(true, "disable", "disabled", "面板增强已停用，当前用户的登录启动项已移除。", string.Empty);
                }
            }
            catch (Exception ex)
            {
                return Result(false, "disable", "failed", "无法停用面板增强：" + ex.Message, GetFailureReason(ex));
            }
        }

        internal static ControllerResult Status()
        {
            try
            {
                bool installed = IsInstalled();
                bool enabled = IsEnabled();
                bool running = IsPanelRunning();
                bool ready = IsPanelReady();
                bool uninstallPending = HasAnyUninstallPending(GetInstallRoot());
                string state;
                string message;
                if (uninstallPending)
                {
                    state = "uninstall_pending";
                    message = "卸载清理仍在等待或需要重试；在此之前不会启动面板。";
                }
                else if (running)
                {
                    state = ready ? "running" : "starting";
                    message = ready
                        ? (installed ? "面板增强正在当前会话中运行；仍需完成人工验收。" : "便携面板正在当前会话中运行，尚未安装登录启动项。")
                        : "面板进程已获得会话锁，但尚未报告就绪。";
                }
                else if (!installed)
                {
                    state = "uninstalled";
                    message = "面板增强尚未安装。";
                }
                else if (!enabled)
                {
                    state = "disabled";
                    message = "面板增强已安装但未启用。";
                }
                else
                {
                    state = "enabled";
                    message = "面板增强已启用，将在当前用户下次登录时启动。";
                }
                ControllerResult result = ControllerResult.Create(true, "status", state, message, installed, enabled, string.Empty);
                result.Running = running;
                result.Ready = ready;
                result.StartupRegistered = enabled;
                return result;
            }
            catch (Exception ex)
            {
                return Result(false, "status", "failed", "无法读取面板状态：" + ex.Message, GetFailureReason(ex));
            }
        }

        internal static ControllerResult Uninstall()
        {
            try
            {
                using (AcquireOperationLock())
                {
                    ControllerResult disabled = Disable();
                    if (!disabled.Success)
                    {
                        return ControllerResult.Create(false, "uninstall", "failed", "面板后台尚未停止，未删除安装文件。", IsInstalled(), IsEnabled(), disabled.FailureReason);
                    }

                    string installRoot = GetInstallRoot();
                    string manifestPath = CombineUnder(installRoot, ManifestFileName);
                    if (!File.Exists(manifestPath))
                    {
                        if (!File.Exists(CombineUnder(installRoot, ControllerFileName)))
                        {
                            return ControllerResult.Create(true, "uninstall", "uninstalled", "面板增强已卸载。", false, false, string.Empty);
                        }
                        return Result(false, "uninstall", "failed", "找不到安装清单，为保护非本工具文件未执行删除。", "manifest_missing");
                    }

                    List<string> files = ReadManifest(installRoot);
                    files.Add(ManifestFileName);
                    string currentController = Path.Combine(GetApplicationBaseDirectory(), ControllerFileName);
                    string installedController = CombineUnder(installRoot, ControllerFileName);
                    if (PathsEqual(currentController, installedController))
                    {
                        ScheduleSelfCleanup(installRoot);
                        return ControllerResult.Create(true, "uninstall", "uninstall_scheduled", "面板增强已停用，安装文件将在控制器退出后清理。", true, false, string.Empty);
                    }

                    DeleteManifestOwnedFiles(installRoot, files);
                    return ControllerResult.Create(true, "uninstall", "uninstalled", "面板增强已卸载；未列入清单的用户数据已保留。", false, false, string.Empty);
                }
            }
            catch (Exception ex)
            {
                return Result(false, "uninstall", "failed", "无法卸载面板增强：" + ex.Message, GetFailureReason(ex));
            }
        }

        internal static bool IsInstalled()
        {
            try
            {
                string root = GetInstallRoot();
                return File.Exists(CombineUnder(root, ControllerFileName)) && File.Exists(CombineUnder(root, CatalogRelativePath));
            }
            catch
            {
                return false;
            }
        }

        internal static bool IsEnabled()
        {
            try
            {
                RegistryKey key = Registry.CurrentUser.OpenSubKey(GetRunRegistryPath(), false);
                if (key == null)
                {
                    return false;
                }
                using (key)
                {
                    object value = key.GetValue(RunValueName, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                    string text = value as string;
                    return string.Equals(text, GetStartupCommand(), StringComparison.OrdinalIgnoreCase);
                }
            }
            catch
            {
                return false;
            }
        }

        internal static ControllerResult CleanupAfterParentExit(int parentProcessId, string token)
        {
            try
            {
                if (parentProcessId <= 0 || string.IsNullOrEmpty(token) || token.Length != 32)
                {
                    return Result(false, "cleanup", "failed", "内部清理参数无效。", "invalid_cleanup_request");
                }
                WaitForParentExit(parentProcessId);
                using (AcquireOperationLock())
                {
                    string installRoot = GetInstallRoot();
                    if (!HasUninstallPendingToken(installRoot, token))
                    {
                        return Result(false, "cleanup", "failed", "卸载清理标记不匹配，未删除文件。", "cleanup_token_mismatch");
                    }
                    List<string> files = ReadManifest(installRoot);
                    files.Add(ManifestFileName);
                    DeleteManifestOwnedFiles(installRoot, files);
                    return ControllerResult.Create(true, "cleanup", "uninstalled", "面板安装文件已清理。", false, false, string.Empty);
                }
            }
            catch (Exception ex)
            {
                try { RecordUninstallFailure(ex); } catch { }
                return Result(false, "cleanup", "failed", "内部清理失败：" + ex.Message, GetFailureReason(ex));
            }
        }

        internal static string GetInstalledDataRootOrCurrent()
        {
            string current = CombineUnder(GetApplicationBaseDirectory(), "picker-data");
            if (File.Exists(CombineUnder(current, "catalog.tsv")))
            {
                return current;
            }
            string installed = GetInstallRoot();
            if (File.Exists(CombineUnder(installed, CatalogRelativePath)))
            {
                return CombineUnder(installed, "picker-data");
            }
            return CombineUnder(GetApplicationBaseDirectory(), "picker-data");
        }

        internal static PanelRuntime TryAcquireRuntime()
        {
            string mutexName = GetObjectName("instance");
            Mutex mutex = new Mutex(false, mutexName);
            bool acquired = false;
            try
            {
                try { acquired = mutex.WaitOne(0); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired)
                {
                    mutex.Close();
                    return null;
                }
                EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.ManualReset, GetObjectName("stop"));
                EventWaitHandle ready = new EventWaitHandle(false, EventResetMode.ManualReset, GetObjectName("ready"));
                EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset, GetObjectName("show"));
                return new PanelRuntime(mutex, stop, ready, show);
            }
            catch
            {
                if (acquired) { try { mutex.ReleaseMutex(); } catch (ApplicationException) { } }
                mutex.Close();
                throw;
            }
        }

        internal static void HideConsoleWindow()
        {
            IntPtr console = LifecycleNativeMethods.GetConsoleWindow();
            if (console != IntPtr.Zero)
            {
                LifecycleNativeMethods.ShowWindow(console, 0);
            }
        }

        internal static void WriteStartupFailureLog(Exception exception)
        {
            try
            {
                string root = GetInstallRoot();
                string userData = CombineUnder(root, "user-data");
                EnsureDirectorySafe(userData);
                string log = CombineUnder(userData, "startup-errors.log");
                if (File.Exists(log) && (File.GetAttributes(log) & FileAttributes.ReparsePoint) != 0)
                {
                    return;
                }
                string line = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + " " + GetFailureReason(exception) + " " + exception.Message + Environment.NewLine;
                File.AppendAllText(log, line, new UTF8Encoding(false));
            }
            catch
            {
                // A background process must not turn a diagnostic write failure
                // into a second startup failure or touch an arbitrary location.
            }
        }

        // The UI opens this current-user/current-session AutoReset event and
        // consumes it on its UI thread.  The method returns null only when the
        // run process disappeared before the UI was initialized.
        internal static EventWaitHandle TryOpenShowEvent()
        {
            try
            {
                return EventWaitHandle.OpenExisting(GetObjectName("show"));
            }
            catch (WaitHandleCannotBeOpenedException)
            {
                return null;
            }
        }

        internal static bool SignalShow()
        {
            try
            {
                EventWaitHandle show = EventWaitHandle.OpenExisting(GetObjectName("show"));
                using (show)
                {
                    show.Set();
                }
                return true;
            }
            catch (WaitHandleCannotBeOpenedException)
            {
                // A just-exited foreground instance is indistinguishable from
                // no instance.  Report it so `show` does not claim success.
                return false;
            }
        }

        internal static string GetFailureReason(Exception ex)
        {
            LifecycleException lifecycle = ex as LifecycleException;
            if (lifecycle != null)
            {
                return lifecycle.Reason;
            }
            if (ex is UnauthorizedAccessException)
            {
                return "access_denied";
            }
            if (ex is IOException)
            {
                return "io_failure";
            }
            return "unexpected_error";
        }

        private static int GetWaitMilliseconds(int productionDefault)
        {
            if (!IsLifecycleTestMode())
            {
                return productionDefault;
            }
            int configured;
            string raw = Environment.GetEnvironmentVariable("AES_PICKER_TEST_WAIT_MS");
            if (int.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out configured) && configured >= 250 && configured <= productionDefault)
            {
                return configured;
            }
            return productionDefault;
        }

        private static ControllerResult Result(bool success, string command, string state, string message, string reason)
        {
            ControllerResult result = ControllerResult.Create(success, command, state, message, IsInstalled(), IsEnabled(), reason);
            result.Running = IsPanelRunning();
            result.Ready = result.Running && IsPanelReady();
            return result;
        }

        private static string GetApplicationBaseDirectory()
        {
            return Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        }

        private static string GetLocalAppData()
        {
            string root = Environment.GetEnvironmentVariable("LOCALAPPDATA");
            if (string.IsNullOrEmpty(root))
            {
                root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            }
            if (string.IsNullOrEmpty(root))
            {
                throw new LifecycleException("localappdata_unavailable", "无法确定 LOCALAPPDATA。 ");
            }
            return Path.GetFullPath(root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        }

        private static string GetManagedBaseRoot()
        {
            return CombineUnder(GetLocalAppData(), ProductDirectoryName);
        }

        private static string GetInstallRoot()
        {
            return CombineUnder(GetManagedBaseRoot(), PanelDirectoryName);
        }

        private static string GetRunRegistryPath()
        {
            if (IsLifecycleTestMode())
            {
                string testPath = Environment.GetEnvironmentVariable("AES_PICKER_TEST_REGISTRY_PATH");
                if (string.IsNullOrEmpty(testPath))
                {
                    testPath = "Software\\AppleEmojiSwitcher\\Tests\\PanelController";
                }
                if (!testPath.StartsWith("Software\\AppleEmojiSwitcher\\Tests\\", StringComparison.OrdinalIgnoreCase))
                {
                    throw new LifecycleException("invalid_test_registry_path", "测试注册表路径必须位于 AppleEmojiSwitcher\\Tests。 ");
                }
                return testPath;
            }
            return "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
        }

        private static bool IsLifecycleTestMode()
        {
            return string.Equals(Environment.GetEnvironmentVariable("AES_PICKER_TEST_MODE"), "1", StringComparison.Ordinal);
        }

        private static string GetStartupCommand()
        {
            return QuoteForCommandLine(CombineUnder(GetInstallRoot(), ControllerFileName)) + " run --background";
        }

        private static void SetStartupRegistration()
        {
            RegistryKey key = Registry.CurrentUser.CreateSubKey(GetRunRegistryPath());
            if (key == null)
            {
                throw new LifecycleException("registry_unavailable", "无法创建当前用户的登录启动项。 ");
            }
            using (key)
            {
                key.SetValue(RunValueName, GetStartupCommand(), RegistryValueKind.String);
            }
        }

        private static void RemoveOwnedStartupRegistration()
        {
            RegistryKey key = Registry.CurrentUser.OpenSubKey(GetRunRegistryPath(), true);
            if (key == null)
            {
                return;
            }
            using (key)
            {
                object value = key.GetValue(RunValueName, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                string text = value as string;
                if (string.Equals(text, GetStartupCommand(), StringComparison.OrdinalIgnoreCase))
                {
                    key.DeleteValue(RunValueName, false);
                }
            }
        }

        private static string QuoteForCommandLine(string path)
        {
            return "\"" + path.Replace("\"", "\\\"") + "\"";
        }

        private static List<string> GetSourcePayload(string sourceRoot)
        {
            EnsureNoReparsePoints(sourceRoot);
            string controller = CombineUnder(sourceRoot, ControllerFileName);
            string catalog = CombineUnder(sourceRoot, CatalogRelativePath);
            string images = CombineUnder(sourceRoot, ImagesRelativePath);
            if (!File.Exists(controller))
            {
                throw new LifecycleException("source_controller_missing", "便携包缺少 PanelController.exe。 ");
            }
            if (!File.Exists(catalog))
            {
                throw new LifecycleException("source_catalog_missing", "便携包缺少 picker-data\\catalog.tsv。 ");
            }
            if (!Directory.Exists(images))
            {
                throw new LifecycleException("source_images_missing", "便携包缺少 picker-data\\images 目录。 ");
            }

            List<string> result = new List<string>();
            result.Add(ControllerFileName);
            result.Add(CatalogRelativePath);
            AddOptionalMetadataFiles(sourceRoot, result);
            AddImageFiles(sourceRoot, images, result);
            return result;
        }

        private static void AddOptionalMetadataFiles(string sourceRoot, List<string> files)
        {
            int i;
            for (i = 0; i < OptionalMetadataFiles.Length; i++)
            {
                string relative = OptionalMetadataFiles[i];
                string file = CombineUnder(sourceRoot, relative);
                if (!File.Exists(file))
                {
                    continue;
                }
                if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0)
                {
                    throw new LifecycleException("unsafe_reparse_path", "拒绝复制重解析点元数据文件。 ");
                }
                files.Add(relative);
            }
        }

        private static void AddImageFiles(string sourceRoot, string directory, List<string> files)
        {
            EnsureNoReparsePoints(directory);
            string[] names = Directory.GetFiles(directory);
            int i;
            for (i = 0; i < names.Length; i++)
            {
                FileInfo info = new FileInfo(names[i]);
                if ((info.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    throw new LifecycleException("unsafe_reparse_path", "拒绝复制重解析点文件。 ");
                }
                string relative = MakeRelativePath(sourceRoot, info.FullName);
                if (!IsManifestEntryAllowed(relative))
                {
                    throw new LifecycleException("invalid_source_file", "数据目录含有不允许的文件路径。 ");
                }
                files.Add(relative);
            }

            string[] children = Directory.GetDirectories(directory);
            for (i = 0; i < children.Length; i++)
            {
                DirectoryInfo child = new DirectoryInfo(children[i]);
                if ((child.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    throw new LifecycleException("unsafe_reparse_path", "拒绝复制重解析点目录。 ");
                }
                AddImageFiles(sourceRoot, child.FullName, files);
            }
        }

        private static void InstallPayload(string sourceRoot, string installRoot, List<string> sourceFiles)
        {
            string baseRoot = GetManagedBaseRoot();
            EnsureDirectorySafe(baseRoot);
            EnsureNoReparsePoints(installRoot);
            string staging = CombineUnder(baseRoot, "panel.staging-" + Guid.NewGuid().ToString("N"));
            try
            {
                EnsureDirectorySafe(staging);
                int i;
                for (i = 0; i < sourceFiles.Count; i++)
                {
                    string relative = sourceFiles[i];
                    CopyFileSafe(CombineUnder(sourceRoot, relative), CombineUnder(staging, relative));
                }

                List<string> previous = ReadManifestIfPresent(installRoot);
                List<string> tracked = MergeManifestEntries(previous, sourceFiles);
                EnsureDirectorySafe(installRoot);
                WriteManifest(installRoot, tracked);

                for (i = 0; i < sourceFiles.Count; i++)
                {
                    string relative = sourceFiles[i];
                    CopyFileSafe(CombineUnder(staging, relative), CombineUnder(installRoot, relative));
                }

                DeleteEntriesNotInNewPayload(installRoot, previous, sourceFiles);
                WriteManifest(installRoot, sourceFiles);
            }
            finally
            {
                DeleteStagingDirectory(staging);
            }
        }

        private static void ValidateInstalledPayload(string installRoot)
        {
            EnsureNoReparsePoints(installRoot);
            if (!File.Exists(CombineUnder(installRoot, ControllerFileName)) || !File.Exists(CombineUnder(installRoot, CatalogRelativePath)))
            {
                throw new LifecycleException("installed_payload_invalid", "已安装的面板文件不完整。 ");
            }
        }

        private static void CopyFileSafe(string source, string destination)
        {
            EnsureNoReparsePoints(source);
            string parent = Path.GetDirectoryName(destination);
            EnsureDirectorySafe(parent);
            if (File.Exists(destination) && (File.GetAttributes(destination) & FileAttributes.ReparsePoint) != 0)
            {
                throw new LifecycleException("unsafe_reparse_path", "拒绝覆盖重解析点文件。 ");
            }
            File.Copy(source, destination, true);
        }

        private static List<string> ReadManifestIfPresent(string installRoot)
        {
            string manifest = CombineUnder(installRoot, ManifestFileName);
            if (!File.Exists(manifest))
            {
                return new List<string>();
            }
            return ReadManifest(installRoot);
        }

        private static List<string> ReadManifest(string installRoot)
        {
            string manifest = CombineUnder(installRoot, ManifestFileName);
            EnsureNoReparsePoints(manifest);
            string[] lines = File.ReadAllLines(manifest, new UTF8Encoding(false));
            List<string> result = new List<string>();
            int i;
            for (i = 0; i < lines.Length; i++)
            {
                string entry = lines[i].Trim();
                if (entry.Length == 0 || entry.StartsWith("#", StringComparison.Ordinal))
                {
                    continue;
                }
                if (!IsManifestEntryAllowed(entry))
                {
                    throw new LifecycleException("invalid_manifest", "安装清单含有不允许的路径，已停止清理。 ");
                }
                if (!result.Contains(entry))
                {
                    result.Add(entry);
                }
            }
            return result;
        }

        private static void WriteManifest(string installRoot, IList<string> files)
        {
            string manifest = CombineUnder(installRoot, ManifestFileName);
            if (File.Exists(manifest) && (File.GetAttributes(manifest) & FileAttributes.ReparsePoint) != 0)
            {
                throw new LifecycleException("unsafe_reparse_path", "拒绝覆盖重解析点安装清单。 ");
            }
            StringBuilder contents = new StringBuilder();
            contents.AppendLine("# AppleEmojiSwitcher PanelController manifest v1");
            int i;
            for (i = 0; i < files.Count; i++)
            {
                if (!IsManifestEntryAllowed(files[i]))
                {
                    throw new LifecycleException("invalid_manifest", "安装清单含有不允许的路径。 ");
                }
                contents.AppendLine(files[i]);
            }
            File.WriteAllText(manifest, contents.ToString(), new UTF8Encoding(false));
        }

        private static List<string> MergeManifestEntries(IList<string> first, IList<string> second)
        {
            List<string> result = new List<string>();
            int i;
            for (i = 0; i < first.Count; i++)
            {
                if (!result.Contains(first[i])) { result.Add(first[i]); }
            }
            for (i = 0; i < second.Count; i++)
            {
                if (!result.Contains(second[i])) { result.Add(second[i]); }
            }
            return result;
        }

        private static void DeleteEntriesNotInNewPayload(string installRoot, IList<string> previous, IList<string> current)
        {
            int i;
            for (i = 0; i < previous.Count; i++)
            {
                if (!current.Contains(previous[i]))
                {
                    DeleteOneManifestOwnedFile(installRoot, previous[i]);
                }
            }
        }

        private static void DeleteManifestOwnedFiles(string installRoot, IList<string> files)
        {
            int i;
            for (i = 0; i < files.Count; i++)
            {
                DeleteOneManifestOwnedFile(installRoot, files[i]);
            }
            TryRemoveEmptyDirectories(installRoot);
        }

        private static void DeleteOneManifestOwnedFile(string installRoot, string relative)
        {
            if (!IsManifestEntryAllowed(relative) && !string.Equals(relative, ManifestFileName, StringComparison.OrdinalIgnoreCase))
            {
                throw new LifecycleException("invalid_manifest", "拒绝删除未清单允许的路径。 ");
            }
            string file = CombineUnder(installRoot, relative);
            if (!File.Exists(file))
            {
                return;
            }
            if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0)
            {
                throw new LifecycleException("unsafe_reparse_path", "拒绝删除重解析点文件。 ");
            }
            File.Delete(file);
        }

        private static void TryRemoveEmptyDirectories(string installRoot)
        {
            string images = CombineUnder(installRoot, ImagesRelativePath);
            string data = CombineUnder(installRoot, "picker-data");
            TryRemoveEmptyDirectory(images);
            TryRemoveEmptyDirectory(data);
            TryRemoveEmptyDirectory(installRoot);
        }

        private static void TryRemoveEmptyDirectory(string path)
        {
            if (!Directory.Exists(path))
            {
                return;
            }
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            {
                throw new LifecycleException("unsafe_reparse_path", "拒绝删除重解析点目录。 ");
            }
            if (Directory.GetFileSystemEntries(path).Length == 0)
            {
                Directory.Delete(path, false);
            }
        }

        private static bool StartPanelAndWaitForReady()
        {
            if (IsPanelRunning())
            {
                return WaitForReadySignal(GetWaitMilliseconds(ReadyWaitMilliseconds));
            }

            EventWaitHandle ready = new EventWaitHandle(false, EventResetMode.ManualReset, GetObjectName("ready"));
            try
            {
                ready.Reset();
                ProcessStartInfo info = new ProcessStartInfo();
                info.FileName = CombineUnder(GetInstallRoot(), ControllerFileName);
                info.Arguments = "run --background";
                info.WorkingDirectory = GetInstallRoot();
                // The executable and its arguments are fixed local paths.
                // Shell activation prevents the long-lived UI from inheriting
                // the controller's redirected stdout/stderr pipe.
                info.UseShellExecute = true;
                info.WindowStyle = ProcessWindowStyle.Hidden;
                using (Process process = Process.Start(info))
                {
                    if (process == null)
                    {
                        return false;
                    }
                    return ready.WaitOne(GetWaitMilliseconds(ReadyWaitMilliseconds)) && IsPanelRunning() && IsPanelReady();
                }
            }
            finally
            {
                ready.Close();
            }
        }

        private static bool StopPanelAndWait(int timeoutMilliseconds)
        {
            if (!IsPanelRunning())
            {
                return true;
            }

            try
            {
                EventWaitHandle stop = EventWaitHandle.OpenExisting(GetObjectName("stop"));
                using (stop)
                {
                    stop.Set();
                }
            }
            catch (WaitHandleCannotBeOpenedException)
            {
                return !IsPanelRunning();
            }

            Stopwatch watch = Stopwatch.StartNew();
            while (watch.ElapsedMilliseconds < timeoutMilliseconds)
            {
                if (!IsPanelRunning())
                {
                    return true;
                }
                Thread.Sleep(50);
            }
            return !IsPanelRunning();
        }

        private static bool WaitForReadySignal(int timeoutMilliseconds)
        {
            try
            {
                EventWaitHandle ready = EventWaitHandle.OpenExisting(GetObjectName("ready"));
                using (ready)
                {
                    return ready.WaitOne(timeoutMilliseconds) && IsPanelRunning() && IsPanelReady();
                }
            }
            catch (WaitHandleCannotBeOpenedException)
            {
                return false;
            }
        }

        private static bool IsPanelRunning()
        {
            Mutex mutex = null;
            bool acquired = false;
            try
            {
                mutex = Mutex.OpenExisting(GetObjectName("instance"));
                try
                {
                    acquired = mutex.WaitOne(0);
                }
                catch (AbandonedMutexException)
                {
                    acquired = true;
                }
                return !acquired;
            }
            catch (WaitHandleCannotBeOpenedException)
            {
                return false;
            }
            finally
            {
                if (acquired && mutex != null)
                {
                    try { mutex.ReleaseMutex(); } catch (ApplicationException) { }
                }
                if (mutex != null)
                {
                    mutex.Close();
                }
            }
        }

        private static bool IsPanelReady()
        {
            try
            {
                EventWaitHandle ready = EventWaitHandle.OpenExisting(GetObjectName("ready"));
                using (ready)
                {
                    return ready.WaitOne(0);
                }
            }
            catch (WaitHandleCannotBeOpenedException)
            {
                return false;
            }
        }

        private static string GetObjectName(string item)
        {
            string sid;
            try
            {
                WindowsIdentity identity = WindowsIdentity.GetCurrent();
                sid = identity != null && identity.User != null ? identity.User.Value : Environment.UserName;
            }
            catch
            {
                sid = Environment.UserName;
            }
            StringBuilder safeSid = new StringBuilder();
            int i;
            for (i = 0; i < sid.Length; i++)
            {
                char c = sid[i];
                safeSid.Append(char.IsLetterOrDigit(c) ? c : '_');
            }
            int sessionId = Process.GetCurrentProcess().SessionId;
            string testSuffix = string.Empty;
            if (IsLifecycleTestMode())
            {
                // Tests may run in the same user session as the installed UI.
                // Scope every named object to both their isolated local data
                // root and test-only registry branch so a test cannot signal,
                // stop, or inspect a real panel instance.
                testSuffix = ".test." + StableScopeHash(GetLocalAppData() + "|" + GetRunRegistryPath());
            }
            return "Local\\AppleEmojiSwitcher.Panel." + safeSid + "." + sessionId.ToString(CultureInfo.InvariantCulture) + testSuffix + "." + item;
        }

        private static string StableScopeHash(string text)
        {
            unchecked
            {
                uint hash = 2166136261U;
                int i;
                for (i = 0; i < text.Length; i++)
                {
                    hash ^= text[i];
                    hash *= 16777619U;
                }
                return hash.ToString("X8", CultureInfo.InvariantCulture);
            }
        }

        private static string CombineUnder(string root, string relative)
        {
            if (string.IsNullOrEmpty(root) || string.IsNullOrEmpty(relative))
            {
                throw new LifecycleException("invalid_path", "路径不能为空。 ");
            }
            string fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string full = Path.GetFullPath(Path.Combine(fullRoot, relative));
            string prefix = fullRoot + Path.DirectorySeparatorChar;
            if (!full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                throw new LifecycleException("invalid_path", "路径越出了面板目录。 ");
            }
            return full;
        }

        private static bool PathsEqual(string first, string second)
        {
            return string.Equals(Path.GetFullPath(first).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar), Path.GetFullPath(second).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar), StringComparison.OrdinalIgnoreCase);
        }

        private static void EnsureDirectorySafe(string path)
        {
            EnsureNoReparsePoints(path);
            Directory.CreateDirectory(path);
            EnsureNoReparsePoints(path);
        }

        private static void EnsureNoReparsePoints(string path)
        {
            string full = Path.GetFullPath(path);
            if (File.Exists(full) && (File.GetAttributes(full) & FileAttributes.ReparsePoint) != 0)
            {
                throw new LifecycleException("unsafe_reparse_path", "拒绝使用重解析点文件。 ");
            }
            DirectoryInfo directory = new DirectoryInfo(File.Exists(full) ? Path.GetDirectoryName(full) : full);
            while (directory != null)
            {
                if (directory.Exists && (directory.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    throw new LifecycleException("unsafe_reparse_path", "拒绝使用包含重解析点的安装路径。 ");
                }
                DirectoryInfo parent = directory.Parent;
                if (parent == null || string.Equals(parent.FullName, directory.FullName, StringComparison.OrdinalIgnoreCase))
                {
                    break;
                }
                directory = parent;
            }
        }

        private static string MakeRelativePath(string root, string fullPath)
        {
            string normalizedRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
            string normalizedPath = Path.GetFullPath(fullPath);
            if (!normalizedPath.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase))
            {
                throw new LifecycleException("invalid_source_file", "源文件越出了数据目录。 ");
            }
            return normalizedPath.Substring(normalizedRoot.Length);
        }

        private static bool IsManifestEntryAllowed(string entry)
        {
            if (string.IsNullOrEmpty(entry) || Path.IsPathRooted(entry) || entry.IndexOf("..", StringComparison.Ordinal) >= 0)
            {
                return false;
            }
            string normalized = entry.Replace('/', '\\');
            if (string.Equals(normalized, ControllerFileName, StringComparison.OrdinalIgnoreCase) || string.Equals(normalized, CatalogRelativePath, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
            int i;
            for (i = 0; i < OptionalMetadataFiles.Length; i++)
            {
                if (string.Equals(normalized, OptionalMetadataFiles[i], StringComparison.OrdinalIgnoreCase)) return true;
            }
            return normalized.StartsWith(ImagesRelativePath + "\\", StringComparison.OrdinalIgnoreCase);
        }

        private static void DeleteStagingDirectory(string staging)
        {
            try
            {
                if (!Directory.Exists(staging))
                {
                    return;
                }
                EnsureNoReparsePoints(staging);
                Directory.Delete(staging, true);
            }
            catch
            {
                // A failed cleanup keeps only a uniquely named staging folder;
                // it is never considered user data or an uninstall target.
            }
        }

        private static IDisposable AcquireOperationLock()
        {
            Mutex mutex = new Mutex(false, GetObjectName("operation"));
            bool acquired = false;
            try
            {
                try { acquired = mutex.WaitOne(GetWaitMilliseconds(StopWaitMilliseconds)); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired)
                {
                    throw new LifecycleException("operation_timeout", "另一项面板维护操作尚未完成。 ");
                }
                return new OperationLease(mutex);
            }
            catch
            {
                if (acquired) { try { mutex.ReleaseMutex(); } catch (ApplicationException) { } }
                mutex.Close();
                throw;
            }
        }

        private static void ThrowIfUninstallPending(string installRoot)
        {
            string manifest = CombineUnder(installRoot, ManifestFileName);
            if (!File.Exists(manifest)) return;
            EnsureNoReparsePoints(manifest);
            string[] lines = File.ReadAllLines(manifest, new UTF8Encoding(false));
            int i;
            for (i = 0; i < lines.Length; i++)
            {
                if (lines[i].StartsWith(UninstallPendingPrefix, StringComparison.Ordinal))
                {
                    throw new LifecycleException("uninstall_in_progress", "卸载清理正在进行，不能同时启用面板。 ");
                }
            }
        }

        private static bool HasUninstallPendingToken(string installRoot, string token)
        {
            string manifest = CombineUnder(installRoot, ManifestFileName);
            if (!File.Exists(manifest)) return false;
            EnsureNoReparsePoints(manifest);
            string expected = UninstallPendingPrefix + token;
            string[] lines = File.ReadAllLines(manifest, new UTF8Encoding(false));
            int i;
            for (i = 0; i < lines.Length; i++)
            {
                if (string.Equals(lines[i].Trim(), expected, StringComparison.Ordinal)) return true;
            }
            return false;
        }

        private static bool HasAnyUninstallPending(string installRoot)
        {
            string manifest = CombineUnder(installRoot, ManifestFileName);
            if (!File.Exists(manifest)) return false;
            EnsureNoReparsePoints(manifest);
            string[] lines = File.ReadAllLines(manifest, new UTF8Encoding(false));
            int i;
            for (i = 0; i < lines.Length; i++)
            {
                if (lines[i].StartsWith(UninstallPendingPrefix, StringComparison.Ordinal)) return true;
            }
            return false;
        }

        private static void MarkUninstallPending(string installRoot, string token)
        {
            string manifest = CombineUnder(installRoot, ManifestFileName);
            if (File.Exists(manifest) && (File.GetAttributes(manifest) & FileAttributes.ReparsePoint) != 0)
            {
                throw new LifecycleException("unsafe_reparse_path", "拒绝标记重解析点安装清单。 ");
            }
            File.AppendAllText(manifest, UninstallPendingPrefix + token + Environment.NewLine, new UTF8Encoding(false));
        }

        private static void ClearUninstallPending(string installRoot, string token)
        {
            string manifest = CombineUnder(installRoot, ManifestFileName);
            if (!File.Exists(manifest)) return;
            EnsureNoReparsePoints(manifest);
            string expected = UninstallPendingPrefix + token;
            string[] lines = File.ReadAllLines(manifest, new UTF8Encoding(false));
            StringBuilder kept = new StringBuilder();
            int i;
            for (i = 0; i < lines.Length; i++)
            {
                if (!string.Equals(lines[i].Trim(), expected, StringComparison.Ordinal)) kept.AppendLine(lines[i]);
            }
            File.WriteAllText(manifest, kept.ToString(), new UTF8Encoding(false));
        }

        private static void RecordUninstallFailure(Exception exception)
        {
            string root = GetInstallRoot();
            string userData = CombineUnder(root, "user-data");
            EnsureDirectorySafe(userData);
            string log = CombineUnder(userData, "uninstall-errors.log");
            if (File.Exists(log) && (File.GetAttributes(log) & FileAttributes.ReparsePoint) != 0) return;
            string line = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + " " + GetFailureReason(exception) + " " + exception.Message + Environment.NewLine;
            File.AppendAllText(log, line, new UTF8Encoding(false));
        }

        private static void WaitForParentExit(int parentProcessId)
        {
            try
            {
                Process parent = Process.GetProcessById(parentProcessId);
                using (parent)
                {
                    if (!parent.HasExited && !parent.WaitForExit(GetWaitMilliseconds(StopWaitMilliseconds)))
                    {
                        throw new LifecycleException("cleanup_parent_running", "原控制器未在限定时间内退出。 ");
                    }
                }
            }
            catch (ArgumentException)
            {
                // It had already exited before the helper queried its PID.
            }
        }

        private static void ScheduleSelfCleanup(string installRoot)
        {
            string token = Guid.NewGuid().ToString("N");
            string currentController = CombineUnder(GetApplicationBaseDirectory(), ControllerFileName);
            string helper = Path.Combine(Path.GetTempPath(), "AppleEmojiSwitcher-PanelCleanup-" + token + ".exe");
            MarkUninstallPending(installRoot, token);
            try
            {
                File.Copy(currentController, helper, false);
                ProcessStartInfo info = new ProcessStartInfo();
                info.FileName = helper;
                info.Arguments = "cleanup --cleanup-parent " + Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) + " --cleanup-token " + token;
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                info.WindowStyle = ProcessWindowStyle.Hidden;
                Process process = Process.Start(info);
                if (process == null)
                {
                    throw new LifecycleException("cleanup_start_failed", "无法启动卸载清理程序。 ");
                }
                process.Close();
            }
            catch
            {
                ClearUninstallPending(installRoot, token);
                try { if (File.Exists(helper)) File.Delete(helper); } catch { }
                throw;
            }
        }
    }

    internal sealed class OperationLease : IDisposable
    {
        private Mutex _mutex;

        internal OperationLease(Mutex mutex)
        {
            _mutex = mutex;
        }

        public void Dispose()
        {
            Mutex mutex = _mutex;
            _mutex = null;
            if (mutex == null) return;
            try { mutex.ReleaseMutex(); } catch (ApplicationException) { }
            mutex.Close();
        }
    }

    internal static class LifecycleNativeMethods
    {
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        internal static extern IntPtr GetConsoleWindow();

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        internal static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    }

#if AES_LIFECYCLE_STUB
    // The build script compiles this only for isolated lifecycle tests, without
    // the WinForms implementation.  It deliberately signals readiness and
    // blocks on the same stop event as the production UI contract.
    internal static class PanelApplication
    {
        public static void Run(string dataRoot, EventWaitHandle stopEvent, EventWaitHandle readyEvent, bool showImmediately)
        {
            if (string.Equals(Environment.GetEnvironmentVariable("AES_PICKER_TEST_UI_FAIL"), "1", StringComparison.Ordinal))
            {
                throw new InvalidOperationException("test UI startup failure");
            }
            readyEvent.Set();
            stopEvent.WaitOne();
        }
    }
#endif
}
