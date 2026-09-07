[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$OperationId,
    [Parameter(Mandatory = $true)][string]$TaskName
)

# One-shot SYSTEM startup finalizer.  It exists only because seguiemj.ttf is
# normally hard-linked into WinSxS: its pre-boot temporary SYSTEM Delete ACE is
# an inode ACL and must be restored through the anchor after target replacement.
$ErrorActionPreference = 'Stop'

function Test-ChildPath([string]$Path, [string]$Parent) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    return $fullPath.StartsWith($fullParent + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-FinalizerSid($Identity) {
    if ($Identity -is [Security.Principal.SecurityIdentifier]) { return $Identity.Value }
    try { return $Identity.Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
    try { return (New-Object Security.Principal.NTAccount([string]$Identity)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { throw 'ACL identity cannot be resolved.' }
}

function Assert-FinalizerTrustedPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Finalizer refused a reparse point: $Path" }
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if ($trusted -notcontains (Get-FinalizerSid $acl.Owner)) { throw "Finalizer refused an untrusted owner: $Path" }
    $writeMask = 2 -bor 4 -bor 16 -bor 64 -bor 256 -bor 65536 -bor 262144 -bor 524288
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        try { $sid = Get-FinalizerSid $rule.IdentityReference }
        catch {
            if ((([int]$rule.FileSystemRights) -band $writeMask) -ne 0) { throw "Finalizer refused an unresolved write-capable identity: $Path" }
            continue
        }
        if (($trusted -notcontains $sid) -and ((([int]$rule.FileSystemRights) -band $writeMask) -ne 0)) { throw "Finalizer refused low-privilege write access: $Path" }
    }
}

function Write-FinalizerJson([string]$Path, $Value) {
    if (-not (Test-ChildPath $Path $Root)) { throw 'Finalizer refused an output outside its root.' }
    $tmp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $previous = "$Path.$([guid]::NewGuid().ToString('N')).bak"
    try {
        [System.IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($tmp, $Path, $previous) }
        else { [System.IO.File]::Move($tmp, $Path) }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Force -ErrorAction SilentlyContinue }
    }
}

function Get-FinalizerInstallationMode($Record, [string]$FallbackHash = '', [string]$Default = 'Unknown') {
    $declared = [string]$Record.installationMode
    if ($declared -in @('Original', 'Built', 'Pinned', 'Unknown')) { return $declared }
    $hash = $FallbackHash
    if ($hash -notmatch '^[a-fA-F0-9]{64}$') {
        foreach ($name in @('installedOutputHash', 'pendingOutputHash', 'outputHash')) {
            $candidate = [string]$Record.$name
            if ($candidate -match '^[a-fA-F0-9]{64}$') { $hash = $candidate; break }
        }
    }
    if ($hash -match '^[a-fA-F0-9]{64}$') {
        if ($hash.ToLowerInvariant() -eq '18e48f1785564fbf511241e0963b265057bfe742036d8543406c6ce07e48ec0b') { return 'Pinned' }
        return 'Built'
    }
    return $Default
}

try {
    $expectedRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'AppleEmojiSwitcher'
    $Root = [System.IO.Path]::GetFullPath($Root)
    if (-not $Root.Equals([System.IO.Path]::GetFullPath($expectedRoot), [StringComparison]::OrdinalIgnoreCase)) { throw 'Finalizer root is not the fixed AppleEmojiSwitcher ProgramData root.' }
    if ($OperationId -notmatch '^[a-f0-9]{32}$' -or $TaskName -notmatch '^\\AppleEmojiSwitcher-Finalize-[a-f0-9]{32}$') { throw 'Finalizer invocation is invalid.' }
    $journalPath = Join-Path $Root 'journal.json'
    foreach ($path in @($Root, (Join-Path $Root 'anchor'), (Join-Path $Root 'finalizer'), $journalPath, $PSCommandPath)) { Assert-FinalizerTrustedPath $path }
    $journal = Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json -ErrorAction Stop
    if ($journal.operationId -ne $OperationId -or $journal.finalizerTaskName -ne $TaskName) { throw 'Finalizer invocation does not match the journal.' }
    $anchor = [string]$journal.anchorPath
    $target = [string]$journal.targetPath
    $source = [string]$journal.finalizerNativeSource
    if (-not (Test-ChildPath $anchor $Root) -or -not (Test-ChildPath $source $Root) -or -not (Test-Path -LiteralPath $anchor -PathType Leaf)) { throw 'Finalizer anchor or helper source is unsafe/missing.' }
    Assert-FinalizerTrustedPath $anchor; Assert-FinalizerTrustedPath $source
    $expectedTarget = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)) 'Fonts\seguiemj.ttf'
    if (-not $target.Equals($expectedTarget, [StringComparison]::OrdinalIgnoreCase)) { throw 'Finalizer target is not seguiemj.ttf.' }
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$journal.finalizerNativeHash).ToLowerInvariant()) { throw 'Finalizer native helper hash mismatch.' }
    Add-Type -TypeDefinition ([System.IO.File]::ReadAllText($source)) -Language CSharp -ErrorAction Stop
    $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    # Restore the old inode first even when Session Manager did not apply the
    # move.  With a hard-linked original this also removes the temporary SYSTEM
    # Delete ACE from its WinSxS aliases and from target when it stayed in place.
    [AppleEmojiSwitcher.NativeTransaction]::SetFileSecuritySddl($anchor, [string]$journal.originalSddl)
    $statePath = Join-Path $Root 'state.json'
    if (Test-Path -LiteralPath $statePath -PathType Leaf) { Assert-FinalizerTrustedPath $statePath }
    $prior = if (Test-Path -LiteralPath $statePath) { Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json } else { [pscustomobject]@{} }
    $pendingOutputHash = [string]$journal.pendingOutputHash
    if (-not $pendingOutputHash) { $pendingOutputHash = [string]$journal.outputHash }
    if ($pendingOutputHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Finalizer journal does not contain a valid pending output hash.' }
    $applied = $actual -eq $pendingOutputHash.ToLowerInvariant()
    if ($applied) { [AppleEmojiSwitcher.NativeTransaction]::SetFileSecuritySddl($target, [string]$journal.originalSddl) }
    $priorMode = Get-FinalizerInstallationMode $prior ([string]$prior.installedOutputHash)
    $journalMode = Get-FinalizerInstallationMode $journal $pendingOutputHash
    $operation = [string]$journal.operation
    $installationMode = if (-not $applied -and $operation -eq 'Restore') { $priorMode } elseif (-not $applied) { 'Original' } elseif ($operation -eq 'Restore') { 'Original' } else { $journalMode }
    $installedOutputHash = if ($applied -and $operation -ne 'Restore') { $pendingOutputHash } elseif (-not $applied -and $operation -eq 'Restore') { [string]$prior.installedOutputHash } else { $null }
    $state = @{ schemaVersion = 1; status = if (-not $applied) { 'NotApplied' } elseif ($operation -eq 'Restore') { 'Original' } else { 'Installed' }; installedOutputHash = $installedOutputHash; pendingOutputHash = $null; pendingOperation = $null; installationMode = $installationMode; pendingInstallationMode = $null; operationId = $OperationId; finalizedUtc = [DateTime]::UtcNow.ToString('o'); renderVerificationPending = ($applied -and $operation -ne 'Restore' -and $installationMode -eq 'Built'); reason = if ($applied) { '' } else { 'The queued boot-time move was not applied; original inode security was restored.' } }
    Write-FinalizerJson $statePath $state
    [AppleEmojiSwitcher.NativeTransaction]::ProtectTransactionFile($statePath)
    schtasks.exe /Delete /TN $TaskName /F | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Finalizer could not delete its one-shot task.' }
    Remove-Item -LiteralPath $anchor -Force -ErrorAction Stop
} catch {
    try { Write-FinalizerJson (Join-Path $Root 'finalizer-error.json') @{ operationId = $OperationId; failedUtc = [DateTime]::UtcNow.ToString('o'); error = $_.Exception.Message } } catch { }
    exit 1
}
