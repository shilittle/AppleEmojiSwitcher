Set-StrictMode -Version 2.0

# This module has one deliberately narrow responsibility: atomically prepare a
# boot-time replacement of the single Windows emoji font, while retaining an
# independently verifiable original.  It never edits the Fonts mapping.

$script:AesKnownLocalReferenceHash = '12c5253251f45c57fa57e2a1c748f821d3ca030a3e757e049a5da6316f213bcb'
$script:AesExpectedAppleSourceHash = '18e48f1785564fbf511241e0963b265057bfe742036d8543406c6ce07e48ec0b'
$script:AesExpectedAppleSourceSize = [int64]256391076
$script:AesFontValueName = 'Segoe UI Emoji (TrueType)'
$script:AesMutexName = 'Global\AppleEmojiSwitcher.SystemTransaction.v1'
$script:AesTestBackend = $null

function Set-AesTestBackend {
    # Internal test seam.  It is intentionally not exported: production callers
    # cannot redirect system paths or privileged registry operations.
    param([Parameter(Mandatory = $true)][hashtable]$Backend)
    $script:AesTestBackend = $Backend
}

function Clear-AesTestBackend { $script:AesTestBackend = $null }

function Get-AesMemberValue {
    param($Object, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function ConvertTo-AesHashtable {
    param($Value)
    if ($null -eq $Value) { return $null }
    # In Windows PowerShell 5.1, path strings can arrive as PSObject-wrapped
    # values and satisfy `-is [pscustomobject]`.  Preserve scalar values before
    # recursively expanding custom-object properties such as String.Length.
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) { $result[[string]$key] = ConvertTo-AesHashtable $Value[$key] }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $result = @()
        foreach ($item in $Value) { $result += ,(ConvertTo-AesHashtable $item) }
        # Preserve a one-item JSON array as an array.  A normal PowerShell
        # return enumerates it and would turn it into a scalar at its caller.
        return ,$result
    }
    if ($Value -is [pscustomobject]) {
        $result = @{}
        foreach ($property in $Value.PSObject.Properties) { $result[$property.Name] = ConvertTo-AesHashtable $property.Value }
        return $result
    }
    return $Value
}

function Get-AesNative {
    $existing = ('AppleEmojiSwitcher.NativeTransaction' -as [type])
    if ($null -ne $existing) { return $existing }
    $source = Join-Path $PSScriptRoot 'NativeTransaction.cs'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing native helper: $source" }
    Add-Type -TypeDefinition ([System.IO.File]::ReadAllText($source)) -Language CSharp -ErrorAction Stop
    return ('AppleEmojiSwitcher.NativeTransaction' -as [type])
}

function Get-AesEnvironment {
    if ($null -ne $script:AesTestBackend) {
        return @{
            Root = [System.IO.Path]::GetFullPath([string](Get-AesMemberValue $script:AesTestBackend 'Root'))
            TargetPath = [System.IO.Path]::GetFullPath([string](Get-AesMemberValue $script:AesTestBackend 'TargetPath'))
            WindowsVersion = [string](Get-AesMemberValue $script:AesTestBackend 'WindowsVersion' '10.0')
            Build = [int](Get-AesMemberValue $script:AesTestBackend 'Build' 22631)
            Architecture = [string](Get-AesMemberValue $script:AesTestBackend 'Architecture' 'x64')
            IsElevated = [bool](Get-AesMemberValue $script:AesTestBackend 'IsElevated' $true)
        }
    }
    $native = Get-AesNative
    $version = $native::GetRealWindowsVersion()
    $windowsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    $architecture = $native::GetNativeArchitecture()
    return @{
        Root = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'AppleEmojiSwitcher'
        TargetPath = Join-Path $windowsRoot 'Fonts\seguiemj.ttf'
        WindowsVersion = $version.ToDisplayString()
        Build = [int]$version.Build
        Architecture = $architecture.Name
        IsElevated = (Test-AesElevation)
    }
}

function Test-AesElevation {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Test-AesSupported {
    param([hashtable]$Environment)
    if ($Environment.Architecture -ne 'x64') { return @{ Supported = $false; Reason = 'Only 64-bit Windows is supported.' } }
    if ($Environment.Build -lt 14393) { return @{ Supported = $false; Reason = 'Windows build 14393 or later is required.' } }
    if ($Environment.WindowsVersion -notmatch '^10\.0') { return @{ Supported = $false; Reason = 'This is not a supported Windows 10/11 kernel.' } }
    return @{ Supported = $true; Reason = '' }
}

function Get-AesHardLinkCount {
    param([string]$Path)
    $hook = Get-AesMemberValue $script:AesTestBackend 'GetHardLinkCount'
    if ($null -ne $hook) { return [uint32](& $hook $Path) }
    return [uint32]((Get-AesNative)::GetHardLinkCount($Path))
}

function Protect-AesTransactionDirectory {
    param([string]$Path)
    $hook = Get-AesMemberValue $script:AesTestBackend 'ProtectDirectory'
    if ($null -ne $hook) { & $hook $Path; return }
    (Get-AesNative)::ProtectTransactionDirectory($Path)
}

function Protect-AesTransactionFile {
    param([string]$Path)
    $hook = Get-AesMemberValue $script:AesTestBackend 'ProtectFile'
    if ($null -ne $hook) { & $hook $Path; return }
    (Get-AesNative)::ProtectTransactionFile($Path)
}

function Test-AesReparsePoint {
    param([string]$Path)
    $hook = Get-AesMemberValue $script:AesTestBackend 'IsReparsePoint'
    if ($null -ne $hook) { return [bool](& $hook $Path) }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-AesTrustedPath {
    param([string]$Path)
    $hook = Get-AesMemberValue $script:AesTestBackend 'AssertTrustedPath'
    if ($null -ne $hook) { & $hook $Path; return }
    if (Test-AesReparsePoint $Path) { throw "Transaction path is a reparse point: $Path" }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $ownerSid = $acl.Owner
    try { $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
    $trustedOwners = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    if ($trustedOwners -notcontains $ownerSid) { throw "Transaction path has an untrusted owner: $Path" }
    $writeMask = 2 -bor 4 -bor 16 -bor 64 -bor 256 -bor 65536 -bor 262144 -bor 524288
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        try { $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
        catch {
            if ((([int]$rule.FileSystemRights) -band $writeMask) -ne 0) { throw "Transaction ACL contains an unresolved write-capable identity: $Path" }
            continue
        }
        if (($trustedOwners -notcontains $sid) -and ((([int]$rule.FileSystemRights) -band $writeMask) -ne 0)) { throw "Transaction path grants write-like access to an untrusted principal: $Path" }
    }
}

function Create-AesRestoreAnchor {
    param([string]$Anchor, [string]$Target)
    $hook = Get-AesMemberValue $script:AesTestBackend 'CreateRestoreAnchor'
    if ($null -ne $hook) { & $hook $Anchor $Target; return }
    (Get-AesNative)::CreateRestoreAnchor($Anchor, $Target)
}

function Grant-AesSystemDeleteUntilReboot {
    param([string]$Path)
    $hook = Get-AesMemberValue $script:AesTestBackend 'GrantSystemDeleteUntilReboot'
    if ($null -ne $hook) { return [string](& $hook $Path) }
    return (Get-AesNative)::GrantSystemDeleteUntilReboot($Path)
}

function Get-AesPaths {
    param([hashtable]$Environment)
    $root = [System.IO.Path]::GetFullPath($Environment.Root)
    return @{
        Root = $root
        BackupDirectory = Join-Path $root 'backup'
        StageDirectory = Join-Path $root 'stage'
        AnchorDirectory = Join-Path $root 'anchor'
        FinalizerDirectory = Join-Path $root 'finalizer'
        BackupFont = Join-Path $root 'backup\seguiemj.ttf'
        BackupMetadata = Join-Path $root 'backup\original.json'
        Journal = Join-Path $root 'journal.json'
        State = Join-Path $root 'state.json'
    }
}

function Test-AesOwnedPath {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    return $fullPath.StartsWith($fullRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Ensure-AesDirectories {
    param([hashtable]$Paths)
    foreach ($directory in @($Paths.Root, $Paths.BackupDirectory, $Paths.StageDirectory, $Paths.AnchorDirectory, $Paths.FinalizerDirectory)) {
        if (-not ([System.IO.Path]::GetFullPath($directory).Equals([System.IO.Path]::GetFullPath($Paths.Root), [StringComparison]::OrdinalIgnoreCase)) -and -not (Test-AesOwnedPath $directory $Paths.Root)) { throw "Unsafe transaction directory: $directory" }
        if (Test-Path -LiteralPath $directory) {
            # An existing directory is trusted only if it was already protected.
            # Do not bless a low-privilege pre-created directory by tightening it.
            Assert-AesTrustedPath $directory
        } else {
            [void][System.IO.Directory]::CreateDirectory($directory)
            Protect-AesTransactionDirectory $directory
        }
    }
    foreach ($file in @($Paths.BackupFont, $Paths.BackupMetadata, $Paths.Journal, $Paths.State)) {
        if (Test-Path -LiteralPath $file -PathType Leaf) { Assert-AesTrustedPath $file }
    }
}

function Read-AesJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return ConvertTo-AesHashtable (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path)) -ErrorAction Stop) }
    catch { return @{ __AesCorrupt = $true; __AesError = $_.Exception.Message } }
}

function Write-AesJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value, [Parameter(Mandatory = $true)][string]$Root)
    if (-not (Test-AesOwnedPath $Path $Root)) { throw "Refusing to write outside the transaction root: $Path" }
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { [void][System.IO.Directory]::CreateDirectory($directory) }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $previous = "$Path.$([guid]::NewGuid().ToString('N')).bak"
    try {
        [System.IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($temporary, $Path, $previous) }
        else { [System.IO.File]::Move($temporary, $Path) }
        Protect-AesTransactionFile $Path
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Force -ErrorAction SilentlyContinue }
    }
}

function Remove-AesOwnedFile {
    param([string]$Path, [hashtable]$Paths)
    if ((Test-AesOwnedPath $Path $Paths.Root) -and (Test-Path -LiteralPath $Path -PathType Leaf)) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
}

function Get-AesHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-AesFileSize {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return [int64]([System.IO.FileInfo]$Path).Length
}

function Invoke-AesCopy {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
    $copyHook = Get-AesMemberValue $script:AesTestBackend 'CopyFile'
    if ($null -ne $copyHook) { & $copyHook $Source $Destination; return }
    Copy-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
}

function Get-AesSecuritySddl {
    param([string]$Path)
    $hook = Get-AesMemberValue $script:AesTestBackend 'GetSecurity'
    if ($null -ne $hook) { return [string](& $hook $Path) }
    return (Get-AesNative)::GetFileSecuritySddl($Path)
}

function Set-AesSecuritySddl {
    param([string]$Path, [string]$Sddl)
    $hook = Get-AesMemberValue $script:AesTestBackend 'SetSecurity'
    if ($null -ne $hook) { & $hook $Path $Sddl; return }
    (Get-AesNative)::SetFileSecuritySddl($Path, $Sddl)
}

function Grant-AesTargetTemporaryAccess {
    param([string]$Path)
    $hook = Get-AesMemberValue $script:AesTestBackend 'GrantTemporaryAccess'
    if ($null -ne $hook) { return [string](& $hook $Path) }
    return (Get-AesNative)::GrantAdministratorsFullControlTemporarily($Path)
}

function Get-AesRegistrySnapshot {
    $hook = Get-AesMemberValue $script:AesTestBackend 'GetFontRegistry'
    if ($null -ne $hook) { return ConvertTo-AesHashtable (& $hook) }
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $key = Get-Item -LiteralPath $path -ErrorAction Stop
    $value = $key.GetValue($script:AesFontValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $kind = if ($null -eq $value) { $null } else { $key.GetValueKind($script:AesFontValueName).ToString() }
    return @{ Path = $path; Name = $script:AesFontValueName; Exists = ($null -ne $value); Value = $value; Kind = $kind }
}

function Get-AesSddlOwner {
    param([string]$Sddl)
    if ([string]::IsNullOrWhiteSpace($Sddl)) { return $null }
    $match = [regex]::Match($Sddl, '^O:(.*?)(?=(?:G:|D:|S:)|$)')
    if (-not $match.Success -or [string]::IsNullOrWhiteSpace($match.Groups[1].Value)) { return $null }
    return $match.Groups[1].Value
}

function Test-AesFontRegistryTarget {
    # Windows normally stores a bare font file name, but valid installations can
    # use a String/ExpandString value that resolves to the exact Fonts target.
    # Do not accept any other relative spelling, registry kind, or target.
    param([hashtable]$Environment, $Registry)
    $value = Get-AesMemberValue $Registry 'Value'
    $kind = [string](Get-AesMemberValue $Registry 'Kind')
    if (-not [bool](Get-AesMemberValue $Registry 'Exists' $false)) {
        return @{ Accepted = $false; Reason = 'The Segoe UI Emoji registry value is missing.'; Value = $null; Kind = $kind; ResolvedPath = $null }
    }
    if ($kind -notin @('String', 'ExpandString') -or $value -isnot [string]) {
        return @{ Accepted = $false; Reason = "The Segoe UI Emoji registry value has unsupported kind '$kind'."; Value = if ($null -eq $value) { $null } else { [string]$value }; Kind = $kind; ResolvedPath = $null }
    }
    $text = [string]$value
    if ($text.Equals('seguiemj.ttf', [StringComparison]::OrdinalIgnoreCase)) {
        return @{ Accepted = $true; Reason = ''; Value = $text; Kind = $kind; ResolvedPath = $Environment.TargetPath }
    }
    $candidate = if ($kind -eq 'ExpandString') { [Environment]::ExpandEnvironmentVariables($text) } else { $text }
    $fullyQualified = ($candidate -match '^[a-zA-Z]:[\\/]' -or $candidate -match '^\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$)')
    if (-not $fullyQualified) {
        return @{ Accepted = $false; Reason = 'The Segoe UI Emoji registry value is neither the bare file name nor a fully qualified drive or UNC path.'; Value = $text; Kind = $kind; ResolvedPath = $null }
    }
    try { $resolved = [System.IO.Path]::GetFullPath($candidate) }
    catch { return @{ Accepted = $false; Reason = 'The Segoe UI Emoji registry value is not a valid path.'; Value = $text; Kind = $kind; ResolvedPath = $null } }
    if (-not $resolved.Equals([System.IO.Path]::GetFullPath($Environment.TargetPath), [StringComparison]::OrdinalIgnoreCase)) {
        return @{ Accepted = $false; Reason = "The Segoe UI Emoji registry value resolves outside the system target: '$resolved'."; Value = $text; Kind = $kind; ResolvedPath = $resolved }
    }
    return @{ Accepted = $true; Reason = ''; Value = $text; Kind = $kind; ResolvedPath = $resolved }
}

function Get-AesMicrosoftSourceIdentity {
    param([hashtable]$Environment)
    $hook = Get-AesMemberValue $script:AesTestBackend 'GetMicrosoftSourceIdentity'
    if ($null -ne $hook) { return ConvertTo-AesHashtable (& $hook $Environment) }
    $hash = Get-AesHash $Environment.TargetPath
    $sddl = Get-AesSecuritySddl $Environment.TargetPath
    $registry = Get-AesRegistrySnapshot
    # The source is accepted only when the fixed Segoe UI Emoji mapping still
    # resolves to this protected system file and its owner is TrustedInstaller.
    # The exact bytes are then journaled as this machine/build's baseline.
    $owner = Get-AesSddlOwner $sddl
    $trustedInstaller = $owner -in @('TI', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $mapping = Test-AesFontRegistryTarget $Environment $registry
    # The pinned Apple release deliberately keeps the original file descriptor
    # when staged.  It must never become a new Windows-native baseline merely
    # because its copied descriptor and registry mapping look legitimate.
    $knownPinnedAppleOutput = ($hash -eq $script:AesExpectedAppleSourceHash)
    return @{ Accepted = ($hash -match '^[a-f0-9]{64}$' -and -not $knownPinnedAppleOutput -and $trustedInstaller -and [bool]$mapping.Accepted); Hash = $hash; Sddl = $sddl; Registry = $registry; OwnerTrustedInstaller = $trustedInstaller; FontOwner = $owner; MappingRetained = [bool]$mapping.Accepted; MappingReason = [string]$mapping.Reason; FontRegistryValue = $mapping.Value; FontRegistryKind = $mapping.Kind; FontRegistryResolvedPath = $mapping.ResolvedPath; KnownPinnedAppleOutput = $knownPinnedAppleOutput; Build = $Environment.Build; WindowsVersion = $Environment.WindowsVersion; KnownReferenceMatch = ($hash -eq $script:AesKnownLocalReferenceHash) }
}

function Get-AesPendingEntries {
    $hook = Get-AesMemberValue $script:AesTestBackend 'GetPendingEntries'
    if ($null -ne $hook) { return @(& $hook) }
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $key = Get-Item -LiteralPath $path -ErrorAction Stop
    $value = $key.GetValue('PendingFileRenameOperations', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($null -eq $value) { return @() }
    return @([string[]]$value)
}

function Set-AesPendingEntries {
    param([string[]]$Entries)
    $hook = Get-AesMemberValue $script:AesTestBackend 'SetPendingEntries'
    if ($null -ne $hook) { & $hook $Entries; return }
    # The registry provider's Get-Item handle can be read-only even when the
    # process is elevated. Open an explicitly writable handle for cancellation
    # and orphan cleanup; do not change the key's ACL or take ownership.
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager', $true)
    if ($null -eq $key) { throw 'The Session Manager registry key could not be opened for writing.' }
    try {
        if ($Entries.Count -eq 0) { $key.DeleteValue('PendingFileRenameOperations', $false) }
        else { $key.SetValue('PendingFileRenameOperations', [string[]]$Entries, [Microsoft.Win32.RegistryValueKind]::MultiString) }
    } finally { $key.Dispose() }
}

function ConvertFrom-AesPendingName {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    # MoveFileEx(..., MOVEFILE_DELAY_UNTIL_REBOOT | MOVEFILE_REPLACE_EXISTING)
    # is materialized by this Windows build as `*1\??\...` for the source
    # and `*1!\??\...` for the replacement destination.  The observed `*1`
    # marker is not part of the DOS path; its semantics are undocumented here.
    # Older/other entries can omit it, so normalize only this exact form.
    $name = $Value
    if ($name.StartsWith('*1')) { $name = $name.Substring(2) }
    if ($name.StartsWith('!')) { $name = $name.Substring(1) }
    if ($name.StartsWith('\??\')) { return $name.Substring(4) }
    return $name
}

function Test-AesPendingPair {
    param([string[]]$Entries, [string]$Source, [string]$Destination)
    $sourceFull = [System.IO.Path]::GetFullPath($Source)
    $destinationFull = [System.IO.Path]::GetFullPath($Destination)
    for ($index = 0; $index + 1 -lt $Entries.Count; $index += 2) {
        try {
            $candidateSource = [System.IO.Path]::GetFullPath((ConvertFrom-AesPendingName $Entries[$index]))
            $candidateDestination = [System.IO.Path]::GetFullPath((ConvertFrom-AesPendingName $Entries[$index + 1]))
            if ($candidateSource.Equals($sourceFull, [StringComparison]::OrdinalIgnoreCase) -and $candidateDestination.Equals($destinationFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        } catch { }
    }
    return $false
}

function Remove-AesPendingPair {
    param([string[]]$Entries, [string]$Source, [string]$Destination)
    $remaining = New-Object 'System.Collections.Generic.List[string]'
    $removed = $false
    $sourceFull = [System.IO.Path]::GetFullPath($Source)
    $destinationFull = [System.IO.Path]::GetFullPath($Destination)
    for ($index = 0; $index -lt $Entries.Count; $index += 2) {
        if ($index + 1 -ge $Entries.Count) { $remaining.Add($Entries[$index]); continue }
        $isMatch = $false
        try {
            $candidateSource = [System.IO.Path]::GetFullPath((ConvertFrom-AesPendingName $Entries[$index]))
            $candidateDestination = [System.IO.Path]::GetFullPath((ConvertFrom-AesPendingName $Entries[$index + 1]))
            $isMatch = $candidateSource.Equals($sourceFull, [StringComparison]::OrdinalIgnoreCase) -and $candidateDestination.Equals($destinationFull, [StringComparison]::OrdinalIgnoreCase)
        } catch { $isMatch = $false }
        if ($isMatch) { $removed = $true; continue }
        $remaining.Add($Entries[$index]); $remaining.Add($Entries[$index + 1])
    }
    return @{ Entries = @($remaining); Removed = $removed }
}

function Test-AesOrphanedStagePendingPair {
    param([string]$Source, [string]$Destination, [hashtable]$Paths, [hashtable]$Environment)
    try {
        $sourceFull = [System.IO.Path]::GetFullPath((ConvertFrom-AesPendingName $Source))
        $destinationFull = [System.IO.Path]::GetFullPath((ConvertFrom-AesPendingName $Destination))
        $stageDirectory = [System.IO.Path]::GetFullPath($Paths.StageDirectory).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        if (-not $destinationFull.Equals([System.IO.Path]::GetFullPath($Environment.TargetPath), [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if (-not (Split-Path -Parent $sourceFull).Equals($stageDirectory, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ((Split-Path -Leaf $sourceFull) -notmatch '^seguiemj\.[a-fA-F0-9]{32}\.ttf$') { return $false }
        return -not (Test-Path -LiteralPath $sourceFull -PathType Leaf)
    } catch { return $false }
}

function Clear-AesOrphanedStagePendingPairs {
    # A failed pre-verification queue can leave an already-dead MoveFileEx
    # pair behind only when a previous build could not recognize its `*1`
    # prefix.  Remove solely our own missing, UUID-named stage -> fixed target
    # pairs; preserve every byte of every other registry entry.
    param([hashtable]$Paths, [hashtable]$Environment)
    $entries = Get-AesPendingEntries
    $remaining = New-Object 'System.Collections.Generic.List[string]'
    $removed = 0
    for ($index = 0; $index -lt $entries.Count; $index += 2) {
        if ($index + 1 -ge $entries.Count) { $remaining.Add($entries[$index]); continue }
        if (Test-AesOrphanedStagePendingPair $entries[$index] $entries[$index + 1] $Paths $Environment) { $removed++; continue }
        $remaining.Add($entries[$index]); $remaining.Add($entries[$index + 1])
    }
    if ($removed -gt 0) { Set-AesPendingEntries ([string[]]$remaining) }
    return $removed
}

function Queue-AesReplace {
    param([string]$Source, [string]$Destination)
    $hook = Get-AesMemberValue $script:AesTestBackend 'QueueMove'
    if ($null -ne $hook) { & $hook $Source $Destination }
    else { (Get-AesNative)::QueueReplaceAtRestart($Source, $Destination) }
    if (-not (Test-AesPendingPair (Get-AesPendingEntries) $Source $Destination)) { throw 'The boot-time replacement could not be verified in PendingFileRenameOperations.' }
}

function Get-AesFinalizerTaskName {
    param([string]$OperationId)
    return "\AppleEmojiSwitcher-Finalize-$OperationId"
}

function Register-AesFinalizer {
    param([hashtable]$Paths, [hashtable]$Journal)
    $hook = Get-AesMemberValue $script:AesTestBackend 'RegisterFinalizer'
    if ($null -ne $hook) { return ConvertTo-AesHashtable (& $hook $Paths $Journal) }
    $scriptSource = Join-Path $PSScriptRoot 'Finalize-Transaction.ps1'
    $nativeSource = Join-Path $PSScriptRoot 'NativeTransaction.cs'
    if (-not (Test-Path -LiteralPath $scriptSource -PathType Leaf) -or -not (Test-Path -LiteralPath $nativeSource -PathType Leaf)) { throw 'Finalizer source files are missing.' }
    $scriptTarget = Join-Path $Paths.FinalizerDirectory ("Finalize-" + $Journal.operationId + '.ps1')
    $nativeTarget = Join-Path $Paths.FinalizerDirectory ("NativeTransaction-" + $Journal.operationId + '.cs')
    foreach ($path in @($scriptTarget, $nativeTarget)) { if (-not (Test-AesOwnedPath $path $Paths.Root) -or (Test-Path -LiteralPath $path)) { throw 'Unsafe or colliding finalizer file path.' } }
    $registeredByThisInvocation = $false
    $scheduleService = $null
    $rootFolder = $null
    $definition = $null; $action = $null; $registered = $null; $verified = $null; $verifiedDefinition = $null; $verifiedAction = $null; $verifiedTrigger = $null; $taskShortName = $null
    try {
        Invoke-AesCopy $scriptSource $scriptTarget; Invoke-AesCopy $nativeSource $nativeTarget
        Protect-AesTransactionFile $scriptTarget; Protect-AesTransactionFile $nativeTarget
        $scriptHash = Get-AesHash $scriptTarget; $nativeHash = Get-AesHash $nativeTarget
        if ($scriptHash -ne (Get-AesHash $scriptSource) -or $nativeHash -ne (Get-AesHash $nativeSource)) { throw 'Finalizer source copy hash verification failed.' }
        $taskName = Get-AesFinalizerTaskName $Journal.operationId
        $Journal.finalizerTaskName = $taskName; $Journal.finalizerScriptPath = $scriptTarget; $Journal.finalizerScriptHash = $scriptHash; $Journal.finalizerNativeSource = $nativeTarget; $Journal.finalizerNativeHash = $nativeHash
        # Persist and protect the invocation contract before registering an
        # ONSTART task.  A reboot cannot observe a task without its journal.
        Write-AesJson $Paths.Journal $Journal $Paths.Root
        $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $taskArguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptTarget + '" -Root "' + $Paths.Root + '" -OperationId "' + $Journal.operationId + '" -TaskName "' + $taskName + '"'
        # schtasks /TR has a 262-character command limit.  Task Scheduler COM
        # persists executable and arguments separately, so the long protected
        # ProgramData paths remain faithfully represented in the task XML.
        $scheduleService = New-Object -ComObject 'Schedule.Service'
        $scheduleService.Connect()
        $rootFolder = $scheduleService.GetFolder('\')
        $definition = $scheduleService.NewTask(0)
        $definition.RegistrationInfo.Description = 'AppleEmojiSwitcher one-shot font transaction finalizer.'
        $definition.Settings.Enabled = $true
        $definition.Settings.Hidden = $true
        $definition.Settings.StartWhenAvailable = $true
        $definition.Principal.UserId = 'SYSTEM'
        $definition.Principal.LogonType = 5 # TASK_LOGON_SERVICE_ACCOUNT
        $definition.Principal.RunLevel = 1  # TASK_RUNLEVEL_HIGHEST
        [void]$definition.Triggers.Create(8) # TASK_TRIGGER_BOOT
        $action = $definition.Actions.Create(0) # TASK_ACTION_EXEC
        $action.Path = $windowsPowerShell
        $action.Arguments = $taskArguments
        $taskShortName = $taskName.TrimStart('\')
        $registered = $rootFolder.RegisterTaskDefinition($taskShortName, $definition, 2, 'SYSTEM', $null, 5, $null) # TASK_CREATE only; never overwrite.
        $registeredByThisInvocation = $true
        $verified = $rootFolder.GetTask($taskShortName)
        $verifiedDefinition = $verified.Definition
        $verifiedAction = $verifiedDefinition.Actions.Item(1)
        $verifiedTrigger = $verifiedDefinition.Triggers.Item(1)
        $systemIds = @('SYSTEM', 'S-1-5-18', 'NT AUTHORITY\SYSTEM')
        if (-not $verified.Path.Equals($taskName, [StringComparison]::OrdinalIgnoreCase) -or $verifiedAction.Type -ne 0 -or -not $verifiedAction.Path.Equals($windowsPowerShell, [StringComparison]::OrdinalIgnoreCase) -or $verifiedAction.Arguments -ne $taskArguments -or $verifiedTrigger.Type -ne 8 -or $verifiedDefinition.Principal.LogonType -ne 5 -or $verifiedDefinition.Principal.RunLevel -ne 1 -or $systemIds -notcontains [string]$verifiedDefinition.Principal.UserId -or -not [bool]$verifiedDefinition.Settings.Hidden) { throw 'The registered startup finalizer does not match its required boot/SYSTEM/hidden action contract.' }
        return @{ TaskName = $taskName; ScriptPath = $scriptTarget; ScriptHash = $scriptHash; NativePath = $nativeTarget; NativeHash = $nativeHash }
    } catch {
        if ($registeredByThisInvocation -and $null -ne $rootFolder -and $taskShortName) { try { $rootFolder.DeleteTask($taskShortName, 0) } catch { } }
        foreach ($path in @($scriptTarget, $nativeTarget)) { try { Remove-AesOwnedFile $path $Paths } catch { } }
        throw
    } finally {
        foreach ($comObject in @($registered, $verified, $verifiedDefinition, $verifiedAction, $verifiedTrigger, $action, $definition, $rootFolder, $scheduleService)) {
            if ($null -ne $comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) }
        }
    }
}

function Remove-AesFinalizer {
    param([hashtable]$Paths, $Journal)
    $taskName = [string](Get-AesMemberValue $Journal 'finalizerTaskName')
    if ($taskName -and $taskName -notmatch '^\\AppleEmojiSwitcher-Finalize-[a-f0-9]{32}$') { throw 'Refusing to delete a task not owned by AppleEmojiSwitcher.' }
    $hook = Get-AesMemberValue $script:AesTestBackend 'RemoveFinalizer'
    if ($null -ne $hook) { & $hook $taskName }
    elseif ($taskName) { & schtasks.exe /Delete /TN $taskName /F 2>$null | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'Could not remove the transaction startup finalizer.' } }
    foreach ($name in @('finalizerScriptPath', 'finalizerNativeSource')) {
        $path = [string](Get-AesMemberValue $Journal $name)
        if ($path) { Remove-AesOwnedFile $path $Paths }
    }
}

function New-AesRestoreAnchor {
    param([hashtable]$Paths, [hashtable]$Environment, [hashtable]$Metadata, [hashtable]$Journal)
    $anchor = Join-Path $Paths.AnchorDirectory ("old-inode-" + $Journal.operationId + '.ttf')
    if (-not (Test-AesOwnedPath $anchor $Paths.Root) -or (Test-Path -LiteralPath $anchor)) { throw 'Unsafe or colliding restore-anchor path.' }
    if ([System.IO.Path]::GetPathRoot($anchor) -ne [System.IO.Path]::GetPathRoot($Environment.TargetPath)) { throw 'ProgramData and the system font are on different volumes; a safe inode restore anchor cannot be created.' }
    # The anchor deliberately shares the original file SDDL.  Its protected
    # parent grants Administrators DeleteChild, which is how cancellation and
    # the SYSTEM finalizer remove it without weakening the shared inode ACL.
    $Journal.anchorPath = $anchor; $Journal.originalSddl = [string]$Metadata.originalSddl; $Journal.anchorCreating = $true
    Write-AesJson $Paths.Journal $Journal $Paths.Root
    try { Create-AesRestoreAnchor $anchor $Environment.TargetPath }
    catch {
        # Hard-link creation can require source access even when backup copying
        # did not.  This temporary Administrators grant is restored immediately.
        $original = Grant-AesTargetTemporaryAccess $Environment.TargetPath
        try {
            if ($original -ne $Metadata.originalSddl) { throw 'Target SDDL drifted before restore-anchor creation.' }
            Create-AesRestoreAnchor $anchor $Environment.TargetPath
        } finally { Set-AesSecuritySddl $Environment.TargetPath ([string]$Metadata.originalSddl) }
    }
    if ((Get-AesHash $anchor) -ne (Get-AesHash $Environment.TargetPath)) { throw 'Restore anchor byte verification failed.' }
    $Journal.anchorCreating = $false; Write-AesJson $Paths.Journal $Journal $Paths.Root
}

function Prepare-AesBootReplacement {
    param([hashtable]$Paths, [hashtable]$Environment, [hashtable]$Metadata, [hashtable]$Journal, [hashtable]$Context)
    New-AesRestoreAnchor $Paths $Environment $Metadata $Journal
    $finalizer = Register-AesFinalizer $Paths $Journal
    $Journal.finalizerTaskName = $finalizer.TaskName; $Journal.finalizerScriptPath = $finalizer.ScriptPath; $Journal.finalizerScriptHash = $finalizer.ScriptHash; $Journal.finalizerNativeSource = $finalizer.NativePath; $Journal.finalizerNativeHash = $finalizer.NativeHash
    Write-AesJson $Paths.Journal $Journal $Paths.Root
    # The target can be a WinSxS hard link.  Retain only a SYSTEM Delete ACE on
    # that old inode until boot; the anchor lets the SYSTEM finalizer restore its
    # exact original SDDL after the target link is replaced.
    $Journal.targetSecurityChanged = $true; $Journal.permissionLifecycle = 'SystemDeleteUntilBoot'; Write-AesJson $Paths.Journal $Journal $Paths.Root
    $Context.targetSecurityChanged = $true; $Context.queueAttempted = $true
    $returnedSddl = Grant-AesSystemDeleteUntilReboot $Environment.TargetPath
    if ($returnedSddl -ne $Metadata.originalSddl) { throw 'Target SDDL drifted before SYSTEM Delete grant.' }
    Queue-AesReplace $Journal.stagePath $Environment.TargetPath
    $Context.queued = $true
}

function Read-AesCoverageReport {
    param([string]$Path, [string]$FontPath, [string]$CurrentWindowsHash)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Coverage report does not exist.' }
    $coverage = Read-AesJson $Path
    if ($null -eq $coverage -or [bool](Get-AesMemberValue $coverage '__AesCorrupt' $false)) { throw 'Coverage report is not valid JSON.' }
    if ([int](Get-AesMemberValue $coverage 'schemaVersion' 0) -ne 1) { throw 'Coverage report schemaVersion must be 1.' }
    $coverageStatus = [string](Get-AesMemberValue $coverage 'status')
    if ($coverageStatus -notin @('passed', 'passed_with_warnings')) { throw 'Coverage report status is neither passed nor passed_with_warnings.' }
    $appleHash = [string](Get-AesMemberValue $coverage 'sourceAppleSha256')
    $windowsHash = [string](Get-AesMemberValue $coverage 'sourceWindowsSha256')
    $outputHash = [string](Get-AesMemberValue $coverage 'outputSha256')
    foreach ($hash in @($appleHash, $windowsHash, $outputHash)) { if ($hash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Coverage report contains an invalid SHA-256 value.' } }
    $checks = Get-AesMemberValue $coverage 'checks'
    if ($null -eq $checks) { throw 'Coverage report does not contain check details.' }
    if ($appleHash.ToLowerInvariant() -ne $script:AesExpectedAppleSourceHash) { throw 'Coverage report was not built from the approved Apple source asset.' }
    # Structural and sequence correctness are hard gates.  The two local
    # rendering probes may report platform-specific display differences, but
    # only under the versioned compatibility policy and an explicit warning
    # report; a failed or omitted probe is never accepted.
    foreach ($checkName in @('sequenceRegression', 'fontStructure', 'textPresentation', 'indexedMetrics')) {
        if ([string](Get-AesMemberValue $checks $checkName) -ne 'passed') { throw "Coverage report check '$checkName' is missing or not passed." }
    }
    $nativeWarnings = $false
    foreach ($checkName in @('nativeSequenceRegression', 'nativeRenderSmoke')) {
        $checkStatus = [string](Get-AesMemberValue $checks $checkName)
        if ($checkStatus -notin @('passed', 'warning')) { throw "Coverage report check '$checkName' is missing, failed, or invalid." }
        if ($checkStatus -eq 'warning') { $nativeWarnings = $true }
    }
    $compatibilityPolicy = [string](Get-AesMemberValue $coverage 'compatibilityPolicy')
    # Do not retrieve the array through the generic helper: PowerShell emits a
    # one-item array as a scalar from a function pipeline.  Retain the stored
    # value so a real one-item JSON warnings array stays an array.
    $warnings = $null
    if ($coverage -is [System.Collections.IDictionary] -and $coverage.Contains('warnings')) { $warnings = $coverage['warnings'] }
    if ($coverageStatus -eq 'passed_with_warnings') {
        if ($compatibilityPolicy -ne 'warn-on-local-display-differences-v1') { throw 'Coverage report warning status lacks the approved compatibility policy.' }
        if ($null -eq $warnings -or $warnings -is [string] -or -not ($warnings -is [System.Collections.IEnumerable]) -or @($warnings).Count -lt 1) { throw 'Coverage report warning status lacks a non-empty warnings array.' }
    }
    if ($nativeWarnings -and $coverageStatus -ne 'passed_with_warnings') { throw 'Coverage report local-display warnings require passed_with_warnings status.' }
    if ($windowsHash.ToLowerInvariant() -ne $CurrentWindowsHash) { throw 'Installed Windows emoji font does not match the coverage report input.' }
    if ($outputHash.ToLowerInvariant() -ne (Get-AesHash $FontPath)) { throw 'Selected font does not match the coverage report output hash.' }
    return $coverage
}

function Test-AesBackupMetadata {
    param([hashtable]$Paths, [hashtable]$Environment)
    $metadata = Read-AesJson $Paths.BackupMetadata
    $fontExists = Test-Path -LiteralPath $Paths.BackupFont -PathType Leaf
    if ($null -eq $metadata -and -not $fontExists) { return @{ Exists = $false; Valid = $false; Metadata = $null; Reason = '' } }
    if ($null -eq $metadata -or [bool](Get-AesMemberValue $metadata '__AesCorrupt' $false) -or -not $fontExists) { return @{ Exists = $true; Valid = $false; Metadata = $metadata; Reason = 'Backup metadata or bytes are missing/corrupt.' } }
    $originalHash = [string](Get-AesMemberValue $metadata 'originalHash')
    if ([int](Get-AesMemberValue $metadata 'schemaVersion' 0) -ne 1 -or $originalHash -notmatch '^[a-fA-F0-9]{64}$') { return @{ Exists = $true; Valid = $false; Metadata = $metadata; Reason = 'Backup metadata does not contain a valid source hash.' } }
    if ((Get-AesHash $Paths.BackupFont) -ne $originalHash.ToLowerInvariant()) { return @{ Exists = $true; Valid = $false; Metadata = $metadata; Reason = 'Backup font bytes do not match its recorded original.' } }
    if ([string](Get-AesMemberValue $metadata 'originalSddl') -eq '' -or $null -eq (Get-AesMemberValue $metadata 'fontRegistry')) { return @{ Exists = $true; Valid = $false; Metadata = $metadata; Reason = 'Backup security or registry snapshot is incomplete.' } }
    return @{ Exists = $true; Valid = $true; Metadata = $metadata; Reason = '' }
}

function Get-AesInstallationMode {
    # Version 1 transaction records predate InstallationMode.  Their output
    # hashes remain authoritative: only the exact pinned release is Pinned;
    # every other recorded replacement is the verified built font.
    param($Record, [string]$FallbackHash = '', [string]$Status = '')
    $declared = [string](Get-AesMemberValue $Record 'installationMode')
    if ($declared -in @('Original', 'Built', 'Pinned', 'Unknown')) { return $declared }
    if ($Status -in @('Original', 'OriginalWithBackup')) { return 'Original' }
    $hash = $FallbackHash
    if ($hash -notmatch '^[a-fA-F0-9]{64}$') {
        foreach ($name in @('installedOutputHash', 'pendingOutputHash', 'outputHash')) {
            $candidate = [string](Get-AesMemberValue $Record $name)
            if ($candidate -match '^[a-fA-F0-9]{64}$') { $hash = $candidate; break }
        }
    }
    if ($hash -match '^[a-fA-F0-9]{64}$') {
        if ($hash.ToLowerInvariant() -eq $script:AesExpectedAppleSourceHash) { return 'Pinned' }
        return 'Built'
    }
    return 'Unknown'
}

function Test-AesPinnedAppleAsset {
    param([Parameter(Mandatory = $true)][string]$Path)
    $size = Get-AesFileSize $Path
    if ($size -ne $script:AesExpectedAppleSourceSize) {
        throw "Pinned Apple font has an unexpected size ($size bytes)."
    }
    $hash = Get-AesHash $Path
    if ($hash -ne $script:AesExpectedAppleSourceHash) {
        throw 'Pinned Apple font does not match the approved release SHA-256.'
    }
    return $hash
}

function Test-AesFinalizerRegistered {
    param([string]$TaskName)
    if ([string]::IsNullOrWhiteSpace($TaskName)) { return $false }
    if ($TaskName -notmatch '^\\AppleEmojiSwitcher-Finalize-[a-f0-9]{32}$') { return $true }
    $hook = Get-AesMemberValue $script:AesTestBackend 'IsFinalizerRegistered'
    if ($null -ne $hook) { return [bool](& $hook $TaskName) }
    # Query the scheduler directly: in Windows PowerShell 5.1, schtasks stderr
    # becomes a terminating error under ErrorActionPreference=Stop even when
    # redirected. Only a missing task means completed cleanup; access/service
    # errors must remain verification failures.
    $service = $null; $folder = $null; $task = $null
    try {
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $folder = $service.GetFolder('\')
        try { $task = $folder.GetTask($TaskName); return $true }
        catch {
            $errorItem = $_.Exception
            while ($null -ne $errorItem) {
                if ($errorItem.HResult -eq -2147024894) { return $false } # HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)
                $errorItem = $errorItem.InnerException
            }
            throw
        }
    } finally {
        foreach ($comObject in @($task, $folder, $service)) {
            if ($null -ne $comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject)
            }
        }
    }
}

function New-AesBaseState {
    param([hashtable]$Environment, [string]$Status = 'Unknown', [string]$Reason = '')
    $support = Test-AesSupported $Environment
    $paths = Get-AesPaths $Environment
    $currentHash = Get-AesHash $Environment.TargetPath
    $backup = Test-AesBackupMetadata $paths $Environment
    return @{
        Supported = [bool]$support.Supported; Reason = if ($Reason) { $Reason } elseif (-not $support.Supported) { $support.Reason } else { '' }
        WindowsVersion = $Environment.WindowsVersion; Build = $Environment.Build; Architecture = $Environment.Architecture; IsElevated = $Environment.IsElevated
        Status = $Status; CurrentFont = $Environment.TargetPath; CurrentHash = $currentHash
        OriginalFont = if ($backup.Exists) { $paths.BackupFont } else { $Environment.TargetPath }
        BackupExists = [bool]$backup.Exists; BackupPath = if ($backup.Exists) { $paths.BackupFont } else { $null }
        InstallationMode = 'Unknown'; RenderVerificationPending = $false; RestartRequired = $false; Operation = $null; Message = $Reason
        DiagnosticCode = $null; OriginalHash = $null; RecordedOutputHash = $null; FontRegistryValue = $null; FontOwner = $null
        VerificationPassed = $false; VerificationReason = ''
    }
}

function Set-AesStateIdentityEvidence {
    param([hashtable]$State, $Identity)
    if ($null -eq $Identity) { return }
    $State.FontRegistryValue = Get-AesMemberValue $Identity 'FontRegistryValue'
    if ($null -eq $State.FontRegistryValue) {
        $registry = Get-AesMemberValue $Identity 'Registry'
        $State.FontRegistryValue = Get-AesMemberValue $registry 'Value'
    }
    $State.FontOwner = Get-AesMemberValue $Identity 'FontOwner'
}

function Set-AesExternalDriftDiagnostics {
    param(
        [hashtable]$State,
        $BackupInfo,
        [string]$OriginalHash,
        [string]$RecordedOutputHash,
        $Identity,
        [string]$IdentityError = ''
    )
    $State.Status = 'ExternalDrift'
    $State.OriginalHash = $OriginalHash
    $State.RecordedOutputHash = $RecordedOutputHash
    Set-AesStateIdentityEvidence $State $Identity
    $currentHash = [string]$State.CurrentHash
    if ($currentHash -notmatch '^[a-f0-9]{64}$') {
        $State.DiagnosticCode = 'FontMissing'
        $State.Reason = "The Segoe UI Emoji target '$($State.CurrentFont)' is missing or unreadable; no SHA-256 can be compared."
        return
    }
    if ([bool](Get-AesMemberValue $BackupInfo 'Valid' $false)) {
        if ($RecordedOutputHash -match '^[a-fA-F0-9]{64}$') {
            $State.DiagnosticCode = 'FontBytesChanged'
            $State.Reason = "Current font SHA-256 '$currentHash' differs from verified original backup '$OriginalHash' and recorded transaction output '$RecordedOutputHash'."
        } else {
            $State.DiagnosticCode = 'MissingInstallRecord'
            $State.Reason = "Current font SHA-256 '$currentHash' differs from verified original backup '$OriginalHash', and state.json has no valid installed output hash."
        }
        return
    }
    if ([bool](Get-AesMemberValue $Identity 'KnownPinnedAppleOutput' $false) -or $currentHash -eq $script:AesExpectedAppleSourceHash -or ($RecordedOutputHash -match '^[a-fA-F0-9]{64}$' -and $currentHash -eq $RecordedOutputHash.ToLowerInvariant())) {
        $State.DiagnosticCode = 'MissingOriginalBackup'
        $State.Reason = "Current font SHA-256 '$currentHash' is a known or recorded replacement, but no verified original backup exists."
        return
    }
    if ($null -ne $Identity) {
        if (-not [bool](Get-AesMemberValue $Identity 'OwnerTrustedInstaller' $false)) {
            $State.DiagnosticCode = 'NativeOwnerUnrecognized'
            $owner = [string](Get-AesMemberValue $Identity 'FontOwner')
            $State.Reason = "Current font SHA-256 '$currentHash' has owner '$owner', not TrustedInstaller; no verified original backup or output record exists."
            return
        }
        if (-not [bool](Get-AesMemberValue $Identity 'MappingRetained' $false)) {
            $State.DiagnosticCode = 'NativeRegistrationMismatch'
            $mappingReason = [string](Get-AesMemberValue $Identity 'MappingReason')
            $State.Reason = "Current font SHA-256 '$currentHash' cannot establish a native baseline: $mappingReason"
            return
        }
    }
    $State.DiagnosticCode = 'MissingOriginalBackup'
    $suffix = if ($IdentityError) { " Source identity inspection failed: $IdentityError" } else { '' }
    $State.Reason = "Current font SHA-256 '$currentHash' has no verified original backup or recorded output.$suffix"
}

function Get-AesSystemState {
    [CmdletBinding()]
    param()
    try {
        $environment = Get-AesEnvironment
        $state = New-AesBaseState $environment
        if (-not $state.Supported) { $state.Status = 'Unsupported'; return $state }
        $paths = Get-AesPaths $environment
        $journal = Read-AesJson $paths.Journal
        $persistent = Read-AesJson $paths.State
        $backupInfo = Test-AesBackupMetadata $paths $environment
        $originalHash = if ($backupInfo.Valid) { [string](Get-AesMemberValue $backupInfo.Metadata 'originalHash') } else { $null }
        $outputHash = [string](Get-AesMemberValue $persistent 'installedOutputHash')
        if (-not $outputHash) { $outputHash = [string](Get-AesMemberValue $persistent 'outputHash') }
        $state.OriginalHash = $originalHash
        $state.RecordedOutputHash = $outputHash
        $identity = $null
        $identityError = ''
        if ($null -ne $journal -and -not [bool](Get-AesMemberValue $journal '__AesCorrupt' $false)) {
            $stage = [string](Get-AesMemberValue $journal 'stagePath')
            $target = [string](Get-AesMemberValue $journal 'targetPath')
            if ($stage -and $target -and (Test-AesOwnedPath $stage $paths.Root) -and $target.Equals($environment.TargetPath, [StringComparison]::OrdinalIgnoreCase) -and (Test-AesPendingPair (Get-AesPendingEntries) $stage $target)) {
                $state.Status = [string](Get-AesMemberValue $journal 'status' 'PendingInstall')
                $state.RestartRequired = $true
                $state.Operation = [string](Get-AesMemberValue $journal 'operation')
                $state.InstallationMode = Get-AesInstallationMode $journal '' $state.Status
                return $state
            }
            $queuedOutput = [string](Get-AesMemberValue $journal 'pendingOutputHash')
            if (-not $queuedOutput) { $queuedOutput = [string](Get-AesMemberValue $journal 'outputHash') }
            if ($queuedOutput -match '^[a-fA-F0-9]{64}$' -and $state.CurrentHash -eq $queuedOutput.ToLowerInvariant()) {
                if ([string](Get-AesMemberValue $journal 'operation') -eq 'Restore') {
                    $state.Status = 'Original'; $state.Reason = 'Restored font bytes were verified after restart.'; $state.InstallationMode = 'Original'
                } else {
                    $state.Status = 'Installed'; $state.Reason = 'Replacement font bytes were verified after restart.'
                    $state.InstallationMode = Get-AesInstallationMode $journal $queuedOutput 'Installed'
                    $state.RenderVerificationPending = ($state.InstallationMode -eq 'Built')
                }
                return $state
            }
            if ($originalHash -and $state.CurrentHash -eq $originalHash.ToLowerInvariant()) { $state.Status = 'NotApplied'; $state.Reason = 'The queued operation was not applied at restart.'; $state.InstallationMode = 'Original'; return $state }
            $state.Status = 'InterruptedTransaction'; $state.Reason = 'Transaction journal exists but its exact boot operation is not queued.'; return $state
        }
        if ($null -ne $journal -and [bool](Get-AesMemberValue $journal '__AesCorrupt' $false)) { $state.Status = 'InterruptedTransaction'; $state.Reason = 'Transaction journal is corrupt.'; return $state }
        if ($state.BackupExists -and -not $backupInfo.Valid) { $state.Status = 'BackupCorrupt'; $state.Reason = $backupInfo.Reason; return $state }
        if (-not $originalHash -and -not $state.BackupExists) {
            # A copied replacement can retain the original file descriptor and
            # registry mapping.  Do not let a known/raw Apple file, or a font
            # already recorded as tool output, become a new native baseline
            # merely because ProgramData was removed.
            $knownRecordedOutput = ($outputHash -match '^[a-fA-F0-9]{64}$' -and $state.CurrentHash -eq $outputHash.ToLowerInvariant())
            if ($state.CurrentHash -ne $script:AesExpectedAppleSourceHash -and -not $knownRecordedOutput) {
                try {
                    $identity = Get-AesMicrosoftSourceIdentity $environment
                    Set-AesStateIdentityEvidence $state $identity
                    if ([bool]$identity.Accepted) { $originalHash = [string]$identity.Hash; $state.OriginalHash = $originalHash }
                } catch { $identityError = $_.Exception.Message }
            }
        }
        if ($originalHash -and $state.CurrentHash -eq $originalHash.ToLowerInvariant()) { $state.Status = if ($state.BackupExists) { 'OriginalWithBackup' } else { 'Original' }; $state.InstallationMode = 'Original'; return $state }
        if ($state.BackupExists -and $outputHash -match '^[a-fA-F0-9]{64}$' -and $state.CurrentHash -eq $outputHash.ToLowerInvariant()) {
            $state.Status = 'Installed'; $state.InstallationMode = Get-AesInstallationMode $persistent $outputHash 'Installed'; $state.RenderVerificationPending = ($state.InstallationMode -eq 'Built'); return $state
        }
        if ($null -eq $identity) {
            try { $identity = Get-AesMicrosoftSourceIdentity $environment }
            catch { $identityError = $_.Exception.Message }
        }
        Set-AesExternalDriftDiagnostics $state $backupInfo $originalHash $outputHash $identity $identityError
        return $state
    } catch {
        return @{ Supported = $false; Reason = $_.Exception.Message; WindowsVersion = $null; Build = $null; Architecture = $null; IsElevated = $false; Status = 'Error'; CurrentFont = $null; CurrentHash = $null; OriginalFont = $null; BackupExists = $false; BackupPath = $null; InstallationMode = 'Unknown'; RenderVerificationPending = $false; RestartRequired = $false; Operation = $null; Message = $_.Exception.Message; VerificationPassed = $false; VerificationReason = $_.Exception.Message }
    }
}

function Invoke-AesLocked {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)
    $mutex = $null; $owned = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, $script:AesMutexName)
        try { $owned = $mutex.WaitOne([TimeSpan]::FromSeconds(15)) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Another AppleEmojiSwitcher transaction is in progress.' }
        return & $Action
    } finally {
        if ($owned -and $null -ne $mutex) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

function Get-AesMutationFailure {
    param([hashtable]$Environment)
    $support = Test-AesSupported $Environment
    if (-not $support.Supported) { return $support.Reason }
    if (-not $Environment.IsElevated) { return 'Administrator elevation is required for a system transaction.' }
    return $null
}

function New-AesBackup {
    param([hashtable]$Paths, [hashtable]$Environment, [hashtable]$Journal, [hashtable]$SourceIdentity)
    if ((Test-Path -LiteralPath $Paths.BackupFont) -or (Test-Path -LiteralPath $Paths.BackupMetadata)) { throw 'A backup already exists and will not be overwritten.' }
    if (-not [bool]$SourceIdentity.Accepted) { throw 'The current Segoe UI Emoji source is not a verified Microsoft/TrustedInstaller baseline.' }
    $originalHash = [string]$SourceIdentity.Hash
    $originalSddl = [string]$SourceIdentity.Sddl
    $registry = $SourceIdentity.Registry
    $Journal.originalHash = $originalHash; $Journal.originalSddl = $originalSddl; $Journal.fontRegistry = $registry; $Journal.status = 'BackingUp'
    Write-AesJson $Paths.Journal $Journal $Paths.Root
    try { Invoke-AesCopy $Environment.TargetPath $Paths.BackupFont }
    catch {
        $Journal.targetSecurityChanged = $true; Write-AesJson $Paths.Journal $Journal $Paths.Root
        try {
            $grantedOriginal = Grant-AesTargetTemporaryAccess $Environment.TargetPath
            if ($grantedOriginal -ne $originalSddl) { throw 'Target security changed before backup and no longer matches the captured descriptor.' }
            Invoke-AesCopy $Environment.TargetPath $Paths.BackupFont
        } finally {
            Set-AesSecuritySddl $Environment.TargetPath $originalSddl
            $Journal.targetSecurityChanged = $false; Write-AesJson $Paths.Journal $Journal $Paths.Root
        }
    }
    if ((Get-AesHash $Paths.BackupFont) -ne $originalHash) { throw 'Backup byte verification failed.' }
    $metadata = @{ schemaVersion = 1; originalHash = $originalHash; originalSddl = $originalSddl; originalOwnerAndAclSddl = $originalSddl; fontRegistry = $registry; targetPath = $Environment.TargetPath; build = $Environment.Build; windowsVersion = $Environment.WindowsVersion; sourceIdentity = $SourceIdentity; createdUtc = [DateTime]::UtcNow.ToString('o'); operationId = $Journal.operationId }
    Write-AesJson $Paths.BackupMetadata $metadata $Paths.Root
    return $metadata
}

function New-AesStageFont {
    param([string]$Source, [hashtable]$Paths, [hashtable]$Metadata, [hashtable]$Journal)
    $stage = Join-Path $Paths.StageDirectory ("seguiemj." + $Journal.operationId + '.ttf')
    if (-not (Test-AesOwnedPath $stage $Paths.Root) -or (Test-Path -LiteralPath $stage)) { throw 'Unsafe or colliding staging path.' }
    $approvedHash = [string](Get-AesMemberValue $Journal 'pendingOutputHash')
    if (-not $approvedHash) { $approvedHash = [string](Get-AesMemberValue $Journal 'outputHash') }
    if ($approvedHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Transaction journal does not contain an approved staged-font hash.' }
    $approvedHash = $approvedHash.ToLowerInvariant()
    try {
        Invoke-AesCopy $Source $stage
        # The candidate was approved before this transaction began.  Comparing
        # only stage and source here would accept a source file that changed
        # during copying, so always bind the staged bytes to the journaled hash.
        if ((Get-AesHash $stage) -ne $approvedHash) { throw 'Staged font bytes no longer match the approved transaction hash.' }
        # The boot-time moved file inherits this original descriptor.  Its
        # stage parent gives SYSTEM DeleteChild, so Session Manager can consume
        # the source even when this descriptor itself lacks DELETE.
        Set-AesSecuritySddl $stage ([string]$Metadata.originalSddl)
        $Journal.stagePath = $stage; Write-AesJson $Paths.Journal $Journal $Paths.Root
        return $stage
    } catch { Remove-AesOwnedFile $stage $Paths; throw }
}

function Invoke-AesInstallRollback {
    param([hashtable]$Context, [hashtable]$Paths, [hashtable]$Environment)
    $safeToRemove = $true
    if ($Context.queueAttempted -and $Context.stagePath) {
        try {
            $remove = Remove-AesPendingPair (Get-AesPendingEntries) $Context.stagePath $Environment.TargetPath
            if ($remove.Removed) { Set-AesPendingEntries ([string[]]$remove.Entries) }
            if (Test-AesPendingPair (Get-AesPendingEntries) $Context.stagePath $Environment.TargetPath) { $safeToRemove = $false }
        } catch { $safeToRemove = $false }
    }
    if ($Context.targetSecurityChanged -and $Context.originalSddl) {
        try { Set-AesSecuritySddl $Environment.TargetPath $Context.originalSddl } catch { $safeToRemove = $false }
    }
    $anchorForRollback = [string]$Context.anchorPath
    if (-not $anchorForRollback -and $Context.journal) { $anchorForRollback = [string](Get-AesMemberValue $Context.journal 'anchorPath') }
    if ($safeToRemove -and $Context.ownsJournal -and $Context.journal) { try { Remove-AesFinalizer $Paths $Context.journal } catch { $safeToRemove = $false } }
    if ($safeToRemove -and $Context.stagePath) { try { Remove-AesOwnedFile $Context.stagePath $Paths } catch { } }
    if ($safeToRemove -and $anchorForRollback) { try { Remove-AesOwnedFile $anchorForRollback $Paths } catch { } }
    if ($safeToRemove -and $Context.createdBackup) {
        try { Remove-AesOwnedFile $Paths.BackupFont $Paths; Remove-AesOwnedFile $Paths.BackupMetadata $Paths } catch { }
    }
    if ($safeToRemove) {
        if ($Context.ownsJournal) { try { Remove-AesOwnedFile $Paths.Journal $Paths } catch { } }
        if ($Context.wroteState) { try { Remove-AesOwnedFile $Paths.State $Paths } catch { } }
    }
}

function Install-AesFont {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FontPath,
        [Parameter(ParameterSetName = 'Built', Mandatory = $true)][string]$ReportPath,
        [Parameter(ParameterSetName = 'Pinned', Mandatory = $true)][switch]$PinnedApple
    )
    # $PSCmdlet is not reliably retained through the mutex callback's dynamic
    # scope on Windows PowerShell 5.1.  Capture the selected set before it.
    $requestedParameterSet = $PSCmdlet.ParameterSetName
    return Invoke-AesLocked {
        $environment = Get-AesEnvironment; $paths = Get-AesPaths $environment
        $failure = Get-AesMutationFailure $environment
        if ($failure) { $result = New-AesBaseState $environment 'Denied' $failure; return $result }
        $context = @{ queued = $false; queueAttempted = $false; createdBackup = $false; stagePath = $null; anchorPath = $null; targetSecurityChanged = $false; originalSddl = $null; journal = $null; ownsJournal = $false; wroteState = $false }
        try {
            $source = [System.IO.Path]::GetFullPath($FontPath)
            if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or [System.IO.Path]::GetExtension($source).ToLowerInvariant() -ne '.ttf') { throw 'FontPath must name an existing .ttf file.' }
            if ($source.Equals($environment.TargetPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'The replacement font cannot be the system target.' }
            $currentHash = Get-AesHash $environment.TargetPath
            $installationMode = if ($requestedParameterSet -eq 'Pinned') { 'Pinned' } else { 'Built' }
            # Pinned mode never takes a caller-supplied report as authority.  It
            # accepts exactly one release byte stream, before any backup, queue,
            # ACL, or transaction-directory mutation is attempted.
            $sourceHash = if ($installationMode -eq 'Pinned') { Test-AesPinnedAppleAsset $source } else { Get-AesHash $source }
            Ensure-AesDirectories $paths
            [void](Clear-AesOrphanedStagePendingPairs $paths $environment)
            $existing = Test-AesBackupMetadata $paths $environment
            $persistent = Read-AesJson $paths.State
            $metadata = $null
            if ($existing.Exists) {
                if (-not $existing.Valid) { throw 'Existing backup is corrupt or belongs to another build; it will not be overwritten.' }
                $metadata = $existing.Metadata
                $oldJournal = Read-AesJson $paths.Journal
                if ($null -ne $oldJournal -and -not [bool](Get-AesMemberValue $oldJournal '__AesCorrupt' $false) -and (Test-AesPendingPair (Get-AesPendingEntries) (Get-AesMemberValue $oldJournal 'stagePath') (Get-AesMemberValue $oldJournal 'targetPath'))) { return (Get-AesSystemState) }
                $knownState = Get-AesSystemState
                # Do not queue or overwrite a second tool-mode font.  Changing
                # between Built and Pinned is intentionally a restore/reboot
                # boundary so the verified original remains the only crossover.
                if ($knownState.Status -eq 'Installed') { return $knownState }
                if ($currentHash -ne ([string]$metadata.originalHash).ToLowerInvariant()) { throw 'External font drift was detected; install will not overwrite it.' }
                $oldAnchor = [string](Get-AesMemberValue $oldJournal 'anchorPath')
                if ($oldAnchor -and (Test-Path -LiteralPath $oldAnchor -PathType Leaf)) { throw 'A previous boot finalizer has not restored its anchor yet.' }
            } else {
                $recordedOutputHash = [string](Get-AesMemberValue $persistent 'installedOutputHash')
                if (-not $recordedOutputHash) { $recordedOutputHash = [string](Get-AesMemberValue $persistent 'outputHash') }
                if ($currentHash -eq $script:AesExpectedAppleSourceHash -or ($recordedOutputHash -match '^[a-fA-F0-9]{64}$' -and $currentHash -eq $recordedOutputHash.ToLowerInvariant())) {
                    throw 'A replacement font is present but no verified original backup exists; install will not treat it as a native baseline.'
                }
                $identity = Get-AesMicrosoftSourceIdentity $environment
                if (-not [bool]$identity.Accepted) { throw 'The current Segoe UI Emoji source is not a verified Microsoft/TrustedInstaller baseline.' }
                if ($currentHash -ne [string]$identity.Hash) { throw 'The current target changed during baseline inspection.' }
            }
            if ($installationMode -eq 'Built') { [void](Read-AesCoverageReport $ReportPath $source $currentHash) }
            $operationId = [guid]::NewGuid().ToString('N')
            $journal = @{ schemaVersion = 1; operationId = $operationId; operation = 'Install'; status = 'PreparingInstall'; targetPath = $environment.TargetPath; stagePath = $null; pendingOutputHash = $sourceHash; outputHash = $sourceHash; installationMode = $installationMode; renderVerificationPending = ($installationMode -eq 'Built'); targetSecurityChanged = $false; createdUtc = [DateTime]::UtcNow.ToString('o') }
            $context.journal = $journal
            Write-AesJson $paths.Journal $journal $paths.Root
            $context.ownsJournal = $true
            if ($null -eq $metadata) { $metadata = New-AesBackup $paths $environment $journal $identity; $context.createdBackup = $true }
            $context.originalSddl = $metadata.originalSddl
            $stage = New-AesStageFont $source $paths $metadata $journal; $context.stagePath = $stage
            Prepare-AesBootReplacement $paths $environment $metadata $journal $context; $context.anchorPath = [string]$journal.anchorPath
            $journal.status = 'PendingInstall'; Write-AesJson $paths.Journal $journal $paths.Root
            Write-AesJson $paths.State @{ schemaVersion = 1; status = 'PendingInstall'; installedOutputHash = $sourceHash; pendingOutputHash = $sourceHash; pendingOperation = 'Install'; installationMode = $installationMode; pendingInstallationMode = $installationMode; renderVerificationPending = ($installationMode -eq 'Built'); operationId = $operationId; updatedUtc = [DateTime]::UtcNow.ToString('o') } $paths.Root
            $context.wroteState = $true
            return (Get-AesSystemState)
        } catch {
            Invoke-AesInstallRollback $context $paths $environment
            return (New-AesBaseState $environment 'Failed' $_.Exception.Message)
        }
    }
}

function Restore-AesFont {
    [CmdletBinding()]
    param()
    return Invoke-AesLocked {
        $environment = Get-AesEnvironment; $paths = Get-AesPaths $environment
        $failure = Get-AesMutationFailure $environment
        if ($failure) { return (New-AesBaseState $environment 'Denied' $failure) }
        $context = @{ queued = $false; queueAttempted = $false; createdBackup = $false; stagePath = $null; anchorPath = $null; targetSecurityChanged = $false; originalSddl = $null; journal = $null; ownsJournal = $false; wroteState = $false }
        try {
            Ensure-AesDirectories $paths
            [void](Clear-AesOrphanedStagePendingPairs $paths $environment)
            $backup = Test-AesBackupMetadata $paths $environment
            if (-not $backup.Valid) { throw 'A valid original backup is required before restore.' }
            $currentHash = Get-AesHash $environment.TargetPath
            $persistent = Read-AesJson $paths.State
            $installedOutputHash = [string](Get-AesMemberValue $persistent 'installedOutputHash')
            if (-not $installedOutputHash) { $installedOutputHash = [string](Get-AesMemberValue $persistent 'outputHash') }
            $installedMode = Get-AesInstallationMode $persistent $installedOutputHash 'Installed'
            $oldJournal = Read-AesJson $paths.Journal
            if ($null -ne $oldJournal -and -not [bool](Get-AesMemberValue $oldJournal '__AesCorrupt' $false) -and (Test-AesPendingPair (Get-AesPendingEntries) (Get-AesMemberValue $oldJournal 'stagePath') (Get-AesMemberValue $oldJournal 'targetPath'))) { return (Get-AesSystemState) }
            if ($currentHash -eq ([string]$backup.Metadata.originalHash).ToLowerInvariant()) { $original = New-AesBaseState $environment 'Original' ''; $original.InstallationMode = 'Original'; return $original }
            if ($installedOutputHash -notmatch '^[a-fA-F0-9]{64}$' -or $currentHash -ne $installedOutputHash.ToLowerInvariant()) { throw 'External font drift was detected; restore will not overwrite it.' }
            $oldAnchor = [string](Get-AesMemberValue $oldJournal 'anchorPath')
            if ($oldAnchor -and (Test-Path -LiteralPath $oldAnchor -PathType Leaf)) { throw 'A previous boot finalizer has not restored its anchor yet.' }
            $operationId = [guid]::NewGuid().ToString('N')
            $journal = @{ schemaVersion = 1; operationId = $operationId; operation = 'Restore'; status = 'PreparingRestore'; targetPath = $environment.TargetPath; stagePath = $null; pendingOutputHash = $backup.Metadata.originalHash; outputHash = $backup.Metadata.originalHash; installationMode = $installedMode; pendingInstallationMode = 'Original'; renderVerificationPending = $false; targetSecurityChanged = $false; createdUtc = [DateTime]::UtcNow.ToString('o') }
            $context.journal = $journal
            Write-AesJson $paths.Journal $journal $paths.Root
            $context.ownsJournal = $true
            $stage = New-AesStageFont $paths.BackupFont $paths $backup.Metadata $journal; $context.stagePath = $stage
            $context.originalSddl = $backup.Metadata.originalSddl
            Prepare-AesBootReplacement $paths $environment $backup.Metadata $journal $context; $context.anchorPath = [string]$journal.anchorPath
            $journal.status = 'PendingRestore'; Write-AesJson $paths.Journal $journal $paths.Root
            Write-AesJson $paths.State @{ schemaVersion = 1; status = 'PendingRestore'; installedOutputHash = $installedOutputHash; pendingOutputHash = $backup.Metadata.originalHash; pendingOperation = 'Restore'; installationMode = $installedMode; pendingInstallationMode = 'Original'; renderVerificationPending = $false; operationId = $operationId; updatedUtc = [DateTime]::UtcNow.ToString('o') } $paths.Root
            $context.wroteState = $true
            return (Get-AesSystemState)
        } catch {
            Invoke-AesInstallRollback $context $paths $environment
            return (New-AesBaseState $environment 'Failed' $_.Exception.Message)
        }
    }
}

function Undo-AesPendingOperation {
    [CmdletBinding()]
    param()
    return Invoke-AesLocked {
        $environment = Get-AesEnvironment; $paths = Get-AesPaths $environment
        $failure = Get-AesMutationFailure $environment
        if ($failure) { return (New-AesBaseState $environment 'Denied' $failure) }
        try {
            Ensure-AesDirectories $paths
            $orphanedPairs = Clear-AesOrphanedStagePendingPairs $paths $environment
            $journal = Read-AesJson $paths.Journal
            if ($null -eq $journal -or [bool](Get-AesMemberValue $journal '__AesCorrupt' $false)) {
                if ($orphanedPairs -gt 0) { return (New-AesBaseState $environment 'Cancelled' 'Removed orphaned AppleEmojiSwitcher boot replacement entries.') }
                return (New-AesBaseState $environment 'NoPendingOperation' '')
            }
            $stage = [string](Get-AesMemberValue $journal 'stagePath')
            $target = [string](Get-AesMemberValue $journal 'targetPath')
            if (-not $stage -or -not (Test-AesOwnedPath $stage $paths.Root) -or -not $target.Equals($environment.TargetPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'Journal does not identify a safe transaction operation.' }
            $remove = Remove-AesPendingPair (Get-AesPendingEntries) $stage $target
            if (-not $remove.Removed) { return (New-AesBaseState $environment 'NoPendingOperation' '') }
            Set-AesPendingEntries ([string[]]$remove.Entries)
            if (Test-AesPendingPair (Get-AesPendingEntries) $stage $target) { throw 'The exact queued operation could not be removed.' }
            if ([bool](Get-AesMemberValue $journal 'targetSecurityChanged' $false)) { Set-AesSecuritySddl $environment.TargetPath ([string](Get-AesMemberValue $journal 'originalSddl')) }
            Remove-AesFinalizer $paths $journal
            Remove-AesOwnedFile $stage $paths
            $anchor = [string](Get-AesMemberValue $journal 'anchorPath')
            if ($anchor) { Remove-AesOwnedFile $anchor $paths }
            Remove-AesOwnedFile $paths.Journal $paths
            $prior = Read-AesJson $paths.State
            if ($null -eq $prior -or [bool](Get-AesMemberValue $prior '__AesCorrupt' $false)) { $prior = @{} }
            $prior.schemaVersion = 1; $prior.status = 'Cancelled'; $prior.pendingOutputHash = $null; $prior.pendingOperation = $null; $prior.updatedUtc = [DateTime]::UtcNow.ToString('o')
            $prior.pendingInstallationMode = $null
            if ([string](Get-AesMemberValue $journal 'operation') -eq 'Install') {
                $prior.installedOutputHash = $null; $prior.installationMode = 'Original'; $prior.renderVerificationPending = $false
            } else {
                $prior.installationMode = Get-AesInstallationMode $prior ([string](Get-AesMemberValue $prior 'installedOutputHash')) 'Installed'
                $prior.renderVerificationPending = ($prior.installationMode -eq 'Built')
            }
            Write-AesJson $paths.State $prior $paths.Root
            return (New-AesBaseState $environment 'Cancelled' '')
        } catch { return (New-AesBaseState $environment 'Failed' $_.Exception.Message) }
    }
}

function Verify-AesInstallation {
    <#
    Read-only verification for the CLI and GUI.  It never calls Ensure-*, takes
    no mutex, requests no elevation, and does not repair a transaction: a
    pending move or unfinished startup finalizer is deliberately reported as
    unverified rather than being silently completed.
    #>
    [CmdletBinding()]
    param()
    $result = Get-AesSystemState
    $result.VerificationPassed = $false
    $result.VerificationReason = ''
    try {
        if (-not [bool]$result.Supported) { throw ([string]$result.Reason) }
        if ($result.Status -in @('PendingInstall', 'PendingRestore', 'PreparingInstall', 'PreparingRestore')) {
            throw 'A boot-time operation is still pending; restart before verifying the installed font.'
        }
        if ($result.Status -notin @('Original', 'OriginalWithBackup', 'Installed')) {
            throw "The current transaction state '$($result.Status)' cannot be verified as complete."
        }
        $environment = Get-AesEnvironment
        $paths = Get-AesPaths $environment
        $backup = Test-AesBackupMetadata $paths $environment
        if ($backup.Exists -and -not $backup.Valid) { throw $backup.Reason }

        $expectedHash = $null
        $expectedSddl = $null
        if ($result.Status -eq 'Installed') {
            if (-not $backup.Valid) { throw 'An installed replacement requires a verified original backup.' }
            $persistent = Read-AesJson $paths.State
            if ($null -eq $persistent -or [bool](Get-AesMemberValue $persistent '__AesCorrupt' $false)) { throw 'Installed font state is missing or corrupt.' }
            $expectedHash = [string](Get-AesMemberValue $persistent 'installedOutputHash')
            if (-not $expectedHash) { $expectedHash = [string](Get-AesMemberValue $persistent 'outputHash') }
            if ($expectedHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Installed font state does not contain a valid output hash.' }
            $expectedSddl = [string](Get-AesMemberValue $backup.Metadata 'originalSddl')
            if ($result.InstallationMode -eq 'Pinned' -and ((Get-AesFileSize $environment.TargetPath) -ne $script:AesExpectedAppleSourceSize -or $expectedHash.ToLowerInvariant() -ne $script:AesExpectedAppleSourceHash)) {
                throw 'Pinned Apple installation does not match its exact approved file identity.'
            }
        } elseif ($backup.Valid) {
            $expectedHash = [string](Get-AesMemberValue $backup.Metadata 'originalHash')
            $expectedSddl = [string](Get-AesMemberValue $backup.Metadata 'originalSddl')
        } else {
            $identity = Get-AesMicrosoftSourceIdentity $environment
            if (-not [bool]$identity.Accepted) { throw 'Current native font has no verified Microsoft/TrustedInstaller baseline.' }
            $expectedHash = [string]$identity.Hash
            $expectedSddl = [string]$identity.Sddl
        }
        if ($result.CurrentHash -ne $expectedHash.ToLowerInvariant()) { throw 'Current font bytes do not match the recorded transaction state.' }
        if ([string]::IsNullOrWhiteSpace($expectedSddl) -or (Get-AesSecuritySddl $environment.TargetPath) -ne $expectedSddl) {
            throw 'Current font owner, group, or DACL does not match the original baseline.'
        }

        $journal = Read-AesJson $paths.Journal
        if ($null -ne $journal) {
            if ([bool](Get-AesMemberValue $journal '__AesCorrupt' $false)) { throw 'Transaction journal is corrupt.' }
            $anchor = [string](Get-AesMemberValue $journal 'anchorPath')
            if ($anchor) {
                if (-not (Test-AesOwnedPath $anchor $paths.Root)) { throw 'Transaction journal contains an unsafe restore-anchor path.' }
                if (Test-Path -LiteralPath $anchor -PathType Leaf) { throw 'Startup finalizer has not restored the original inode permissions yet.' }
            }
            $taskName = [string](Get-AesMemberValue $journal 'finalizerTaskName')
            if ($taskName -and (Test-AesFinalizerRegistered $taskName)) { throw 'Startup finalizer is still registered; permission rollback is incomplete.' }
        }
        $result.VerificationPassed = $true
        $result.VerificationReason = 'Font bytes, backup bytes, and original owner/group/DACL state are verified.'
    } catch {
        $result.VerificationPassed = $false
        $result.VerificationReason = $_.Exception.Message
    }
    return $result
}

function Confirm-AesState {
    [CmdletBinding()]
    param()
    $state = Get-AesSystemState
    if ($state.Status -in @('PendingInstall', 'PendingRestore')) { return $state }
    # Session Manager consumes the registry pair during boot but cannot remove
    # our journal.  Confirmation is read-only: it verifies the target hash and
    # reports completion without deleting evidence or requiring elevation.
    try {
        $environment = Get-AesEnvironment; $paths = Get-AesPaths $environment
        $journal = Read-AesJson $paths.Journal
        if ($null -eq $journal -or [bool](Get-AesMemberValue $journal '__AesCorrupt' $false)) { return $state }
        $stage = [string](Get-AesMemberValue $journal 'stagePath')
        $target = [string](Get-AesMemberValue $journal 'targetPath')
        $outputHash = [string](Get-AesMemberValue $journal 'outputHash')
        if (-not $outputHash) { $outputHash = [string](Get-AesMemberValue $journal 'pendingOutputHash') }
        if (-not $stage -or -not (Test-AesOwnedPath $stage $paths.Root) -or -not $target.Equals($environment.TargetPath, [StringComparison]::OrdinalIgnoreCase) -or $outputHash -notmatch '^[a-fA-F0-9]{64}$') { return $state }
        if (Test-AesPendingPair (Get-AesPendingEntries) $stage $target) { return $state }
        $confirmed = New-AesBaseState $environment
        if ($confirmed.CurrentHash -eq $outputHash.ToLowerInvariant()) {
            if ([string](Get-AesMemberValue $journal 'operation') -eq 'Restore') {
                $confirmed.Status = 'Original'; $confirmed.Reason = 'The queued original font was verified after restart.'; $confirmed.InstallationMode = 'Original'
            } else {
                $confirmed.Status = 'Installed'; $confirmed.Reason = 'The queued replacement font was verified after restart.'
                $confirmed.InstallationMode = Get-AesInstallationMode $journal $outputHash 'Installed'
                $confirmed.RenderVerificationPending = ($confirmed.InstallationMode -eq 'Built')
            }
            return $confirmed
        }
        $backup = Test-AesBackupMetadata $paths $environment
        if ($backup.Valid -and $confirmed.CurrentHash -eq ([string](Get-AesMemberValue $backup.Metadata 'originalHash')).ToLowerInvariant()) {
            $confirmed.Status = 'NotApplied'; $confirmed.Reason = 'The queued operation was not applied at restart.'; $confirmed.InstallationMode = 'Original'; return $confirmed
        }
        $confirmed.Status = 'ExternalDrift'; $confirmed.Reason = 'The post-restart font hash differs from the queued output.'; return $confirmed
    } catch { return $state }
    return $state
}

Export-ModuleMember -Function Get-AesSystemState, Install-AesFont, Restore-AesFont, Undo-AesPendingOperation, Confirm-AesState, Verify-AesInstallation
