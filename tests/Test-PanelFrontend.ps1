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

function Assert-Contains {
    param([string]$Text, [string]$Needle, [string]$Message)
    if ($null -eq $Text -or $Text.IndexOf($Needle, [StringComparison]::Ordinal) -lt 0) { throw $Message }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$commonPath = Join-Path $repoRoot 'lib\Common.ps1'
$panelPath = Join-Path $repoRoot 'lib\Panel.ps1'
. $commonPath
. $panelPath

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('AES 面板前端 ' + [Guid]::NewGuid().ToString('N'))
$portableRoot = Join-Path $tempRoot '便携 包 with spaces'
$portableBin = Join-Path $portableRoot 'bin'
$installedRoot = Join-Path $tempRoot '安装目录 with spaces'
New-Item -ItemType Directory -Path $portableBin -Force | Out-Null
New-Item -ItemType Directory -Path $installedRoot -Force | Out-Null
New-Item -ItemType File -Path (Join-Path $portableBin 'PanelController.exe') -Force | Out-Null

$oldLocalAppData = $env:LOCALAPPDATA
$oldInvoker = $script:AesPanelControllerInvoker
try {
    $env:LOCALAPPDATA = $tempRoot
    New-Item -ItemType File -Path (Join-Path $installedRoot 'PanelController.exe') -Force | Out-Null

    $enablePath = Resolve-AesPanelControllerPath -PackageRoot $portableRoot -Command 'enable'
    Assert-Equal $enablePath (Join-Path $portableBin 'PanelController.exe') 'enable prefers portable controller during an upgrade'

    # The installed path is intentionally under the test LOCALAPPDATA tree.
    $installedPanelDir = Get-AesPanelLocalRoot
    New-Item -ItemType Directory -Path $installedPanelDir -Force | Out-Null
    New-Item -ItemType File -Path (Get-AesPanelInstalledControllerPath) -Force | Out-Null
    $statusPath = Resolve-AesPanelControllerPath -PackageRoot $portableRoot -Command 'status'
    Assert-Equal $statusPath (Get-AesPanelInstalledControllerPath) 'status prefers the installed controller'
    Assert-Equal (Resolve-AesPanelControllerPath -PackageRoot $portableRoot -Command 'disable') (Get-AesPanelInstalledControllerPath) 'disable prefers installed controller'
    Assert-Equal (Resolve-AesPanelControllerPath -PackageRoot $portableRoot -Command 'uninstall') (Get-AesPanelInstalledControllerPath) 'uninstall prefers installed controller'
    Remove-Item -LiteralPath (Get-AesPanelInstalledControllerPath) -Force
    Assert-Equal (Resolve-AesPanelControllerPath -PackageRoot $portableRoot -Command 'status') (Join-Path $portableBin 'PanelController.exe') 'status falls back to portable controller'

    $successJson = '{"success":true,"command":"enable","state":"enabled","message":"扩展已启用","manualAcceptance":"pending","installed":true,"enabled":true,"injectedCount":2,"failureReason":""}'
    $success = ConvertFrom-AesPanelJson -Command 'enable' -RawOutput $successJson -ProcessExitCode 0 -ControllerPath 'C:\临时 路径\PanelController.exe'
    Assert-True $success.Success 'success JSON is accepted'
    Assert-Equal $success.InjectedCount 2 'injected count is preserved'
    Assert-Contains (Format-AesPanelResultMessage -Result $success) '仍需手工验收' 'manual acceptance remains visible'

    $invalid = ConvertFrom-AesPanelJson -Command 'status' -RawOutput 'not-json' -ProcessExitCode 0
    Assert-True (-not $invalid.Success) 'invalid controller response must not report success'
    Assert-Equal $invalid.ExitCode 1 'invalid JSON with exit zero becomes failure'
    $crashed = ConvertFrom-AesPanelJson -Command 'enable' -RawOutput $successJson -ProcessExitCode 1
    Assert-True (-not $crashed.Success) 'nonzero controller exit overrides success payload'

    $failureJson = '{"success":false,"command":"disable","state":"failed","message":"版本不匹配","manualAcceptance":"pending","installed":true,"enabled":true,"injectedCount":0,"failureReason":"component_hash_mismatch"}'
    $failure = ConvertFrom-AesPanelJson -Command 'disable' -RawOutput $failureJson -ProcessExitCode 1 -ControllerPath 'C:\临时 路径\PanelController.exe'
    Assert-True (-not $failure.Success) 'failure JSON remains failure'
    Assert-Equal $failure.FailureReason 'component_hash_mismatch' 'failure reason is preserved'

    # Isolated native outcomes: this exercises the same invocation path while
    # avoiding registration, login startup, process injection, or host restart.
    $script:AesPanelControllerInvoker = {
        param($command, $controller)
        if ($command -eq 'status') {
            return '{"success":true,"command":"status","state":"disabled","message":"未启用","manualAcceptance":"pending","installed":false,"enabled":false,"injectedCount":0,"failureReason":""}'
        }
        return '{"success":false,"command":"' + $command + '","state":"failed","message":"模拟失败","manualAcceptance":"pending","installed":false,"enabled":false,"injectedCount":0,"failureReason":"mock_failure"}'
    }
    New-Item -ItemType File -Path (Get-AesPanelInstalledControllerPath) -Force | Out-Null
    $mockStatus = Invoke-AesPanelController -Command 'status' -PackageRoot $portableRoot
    Assert-True $mockStatus.Success 'mock native status is returned through common invocation'
    Assert-Equal $mockStatus.State 'disabled' 'mock native state is returned'
    $mockEnable = Invoke-AesPanelController -Command 'enable' -PackageRoot $portableRoot
    Assert-True (-not $mockEnable.Success) 'mock native failure is returned through common invocation'
    Assert-Equal $mockEnable.FailureReason 'mock_failure' 'mock native failure reason is returned'

    $cmdText = [IO.File]::ReadAllText((Join-Path $repoRoot 'panel.cmd'))
    Assert-Contains $cmdText '%~dp0AppleEmojiSwitcher.Panel.ps1' 'launcher uses its own path for spaces and Chinese paths'
    Assert-Contains $cmdText 'DisableDelayedExpansion' 'launcher preserves non-ASCII argument handling'
    $panelText = [IO.File]::ReadAllText($panelPath)
    Assert-True ($panelText -notmatch 'PresentationFramework|python\.exe|Bootstrap\.ps1|Initialize-AesPowerShellModules') 'standalone panel module does not load WPF, Python, or font bootstrap'
    $guiText = [IO.File]::ReadAllText((Join-Path $repoRoot 'AppleEmojiSwitcher.ps1'))
    foreach ($needle in @('PanelEnableButton', 'PanelDisableButton', 'PanelStatusButton', 'Start-AesPanelUiAction', 'Update-AesPanelUiAction')) {
        Assert-Contains $guiText $needle ('GUI integration contains ' + $needle)
    }

    foreach ($path in @((Join-Path $repoRoot 'AppleEmojiSwitcher.Panel.ps1'), $panelPath, (Join-Path $repoRoot 'AppleEmojiSwitcher.ps1'))) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
        Assert-Equal @($errors).Count 0 ('PowerShell parser accepts ' + $path)
    }

    'PASS panel frontend: controller selection, JSON success/failure, isolated mock outcomes, launcher paths, GUI hooks, and PowerShell parsing.'
}
finally {
    $script:AesPanelControllerInvoker = $oldInvoker
    if ($null -eq $oldLocalAppData) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $oldLocalAppData }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
