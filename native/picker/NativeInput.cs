using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;

namespace AesPicker
{
    /// <summary>Raised only for an unmodified physical Win+. or Win+; sequence.</summary>
    public sealed class HotkeyPressedEventArgs : EventArgs
    {
        internal HotkeyPressedEventArgs(IntPtr targetWindow) { TargetWindow = targetWindow; }
        public IntPtr TargetWindow { get; private set; }
    }

    /// <summary>
    /// A narrow low-level hook. It does not consume a Windows key until the selected emoji shortcut has
    /// actually been seen, and it ignores this application's SendInput marker and all injected key events.
    /// </summary>
    public sealed class KeyboardInterceptor : IDisposable
    {
        private const int WhKeyboardLl = 13;
        private const int WmKeyDown = 0x0100;
        private const int WmKeyUp = 0x0101;
        private const int WmSysKeyDown = 0x0104;
        private const int WmSysKeyUp = 0x0105;
        private const int VkOemPeriod = 0xBE;
        private const int VkOemSemicolon = 0xBA;
        private const int VkLwin = 0x5B;
        private const int VkRwin = 0x5C;
        private const int LlkhfInjected = 0x10;

        private readonly LowLevelKeyboardProc _callback;
        private IntPtr _hook = IntPtr.Zero;
        private int _suppressedOemMask;

        public KeyboardInterceptor()
        {
            _callback = HookCallback;
            _hook = PickerNativeMethods.SetWindowsHookEx(WhKeyboardLl, _callback, PickerNativeMethods.GetModuleHandle(null), 0);
            if (_hook == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "无法安装 Win+. 键盘钩子。");
        }

        public event EventHandler<HotkeyPressedEventArgs> HotkeyPressed;
        public bool LastStartMenuMaskSucceeded { get; private set; }

        public void Dispose()
        {
            IntPtr hook = Interlocked.Exchange(ref _hook, IntPtr.Zero);
            if (hook != IntPtr.Zero) PickerNativeMethods.UnhookWindowsHookEx(hook);
            GC.SuppressFinalize(this);
        }

        private IntPtr HookCallback(int code, IntPtr wParam, IntPtr lParam)
        {
            if (code >= 0)
            {
                int message = wParam.ToInt32();
                KeyboardHookData data = (KeyboardHookData)Marshal.PtrToStructure(lParam, typeof(KeyboardHookData));
                bool injected = IsInjected(data);
                if (!injected && (data.VirtualKey == VkLwin || data.VirtualKey == VkRwin))
                {
                    if (message == WmKeyDown || message == WmSysKeyDown) NativeInput.ReportPhysicalWindowsKey(data.VirtualKey, true);
                    else if (message == WmKeyUp || message == WmSysKeyUp) NativeInput.ReportPhysicalWindowsKey(data.VirtualKey, false);
                }
                if (message == WmKeyDown || message == WmSysKeyDown)
                {
                    int oemMask = OemMask(data.VirtualKey);
                    if (!injected && oemMask != 0 && NativeInput.AreWindowsKeysDown() && !HasOtherModifiers())
                    {
                        bool firstPress = _suppressedOemMask == 0;
                        _suppressedOemMask |= oemMask; // Repeated OEM keydowns are consumed but do not show another panel.
                        if (firstPress)
                        {
                            // Do not consume physical Win key-up.  A marker-tagged unused VK is the conventional
                            // menu mask after consuming a Win chord; if it fails we still leave the physical key alone.
                            LastStartMenuMaskSucceeded = NativeInput.TrySendStartMenuMask();
                            // Capture before the panel takes activation. The event receiver posts work to its UI loop.
                            IntPtr target = NativeInput.CaptureForegroundWindow();
                            EventHandler<HotkeyPressedEventArgs> handler = HotkeyPressed;
                            if (handler != null) handler(this, new HotkeyPressedEventArgs(target));
                        }
                        return new IntPtr(1);
                    }
                }
                else if (message == WmKeyUp || message == WmSysKeyUp)
                {
                    int oemMask = OemMask(data.VirtualKey);
                    if (!injected && oemMask != 0 && (_suppressedOemMask & oemMask) != 0)
                    {
                        _suppressedOemMask &= ~oemMask;
                        return new IntPtr(1);
                    }
                }
            }
            return PickerNativeMethods.CallNextHookEx(_hook, code, wParam, lParam);
        }

        private static int OemMask(uint virtualKey)
        {
            if (virtualKey == VkOemPeriod) return 1;
            if (virtualKey == VkOemSemicolon) return 2;
            return 0;
        }

        private static bool IsInjected(KeyboardHookData data)
        {
            return (data.Flags & LlkhfInjected) != 0 || data.ExtraInfo == NativeInput.InjectionMarker;
        }

        private static bool HasOtherModifiers()
        {
            return NativeInput.IsKeyDown(NativeInput.VkControl) || NativeInput.IsKeyDown(NativeInput.VkMenu) ||
                NativeInput.IsKeyDown(NativeInput.VkShift);
        }
    }

    /// <summary>Foreground validation and Unicode SendInput. It never writes to the clipboard implicitly.</summary>
    public static class NativeInput
    {
        internal const int VkShift = 0x10;
        internal const int VkControl = 0x11;
        internal const int VkMenu = 0x12;
        internal const int VkLwin = 0x5B;
        internal const int VkRwin = 0x5C;
        private const uint KeyeventfKeyup = 0x0002;
        private const uint KeyeventfUnicode = 0x0004;
        private const uint KeyeventfExtendedkey = 0x0001;
        private static int _trackedWindowsKeyMask;
        private static int _hasTrackedWindowsKeyState;
        internal static readonly IntPtr InjectionMarker = IntPtr.Size == 8
            ? new IntPtr(unchecked((long)0x4153455049434B52L))
            : new IntPtr(unchecked((int)0x5049434B));

        public static IntPtr CaptureForegroundWindow()
        {
            return PickerNativeMethods.GetForegroundWindow();
        }

        public static bool AreWindowsKeysDown()
        {
            if (Interlocked.CompareExchange(ref _hasTrackedWindowsKeyState, 0, 0) != 0)
            {
                return Interlocked.CompareExchange(ref _trackedWindowsKeyMask, 0, 0) != 0;
            }
            return IsKeyDown(VkLwin) || IsKeyDown(VkRwin);
        }

        internal static void ReportPhysicalWindowsKey(uint virtualKey, bool down)
        {
            int bit = virtualKey == VkLwin ? 1 : virtualKey == VkRwin ? 2 : 0;
            if (bit == 0) return;
            int current = Interlocked.CompareExchange(ref _trackedWindowsKeyMask, 0, 0);
            while (true)
            {
                int next = down ? current | bit : current & ~bit;
                int observed = Interlocked.CompareExchange(ref _trackedWindowsKeyMask, next, current);
                if (observed == current) break;
                current = observed;
            }
            Interlocked.Exchange(ref _hasTrackedWindowsKeyState, 1);
        }

        internal static bool IsTrackedWindowsKeyDown(int virtualKey)
        {
            int bit = virtualKey == VkLwin ? 1 : virtualKey == VkRwin ? 2 : 0;
            if (bit == 0) return false;
            if (Interlocked.CompareExchange(ref _hasTrackedWindowsKeyState, 0, 0) == 0) return IsKeyDown(virtualKey);
            return (Interlocked.CompareExchange(ref _trackedWindowsKeyMask, 0, 0) & bit) != 0;
        }

        internal static bool IsKeyDown(int virtualKey)
        {
            return (PickerNativeMethods.GetAsyncKeyState(virtualKey) & unchecked((short)0x8000)) != 0;
        }

        /// <summary>Returns the exact UTF-16 code units. No Unicode normalization or code-point iteration occurs here.</summary>
        public static ushort[] ToUtf16Units(string sequence)
        {
            if (sequence == null) throw new ArgumentNullException("sequence");
            ushort[] units = new ushort[sequence.Length];
            for (int i = 0; i < sequence.Length; i++) units[i] = sequence[i];
            return units;
        }

        /// <summary>Used by pure tests to prove that a surrogate pair, ZWJ and variation selector survive the input conversion.</summary>
        public static string FromUtf16Units(ushort[] units)
        {
            if (units == null) throw new ArgumentNullException("units");
            char[] characters = new char[units.Length];
            for (int i = 0; i < units.Length; i++) characters[i] = (char)units[i];
            return new string(characters);
        }

        public static bool TryInsertUnicode(IntPtr targetWindow, string sequence, out string failureReason)
        {
            return TryInsertUnicode(targetWindow, GetWindowProcessId(targetWindow), sequence, out failureReason);
        }

        /// <summary>
        /// Sends only when the current HWND still belongs to the PID captured with it.  This prevents an
        /// HWND that was destroyed and recycled while the panel was visible from receiving text.
        /// </summary>
        public static bool TryInsertUnicode(IntPtr targetWindow, uint expectedProcessId, string sequence, out string failureReason)
        {
            failureReason = String.Empty;
            if (String.IsNullOrEmpty(sequence))
            {
                failureReason = "表情序列为空。";
                return false;
            }
            if (AreWindowsKeysDown())
            {
                failureReason = "请先松开 Windows 键。";
                return false;
            }
            if (AreTextModifiersDown())
            {
                failureReason = "请先松开 Ctrl、Alt 和 Shift 键。";
                return false;
            }
            if (targetWindow == IntPtr.Zero || expectedProcessId == 0 || !PickerNativeMethods.IsWindow(targetWindow) ||
                GetWindowProcessId(targetWindow) != expectedProcessId)
            {
                failureReason = "原输入窗口已变化或关闭。";
                return false;
            }
            // A panel click activates this form. Restoring and checking the captured target makes the send fail closed
            // instead of sending characters to whichever window happened to become active.
            PickerNativeMethods.SetForegroundWindow(targetWindow);
            Thread.Sleep(20);
            if (PickerNativeMethods.GetForegroundWindow() != targetWindow || GetWindowProcessId(targetWindow) != expectedProcessId)
            {
                failureReason = "无法恢复原输入窗口焦点；未发送字符。";
                return false;
            }
            uint sent;
            int total;
            if (!SendUnicodeUnits(ToUtf16Units(sequence), out sent, out total))
            {
                int error = Marshal.GetLastWin32Error();
                failureReason = sent > 0
                    ? "仅发送了 " + sent + "/" + total + " 个 UTF-16 键事件，字符可能已部分输入，不能自动回滚。"
                    : error == 0
                    ? "目标窗口拒绝输入（可能权限更高）；未修改剪贴板。"
                    : "SendInput 失败（错误 " + error + "）；未修改剪贴板。";
                return false;
            }
            return true;
        }

        public static bool OpenNativePanel(IntPtr targetWindow, out string failureReason)
        {
            return OpenNativePanel(targetWindow, GetWindowProcessId(targetWindow), out failureReason);
        }

        public static bool OpenNativePanel(IntPtr targetWindow, uint expectedProcessId, out string failureReason)
        {
            bool uncertain;
            return OpenNativePanel(targetWindow, expectedProcessId, out failureReason, out uncertain);
        }

        public static bool OpenNativePanel(IntPtr targetWindow, uint expectedProcessId, out string failureReason, out bool uncertain)
        {
            uncertain = false;
            failureReason = String.Empty;
            if (AreWindowsKeysDown())
            {
                failureReason = "请先松开 Windows 键。";
                return false;
            }
            if (AreTextModifiersDown())
            {
                failureReason = "请先松开 Ctrl、Alt 和 Shift 键。";
                return false;
            }
            if (targetWindow == IntPtr.Zero || expectedProcessId == 0 || !PickerNativeMethods.IsWindow(targetWindow) ||
                GetWindowProcessId(targetWindow) != expectedProcessId)
            {
                failureReason = "原输入窗口已变化或关闭。";
                return false;
            }
            PickerNativeMethods.SetForegroundWindow(targetWindow);
            Thread.Sleep(20);
            if (PickerNativeMethods.GetForegroundWindow() != targetWindow || GetWindowProcessId(targetWindow) != expectedProcessId)
            {
                failureReason = "无法恢复原输入窗口焦点。";
                return false;
            }
            Input[] inputs = new Input[] {
                VirtualKeyInput(VkLwin, false), VirtualKeyInput(0xBE, false),
                VirtualKeyInput(0xBE, true), VirtualKeyInput(VkLwin, true)
            };
            uint sent = PickerNativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input)));
            if (sent != inputs.Length)
            {
                uncertain = sent > 0;
                if (sent > 0) ReleaseNativeShortcutKeys();
                failureReason = sent > 0
                    ? "原生快捷键只发送了 " + sent + "/" + inputs.Length + " 个键事件，已尝试松开按键，打开状态不确定。"
                    : "未能模拟 Win+.（错误 " + Marshal.GetLastWin32Error() + "）。";
                return false;
            }
            return true;
        }

        internal static void SetCueBanner(IntPtr textBox, string value)
        {
            if (textBox != IntPtr.Zero) PickerNativeMethods.SendMessage(textBox, 0x1501, new IntPtr(1), value ?? String.Empty);
        }

        private static bool SendUnicodeUnits(ushort[] units, out uint sent, out int total)
        {
            Input[] inputs = new Input[units.Length * 2];
            for (int i = 0; i < units.Length; i++)
            {
                inputs[i * 2] = UnicodeInput(units[i], false);
                inputs[i * 2 + 1] = UnicodeInput(units[i], true);
            }
            total = inputs.Length;
            sent = PickerNativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input)));
            return sent == inputs.Length;
        }

        internal static bool TrySendStartMenuMask()
        {
            Input[] inputs = new Input[] { VirtualKeyInput(0xE8, false), VirtualKeyInput(0xE8, true) };
            uint sent = PickerNativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input)));
            if (sent == 1)
            {
                Input[] release = new Input[] { VirtualKeyInput(0xE8, true) };
                PickerNativeMethods.SendInput(1, release, Marshal.SizeOf(typeof(Input)));
            }
            return sent == inputs.Length;
        }

        private static void ReleaseNativeShortcutKeys()
        {
            // The preceding SendInput may have stopped after either key-down. Releasing both is idempotent and avoids
            // leaving an injected Win/OEM key logically down; the caller still reports that opening is uncertain.
            Input[] releases = new Input[] { VirtualKeyInput(0xBE, true), VirtualKeyInput(VkLwin, true) };
            PickerNativeMethods.SendInput((uint)releases.Length, releases, Marshal.SizeOf(typeof(Input)));
        }

        private static bool AreTextModifiersDown()
        {
            return IsKeyDown(VkControl) || IsKeyDown(VkMenu) || IsKeyDown(VkShift);
        }

        public static uint GetWindowProcessId(IntPtr window)
        {
            uint processId;
            PickerNativeMethods.GetWindowThreadProcessId(window, out processId);
            return processId;
        }

        private static Input UnicodeInput(ushort unit, bool up)
        {
            Input input = new Input();
            input.Type = 1;
            input.Data.Keyboard.VirtualKey = 0;
            input.Data.Keyboard.ScanCode = unit;
            input.Data.Keyboard.Flags = KeyeventfUnicode | (up ? KeyeventfKeyup : 0);
            input.Data.Keyboard.Time = 0;
            input.Data.Keyboard.ExtraInfo = InjectionMarker;
            return input;
        }

        private static Input VirtualKeyInput(int virtualKey, bool up)
        {
            Input input = new Input();
            input.Type = 1;
            input.Data.Keyboard.VirtualKey = (ushort)virtualKey;
            input.Data.Keyboard.ScanCode = 0;
            input.Data.Keyboard.Flags = (up ? KeyeventfKeyup : 0) | ((virtualKey == VkLwin || virtualKey == VkRwin) ? KeyeventfExtendedkey : 0);
            input.Data.Keyboard.Time = 0;
            input.Data.Keyboard.ExtraInfo = InjectionMarker;
            return input;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct KeyboardHookData
    {
        public uint VirtualKey;
        public uint ScanCode;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    internal delegate IntPtr LowLevelKeyboardProc(int code, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    internal struct Input
    {
        public uint Type;
        public InputUnion Data;
    }

    [StructLayout(LayoutKind.Explicit)]
    internal struct InputUnion
    {
        [FieldOffset(0)] public MouseInput Mouse;
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public HardwareInput Hardware;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct MouseInput
    {
        public int X;
        public int Y;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct HardwareInput
    {
        public uint Message;
        public ushort ParameterL;
        public ushort ParameterH;
    }

    internal static class PickerNativeMethods
    {
        [DllImport("user32.dll", SetLastError = true)]
        internal static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc callback, IntPtr module, uint threadId);
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")]
        internal static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")]
        internal static extern short GetAsyncKeyState(int virtualKey);
        [DllImport("user32.dll")]
        internal static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll")]
        internal static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll", SetLastError = true)]
        internal static extern uint SendInput(uint count, [In, Out] Input[] inputs, int size);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, string lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        internal static extern IntPtr GetModuleHandle(string moduleName);
    }
}
