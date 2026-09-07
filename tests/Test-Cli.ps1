[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$packageRoot = Split-Path -Parent $PSScriptRoot
$cliPath = Join-Path $packageRoot 'AppleEmojiSwitcher.Cli.ps1'
$fixtureName = 'AesCliFixture-' + [guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) $fixtureName

function Assert-AesCliTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-AesCliTestJunction {
    param([Parameter(Mandatory = $true)][string]$Link, [Parameter(Mandatory = $true)][string]$Target)
    [IO.Directory]::CreateDirectory($Target) | Out-Null
    $command = 'mklink /J "' + $Link + '" "' + $Target + '"'
    & $env:ComSpec /d /c $command | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('无法创建隔离测试 junction：{0}' -f $Link) }
}

try {
    # Dot-sourcing only defines functions because the entry script checks its
    # invocation name.  The tests replace boundary functions below; no font,
    # UAC, registry, queue, or network operation is reached.
    . $cliPath

    Assert-AesCliTest ((Resolve-AesCliCommand 'INSTALL') -eq 'Install') 'install 命令未被识别。'
    Assert-AesCliTest ((Resolve-AesCliCommand ' verify ') -eq 'Verify') 'verify 命令未被识别。'
    Assert-AesCliTest ((Resolve-AesCliCommand 'unknown') -eq $null) '未知命令被误接受。'
    Assert-AesCliTest ((Resolve-AesCliMenuChoice '1') -eq 'Install') '菜单 1 未映射到 install。'
    Assert-AesCliTest ((Resolve-AesCliMenuChoice '0') -eq 'Exit') '菜单 0 未映射到退出。'
    $eofChoice = @(Resolve-AesCliMenuChoice $null)
    Assert-AesCliTest ($eofChoice.Count -eq 1 -and $null -eq $eofChoice[0]) 'EOF 未被当作退出处理。'

    $uac = Get-AesCliUacDeniedResult
    Assert-AesCliTest ([int]$uac.ExitCode -eq 1223) '拒绝 UAC 没有返回 1223。'
    Assert-AesCliTest ($uac.Message -match '未修改系统字体') '拒绝 UAC 的说明不清楚。'
    Assert-AesCliTest ((Get-AesCliStateExitCode @{ Status = 'PendingInstall'; RestartRequired = $true }) -eq 3010) '待重启状态没有返回 3010。'
    Assert-AesCliTest ((Get-AesCliStateExitCode @{ Status = 'Denied' }) -eq 1) '事务拒绝没有返回失败码。'

    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null

    $reparseTarget = Join-Path $fixtureRoot 'reparse-target'
    $rootJunction = Join-Path $fixtureRoot 'root-junction'
    New-AesCliTestJunction -Link $rootJunction -Target $reparseTarget
    $script:AesCliDataRoot = $rootJunction
    $rootJunctionRejected = $false
    try { Initialize-AesCliDirectories } catch { $rootJunctionRejected = $_.Exception.Message -match '重解析点' }
    Assert-AesCliTest $rootJunctionRejected 'CLI 数据根的 junction 没有被拒绝。'

    $logsParent = Join-Path $fixtureRoot 'logs-parent'
    [IO.Directory]::CreateDirectory($logsParent) | Out-Null
    New-AesCliTestJunction -Link (Join-Path $logsParent 'logs') -Target (Join-Path $fixtureRoot 'logs-target')
    $script:AesCliDataRoot = $logsParent
    $logsJunctionRejected = $false
    try { Initialize-AesCliDirectories } catch { $logsJunctionRejected = $_.Exception.Message -match '重解析点' }
    Assert-AesCliTest $logsJunctionRejected 'CLI logs 目录的 junction 没有被拒绝。'

    $resultParent = Join-Path $fixtureRoot 'result-parent'
    [IO.Directory]::CreateDirectory((Join-Path $resultParent 'runs')) | Out-Null
    $linkedResultId = [guid]::NewGuid().ToString('N')
    New-AesCliTestJunction -Link (Join-Path (Join-Path $resultParent 'runs') ($linkedResultId + '.json')) -Target (Join-Path $fixtureRoot 'result-target')
    $resultLinkRejected = $false
    try { Get-AesCliResultPath -Root $resultParent -Id $linkedResultId | Out-Null } catch { $resultLinkRejected = $_.Exception.Message -match '重解析点' }
    Assert-AesCliTest $resultLinkRejected 'CLI 结果文件目标 junction 没有被拒绝。'
    $script:AesCliDataRoot = $null

    $fontPath = Join-Path $fixtureRoot '固定 字体.ttf'
    [IO.File]::WriteAllBytes($fontPath, [byte[]](1, 2, 3, 4, 5, 6))
    $fontHash = (Get-FileHash -LiteralPath $fontPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-AesCliTest ((Assert-AesCliPinnedFont -FontPath $fontPath -PinnedSpec @{ sha256 = $fontHash; size = 6 }) -eq [IO.Path]::GetFullPath($fontPath)) '固定字体的哈希与大小校验失败。'
    $badPinned = $false
    try { Assert-AesCliPinnedFont -FontPath $fontPath -PinnedSpec @{ sha256 = ('0' * 64); size = 6 } | Out-Null } catch { $badPinned = $true }
    Assert-AesCliTest $badPinned '错误固定字体哈希被接受。'

    $script:fakeState = @{ Supported = $true; Status = 'Installed'; InstallationMode = 'Built'; BackupExists = $true; WindowsVersion = '10.0'; Build = 22631; Architecture = 'x64' }
    $script:resourceCalls = 0
    $script:mutationCalls = 0
    function Get-AesCliSystemState { return $script:fakeState }
    function Show-AesCliState { param($State) }
    function Write-AesCliInfo { param($Message) }
    function Write-AesCliWarning { param($Message) }
    function Write-AesCliError { param($Message) }
    function Initialize-AesFontResource { param($PackageRoot, $CacheRoot, $Progress, $Cancelled) $script:resourceCalls++; return @{ AppleFont = $fontPath; CacheRoot = $fixtureRoot } }
    function Get-AesPinnedFontSpec { param($PackageRoot) return @{ sha256 = $fontHash; size = 6 } }
    function Assert-AesCliPinnedFont { param($FontPath, $PinnedSpec) return $FontPath }
    function Invoke-AesCliMutation { param($Action, $FontPath) $script:mutationCalls++; return @{ ExitCode = 3010; Message = '已安排'; State = @{ Status = 'PendingInstall'; InstallationMode = 'Pinned'; RestartRequired = $true } } }

    $modeConflictCode = Invoke-AesCliInstall
    Assert-AesCliTest ($modeConflictCode -eq 0) '已有 GUI 完整模式安装没有作为无重复操作返回 0。'
    Assert-AesCliTest ($script:resourceCalls -eq 0 -and $script:mutationCalls -eq 0) '已有 GUI 安装仍触发了下载或排队。'

    $script:fakeState = @{ Supported = $true; Status = 'OriginalWithBackup'; InstallationMode = 'Original'; BackupExists = $true; WindowsVersion = '10.0'; Build = 22631; Architecture = 'x64' }
    $eligibleCode = Invoke-AesCliInstall
    Assert-AesCliTest ($eligibleCode -eq 3010) '原生状态的极简安装没有保留待重启返回码。'
    Assert-AesCliTest ($script:resourceCalls -eq 1 -and $script:mutationCalls -eq 1) '合格状态没有仅准备一次固定字体并安排事务。'

    $failure = Get-AesCliMutationFailure -CoreResult @(@{ Status = 'Failed'; Reason = '具体队列错误' })
    Assert-AesCliTest ($failure -eq '具体队列错误') '事务具体错误被吞掉。'
    $verifyMessage = Get-AesCliVerifyMessage -Verification @{ VerificationPassed = $true } -State @{ Status = 'Installed'; InstallationMode = 'Pinned' }
    Assert-AesCliTest ($verifyMessage -match '未执行实际表情绘制验收') 'verify 对实际绘制能力作出了夸大表述。'

    $unicodeRoot = Join-Path $fixtureRoot '用户 空格\CLI 数据'
    $runId = [guid]::NewGuid().ToString('N')
    $arguments = @(Get-AesCliElevationArguments -Action 'Install' -Id $runId -Root $unicodeRoot -FontPath $fontPath)
    Assert-AesCliTest ($arguments -contains $unicodeRoot) '带中文和空格的数据目录没有原样传递给提权子进程。'
    Assert-AesCliTest ($arguments -contains $fontPath) '带空格的字体路径没有原样传递给提权子进程。'
    $quoted = (($arguments | ForEach-Object { ConvertTo-AesCommandLineArgument -Value $_ }) -join ' ')
    Assert-AesCliTest ($quoted -match [regex]::Escape('"' + $unicodeRoot + '"')) '带中文和空格的数据目录没有正确命令行引用。'

    $resultRoot = Join-Path $fixtureRoot 'result-root'
    $resultId = [guid]::NewGuid().ToString('N')
    $started = [DateTime]::UtcNow
    Write-AesCliRunResult -Root $resultRoot -Id $resultId -Action 'Cancel' -ExitCode 1 -Message '具体取消错误' -State @{ Status = 'Failed' } | Out-Null
    $result = Read-AesCliRunResult -Root $resultRoot -Id $resultId -Action 'Cancel' -StartedUtc $started.AddMinutes(-1) -ProcessExitCode 1
    Assert-AesCliTest ($result.message -eq '具体取消错误') '管理员子进程的具体错误没有返回给父进程。'
    $mismatchRejected = $false
    try { Read-AesCliRunResult -Root $resultRoot -Id $resultId -Action 'Cancel' -StartedUtc $started.AddMinutes(-1) -ProcessExitCode 0 | Out-Null } catch { $mismatchRejected = $true }
    Assert-AesCliTest $mismatchRejected '不一致的管理员进程退出码被接受。'

    $cmdText = [IO.File]::ReadAllText((Join-Path $packageRoot 'aes.cmd'), [Text.Encoding]::ASCII)
    Assert-AesCliTest ($cmdText -match 'DisableDelayedExpansion') '启动器没有关闭延迟展开。'
    Assert-AesCliTest ($cmdText -match 'Sysnative') '启动器没有处理 32 位 cmd 到 x64 PowerShell 的路径。'
    Assert-AesCliTest ($cmdText -match 'pause') '无参数双击启动器没有保留结果窗口。'
    Assert-AesCliTest ($cmdText -match 'Exit code:' -and $cmdText -notmatch '退出码') '启动器退出提示没有保持 ASCII。'

    # Exercise the real CMD launcher from a path that includes Chinese, a
    # space, and !.  Both actions are read-only.  The copied subset mirrors
    # the portable CLI layout without downloading or changing system state.
    $portableRoot = Join-Path $fixtureRoot '中文 空格! CLI'
    [IO.Directory]::CreateDirectory((Join-Path $portableRoot 'lib')) | Out-Null
    foreach ($name in @('AppleEmojiSwitcher.Cli.ps1', 'aes.cmd', 'fonts.lock.json')) {
        Copy-Item -LiteralPath (Join-Path $packageRoot $name) -Destination (Join-Path $portableRoot $name) -Force
    }
    foreach ($name in @('Common.ps1', 'SystemTransaction.psm1', 'NativeTransaction.cs', 'Finalize-Transaction.ps1')) {
        Copy-Item -LiteralPath (Join-Path $packageRoot ('lib\' + $name)) -Destination (Join-Path $portableRoot ('lib\' + $name)) -Force
    }
    $portableCmd = Join-Path $portableRoot 'aes.cmd'
    $helpOutput = @(& $env:ComSpec /d /c $portableCmd help 2>&1)
    Assert-AesCliTest ($LASTEXITCODE -eq 0 -and ($helpOutput -join "`n") -match 'AppleEmojiSwitcher') '中文空格感叹号路径下的 aes.cmd help 失败。'
    $statusOutput = @(& $env:ComSpec /d /c $portableCmd status 2>&1)
    Assert-AesCliTest ($LASTEXITCODE -eq 0 -and ($statusOutput -join "`n") -match '状态：') '中文空格感叹号路径下的 aes.cmd status 失败。'

    Write-Output 'PASS CLI: command/menu routing, exit codes, fixed-font validation, GUI-mode no-download boundary, error propagation, UAC result contract, reparse-point rejection, Unicode/space quoting, real CMD help/status, and verify wording.'
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        $expected = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) $fixtureName))
        if ([IO.Path]::GetFullPath($fixtureRoot).Equals($expected, [StringComparison]::OrdinalIgnoreCase) -and $fixtureName -match '^AesCliFixture-[a-f0-9]{32}$') {
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
