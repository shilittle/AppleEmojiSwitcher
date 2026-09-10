[CmdletBinding()]
param()

# Isolated transaction tests.  The module's private backend seam redirects the
# target, registry value, PendingFileRenameOperations and security operations to
# a disposable temp directory.  No UAC prompt, HKLM write, or Fonts write occurs.

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\lib\SystemTransaction.psm1'
$transactionModule = Import-Module $modulePath -Force -PassThru

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ([string]$Actual -ne [string]$Expected) { throw "Assertion failed: $Message (actual '$Actual', expected '$Expected')" }
}

function Get-TestHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Read-only scheduler regression under the same strict preference as the CLI.
# A GUID task name is queried only; no task is created, changed or deleted.
$absentFinalizer = & $transactionModule {
    $ErrorActionPreference = 'Stop'
    Test-AesFinalizerRegistered ('\AppleEmojiSwitcher-Finalize-' + [guid]::NewGuid().ToString('N'))
}
Assert-Equal $absentFinalizer $false 'An already removed finalizer must not make strict CLI verification fail'
$wrappedRegistryPath = Join-Path $env:WINDIR 'Fonts\seguiemj.ttf'
$convertedRegistryPath = & $transactionModule { param($value) ConvertTo-AesHashtable $value } $wrappedRegistryPath
Assert-True ($convertedRegistryPath -is [string]) 'PSObject-wrapped registry path remains a string during transaction JSON conversion'
Assert-Equal $convertedRegistryPath $wrappedRegistryPath 'transaction JSON conversion preserves a registry path string exactly'

function New-IsolatedCase {
    param([switch]$FailStage, [switch]$FailQueue, [switch]$NativeMovePrefix, [switch]$TamperStage)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("AppleEmojiSwitcher-Test-" + [guid]::NewGuid().ToString('N'))
    $targetDirectory = Join-Path $root 'fake-windows\Fonts'
    [void][System.IO.Directory]::CreateDirectory($targetDirectory)
    $target = Join-Path $targetDirectory 'seguiemj.ttf'
    $source = Join-Path $root 'candidate.ttf'
    [System.IO.File]::WriteAllBytes($target, [System.Text.Encoding]::UTF8.GetBytes('verified test Windows emoji original'))
    [System.IO.File]::WriteAllBytes($source, [System.Text.Encoding]::UTF8.GetBytes('coverage-approved replacement emoji font'))
    $originalHash = Get-TestHash $target
    $state = @{ Pending = @('C:\\unrelated-old.tmp', 'C:\\unrelated-new.tmp', 'C:\\delete-me.tmp', ''); QueueCount = 0; Security = @{}; TempGrantCount = 0 }
    $state.Security[$target] = 'O:BADG:BAD:(A;;FA;;;BA)'
    $coverage = Join-Path $root 'coverage.json'
    @{ schemaVersion = 1; status = 'passed'; sourceAppleSha256 = '18e48f1785564fbf511241e0963b265057bfe742036d8543406c6ce07e48ec0b'; sourceWindowsSha256 = $originalHash; outputSha256 = (Get-TestHash $source); checks = @{ nativeSequenceRegression = 'passed'; sequenceRegression = 'passed'; fontStructure = 'passed'; textPresentation = 'passed'; indexedMetrics = 'passed'; nativeRenderSmoke = 'passed' } } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $coverage -Encoding utf8
    $backend = @{
        Root = (Join-Path $root 'transaction-root'); TargetPath = $target; WindowsVersion = '10.0'; Build = 22631; Architecture = 'x64'; IsElevated = $true; ExpectedWindowsHash = $originalHash
        ProtectDirectory = { param($path) }
        ProtectFile = { param($path) }
        AssertTrustedPath = { param($path) }
        GetSecurity = { param($path) if ($state.Security.ContainsKey($path)) { return $state.Security[$path] }; return 'O:BADG:BAD:(A;;FA;;;BA)' }
        SetSecurity = { param($path, $sddl) $state.Security[$path] = $sddl }
        GrantTemporaryAccess = { param($path) $state.TempGrantCount++; return $state.Security[$path] }
        GrantSystemDeleteUntilReboot = { param($path) $original = $state.Security[$path]; $state.Security[$path] = 'O:BADG:BAD:(A;;SD;;;SY)'; return $original }
        GetFontRegistry = { return @{ Path = 'HKLM:\\test-fonts'; Name = 'Segoe UI Emoji (TrueType)'; Exists = $true; Value = 'seguiemj.ttf'; Kind = 'String' } }
        GetMicrosoftSourceIdentity = { param($environment) return @{ Accepted = $true; Hash = $originalHash; Sddl = 'O:BADG:BAD:(A;;FA;;;BA)'; Registry = @{ Path = 'HKLM:\\test-fonts'; Name = 'Segoe UI Emoji (TrueType)'; Exists = $true; Value = 'seguiemj.ttf'; Kind = 'String' }; Build = $environment.Build; WindowsVersion = $environment.WindowsVersion } }
        GetPendingEntries = { return @($state.Pending) }
        SetPendingEntries = { param($entries) $state.Pending = @($entries) }
        QueueMove = {
            param($sourcePath, $destinationPath)
            $state.QueueCount++
            if ($FailQueue) { throw 'injected queue verification failure' }
            if ($NativeMovePrefix) {
                # Actual delayed replacement entries on this Windows build
                # carry the observed *1 prefix.
                $state.Pending = @($state.Pending) + @(('*1\??\' + $sourcePath), ('*1!\??\' + $destinationPath))
            } else {
                $state.Pending = @($state.Pending) + @($sourcePath, $destinationPath)
            }
        }
        CreateRestoreAnchor = { param($anchorPath, $targetPath) Copy-Item -LiteralPath $targetPath -Destination $anchorPath -ErrorAction Stop }
        RegisterFinalizer = { param($paths, $journal) $state.FinalizerTask = "\AppleEmojiSwitcher-Finalize-$($journal.operationId)"; return @{ TaskName = $state.FinalizerTask; ScriptPath = (Join-Path $paths.FinalizerDirectory 'test-finalizer.ps1'); ScriptHash = ('b' * 64); NativePath = (Join-Path $paths.FinalizerDirectory 'test-native.cs'); NativeHash = ('c' * 64) } }
        RemoveFinalizer = { param($taskName) if ($state.FinalizerTask -eq $taskName) { $state.FinalizerTask = $null } }
        IsFinalizerRegistered = { param($taskName) return ($state.FinalizerTask -eq $taskName) }
        CopyFile = {
            param($sourcePath, $destinationPath)
            if ($FailStage -and $destinationPath -match '[\\/]stage[\\/]') { throw 'injected stage copy failure' }
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -ErrorAction Stop
            if ($TamperStage -and $destinationPath -match '[\\/]stage[\\/]') {
                # Emulate a hostile/racy producer that changes both inputs
                # after the report has approved the original candidate bytes.
                $tampered = [System.Text.Encoding]::UTF8.GetBytes('tampered source and stage bytes')
                [System.IO.File]::WriteAllBytes($sourcePath, $tampered)
                [System.IO.File]::WriteAllBytes($destinationPath, $tampered)
            }
        }
    }
    foreach ($key in @($backend.Keys)) {
        if ($backend[$key] -is [scriptblock]) { $backend[$key] = $backend[$key].GetNewClosure() }
    }
    return @{ Root = $root; Target = $target; Source = $source; Coverage = $coverage; OriginalHash = $originalHash; State = $state; Backend = $backend }
}

function Use-IsolatedCase {
    param([hashtable]$Case)
    & $transactionModule { param($backend) Set-AesTestBackend -Backend $backend } $Case.Backend
}

function Clear-IsolatedCase {
    & $transactionModule { Clear-AesTestBackend }
}

function Set-TestPinnedIdentity {
    param([hashtable]$Case)
    $hash = Get-TestHash $Case.Source
    $size = [int64]([System.IO.FileInfo]$Case.Source).Length
    & $transactionModule { param($expectedHash, $expectedSize) $script:AesExpectedAppleSourceHash = $expectedHash; $script:AesExpectedAppleSourceSize = $expectedSize } $hash $size
}

function Reset-TestPinnedIdentity {
    & $transactionModule { $script:AesExpectedAppleSourceHash = '18e48f1785564fbf511241e0963b265057bfe742036d8543406c6ce07e48ec0b'; $script:AesExpectedAppleSourceSize = [int64]256391076 }
}

function Remove-IsolatedCase {
    param([hashtable]$Case)
    $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $root = [System.IO.Path]::GetFullPath($Case.Root)
    if ($root.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $root) -like 'AppleEmojiSwitcher-Test-*') {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$cases = New-Object 'System.Collections.Generic.List[hashtable]'
try {
    # Existing unrelated PendingFileRenameOperations entries must survive, while
    # the unique stage/target pair is added exactly once.
    $case = New-IsolatedCase; $cases.Add($case); Use-IsolatedCase $case
    $install = Install-AesFont -FontPath $case.Source -ReportPath $case.Coverage
    Assert-Equal $install.Status 'PendingInstall' ("install queues a pending replacement: " + $install.Reason)
    Assert-Equal $case.State.QueueCount 1 'one MoveFileEx-equivalent queue call'
    Assert-Equal $case.State.Pending[0] 'C:\\unrelated-old.tmp' 'first unrelated source is retained'
    Assert-Equal $case.State.Pending[1] 'C:\\unrelated-new.tmp' 'first unrelated destination is retained'
    Assert-Equal $case.State.Pending[2] 'C:\\delete-me.tmp' 'unrelated deletion source is retained'
    Assert-Equal $case.State.Pending[3] '' 'unrelated deletion destination is retained'

    # Windows records delayed replacement pairs as *1\\??\\source and
    # *1!\\??\\destination.  Queue verification and cancellation must
    # recognize that representation, while an orphaned missing AES stage pair
    # is removed without touching unrelated registry entries.
    $prefixedCase = New-IsolatedCase -NativeMovePrefix; $cases.Add($prefixedCase); Use-IsolatedCase $prefixedCase
    $orphanStage = Join-Path $prefixedCase.Backend.Root ('stage\seguiemj.' + ('a' * 32) + '.ttf')
    $prefixedCase.State.Pending = @($prefixedCase.State.Pending) + @(('*1\??\' + $orphanStage), ('*1!\??\' + $prefixedCase.Target))
    $prefixedInstall = Install-AesFont -FontPath $prefixedCase.Source -ReportPath $prefixedCase.Coverage
    Assert-Equal $prefixedInstall.Status 'PendingInstall' ('prefixed native queue pair is verified: ' + $prefixedInstall.Reason)
    Assert-Equal $prefixedCase.State.QueueCount 1 'prefixed native queue calls MoveFileEx once'
    Assert-Equal $prefixedCase.State.Pending.Count 6 'only the missing AES orphan pair was removed before queueing'
    Assert-Equal $prefixedCase.State.Pending[0] 'C:\\unrelated-old.tmp' 'orphan cleanup retains unrelated source'
    Assert-Equal $prefixedCase.State.Pending[1] 'C:\\unrelated-new.tmp' 'orphan cleanup retains unrelated destination'
    $prefixedCancel = Undo-AesPendingOperation
    Assert-Equal $prefixedCancel.Status 'Cancelled' 'prefixed native queue pair is cancelled'
    Assert-Equal $prefixedCase.State.Pending.Count 4 'prefixed cancellation removes only its pair'

    # An interrupted pre-verification attempt has no journal, but an explicit
    # Undo still removes only its exact, already-missing stage pair.
    $orphanOnlyCase = New-IsolatedCase; $cases.Add($orphanOnlyCase); Use-IsolatedCase $orphanOnlyCase
    $orphanOnlyStage = Join-Path $orphanOnlyCase.Backend.Root ('stage\seguiemj.' + ('b' * 32) + '.ttf')
    $orphanOnlyCase.State.Pending = @($orphanOnlyCase.State.Pending) + @(('*1\??\' + $orphanOnlyStage), ('*1!\??\' + $orphanOnlyCase.Target))
    $orphanUndo = Undo-AesPendingOperation
    Assert-Equal $orphanUndo.Status 'Cancelled' 'journal-less orphaned native pair is cancelled'
    Assert-Equal $orphanOnlyCase.State.Pending.Count 4 'journal-less cancellation preserves unrelated entries'

    # A second request recognizes the exact queued pair and does not queue a
    # duplicate operation or overwrite the backup.
    $again = Install-AesFont -FontPath $case.Source -ReportPath $case.Coverage
    Assert-Equal $again.Status 'PendingInstall' 'duplicate install remains pending'
    Assert-Equal $case.State.QueueCount 1 'duplicate install does not requeue'

    # After Session Manager consumes our unique pair, confirmation must hash the
    # boot result and report installed (with render verification still pending).
    $confirmCase = New-IsolatedCase; $cases.Add($confirmCase); Use-IsolatedCase $confirmCase
    $confirmInstall = Install-AesFont -FontPath $confirmCase.Source -ReportPath $confirmCase.Coverage
    Assert-Equal $confirmInstall.Status 'PendingInstall' 'confirmation case queues install'
    $confirmJournal = Get-Content -Raw -LiteralPath (Join-Path $confirmCase.Backend.Root 'journal.json') | ConvertFrom-Json
    $confirmCase.State.Pending = @($confirmCase.State.Pending[0..3])
    Copy-Item -LiteralPath $confirmCase.Source -Destination $confirmCase.Target -Force
    Remove-Item -LiteralPath $confirmJournal.stagePath -Force
    $confirmed = Confirm-AesState
    Assert-Equal $confirmed.Status 'Installed' 'post-restart confirmation hashes installed output'
    Assert-True $confirmed.RenderVerificationPending 'installed output still requests render verification'

    # Restore keeps the installed output hash separate from its pending original
    # hash.  Cancelling that restore therefore returns to Installed, not drift.
    $restoreCase = New-IsolatedCase; $cases.Add($restoreCase); Use-IsolatedCase $restoreCase
    $restoreInstall = Install-AesFont -FontPath $restoreCase.Source -ReportPath $restoreCase.Coverage
    Assert-Equal $restoreInstall.Status 'PendingInstall' 'restore case queues install'
    $installJournal = Get-Content -Raw -LiteralPath (Join-Path $restoreCase.Backend.Root 'journal.json') | ConvertFrom-Json
    $restoreCase.State.Pending = @($restoreCase.State.Pending[0..3])
    Copy-Item -LiteralPath $restoreCase.Source -Destination $restoreCase.Target -Force
    Remove-Item -LiteralPath $installJournal.stagePath -Force
    Remove-Item -LiteralPath $installJournal.anchorPath -Force
    $restoreCase.State.Security[$restoreCase.Target] = 'O:BADG:BAD:(A;;FA;;;BA)'
    @{ schemaVersion = 1; status = 'Installed'; installedOutputHash = (Get-TestHash $restoreCase.Source); pendingOutputHash = $null; pendingOperation = $null } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $restoreCase.Backend.Root 'state.json') -Encoding utf8
    $restorePending = Restore-AesFont
    Assert-Equal $restorePending.Status 'PendingRestore' ("restore queues verified backup: " + $restorePending.Reason)
    $restoreState = Get-Content -Raw -LiteralPath (Join-Path $restoreCase.Backend.Root 'state.json') | ConvertFrom-Json
    Assert-Equal $restoreState.installedOutputHash (Get-TestHash $restoreCase.Source) 'restore preserves installed output hash'
    Assert-Equal $restoreState.pendingOutputHash $restoreCase.OriginalHash 'restore records only original as pending output'
    $undoRestore = Undo-AesPendingOperation
    Assert-Equal $undoRestore.Status 'Cancelled' ("restore cancellation succeeds: " + $undoRestore.Reason)
    $afterUndoRestore = Get-AesSystemState
    Assert-Equal $afterUndoRestore.Status 'Installed' 'cancelled restore retains installed state'

    Use-IsolatedCase $case

    # Cancellation removes only our stage/target pair, keeps all unrelated
    # entries, deletes stage bytes, and restores a journaled target descriptor.
    $journalPath = Join-Path $case.Backend.Root 'journal.json'
    $journal = Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
    $journal.targetSecurityChanged = $true; $journal.originalSddl = 'O:BADG:BAD:(A;;FA;;;BA)'
    $journal | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $journalPath -Encoding utf8
    $case.State.Security[$case.Target] = 'O:BADG:BAD:(A;;FA;;;WD)'
    # MoveFileEx replacement destinations are represented as !\??\DOS-path.
    $case.State.Pending[$case.State.Pending.Count - 1] = '!\??\' + $case.Target
    $stage = $journal.stagePath
    $cancel = Undo-AesPendingOperation
    Assert-Equal $cancel.Status 'Cancelled' 'cancellation succeeds'
    Assert-Equal $case.State.Pending.Count 4 'only the exact queued pair was removed'
    Assert-Equal $case.State.Security[$case.Target] 'O:BADG:BAD:(A;;FA;;;BA)' 'journaled security descriptor was restored'
    Assert-True (-not (Test-Path -LiteralPath $stage)) 'stage file was removed after cancellation'
    $afterInstallCancel = Get-AesSystemState
    Assert-Equal $afterInstallCancel.Status 'OriginalWithBackup' 'cancelled install returns to the verified original instead of drift'

    # On a first run, Windows may register the system font with an exact
    # absolute String path or an ExpandString path.  Both are equivalent to the
    # normal bare filename, while foreign targets and unsupported registry kinds
    # must remain fail-closed.
    $bareCase = New-IsolatedCase; $cases.Add($bareCase)
    $bareCase.Backend.Remove('GetMicrosoftSourceIdentity')
    $bareCase.State.Security[$bareCase.Target] = 'O:TIG:SYD:PAI(A;;FA;;;SY)'
    Use-IsolatedCase $bareCase
    Assert-Equal (Get-AesSystemState).Status 'Original' 'default bare filename uses the real source-identity rules'
    Assert-Equal $bareCase.State.QueueCount 0 'read-only native detection does not queue a transaction'

    $absoluteCase = New-IsolatedCase; $cases.Add($absoluteCase)
    $absoluteCase.Backend.Remove('GetMicrosoftSourceIdentity')
    $absoluteCase.State.Security[$absoluteCase.Target] = 'O:TIG:SYD:PAI(A;;FA;;;SY)'
    $absoluteValue = $absoluteCase.Target
    $absoluteCase.Backend.GetFontRegistry = { return @{ Path = 'HKLM:\test-fonts'; Name = 'Segoe UI Emoji (TrueType)'; Exists = $true; Value = $absoluteValue; Kind = 'String' } }.GetNewClosure()
    Use-IsolatedCase $absoluteCase
    $absoluteState = Get-AesSystemState
    Assert-Equal $absoluteState.Status 'Original' 'exact absolute String registry target is an accepted native baseline'
    $absoluteInstall = Install-AesFont -FontPath $absoluteCase.Source -ReportPath $absoluteCase.Coverage
    Assert-Equal $absoluteInstall.Status 'PendingInstall' 'first install accepts an exact absolute String registry target'
    $absoluteBackupMetadata = Get-Content -Raw -LiteralPath (Join-Path $absoluteCase.Backend.Root 'backup\original.json') | ConvertFrom-Json
    Assert-Equal $absoluteBackupMetadata.fontRegistry.Value $absoluteValue 'first install preserves the exact absolute registry value in backup metadata'
    $absoluteCancel = Undo-AesPendingOperation
    Assert-Equal $absoluteCancel.Status 'Cancelled' 'cancel works after first install with an absolute String registry target'
    Assert-Equal (Get-AesSystemState).Status 'OriginalWithBackup' 'absolute String transaction cancellation keeps the verified original'

    $expandCase = New-IsolatedCase; $cases.Add($expandCase)
    $expandCase.Backend.Remove('GetMicrosoftSourceIdentity')
    $expandCase.Backend.GetSecurity = { param($path) return 'O:TIG:SYD:PAI(A;;FA;;;SY)' }
    $expandValue = '%TEMP%\' + (Split-Path -Leaf $expandCase.Root) + '\fake-windows\Fonts\seguiemj.ttf'
    $expandCase.Backend.GetFontRegistry = { return @{ Path = 'HKLM:\test-fonts'; Name = 'Segoe UI Emoji (TrueType)'; Exists = $true; Value = $expandValue; Kind = 'ExpandString' } }.GetNewClosure()
    Use-IsolatedCase $expandCase
    Assert-Equal (Get-AesSystemState).Status 'Original' 'exact ExpandString registry target is an accepted native baseline'

    $foreignRegistryCase = New-IsolatedCase; $cases.Add($foreignRegistryCase)
    $foreignRegistryCase.Backend.Remove('GetMicrosoftSourceIdentity')
    $foreignRegistryCase.Backend.GetSecurity = { param($path) return 'O:TIG:SYD:PAI(A;;FA;;;SY)' }
    $foreignRegistryCase.Backend.GetFontRegistry = { return @{ Path = 'HKLM:\test-fonts'; Name = 'Segoe UI Emoji (TrueType)'; Exists = $true; Value = 'C:\foreign\seguiemj.ttf'; Kind = 'String' } }
    Use-IsolatedCase $foreignRegistryCase
    $foreignRegistryState = Get-AesSystemState
    Assert-Equal $foreignRegistryState.Status 'ExternalDrift' 'foreign registry path remains external drift'
    Assert-Equal $foreignRegistryState.DiagnosticCode 'NativeRegistrationMismatch' 'foreign registry path receives a specific read-only diagnostic'
    $foreignRegistryInstall = Install-AesFont -FontPath $foreignRegistryCase.Source -ReportPath $foreignRegistryCase.Coverage
    Assert-Equal $foreignRegistryInstall.Status 'Failed' 'foreign registry path cannot be accepted as a first-install baseline'
    Assert-Equal $foreignRegistryCase.State.QueueCount 0 'foreign registry path never queues a replacement'

    foreach ($driveRelativeValue in @('C:seguiemj.ttf', '\Windows\Fonts\seguiemj.ttf')) {
        $driveRelativeCase = New-IsolatedCase; $cases.Add($driveRelativeCase)
        $driveRelativeCase.Backend.Remove('GetMicrosoftSourceIdentity')
        $driveRelativeCase.Backend.GetSecurity = { param($path) return 'O:TIG:SYD:PAI(A;;FA;;;SY)' }
        $registryValue = $driveRelativeValue
        $driveRelativeCase.Backend.GetFontRegistry = { return @{ Path = 'HKLM:\test-fonts'; Name = 'Segoe UI Emoji (TrueType)'; Exists = $true; Value = $registryValue; Kind = 'String' } }.GetNewClosure()
        Use-IsolatedCase $driveRelativeCase
        $driveRelativeState = Get-AesSystemState
        Assert-Equal $driveRelativeState.Status 'ExternalDrift' "non-fully-qualified registry path '$driveRelativeValue' remains external drift"
        Assert-Equal $driveRelativeState.DiagnosticCode 'NativeRegistrationMismatch' "non-fully-qualified registry path '$driveRelativeValue' receives a registration diagnostic"
    }

    $badKindCase = New-IsolatedCase; $cases.Add($badKindCase)
    $badKindCase.Backend.Remove('GetMicrosoftSourceIdentity')
    $badKindCase.Backend.GetSecurity = { param($path) return 'O:TIG:SYD:PAI(A;;FA;;;SY)' }
    $badKindCase.Backend.GetFontRegistry = { return @{ Path = 'HKLM:\test-fonts'; Name = 'Segoe UI Emoji (TrueType)'; Exists = $true; Value = 'seguiemj.ttf'; Kind = 'MultiString' } }
    Use-IsolatedCase $badKindCase
    $badKindState = Get-AesSystemState
    Assert-Equal $badKindState.Status 'ExternalDrift' 'unsupported registry kind remains external drift'
    Assert-Equal $badKindState.DiagnosticCode 'NativeRegistrationMismatch' 'unsupported registry kind receives a specific diagnostic'

    $ownerCase = New-IsolatedCase; $cases.Add($ownerCase)
    $ownerCase.Backend.Remove('GetMicrosoftSourceIdentity')
    $ownerCase.Backend.GetSecurity = { param($path) return 'O:BAG:SYD:PAI(A;;FA;;;SY)' }
    Use-IsolatedCase $ownerCase
    $ownerState = Get-AesSystemState
    Assert-Equal $ownerState.Status 'ExternalDrift' 'non-TrustedInstaller source remains external drift'
    Assert-Equal $ownerState.DiagnosticCode 'NativeOwnerUnrecognized' 'non-TrustedInstaller source receives a specific diagnostic'

    $ownerPrefixCase = New-IsolatedCase; $cases.Add($ownerPrefixCase)
    $ownerPrefixCase.Backend.Remove('GetMicrosoftSourceIdentity')
    $ownerPrefixCase.Backend.GetSecurity = { param($path) return 'O:S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464-999G:SYD:PAI(A;;FA;;;SY)' }
    Use-IsolatedCase $ownerPrefixCase
    $ownerPrefixState = Get-AesSystemState
    Assert-Equal $ownerPrefixState.Status 'ExternalDrift' 'TrustedInstaller SID prefix with an extra subauthority remains external drift'
    Assert-Equal $ownerPrefixState.DiagnosticCode 'NativeOwnerUnrecognized' 'TrustedInstaller SID prefix with an extra subauthority is not accepted'

    # A fixed Apple file or a recorded prior output without a backup is never
    # permitted to become a new native baseline, even if it retains the original
    # descriptor and mapping after ProgramData was removed.
    $recordWithoutBackupCase = New-IsolatedCase; $cases.Add($recordWithoutBackupCase)
    Copy-Item -LiteralPath $recordWithoutBackupCase.Source -Destination $recordWithoutBackupCase.Target -Force
    [void][System.IO.Directory]::CreateDirectory($recordWithoutBackupCase.Backend.Root)
    @{ schemaVersion = 1; status = 'Installed'; installedOutputHash = (Get-TestHash $recordWithoutBackupCase.Source) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $recordWithoutBackupCase.Backend.Root 'state.json') -Encoding utf8
    Use-IsolatedCase $recordWithoutBackupCase
    $recordWithoutBackupState = Get-AesSystemState
    Assert-Equal $recordWithoutBackupState.Status 'ExternalDrift' 'recorded output without an original backup is not accepted as native'
    Assert-Equal $recordWithoutBackupState.DiagnosticCode 'MissingOriginalBackup' 'recorded output without a backup identifies the missing evidence'
    $recordWithoutBackupInstall = Install-AesFont -FontPath $recordWithoutBackupCase.Source -ReportPath $recordWithoutBackupCase.Coverage
    Assert-Equal $recordWithoutBackupInstall.Status 'Failed' 'recorded output without a backup cannot be reinstalled as native'
    Assert-Equal $recordWithoutBackupCase.State.QueueCount 0 'recorded output without a backup never queues a replacement'

    $pinnedWithoutBackupCase = New-IsolatedCase; $cases.Add($pinnedWithoutBackupCase)
    try {
        Set-TestPinnedIdentity $pinnedWithoutBackupCase
        Copy-Item -LiteralPath $pinnedWithoutBackupCase.Source -Destination $pinnedWithoutBackupCase.Target -Force
        Use-IsolatedCase $pinnedWithoutBackupCase
        $pinnedWithoutBackupState = Get-AesSystemState
        Assert-Equal $pinnedWithoutBackupState.Status 'ExternalDrift' 'known pinned Apple bytes without an original backup are not accepted as native'
        Assert-Equal $pinnedWithoutBackupState.DiagnosticCode 'MissingOriginalBackup' 'known pinned Apple bytes identify the missing original backup'
        $pinnedWithoutBackupInstall = Install-AesFont -FontPath $pinnedWithoutBackupCase.Source -PinnedApple
        Assert-Equal $pinnedWithoutBackupInstall.Status 'Failed' 'known pinned Apple bytes without a backup cannot be reinstalled as native'
        Assert-Equal $pinnedWithoutBackupCase.State.QueueCount 0 'known pinned Apple bytes without a backup never queue a replacement'
    } finally { Reset-TestPinnedIdentity }

    # A corrupt backup is a hard stop; it must not queue a new operation.
    $case = New-IsolatedCase; $cases.Add($case); Use-IsolatedCase $case
    [void][System.IO.Directory]::CreateDirectory((Join-Path $case.Backend.Root 'backup'))
    [System.IO.File]::WriteAllText((Join-Path $case.Backend.Root 'backup\\original.json'), '{not json')
    [System.IO.File]::WriteAllText((Join-Path $case.Backend.Root 'backup\\seguiemj.ttf'), 'wrong backup bytes')
    $corrupt = Install-AesFont -FontPath $case.Source -ReportPath $case.Coverage
    Assert-Equal $corrupt.Status 'Failed' 'corrupt backup prevents install'
    Assert-Equal $case.State.QueueCount 0 'corrupt backup never queues replacement'

    # A pre-created untrusted ProgramData transaction root is never tightened
    # and reused.  The privileged operation fails before any queue/ACL action.
    $case = New-IsolatedCase; $cases.Add($case)
    [void][System.IO.Directory]::CreateDirectory($case.Backend.Root)
    $case.Backend.AssertTrustedPath = { param($path) throw 'injected untrusted transaction root' }
    Use-IsolatedCase $case
    $untrustedRoot = Install-AesFont -FontPath $case.Source -ReportPath $case.Coverage
    Assert-Equal $untrustedRoot.Status 'Failed' 'untrusted existing core root prevents install'
    Assert-Equal $case.State.QueueCount 0 'untrusted root never queues replacement'

    # A legacy `status: passed` report cannot bypass the native sequence gate.
    $case = New-IsolatedCase; $cases.Add($case); Use-IsolatedCase $case
    $legacyReport = Get-Content -Raw -LiteralPath $case.Coverage | ConvertFrom-Json
    $legacyReport.checks.PSObject.Properties.Remove('nativeSequenceRegression')
    $legacyReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $case.Coverage -Encoding utf8
    $legacy = Install-AesFont -FontPath $case.Source -ReportPath $case.Coverage
    Assert-Equal $legacy.Status 'Failed' 'legacy coverage missing native sequence regression is rejected'
    Assert-Equal $case.State.QueueCount 0 'legacy coverage never queues replacement'

    # Explicit local-display warnings are accepted only under the versioned
    # policy.  The hard structure/sequence checks remain passed.
    $case = New-IsolatedCase; $cases.Add($case); Use-IsolatedCase $case
    $warningReport = Get-Content -Raw -LiteralPath $case.Coverage | ConvertFrom-Json
    $warningReport.status = 'passed_with_warnings'
    $warningReport | Add-Member -NotePropertyName compatibilityPolicy -NotePropertyValue 'warn-on-local-display-differences-v1'
    $warningReport | Add-Member -NotePropertyName warnings -NotePropertyValue @(@{ check = 'nativeSequenceRegression'; detail = 'local flag rendering differs' })
    $warningReport.checks.nativeSequenceRegression = 'warning'
    $warningReport.checks.nativeRenderSmoke = 'warning'
    $warningReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $case.Coverage -Encoding utf8
    $warningInstall = Install-AesFont -FontPath $case.Source -ReportPath $case.Coverage
    Assert-Equal $warningInstall.Status 'PendingInstall' ("explicit compatibility warnings queue replacement: " + $warningInstall.Reason)
    Assert-Equal $case.State.QueueCount 1 'approved local-display warnings queue once'

    # A warning policy never relaxes a structural correctness failure.
    $case = New-IsolatedCase; $cases.Add($case); Use-IsolatedCase $case
    $failedSafetyReport = Get-Content -Raw -LiteralPath $case.Coverage | ConvertFrom-Json
    $failedSafetyReport.status = 'passed_with_warnings'
    $failedSafetyReport | Add-Member -NotePropertyName compatibilityPolicy -NotePropertyValue 'warn-on-local-display-differences-v1'
    $failedSafetyReport | Add-Member -NotePropertyName warnings -NotePropertyValue @(@{ check = 'nativeRenderSmoke'; detail = 'local display warning' })
    $failedSafetyReport.checks.nativeRenderSmoke = 'warning'
    $failedSafetyReport.checks.fontStructure = 'failed'
    $failedSafetyReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $case.Coverage -Encoding utf8
    $failedSafety = Install-AesFont -FontPath $case.Source -ReportPath $case.Coverage
    Assert-Equal $failedSafety.Status 'Failed' 'failed structural coverage check is rejected under warning policy'
    Assert-Equal $case.State.QueueCount 0 'failed structural coverage never queues replacement'

    # A failed staging copy rolls back its new backup and leaves the original
    # target and its descriptor untouched.
    $case = New-IsolatedCase -FailStage; $cases.Add($case); Use-IsolatedCase $case
    $failedStage = Install-AesFont -FontPath $case.Source -ReportPath $case.Coverage
    Assert-Equal $failedStage.Status 'Failed' 'stage failure is reported'
    Assert-Equal $case.State.QueueCount 0 'stage failure never queues replacement'
    Assert-Equal (Get-TestHash $case.Target) $case.OriginalHash 'stage failure preserves target bytes'
    Assert-Equal $case.State.Security[$case.Target] 'O:BADG:BAD:(A;;FA;;;BA)' 'stage failure preserves target security'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $case.Backend.Root 'backup\\seguiemj.ttf'))) 'rollback removes only its newly created backup'

    # The staging helper must bind the copied bytes to the already approved
    # journal hash, not merely compare the stage to a source that could change
    # in the copy window.  A pre-existing verified backup must survive intact.
    $case = New-IsolatedCase -TamperStage; $cases.Add($case)
    $backupDirectory = Join-Path $case.Backend.Root 'backup'; [void][System.IO.Directory]::CreateDirectory($backupDirectory)
    $backupFont = Join-Path $backupDirectory 'seguiemj.ttf'; $backupMetadata = Join-Path $backupDirectory 'original.json'
    Copy-Item -LiteralPath $case.Target -Destination $backupFont
    @{ schemaVersion = 1; originalHash = $case.OriginalHash; originalSddl = 'O:BADG:BAD:(A;;FA;;;BA)'; originalOwnerAndAclSddl = 'O:BADG:BAD:(A;;FA;;;BA)'; fontRegistry = @{ Exists = $true }; targetPath = $case.Target; build = 22631 } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $backupMetadata -Encoding utf8
    Use-IsolatedCase $case
    $tamperedStage = Install-AesFont -FontPath $case.Source -ReportPath $case.Coverage
    Assert-Equal $tamperedStage.Status 'Failed' 'source/stage tampering after approval is rejected'
    Assert-Equal $case.State.QueueCount 0 'source/stage tampering never queues replacement'
    Assert-Equal (Get-TestHash $case.Target) $case.OriginalHash 'source/stage tampering preserves target bytes'
    Assert-Equal (Get-TestHash $backupFont) $case.OriginalHash 'source/stage tampering preserves the existing original backup'
    Assert-True (Test-Path -LiteralPath $backupMetadata -PathType Leaf) 'source/stage tampering preserves existing backup metadata'
    Assert-True (-not (Get-ChildItem -LiteralPath (Join-Path $case.Backend.Root 'stage') -File -ErrorAction SilentlyContinue)) 'tampered stage bytes are removed during rollback'

    # If queueing fails after the target has its temporary SYSTEM Delete ACE,
    # rollback restores the original descriptor and removes anchor/finalizer.
    $case = New-IsolatedCase -FailQueue; $cases.Add($case); Use-IsolatedCase $case
    $failedQueue = Install-AesFont -FontPath $case.Source -ReportPath $case.Coverage
    Assert-Equal $failedQueue.Status 'Failed' 'queue failure is reported'
    Assert-Equal $case.State.Security[$case.Target] 'O:BADG:BAD:(A;;FA;;;BA)' 'queue failure restores target security'
    Assert-Equal $case.State.Pending.Count 4 'queue failure preserves all unrelated pending entries'
    Assert-True ($null -eq $case.State.FinalizerTask) 'queue failure removes the registered finalizer'
    Assert-True (-not (Get-ChildItem -LiteralPath (Join-Path $case.Backend.Root 'anchor') -File -ErrorAction SilentlyContinue)) 'queue failure removes its restore anchor'

    # A Windows update after an older verified backup remains external drift.
    # A current TrustedInstaller owner and valid native registry mapping do not
    # authorize replacing the newer Windows bytes or silently rebasing backup.
    $case = New-IsolatedCase; $cases.Add($case); Use-IsolatedCase $case
    $backupDirectory = Join-Path $case.Backend.Root 'backup'; [void][System.IO.Directory]::CreateDirectory($backupDirectory)
    Copy-Item -LiteralPath $case.Target -Destination (Join-Path $backupDirectory 'seguiemj.ttf')
    @{ schemaVersion = 1; originalHash = $case.OriginalHash; originalSddl = 'O:BADG:BAD:(A;;FA;;;BA)'; originalOwnerAndAclSddl = 'O:BADG:BAD:(A;;FA;;;BA)'; fontRegistry = @{ Exists = $true }; targetPath = $case.Target; build = 22631 } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $backupDirectory 'original.json') -Encoding utf8
    @{ schemaVersion = 1; status = 'Installed'; outputHash = (Get-TestHash $case.Source) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $case.Backend.Root 'state.json') -Encoding utf8
    [System.IO.File]::WriteAllBytes($case.Target, [System.Text.Encoding]::UTF8.GetBytes('external Windows update font'))
    $case.Backend.Remove('GetMicrosoftSourceIdentity')
    $case.Backend.GetSecurity = { param($path) return 'O:TIG:SYD:PAI(A;;FA;;;SY)' }
    $case.Backend.GetFontRegistry = { return @{ Path = 'HKLM:\test-fonts'; Name = 'Segoe UI Emoji (TrueType)'; Exists = $true; Value = 'seguiemj.ttf'; Kind = 'String' } }
    Use-IsolatedCase $case
    $drift = Get-AesSystemState
    Assert-Equal $drift.Status 'ExternalDrift' 'external font is recognized as drift'
    Assert-Equal $drift.DiagnosticCode 'FontBytesChanged' 'newer native bytes after an old backup are diagnosed without automatic acceptance'
    Assert-Equal $drift.OriginalHash $case.OriginalHash 'drift reports the verified original backup hash'
    Assert-Equal $drift.RecordedOutputHash (Get-TestHash $case.Source) 'drift reports the recorded transaction output hash'
    $restore = Restore-AesFont
    Assert-Equal $restore.Status 'Failed' 'restore refuses external drift'
    Assert-Equal $case.State.QueueCount 0 'external drift never queues restore'

    $missingRecordCase = New-IsolatedCase; $cases.Add($missingRecordCase); Use-IsolatedCase $missingRecordCase
    $backupDirectory = Join-Path $missingRecordCase.Backend.Root 'backup'; [void][System.IO.Directory]::CreateDirectory($backupDirectory)
    Copy-Item -LiteralPath $missingRecordCase.Target -Destination (Join-Path $backupDirectory 'seguiemj.ttf')
    @{ schemaVersion = 1; originalHash = $missingRecordCase.OriginalHash; originalSddl = 'O:BADG:BAD:(A;;FA;;;BA)'; originalOwnerAndAclSddl = 'O:BADG:BAD:(A;;FA;;;BA)'; fontRegistry = @{ Exists = $true }; targetPath = $missingRecordCase.Target; build = 22631 } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $backupDirectory 'original.json') -Encoding utf8
    Copy-Item -LiteralPath $missingRecordCase.Source -Destination $missingRecordCase.Target -Force
    $missingRecord = Get-AesSystemState
    Assert-Equal $missingRecord.Status 'ExternalDrift' 'replacement bytes without a state record remain external drift'
    Assert-Equal $missingRecord.DiagnosticCode 'MissingInstallRecord' 'replacement bytes without a state record identify missing transaction evidence'

    $missingFontCase = New-IsolatedCase; $cases.Add($missingFontCase); Use-IsolatedCase $missingFontCase
    Remove-Item -LiteralPath $missingFontCase.Target -Force
    $missingFont = Get-AesSystemState
    Assert-Equal $missingFont.Status 'ExternalDrift' 'missing target remains external drift'
    Assert-Equal $missingFont.DiagnosticCode 'FontMissing' 'missing target receives a specific diagnostic'

    # Verify-AesInstallation is read-only and checks the active bytes, the
    # immutable backup, and the original owner/group/DACL before declaring an
    # installed replacement complete.
    $case = New-IsolatedCase; $cases.Add($case); Use-IsolatedCase $case
    $backupDirectory = Join-Path $case.Backend.Root 'backup'; [void][System.IO.Directory]::CreateDirectory($backupDirectory)
    Copy-Item -LiteralPath $case.Target -Destination (Join-Path $backupDirectory 'seguiemj.ttf')
    @{ schemaVersion = 1; originalHash = $case.OriginalHash; originalSddl = 'O:BADG:BAD:(A;;FA;;;BA)'; originalOwnerAndAclSddl = 'O:BADG:BAD:(A;;FA;;;BA)'; fontRegistry = @{ Exists = $true }; targetPath = $case.Target; build = 22631 } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $backupDirectory 'original.json') -Encoding utf8
    Copy-Item -LiteralPath $case.Source -Destination $case.Target -Force
    @{ schemaVersion = 1; status = 'Installed'; installedOutputHash = (Get-TestHash $case.Source); installationMode = 'Built' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $case.Backend.Root 'state.json') -Encoding utf8
    $verified = Verify-AesInstallation
    Assert-True $verified.VerificationPassed 'installed built font verifies without drawing claims'
    $case.State.Security[$case.Target] = 'O:BADG:BAD:(A;;FA;;;WD)'
    $badPermissions = Verify-AesInstallation
    Assert-True (-not $badPermissions.VerificationPassed) 'verification rejects owner/group/DACL drift'
    Assert-True ($badPermissions.VerificationReason -match 'owner, group, or DACL') 'verification reports permission drift'
    $case.State.Security[$case.Target] = 'O:BADG:BAD:(A;;FA;;;BA)'
    $finalizerId = 'f' * 32; $case.State.FinalizerTask = "\AppleEmojiSwitcher-Finalize-$finalizerId"
    @{ schemaVersion = 1; operationId = $finalizerId; operation = 'Install'; targetPath = $case.Target; stagePath = (Join-Path $case.Backend.Root 'stage\seguiemj.ffffffffffffffffffffffffffffffff.ttf'); pendingOutputHash = (Get-TestHash $case.Source); installationMode = 'Built'; anchorPath = (Join-Path $case.Backend.Root 'anchor\old-inode.ffffffffffffffffffffffffffffffff.ttf'); finalizerTaskName = $case.State.FinalizerTask } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $case.Backend.Root 'journal.json') -Encoding utf8
    $unfinishedFinalizer = Verify-AesInstallation
    Assert-True (-not $unfinishedFinalizer.VerificationPassed) 'installed bytes are not complete while finalizer remains registered'
    Assert-True ($unfinishedFinalizer.VerificationReason -match 'finalizer') 'verification identifies finalizer rollback state'
    $case.State.FinalizerTask = $null

    # Pinned mode verifies only the fixed release identity.  The temporary
    # private expected identity lets this isolated test use tiny fixture bytes;
    # production callers cannot set it through any exported parameter.
    $pinCase = New-IsolatedCase; $cases.Add($pinCase); Use-IsolatedCase $pinCase
    Set-TestPinnedIdentity $pinCase
    try {
        $badHashPath = Join-Path $pinCase.Root 'bad-hash.ttf'
        $badHashBytes = [System.IO.File]::ReadAllBytes($pinCase.Source); $badHashBytes[0] = $badHashBytes[0] -bxor 1
        [System.IO.File]::WriteAllBytes($badHashPath, $badHashBytes)
        $badHash = Install-AesFont -FontPath $badHashPath -PinnedApple
        Assert-Equal $badHash.Status 'Failed' 'pinned mode rejects an incorrect SHA-256'
        Assert-Equal $pinCase.State.QueueCount 0 'incorrect pinned hash never queues a replacement'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $pinCase.Backend.Root 'backup\seguiemj.ttf'))) 'incorrect pinned hash creates no original backup'

        $badSizePath = Join-Path $pinCase.Root 'bad-size.ttf'
        $originalBytes = [System.IO.File]::ReadAllBytes($pinCase.Source); $largerBytes = New-Object byte[] ($originalBytes.Length + 1); [Array]::Copy($originalBytes, $largerBytes, $originalBytes.Length)
        [System.IO.File]::WriteAllBytes($badSizePath, $largerBytes)
        $badSize = Install-AesFont -FontPath $badSizePath -PinnedApple
        Assert-Equal $badSize.Status 'Failed' 'pinned mode rejects an incorrect byte size'
        Assert-Equal $pinCase.State.QueueCount 0 'incorrect pinned size never queues a replacement'

        $pinned = Install-AesFont -FontPath $pinCase.Source -PinnedApple
        Assert-Equal $pinned.Status 'PendingInstall' ('pinned release queues a verified replacement: ' + $pinned.Reason)
        Assert-Equal $pinned.InstallationMode 'Pinned' 'pinned pending state records its mode'
        Assert-True (-not $pinned.RenderVerificationPending) 'pinned mode never claims a render-verification requirement'
        $pinnedJournal = Get-Content -Raw -LiteralPath (Join-Path $pinCase.Backend.Root 'journal.json') | ConvertFrom-Json
        Assert-Equal $pinnedJournal.installationMode 'Pinned' 'pinned mode reaches the finalizer journal'
        $pendingVerification = Verify-AesInstallation
        Assert-True (-not $pendingVerification.VerificationPassed) 'pending pinned replacement is not reported complete'
        $pinnedAgain = Install-AesFont -FontPath $pinCase.Source -PinnedApple
        Assert-Equal $pinnedAgain.Status 'PendingInstall' 'duplicate pinned request reports the existing transaction'
        Assert-Equal $pinCase.State.QueueCount 1 'duplicate pinned request does not queue again'

        # Simulate the consumed boot pair and a completed permission rollback,
        # then ensure a GUI/Built request cannot overwrite the installed pinned
        # font until the shared restore/reboot boundary has happened.
        $pinCase.State.Pending = @($pinCase.State.Pending[0..3])
        Copy-Item -LiteralPath $pinCase.Source -Destination $pinCase.Target -Force
        Remove-Item -LiteralPath $pinnedJournal.stagePath -Force
        Remove-Item -LiteralPath $pinnedJournal.anchorPath -Force
        $pinCase.State.FinalizerTask = $null
        $pinCase.State.Security[$pinCase.Target] = 'O:BADG:BAD:(A;;FA;;;BA)'
        $installedPinned = Get-AesSystemState
        Assert-Equal $installedPinned.InstallationMode 'Pinned' 'legacy journal inference recognizes the fixed pinned hash'
        $crossMode = Install-AesFont -FontPath $pinCase.Source -ReportPath $pinCase.Coverage
        Assert-Equal $crossMode.Status 'Installed' 'cross-mode request reports the installed pinned font'
        Assert-Equal $pinCase.State.QueueCount 1 'cross-mode request does not overwrite or queue'
        $restorePinned = Restore-AesFont
        Assert-Equal $restorePinned.Status 'PendingRestore' ('CLI can restore a pinned installation created by the shared transaction core: ' + $restorePinned.Reason)
        Assert-Equal $restorePinned.InstallationMode 'Pinned' 'pending restore retains the installed mode for status reporting'
        $cancelPinnedRestore = Undo-AesPendingOperation
        Assert-Equal $cancelPinnedRestore.Status 'Cancelled' 'CLI can cancel the pending shared restore'
        $afterPinnedCancel = Get-AesSystemState
        Assert-Equal $afterPinnedCancel.InstallationMode 'Pinned' 'cancelled restore returns to the pinned installation mode'
    } finally { Reset-TestPinnedIdentity }

    # Old persistent state records have no mode field.  A non-pinned output is
    # conservatively inferred as Built so current GUI installations remain
    # compatible with the new CLI.
    $legacyCase = New-IsolatedCase; $cases.Add($legacyCase); Use-IsolatedCase $legacyCase
    $backupDirectory = Join-Path $legacyCase.Backend.Root 'backup'; [void][System.IO.Directory]::CreateDirectory($backupDirectory)
    Copy-Item -LiteralPath $legacyCase.Target -Destination (Join-Path $backupDirectory 'seguiemj.ttf')
    @{ schemaVersion = 1; originalHash = $legacyCase.OriginalHash; originalSddl = 'O:BADG:BAD:(A;;FA;;;BA)'; originalOwnerAndAclSddl = 'O:BADG:BAD:(A;;FA;;;BA)'; fontRegistry = @{ Exists = $true }; targetPath = $legacyCase.Target; build = 22631 } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $backupDirectory 'original.json') -Encoding utf8
    Copy-Item -LiteralPath $legacyCase.Source -Destination $legacyCase.Target -Force
    @{ schemaVersion = 1; status = 'Installed'; outputHash = (Get-TestHash $legacyCase.Source) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $legacyCase.Backend.Root 'state.json') -Encoding utf8
    $legacyMode = Get-AesSystemState
    Assert-Equal $legacyMode.InstallationMode 'Built' 'legacy state without a mode is inferred as Built'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\lib\Finalize-Transaction.ps1')) -match 'installationMode') 'startup finalizer persists installation mode into finalized state'

    'PASS Test-SystemTransaction.ps1: isolated queue, mode-aware install/restore/cancel, Pinned asset rejection, verification, and legacy state cases passed.'
} finally {
    Clear-IsolatedCase
    Reset-TestPinnedIdentity
    foreach ($case in $cases) { Remove-IsolatedCase $case }
    Remove-Module SystemTransaction -Force -ErrorAction SilentlyContinue
}
