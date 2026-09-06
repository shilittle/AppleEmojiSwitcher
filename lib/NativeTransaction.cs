// Native helpers for AppleEmojiSwitcher.  This source is compiled on demand by
// SystemTransaction.psm1, so the published application does not need an
// untracked native binary.
using System;
using System.ComponentModel;
using System.IO;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;

namespace AppleEmojiSwitcher
{
    public sealed class NativeVersionInfo
    {
        public int Major;
        public int Minor;
        public int Build;
        public string ToDisplayString() { return Major + "." + Minor; }
    }

    public sealed class NativeArchitectureInfo
    {
        public ushort ProcessorArchitecture;
        public string Name;
    }

    public static class NativeTransaction
    {
        private const int MOVEFILE_REPLACE_EXISTING = 0x1;
        private const int MOVEFILE_DELAY_UNTIL_REBOOT = 0x4;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct RTL_OSVERSIONINFOEX
        {
            public int dwOSVersionInfoSize;
            public int dwMajorVersion;
            public int dwMinorVersion;
            public int dwBuildNumber;
            public int dwPlatformId;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            public string szCSDVersion;
            public ushort wServicePackMajor;
            public ushort wServicePackMinor;
            public ushort wSuiteMask;
            public byte wProductType;
            public byte wReserved;
        }

        [DllImport("ntdll.dll", CharSet = CharSet.Unicode)]
        private static extern int RtlGetVersion(ref RTL_OSVERSIONINFOEX versionInfo);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);

        [StructLayout(LayoutKind.Sequential)]
        private struct SYSTEM_INFO
        {
            public ushort wProcessorArchitecture;
            public ushort wReserved;
            public uint dwPageSize;
            public IntPtr lpMinimumApplicationAddress;
            public IntPtr lpMaximumApplicationAddress;
            public IntPtr dwActiveProcessorMask;
            public uint dwNumberOfProcessors;
            public uint dwProcessorType;
            public uint dwAllocationGranularity;
            public ushort wProcessorLevel;
            public ushort wProcessorRevision;
        }

        private const ushort PROCESSOR_ARCHITECTURE_INTEL = 0;
        private const ushort PROCESSOR_ARCHITECTURE_AMD64 = 9;
        private const ushort PROCESSOR_ARCHITECTURE_ARM64 = 12;

        [DllImport("kernel32.dll")]
        private static extern void GetNativeSystemInfo(out SYSTEM_INFO systemInfo);

        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(IntPtr fileHandle, out BY_HANDLE_FILE_INFORMATION information);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateHardLink(string fileName, string existingFileName, IntPtr securityAttributes);

        [StructLayout(LayoutKind.Sequential)]
        private struct LUID
        {
            public uint LowPart;
            public int HighPart;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct TOKEN_PRIVILEGES
        {
            public uint PrivilegeCount;
            public LUID Luid;
            public uint Attributes;
        }

        private const uint TOKEN_ADJUST_PRIVILEGES = 0x20;
        private const uint TOKEN_QUERY = 0x8;
        private const uint SE_PRIVILEGE_ENABLED = 0x2;
        private const int ERROR_NOT_ALL_ASSIGNED = 1300;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool LookupPrivilegeValue(string systemName, string name, out LUID luid);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool AdjustTokenPrivileges(IntPtr tokenHandle, bool disableAllPrivileges, ref TOKEN_PRIVILEGES newState, uint bufferLength, IntPtr previousState, IntPtr returnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        private static void EnablePrivilege(string privilegeName)
        {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken failed.");
            try
            {
                LUID luid;
                if (!LookupPrivilegeValue(null, privilegeName, out luid))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "LookupPrivilegeValue failed for " + privilegeName + ".");
                TOKEN_PRIVILEGES state = new TOKEN_PRIVILEGES { PrivilegeCount = 1, Luid = luid, Attributes = SE_PRIVILEGE_ENABLED };
                if (!AdjustTokenPrivileges(token, false, ref state, 0, IntPtr.Zero, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "AdjustTokenPrivileges failed for " + privilegeName + ".");
                int error = Marshal.GetLastWin32Error();
                if (error == ERROR_NOT_ALL_ASSIGNED)
                    throw new UnauthorizedAccessException("The process token does not hold " + privilegeName + ".");
            }
            finally { CloseHandle(token); }
        }

        // The transaction records and restores the owner, group, and DACL.
        // It deliberately does not read or change the SACL, so it must not
        // require SeSecurityPrivilege from an otherwise capable elevated
        // administrator token.
        private const AccessControlSections OwnerGroupAndDacl =
            AccessControlSections.Owner | AccessControlSections.Group | AccessControlSections.Access;

        private static void EnableRestorePrivilege()
        {
            // Disabled by default even in an elevated administrator token.
            // Required when returning a protected file to TrustedInstaller.
            EnablePrivilege("SeRestorePrivilege");
        }

        private static void EnableTakeOwnershipPrivilege()
        {
            EnablePrivilege("SeTakeOwnershipPrivilege");
        }

        private static void EnableTakeOwnershipAndRestorePrivileges()
        {
            EnableTakeOwnershipPrivilege();
            EnableRestorePrivilege();
        }

        public static NativeVersionInfo GetRealWindowsVersion()
        {
            RTL_OSVERSIONINFOEX info = new RTL_OSVERSIONINFOEX();
            info.dwOSVersionInfoSize = Marshal.SizeOf(typeof(RTL_OSVERSIONINFOEX));
            int status = RtlGetVersion(ref info);
            if (status != 0)
                throw new Win32Exception(status, "RtlGetVersion failed.");
            return new NativeVersionInfo { Major = info.dwMajorVersion, Minor = info.dwMinorVersion, Build = info.dwBuildNumber };
        }

        public static NativeArchitectureInfo GetNativeArchitecture()
        {
            SYSTEM_INFO info;
            GetNativeSystemInfo(out info);
            string name = info.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_AMD64 ? "x64" :
                          info.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_ARM64 ? "ARM64" :
                          info.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_INTEL ? "x86" : "Unknown";
            return new NativeArchitectureInfo { ProcessorArchitecture = info.wProcessorArchitecture, Name = name };
        }

        public static uint GetHardLinkCount(string path)
        {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                BY_HANDLE_FILE_INFORMATION information;
                SafeFileHandle handle = stream.SafeFileHandle;
                if (!GetFileInformationByHandle(handle.DangerousGetHandle(), out information))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "GetFileInformationByHandle failed.");
                return information.NumberOfLinks;
            }
        }

        public static void CreateRestoreAnchor(string anchorPath, string sourcePath)
        {
            if (!CreateHardLink(anchorPath, sourcePath, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateHardLink for the transaction anchor failed.");
        }

        public static void ProtectTransactionDirectory(string path)
        {
            EnableRestorePrivilege();
            DirectorySecurity security = new DirectorySecurity();
            security.SetSecurityDescriptorSddlForm("O:BAG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)", OwnerGroupAndDacl);
            new DirectoryInfo(path).SetAccessControl(security);
        }

        public static void ProtectTransactionFile(string path)
        {
            EnableRestorePrivilege();
            FileSecurity security = new FileSecurity();
            security.SetSecurityDescriptorSddlForm("O:BAG:SYD:PAI(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x120089;;;BU)", OwnerGroupAndDacl);
            new FileInfo(path).SetAccessControl(security);
        }

        public static void QueueReplaceAtRestart(string source, string destination)
        {
            if (!MoveFileEx(source, destination, MOVEFILE_REPLACE_EXISTING | MOVEFILE_DELAY_UNTIL_REBOOT))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "MoveFileEx could not queue the boot-time replacement.");
        }

        public static string GetFileSecuritySddl(string path)
        {
            FileSecurity security = new FileInfo(path).GetAccessControl(OwnerGroupAndDacl);
            return security.GetSecurityDescriptorSddlForm(OwnerGroupAndDacl);
        }

        public static void SetFileSecuritySddl(string path, string sddl)
        {
            EnableRestorePrivilege();
            FileSecurity security = new FileSecurity();
            security.SetSecurityDescriptorSddlForm(sddl, OwnerGroupAndDacl);
            new FileInfo(path).SetAccessControl(security);
        }

        // This is deliberately temporary.  The caller records the returned
        // SDDL first and restores it in a finally block before queuing reboot.
        public static string GrantAdministratorsFullControlTemporarily(string path)
        {
            EnableTakeOwnershipPrivilege();
            string original = GetFileSecuritySddl(path);
            FileSecurity security = new FileInfo(path).GetAccessControl();
            SecurityIdentifier administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            security.SetOwner(administrators);
            security.AddAccessRule(new FileSystemAccessRule(administrators, FileSystemRights.FullControl, AccessControlType.Allow));
            new FileInfo(path).SetAccessControl(security);
            return original;
        }

        // The replacement target keeps this extra SYSTEM rule until Session
        // Manager consumes it at boot.  The staged successor has the original
        // descriptor; the one-shot finalizer restores the old shared inode
        // through its anchor after boot.
        public static string GrantSystemDeleteUntilReboot(string path)
        {
            EnableTakeOwnershipAndRestorePrivileges();
            FileInfo file = new FileInfo(path);
            FileSecurity originalSecurity = file.GetAccessControl(OwnerGroupAndDacl);
            string original = originalSecurity.GetSecurityDescriptorSddlForm(OwnerGroupAndDacl);
            SecurityIdentifier originalOwner = (SecurityIdentifier)originalSecurity.GetOwner(typeof(SecurityIdentifier));
            SecurityIdentifier administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            SecurityIdentifier localSystem = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);

            // Take ownership first so the exact DACL can be amended without
            // relying on an inherited Administrators ACE.
            originalSecurity.SetOwner(administrators);
            file.SetAccessControl(originalSecurity);

            FileSecurity bootSecurity = file.GetAccessControl();
            bootSecurity.AddAccessRule(new FileSystemAccessRule(localSystem, FileSystemRights.Delete, AccessControlType.Allow));
            bootSecurity.SetOwner(originalOwner);
            file.SetAccessControl(bootSecurity);
            return original;
        }
    }
}
