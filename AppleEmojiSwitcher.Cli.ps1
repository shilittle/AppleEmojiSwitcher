[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'Menu',
    [ValidateSet('Install', 'Restore', 'Cancel')]
    [string]$ElevatedAction,
    [string]$RunId,
    [string]$DataRoot,
    [string]$FontPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AesCliPackageRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$script:AesCliScriptPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Definition)
$script:AesCliDataRoot = $null
$script:AesCliLogPath = $null

$commonPath = Join-Path $script:AesCliPackageRoot 'lib\Common.ps1'
if (Test-Path -LiteralPath $commonPath -PathType Leaf) {
    # Keep the common functions in this script scope.  Dot-sourcing from an
    # initializer function would discard them when that function returns.
    . $commonPath
}

function Get-AesCliValue {
    param($InputObject, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)

    $shared = Get-Command -Name 'Get-AesProperty' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $shared) {
        $value = Get-AesProperty -InputObject $InputObject -Name $Name
        if ($null -ne $value) { return $value }
        return $Default
    }
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function Get-AesCliDataRoot {
    $localAppData = [IO.Path]::GetFullPath((Get-AesLocalAppDataRoot))
    return [IO.Path]::GetFullPath((Join-Path $localAppData 'AppleEmojiSwitcher\cli'))
}

function Assert-AesCliNoReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    # The elevated worker writes only a short result and a log under the
    # caller's LocalAppData.  Existing junctions or symlinks in that chain
    # would otherwise let a low-integrity caller redirect those writes.
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            $attributes = [IO.File]::GetAttributes($current)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ('CLI 数据路径包含重解析点，已拒绝写入：{0}' -f $current)
            }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent -or $parent.FullName.Equals($current, [StringComparison]::OrdinalIgnoreCase)) { break }
        $current = $parent.FullName
    }
}

function Assert-AesCliDirectChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path)
    $pathParent = [IO.Directory]::GetParent($pathFull)
    if ($null -eq $pathParent -or -not $pathFull.StartsWith($parentFull + '\', [StringComparison]::OrdinalIgnoreCase) -or -not $pathParent.FullName.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('不安全的 CLI {0} 路径：{1}' -f $Label, $pathFull)
    }
    Assert-AesCliNoReparsePoint -Path $pathFull
    return $pathFull
}

function Initialize-AesCliDirectories {
    if ([string]::IsNullOrWhiteSpace($script:AesCliDataRoot)) {
        $script:AesCliDataRoot = Get-AesCliDataRoot
    }
    $script:AesCliDataRoot = [IO.Path]::GetFullPath($script:AesCliDataRoot)
    Assert-AesCliNoReparsePoint -Path $script:AesCliDataRoot
    [IO.Directory]::CreateDirectory($script:AesCliDataRoot) | Out-Null
    Assert-AesCliNoReparsePoint -Path $script:AesCliDataRoot
    foreach ($name in @('logs', 'runs')) {
        $child = Assert-AesCliDirectChildPath -Parent $script:AesCliDataRoot -Path (Join-Path $script:AesCliDataRoot $name) -Label $name
        [IO.Directory]::CreateDirectory($child) | Out-Null
        Assert-AesCliDirectChildPath -Parent $script:AesCliDataRoot -Path $child -Label $name | Out-Null
    }
}

function Get-AesCliLogPath {
    param([Parameter(Mandatory = $true)][string]$Action)

    Initialize-AesCliDirectories
    $safeAction = $Action.ToLowerInvariant() -replace '[^a-z0-9_-]', '_'
    return (Join-Path (Join-Path $script:AesCliDataRoot 'logs') ('{0}-{1}.log' -f [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff'), $safeAction))
}

function Write-AesCliLog {
    param([Parameter(Mandatory = $true)][string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')

    if ([string]::IsNullOrWhiteSpace($script:AesCliLogPath)) { return }
    Initialize-AesCliDirectories
    $logRoot = Assert-AesCliDirectChildPath -Parent $script:AesCliDataRoot -Path (Join-Path $script:AesCliDataRoot 'logs') -Label 'logs'
    $logPath = Assert-AesCliDirectChildPath -Parent $logRoot -Path $script:AesCliLogPath -Label 'log file'
    $line = '[{0}] [{1}] {2}{3}' -f [DateTime]::UtcNow.ToString('o'), $Level, $Message, [Environment]::NewLine
    [IO.File]::AppendAllText($logPath, $line, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-AesCliInfo {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ('[信息] ' + $Message)
    Write-AesCliLog -Message $Message
}

function Write-AesCliWarning {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ('[提示] ' + $Message) -ForegroundColor Yellow
    Write-AesCliLog -Message $Message -Level 'WARN'
}

function Write-AesCliError {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ('[错误] ' + $Message) -ForegroundColor Red
    Write-AesCliLog -Message $Message -Level 'ERROR'
}

function Import-AesCliTransaction {
    $modulePath = Join-Path $script:AesCliPackageRoot 'lib\SystemTransaction.psm1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw ('缺少系统事务模块：{0}' -f $modulePath)
    }
    Import-Module -Name $modulePath -Force -DisableNameChecking -ErrorAction Stop | Out-Null
}

function Get-AesCliSystemState {
    Import-AesCliTransaction
    $result = @(Get-AesSystemState)
    if ($result.Count -eq 0) { throw '系统事务模块未返回状态。' }
    return $result[$result.Count - 1]
}

function Test-AesCliAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-AesCliPendingState {
    param($State)
    $status = [string](Get-AesCliValue -InputObject $State -Name 'Status')
    return ($status -match '(?i)pending|reboot|restart') -or [bool](Get-AesCliValue -InputObject $State -Name 'RestartRequired' $false)
}

function Get-AesCliStateExitCode {
    param($State)
    if (Test-AesCliPendingState -State $State) { return 3010 }
    $status = [string](Get-AesCliValue -InputObject $State -Name 'Status')
    if ($status -match '(?i)failed|denied|unsupported|error|drift|corrupt|interrupted|notapplied') { return 1 }
    return 0
}

function Get-AesCliStateLabel {
    param($State)
    $status = [string](Get-AesCliValue -InputObject $State -Name 'Status' 'Unknown')
    switch -Regex ($status) {
        '^Original$' { return '原生字体' }
        '^OriginalWithBackup$' { return '原生字体（已保存备份）' }
        '^PendingInstall$' { return '待重启替换' }
        '^PendingRestore$' { return '待重启恢复' }
        '^Installed$' { return '已安装替换字体' }
        '^Cancelled$' { return '已取消待重启操作' }
        '^NoPendingOperation$' { return '没有待重启操作' }
        '^Unsupported$' { return '系统不受支持' }
        '^ExternalDrift$' { return '检测到外部字体改动' }
        default { return $status }
    }
}

function Show-AesCliState {
    param($State)
    if ($null -eq $State) {
        Write-AesCliWarning '没有可显示的系统状态。'
        return
    }
    $system = '{0}，Build {1}，{2}' -f (Get-AesCliValue $State 'WindowsVersion' 'Windows'), (Get-AesCliValue $State 'Build' '?'), (Get-AesCliValue $State 'Architecture' '?')
    $mode = [string](Get-AesCliValue $State 'InstallationMode' 'Unknown')
    $backup = if ([bool](Get-AesCliValue $State 'BackupExists' $false)) { '已验证备份存在' } else { '尚无备份' }
    Write-Host ('系统：{0}' -f $system)
    Write-Host ('状态：{0}' -f (Get-AesCliStateLabel -State $State))
    Write-Host ('安装模式：{0}' -f $mode)
    Write-Host ('备份：{0}' -f $backup)
    $reason = [string](Get-AesCliValue $State 'Reason' '')
    if (-not [string]::IsNullOrWhiteSpace($reason)) { Write-Host ('说明：{0}' -f $reason) }
}

function Assert-AesCliSupportedState {
    param($State)
    if (-not [bool](Get-AesCliValue -InputObject $State -Name 'Supported' $false)) {
        $reason = [string](Get-AesCliValue -InputObject $State -Name 'Reason' '当前系统不受支持。')
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = '当前系统不受支持。' }
        throw $reason
    }
}

function Get-AesCliInstallDecision {
    param($State)
    $status = [string](Get-AesCliValue -InputObject $State -Name 'Status')
    $mode = [string](Get-AesCliValue -InputObject $State -Name 'InstallationMode' 'Unknown')
    if (Test-AesCliPendingState -State $State) {
        if ($mode -eq 'Pinned') { return @{ Kind = 'AlreadyPending'; Message = '极简苹果字体已安排，重启后生效；不会重复排队或下载。' } }
        return @{ Kind = 'AlreadyPending'; Message = '当前已有本工具待重启操作。请先重启，或先取消后恢复原生字体并重启，再切换模式；不会下载或重复排队。' }
    }
    if ($status -eq 'Installed') {
        if ($mode -eq 'Pinned') { return @{ Kind = 'AlreadyInstalled'; Message = '极简苹果字体已经安装；不会重复下载或排队。' } }
        return @{ Kind = 'AlreadyInstalled'; Message = '当前已安装完整模式字体。请先执行 restore 并重启，再安装极简模式；不会下载或重复排队。' }
    }
    if ($status -in @('Original', 'OriginalWithBackup', 'Cancelled', 'NoPendingOperation')) {
        return @{ Kind = 'Eligible'; Message = '' }
    }
    return @{ Kind = 'Blocked'; Message = ('当前状态“{0}”不适合安排替换：{1}' -f $status, [string](Get-AesCliValue $State 'Reason' '请先处理状态后再试。')) }
}

function Assert-AesCliPinnedFont {
    param(
        [Parameter(Mandatory = $true)][string]$FontPath,
        [Parameter(Mandatory = $true)]$PinnedSpec
    )
    $path = [IO.Path]::GetFullPath($FontPath)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('固定苹果字体不存在：{0}' -f $path) }
    if ([IO.Path]::GetExtension($path).ToLowerInvariant() -ne '.ttf') { throw '固定苹果字体不是 .ttf 文件。' }
    $expectedHash = ([string](Get-AesCliValue $PinnedSpec 'sha256' (Get-AesCliValue $PinnedSpec 'Sha256' ''))).ToLowerInvariant()
    $expectedSize = Get-AesCliValue $PinnedSpec 'size' (Get-AesCliValue $PinnedSpec 'Size' $null)
    if ($expectedHash -notmatch '^[a-f0-9]{64}$' -or $null -eq $expectedSize) { throw '固定字体规范缺少 SHA-256 或大小。' }
    $actualSize = [int64]([IO.FileInfo]$path).Length
    if ($actualSize -ne [int64]$expectedSize) { throw ('固定苹果字体大小不匹配：预期 {0}，实际 {1}。' -f $expectedSize, $actualSize) }
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) { throw '固定苹果字体 SHA-256 不匹配。' }
    return $path
}

function Get-AesCliMutationFailure {
    param($CoreResult)
    foreach ($item in @($CoreResult)) {
        $status = [string](Get-AesCliValue $item 'Status' '')
        if ($status -match '(?i)failed|denied|unsupported|error|drift|corrupt|interrupted') {
            $reason = [string](Get-AesCliValue $item 'Reason' '')
            if ([string]::IsNullOrWhiteSpace($reason)) { $reason = '系统事务返回失败状态。' }
            return $reason
        }
    }
    return $null
}

function Get-AesCliMutationMessage {
    param([Parameter(Mandatory = $true)][string]$Action, $State)
    if (Test-AesCliPendingState -State $State) {
        if ($Action -eq 'Restore') { return '恢复原生字体已安排。保存工作后重启电脑即可生效。' }
        if ($Action -eq 'Install') { return '极简苹果字体替换已安排。保存工作后重启电脑即可生效。' }
        return '待重启操作仍存在；重启后再验证。'
    }
    $status = [string](Get-AesCliValue $State 'Status' '')
    if ($Action -eq 'Cancel' -and $status -in @('Cancelled', 'NoPendingOperation', 'Original', 'OriginalWithBackup')) { return '本工具的待重启操作已取消，或当前没有可取消的操作。' }
    if ($Action -eq 'Restore' -and $status -match '(?i)^original') { return '原生字体状态已确认。' }
    if ($Action -eq 'Install' -and $status -eq 'Installed') { return '极简苹果字体状态已确认。' }
    return ('系统事务完成，当前状态：{0}。' -f (Get-AesCliStateLabel -State $State))
}

function Invoke-AesCliMutationCore {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Restore', 'Cancel')][string]$Action,
        [string]$FontPath
    )
    if (-not (Test-AesCliAdministrator)) { throw '系统变更必须在管理员进程中执行。' }
    Import-AesCliTransaction
    $coreResult = $null
    switch ($Action) {
        'Install' {
            if ([string]::IsNullOrWhiteSpace($FontPath)) { throw '极简安装缺少已校验的固定苹果字体。' }
            $coreResult = @(Install-AesFont -FontPath $FontPath -PinnedApple)
        }
        'Restore' { $coreResult = @(Restore-AesFont) }
        'Cancel' { $coreResult = @(Undo-AesPendingOperation) }
    }
    $failure = Get-AesCliMutationFailure -CoreResult $coreResult
    $state = Get-AesCliSystemState
    if (-not [string]::IsNullOrWhiteSpace($failure)) {
        return @{ ExitCode = 1; Message = $failure; State = $state }
    }
    $exitCode = Get-AesCliStateExitCode -State $state
    return @{ ExitCode = $exitCode; Message = (Get-AesCliMutationMessage -Action $Action -State $state); State = $state }
}

function Test-AesCliRunId {
    param([string]$Value)
    return (-not [string]::IsNullOrWhiteSpace($Value)) -and ($Value -match '^[a-fA-F0-9]{32}$')
}

function Assert-AesCliChildDataRoot {
    param([Parameter(Mandatory = $true)][string]$RequestedRoot)
    $expected = Get-AesCliDataRoot
    $actual = [IO.Path]::GetFullPath($RequestedRoot)
    if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw '管理员子进程拒绝了不属于当前用户 CLI 数据目录的结果路径。'
    }
    Assert-AesCliNoReparsePoint -Path $actual
    return $expected
}

function Get-AesCliResultPath {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Id)
    if (-not (Test-AesCliRunId $Id)) { throw '管理员结果请求编号无效。' }
    $rootFull = [IO.Path]::GetFullPath($Root)
    Assert-AesCliNoReparsePoint -Path $rootFull
    $runRoot = Assert-AesCliDirectChildPath -Parent $rootFull -Path (Join-Path $rootFull 'runs') -Label 'runs'
    $result = [IO.Path]::GetFullPath((Join-Path $runRoot ($Id.ToLowerInvariant() + '.json')))
    Assert-AesCliDirectChildPath -Parent $runRoot -Path $result -Label 'result file' | Out-Null
    return $result
}

function Write-AesCliRunResult {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$Message,
        $State
    )
    $path = Get-AesCliResultPath -Root $Root -Id $Id
    [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    $payload = [ordered]@{ runId = $Id.ToLowerInvariant(); action = $Action; exitCode = $ExitCode; message = $Message; timestampUtc = [DateTime]::UtcNow.ToString('o'); state = $State }
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $runRoot = Split-Path -Parent $path
        Assert-AesCliDirectChildPath -Parent $runRoot -Path $path -Label 'result file' | Out-Null
        Assert-AesCliDirectChildPath -Parent $runRoot -Path $temporary -Label 'temporary result file' | Out-Null
        [IO.File]::WriteAllText($temporary, ($payload | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::Replace($temporary, $path, $null) }
        else { [IO.File]::Move($temporary, $path) }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    return $path
}

function Read-AesCliRunResult {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][DateTime]$StartedUtc,
        [Parameter(Mandatory = $true)][int]$ProcessExitCode
    )
    $path = Get-AesCliResultPath -Root $Root -Id $Id
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw '管理员子进程未写入本次操作结果。' }
    try { $result = [IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw '管理员子进程结果文件无效。' }
    if ([string](Get-AesCliValue $result 'runId' '') -ne $Id.ToLowerInvariant()) { throw '管理员子进程结果编号不匹配。' }
    if ([string](Get-AesCliValue $result 'action' '') -ne $Action) { throw '管理员子进程结果操作不匹配。' }
    $childExit = Get-AesCliValue $result 'exitCode' $null
    if ($null -eq $childExit -or [int]$childExit -ne $ProcessExitCode) { throw '管理员子进程退出码与结果不一致。' }
    $stamp = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string](Get-AesCliValue $result 'timestampUtc' ''), [ref]$stamp) -or $stamp.ToUniversalTime() -lt $StartedUtc.ToUniversalTime()) { throw '管理员子进程结果不是本次操作生成的。' }
    return $result
}

function Get-AesCliElevationArguments {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$FontPath
    )
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($value in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:AesCliScriptPath, '-Command', 'Elevated', '-ElevatedAction', $Action, '-RunId', $Id, '-DataRoot', $Root)) { $values.Add([string]$value) }
    if ($Action -eq 'Install') {
        if ([string]::IsNullOrWhiteSpace($FontPath)) { throw '极简安装缺少字体路径。' }
        $values.Add('-FontPath')
        $values.Add($FontPath)
    }
    return @($values.ToArray())
}

function Get-AesCliUacDeniedResult {
    return @{ ExitCode = 1223; Message = '已取消管理员授权，未修改系统字体。'; State = $null }
}

function Start-AesCliElevatedMutation {
    param([Parameter(Mandatory = $true)][ValidateSet('Install', 'Restore', 'Cancel')][string]$Action, [string]$FontPath)
    Initialize-AesCliDirectories
    $id = [guid]::NewGuid().ToString('N')
    $resultPath = Get-AesCliResultPath -Root $script:AesCliDataRoot -Id $id
    if (Test-Path -LiteralPath $resultPath -PathType Leaf) { Remove-Item -LiteralPath $resultPath -Force -ErrorAction Stop }
    $powershell = Get-AesPowerShellPath
    $arguments = Get-AesCliElevationArguments -Action $Action -Id $id -Root $script:AesCliDataRoot -FontPath $FontPath
    $argumentText = (($arguments | ForEach-Object { ConvertTo-AesCommandLineArgument -Value $_ }) -join ' ')
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $powershell
    $info.Arguments = $argumentText
    $info.WorkingDirectory = $script:AesCliPackageRoot
    $info.UseShellExecute = $true
    $info.Verb = 'runas'
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $started = [DateTime]::UtcNow
    $process = $null
    try {
        try { $process = [Diagnostics.Process]::Start($info) }
        catch [ComponentModel.Win32Exception] {
            if ($_.Exception.NativeErrorCode -eq 1223) { return (Get-AesCliUacDeniedResult) }
            throw
        }
        if ($null -eq $process) { throw '管理员子进程未启动。' }
        $process.WaitForExit()
        $result = Read-AesCliRunResult -Root $script:AesCliDataRoot -Id $id -Action $Action -StartedUtc $started -ProcessExitCode $process.ExitCode
        return @{ ExitCode = [int](Get-AesCliValue $result 'exitCode'); Message = [string](Get-AesCliValue $result 'message'); State = Get-AesCliValue $result 'state' }
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Invoke-AesCliElevatedEntry {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Restore', 'Cancel')][string]$Action,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$RequestedRoot,
        [string]$FontPath
    )
    $root = Assert-AesCliChildDataRoot -RequestedRoot $RequestedRoot
    if (-not (Test-AesCliRunId $Id)) { throw '管理员子进程请求编号无效。' }
    $script:AesCliDataRoot = $root
    Initialize-AesCliDirectories
    $script:AesCliLogPath = Join-Path (Join-Path $root 'logs') ($Id.ToLowerInvariant() + '-' + $Action.ToLowerInvariant() + '-elevated.log')
    $outcome = $null
    try {
        Write-AesCliLog -Message ('管理员子进程开始：' + $Action)
        $outcome = Invoke-AesCliMutationCore -Action $Action -FontPath $FontPath
    }
    catch {
        $outcome = @{ ExitCode = 1; Message = $_.Exception.Message; State = $null }
        Write-AesCliLog -Message $_.Exception.Message -Level 'ERROR'
    }
    $code = [int](Get-AesCliValue $outcome 'ExitCode' 1)
    $message = [string](Get-AesCliValue $outcome 'Message' '管理员子进程未返回说明。')
    Write-AesCliRunResult -Root $root -Id $Id -Action $Action -ExitCode $code -Message $message -State (Get-AesCliValue $outcome 'State') | Out-Null
    return $code
}

function Invoke-AesCliMutation {
    param([Parameter(Mandatory = $true)][ValidateSet('Install', 'Restore', 'Cancel')][string]$Action, [string]$FontPath)
    if (Test-AesCliAdministrator) {
        return (Invoke-AesCliMutationCore -Action $Action -FontPath $FontPath)
    }
    Write-AesCliInfo '等待系统变更所需的管理员授权。'
    return (Start-AesCliElevatedMutation -Action $Action -FontPath $FontPath)
}

function Invoke-AesCliInstall {
    $state = Get-AesCliSystemState
    Show-AesCliState -State $state
    Assert-AesCliSupportedState -State $state
    $decision = Get-AesCliInstallDecision -State $state
    switch ([string]$decision.Kind) {
        'AlreadyPending' { Write-AesCliInfo $decision.Message; return 3010 }
        'AlreadyInstalled' { Write-AesCliInfo $decision.Message; return 0 }
        'Blocked' { Write-AesCliError $decision.Message; return 1 }
    }
    Write-AesCliInfo '准备固定版本的苹果原版字体（约 245 MiB）；不会下载 Python、Unicode 数据或渲染组件。'
    $cacheRoot = [IO.Path]::GetFullPath((Join-Path (Get-AesLocalAppDataRoot) 'AppleEmojiSwitcher\cache'))
    $progress = {
        param($event)
        $message = [string](Get-AesCliValue $event 'Message' '')
        if (-not [string]::IsNullOrWhiteSpace($message)) { Write-AesCliInfo $message }
    }.GetNewClosure()
    $resources = Initialize-AesFontResource -PackageRoot $script:AesCliPackageRoot -CacheRoot $cacheRoot -Progress $progress
    $fontPath = Assert-AesCliPinnedFont -FontPath ([string](Get-AesCliValue $resources 'AppleFont')) -PinnedSpec (Get-AesPinnedFontSpec -PackageRoot $script:AesCliPackageRoot)
    $outcome = Invoke-AesCliMutation -Action 'Install' -FontPath $fontPath
    $message = [string](Get-AesCliValue $outcome 'Message' '')
    if ([int](Get-AesCliValue $outcome 'ExitCode' 1) -eq 1) { Write-AesCliError $message } else { Write-AesCliInfo $message }
    return [int](Get-AesCliValue $outcome 'ExitCode' 1)
}

function Invoke-AesCliRestore {
    $outcome = Invoke-AesCliMutation -Action 'Restore'
    $message = [string](Get-AesCliValue $outcome 'Message' '')
    if ([int](Get-AesCliValue $outcome 'ExitCode' 1) -eq 1) { Write-AesCliError $message } else { Write-AesCliInfo $message }
    return [int](Get-AesCliValue $outcome 'ExitCode' 1)
}

function Invoke-AesCliCancel {
    $outcome = Invoke-AesCliMutation -Action 'Cancel'
    $message = [string](Get-AesCliValue $outcome 'Message' '')
    if ([int](Get-AesCliValue $outcome 'ExitCode' 1) -eq 1) { Write-AesCliError $message } else { Write-AesCliInfo $message }
    return [int](Get-AesCliValue $outcome 'ExitCode' 1)
}

function Invoke-AesCliStatus {
    $state = Get-AesCliSystemState
    Show-AesCliState -State $state
    return (Get-AesCliStateExitCode -State $state)
}

function Get-AesCliVerifyMessage {
    param($Verification, $State)
    if (Test-AesCliPendingState -State $State) { return '当前有待重启操作；重启后才能确认最终字体文件。' }
    if ([bool](Get-AesCliValue $Verification 'VerificationPassed' $false)) { return '文件、备份与权限状态校验通过；CLI 未执行实际表情绘制验收。' }
    $reason = [string](Get-AesCliValue $Verification 'VerificationReason' '')
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = '校验模块未确认当前字体状态。' }
    return ('文件、备份或权限状态校验未通过：{0}。CLI 未执行实际表情绘制验收。' -f $reason)
}

function Invoke-AesCliVerify {
    Import-AesCliTransaction
    $state = Get-AesCliSystemState
    $verification = @(Verify-AesInstallation)
    if ($verification.Count -eq 0) { throw '安装核验模块未返回结果。' }
    $result = $verification[$verification.Count - 1]
    $message = Get-AesCliVerifyMessage -Verification $result -State $state
    if ([bool](Get-AesCliValue $result 'VerificationPassed' $false)) { Write-AesCliInfo $message } else { Write-AesCliWarning $message }
    Show-AesCliState -State $state
    if (Test-AesCliPendingState -State $state) { return 3010 }
    if (-not [bool](Get-AesCliValue $result 'VerificationPassed' $false)) { return 1 }
    return 0
}

function Show-AesCliHelp {
    Write-Host 'AppleEmojiSwitcher 极简 CLI'
    Write-Host '  aes.cmd install  下载固定苹果字体并安排重启替换'
    Write-Host '  aes.cmd restore  安排恢复原生字体'
    Write-Host '  aes.cmd cancel   取消本工具待重启操作'
    Write-Host '  aes.cmd status   查看系统、模式、备份和待重启状态'
    Write-Host '  aes.cmd verify   核验文件、备份及权限（不检查实际绘制）'
    Write-Host '  aes.cmd help     显示本帮助'
    Write-Host '无参数时显示中文数字菜单。系统修改会请求管理员权限，工具不会自动重启。'
}

function Resolve-AesCliMenuChoice {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    switch ($Value.Trim()) {
        '1' { return 'Install' }
        '2' { return 'Restore' }
        '3' { return 'Cancel' }
        '4' { return 'Status' }
        '5' { return 'Verify' }
        '0' { return 'Exit' }
        default { return 'Invalid' }
    }
}

function Invoke-AesCliMenu {
    Write-Host 'AppleEmojiSwitcher 极简 CLI'
    Write-Host '1. 一键替换为固定苹果原版字体'
    Write-Host '2. 恢复 Windows 原生字体'
    Write-Host '3. 取消本工具待重启操作'
    Write-Host '4. 查看状态'
    Write-Host '5. 核验文件与事务状态'
    Write-Host '0. 退出'
    $choice = Resolve-AesCliMenuChoice -Value ([Console]::In.ReadLine())
    if ($null -eq $choice -or $choice -eq 'Exit') { return 0 }
    if ($choice -eq 'Invalid') { Write-AesCliError '请输入 0 到 5。'; return 1 }
    return (Invoke-AesCliCommand -RequestedCommand $choice)
}

function Resolve-AesCliCommand {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'Menu' }
    switch ($Value.Trim().ToLowerInvariant()) {
        'install' { return 'Install' }
        'restore' { return 'Restore' }
        'cancel' { return 'Cancel' }
        'status' { return 'Status' }
        'verify' { return 'Verify' }
        'help' { return 'Help' }
        'menu' { return 'Menu' }
        default { return $null }
    }
}

function Invoke-AesCliCommand {
    param([AllowNull()][string]$RequestedCommand)
    $commandName = Resolve-AesCliCommand -Value $RequestedCommand
    if ($null -eq $commandName) { Write-AesCliError ('未知命令：{0}。使用 aes.cmd help 查看帮助。' -f $RequestedCommand); return 1 }
    if ($commandName -eq 'Menu') { return (Invoke-AesCliMenu) }
    if ($commandName -eq 'Help') { Show-AesCliHelp; return 0 }
    switch ($commandName) {
        'Install' { return (Invoke-AesCliInstall) }
        'Restore' { return (Invoke-AesCliRestore) }
        'Cancel' { return (Invoke-AesCliCancel) }
        'Status' { return (Invoke-AesCliStatus) }
        'Verify' { return (Invoke-AesCliVerify) }
    }
    return 1
}

function Initialize-AesCliRuntime {
    $commonPath = Join-Path $script:AesCliPackageRoot 'lib\Common.ps1'
    if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) { throw ('缺少共享公共模块：{0}' -f $commonPath) }
    if ($null -eq (Get-Command -Name 'Get-AesLocalAppDataRoot' -CommandType Function -ErrorAction SilentlyContinue)) {
        throw '共享公共模块未能加载。'
    }
    Initialize-AesPowerShellModules
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 1
    try {
        Initialize-AesCliRuntime
        if ($Command -eq 'Elevated') {
            $exitCode = Invoke-AesCliElevatedEntry -Action $ElevatedAction -Id $RunId -RequestedRoot $DataRoot -FontPath $FontPath
        }
        else {
            $script:AesCliDataRoot = Get-AesCliDataRoot
            Initialize-AesCliDirectories
            $script:AesCliLogPath = Get-AesCliLogPath -Action $Command
            Write-AesCliLog -Message ('开始 CLI 操作：' + $Command)
            $exitCode = Invoke-AesCliCommand -RequestedCommand $Command
        }
    }
    catch {
        try { Write-AesCliError $_.Exception.Message } catch { Write-Error $_.Exception.Message }
        $exitCode = 1
    }
    exit ([int]$exitCode)
}
