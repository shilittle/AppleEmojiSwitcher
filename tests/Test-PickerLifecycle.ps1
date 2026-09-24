Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw ('{0}: actual={1}; expected={2}' -f $Message, $Actual, $Expected) }
}

function Invoke-ControllerJson {
    param([Parameter(Mandatory = $true)][string]$Controller, [Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = & $Controller @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { throw ('controller returned no JSON for ' + ($Arguments -join ' ')) }
    try { $payload = $text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw ('controller returned invalid JSON for ' + ($Arguments -join ' ') + ': ' + $text) }
    return [pscustomobject]@{ ExitCode = $code; Payload = $payload; Raw = $text }
}

function Assert-ControllerResult {
    param($Result, [bool]$Success, [string]$Command, [string]$Message)
    Assert-Equal ([bool]$Result.Payload.success) $Success ($Message + ' success')
    Assert-Equal ([string]$Result.Payload.command) $Command ($Message + ' command')
    Assert-Equal ([int]$Result.Payload.injectedCount) 0 ($Message + ' has no injection')
    Assert-Equal ([string]$Result.Payload.manualAcceptance) 'pending' ($Message + ' preserves manual acceptance')
    Assert-Equal ($Result.ExitCode -eq 0) $Success ($Message + ' exit code')
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$build = Join-Path $repoRoot 'native\picker\build-picker.cmd'
$compiledController = Join-Path $repoRoot 'bin\PanelController.LifecycleTest.exe'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('AES-PickerLifecycle-' + [Guid]::NewGuid().ToString('N'))
$portableBin = Join-Path $tempRoot 'portable\bin'
$badBin = Join-Path $tempRoot 'bad-portable\bin'
$isolatedLocalAppData = Join-Path $tempRoot 'local-app-data'
$registryPath = 'Software\AppleEmojiSwitcher\Tests\PickerLifecycle-' + [Guid]::NewGuid().ToString('N')
$oldLocalAppData = $env:LOCALAPPDATA
$oldMode = $env:AES_PICKER_TEST_MODE
$oldRegistry = $env:AES_PICKER_TEST_REGISTRY_PATH
$oldWait = $env:AES_PICKER_TEST_WAIT_MS
$oldUiFailure = $env:AES_PICKER_TEST_UI_FAIL
$portableController = $null

try {
    & cmd.exe /d /c $build --lifecycle-stub
    if ($LASTEXITCODE -ne 0) { throw 'lifecycle stub build failed' }
    Assert-True (Test-Path -LiteralPath $compiledController -PathType Leaf) 'lifecycle stub executable was not built'

    New-Item -ItemType Directory -Path (Join-Path $portableBin 'picker-data\images') -Force | Out-Null
    New-Item -ItemType Directory -Path $badBin -Force | Out-Null
    Copy-Item -LiteralPath $compiledController -Destination (Join-Path $portableBin 'PanelController.exe') -Force
    Copy-Item -LiteralPath $compiledController -Destination (Join-Path $badBin 'PanelController.exe') -Force
    [IO.File]::WriteAllText((Join-Path $portableBin 'picker-data\catalog.tsv'), "unicode`tname`n😀`ttest", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $portableBin 'picker-data\images\sample.txt'), 'fixture', (New-Object Text.UTF8Encoding($false)))
    $portableController = Join-Path $portableBin 'PanelController.exe'

    $env:LOCALAPPDATA = $isolatedLocalAppData
    $env:AES_PICKER_TEST_MODE = '1'
    $env:AES_PICKER_TEST_REGISTRY_PATH = $registryPath
    $env:AES_PICKER_TEST_WAIT_MS = '750'
    Remove-Item Env:AES_PICKER_TEST_UI_FAIL -ErrorAction SilentlyContinue

    $missing = Invoke-ControllerJson -Controller (Join-Path $badBin 'PanelController.exe') -Arguments @('enable', '--json')
    Assert-ControllerResult $missing $false 'enable' 'missing catalog is rejected'
    Assert-Equal ([string]$missing.Payload.failureReason) 'source_catalog_missing' 'missing catalog failure reason'

    $enabled = Invoke-ControllerJson -Controller $portableController -Arguments @('enable', '--json')
    Assert-ControllerResult $enabled $true 'enable' 'enable copies payload and starts stub'
    Assert-True ([bool]$enabled.Payload.installed) 'enable reports installed'
    Assert-True ([bool]$enabled.Payload.enabled) 'enable reports enabled'
    $installedRoot = Join-Path $isolatedLocalAppData 'AppleEmojiSwitcher\panel'
    Assert-True (Test-Path -LiteralPath (Join-Path $installedRoot 'PanelController.exe') -PathType Leaf) 'controller copied into isolated local app data'
    Assert-True (Test-Path -LiteralPath (Join-Path $installedRoot 'picker-data\catalog.tsv') -PathType Leaf) 'catalog copied into isolated local app data'
    Assert-True (Test-Path -LiteralPath (Join-Path $installedRoot 'install-manifest.txt') -PathType Leaf) 'owned-file manifest written'
    $runKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryPath, $false)
    try {
        Assert-True ($null -ne $runKey) 'isolated test startup key was created'
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$runKey.GetValue('AppleEmojiSwitcher.PanelController', $null))) 'isolated test startup value was created'
    }
    finally { if ($null -ne $runKey) { $runKey.Dispose() } }

    $status = Invoke-ControllerJson -Controller $portableController -Arguments @('status', '--json')
    Assert-ControllerResult $status $true 'status' 'status after enable'
    Assert-Equal ([string]$status.Payload.state) 'running' 'stub reports current-session running state'

    $disabled = Invoke-ControllerJson -Controller $portableController -Arguments @('disable', '--json')
    Assert-ControllerResult $disabled $true 'disable' 'disable removes startup and waits for stop'
    Assert-True (-not [bool]$disabled.Payload.enabled) 'disable reports disabled'
    $runKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryPath, $false)
    try {
        Assert-True ($null -eq $runKey -or $null -eq $runKey.GetValue('AppleEmojiSwitcher.PanelController', $null)) 'disable did not leave a startup value'
    }
    finally { if ($null -ne $runKey) { $runKey.Dispose() } }

    $env:AES_PICKER_TEST_UI_FAIL = '1'
    $startupFailure = Invoke-ControllerJson -Controller $portableController -Arguments @('enable', '--json')
    Assert-ControllerResult $startupFailure $false 'enable' 'startup failure is surfaced'
    Assert-Equal ([string]$startupFailure.Payload.failureReason) 'startup_not_ready' 'startup failure reason'
    Assert-True (-not [bool]$startupFailure.Payload.enabled) 'failed startup rolls back test startup registration'
    Remove-Item Env:AES_PICKER_TEST_UI_FAIL -ErrorAction SilentlyContinue

    $enabledAgain = Invoke-ControllerJson -Controller $portableController -Arguments @('enable', '--json')
    Assert-ControllerResult $enabledAgain $true 'enable' 'enable recovers after startup failure'
    New-Item -ItemType Directory -Path (Join-Path $installedRoot 'user-data') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $installedRoot 'user-data\keep.txt'), 'keep', (New-Object Text.UTF8Encoding($false)))

    $installedController = Join-Path $installedRoot 'PanelController.exe'
    $uninstall = Invoke-ControllerJson -Controller $installedController -Arguments @('uninstall', '--json')
    Assert-ControllerResult $uninstall $true 'uninstall' 'self uninstall is scheduled after controller exits'
    Assert-Equal ([string]$uninstall.Payload.state) 'uninstall_scheduled' 'installed controller uses delayed self cleanup'
    $deadline = (Get-Date).AddSeconds(15)
    while ((Test-Path -LiteralPath $installedController) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 150 }
    Assert-True (-not (Test-Path -LiteralPath $installedController)) 'self cleanup removed only the installed controller after exit'
    Assert-True (Test-Path -LiteralPath (Join-Path $installedRoot 'user-data\keep.txt') -PathType Leaf) 'uninstall preserved user data outside the manifest'

    $reparseLocalAppData = Join-Path $tempRoot 'reparse-local-app-data'
    $outside = Join-Path $tempRoot 'junction-target'
    $junction = Join-Path $reparseLocalAppData 'AppleEmojiSwitcher'
    New-Item -ItemType Directory -Path $reparseLocalAppData, $outside -Force | Out-Null
    & cmd.exe /d /c "mklink /J `"$junction`" `"$outside`"" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'could not create isolated junction fixture' }
    $env:LOCALAPPDATA = $reparseLocalAppData
    $reparse = Invoke-ControllerJson -Controller $portableController -Arguments @('enable', '--json')
    Assert-ControllerResult $reparse $false 'enable' 'reparse-point install root is rejected'
    Assert-Equal ([string]$reparse.Payload.failureReason) 'unsafe_reparse_path' 'reparse-point failure reason'
    [IO.Directory]::Delete($junction, $false)
    Assert-True (-not (Test-Path -LiteralPath $junction)) 'junction fixture was removed without traversing its target'

    'PASS picker lifecycle: isolated install/start/stop, failed readiness rollback, self-uninstall, manifest user-data preservation, and reparse rejection.'
}
finally {
    if (-not [string]::IsNullOrEmpty($portableController) -and (Test-Path -LiteralPath $portableController -PathType Leaf)) {
        try { & $portableController disable --json | Out-Null } catch { }
    }
    try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryPath, $false) } catch { }
    if ($null -eq $oldLocalAppData) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $oldLocalAppData }
    if ($null -eq $oldMode) { Remove-Item Env:AES_PICKER_TEST_MODE -ErrorAction SilentlyContinue } else { $env:AES_PICKER_TEST_MODE = $oldMode }
    if ($null -eq $oldRegistry) { Remove-Item Env:AES_PICKER_TEST_REGISTRY_PATH -ErrorAction SilentlyContinue } else { $env:AES_PICKER_TEST_REGISTRY_PATH = $oldRegistry }
    if ($null -eq $oldWait) { Remove-Item Env:AES_PICKER_TEST_WAIT_MS -ErrorAction SilentlyContinue } else { $env:AES_PICKER_TEST_WAIT_MS = $oldWait }
    if ($null -eq $oldUiFailure) { Remove-Item Env:AES_PICKER_TEST_UI_FAIL -ErrorAction SilentlyContinue } else { $env:AES_PICKER_TEST_UI_FAIL = $oldUiFailure }
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $tempFull = [IO.Path]::GetFullPath($tempRoot)
    if ($tempFull.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $tempFull)) {
        try { [IO.Directory]::Delete($tempFull, $true) } catch { }
    }
}
