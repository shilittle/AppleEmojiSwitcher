[CmdletBinding()]
param(
    [ValidateSet('Ui', 'Apply', 'Restore', 'Cancel', 'Verify')]
    [string]$Action = 'Ui',
    [string]$PackageRoot,
    [string]$CacheRoot,
    [string]$UiRoot,
    [string]$ReportPath,
    [string]$CoveragePath,
    [string]$PreparedFontPath,
    [switch]$MutationOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Initialize-AesPowerShellModules {
    # Hidden WSH/Start-Process launches can inherit a PSModulePath assembled
    # by another PowerShell host.  Repair it only for this process, then load
    # the built-in modules needed by the transaction layer.  No user or
    # machine environment variable is persisted.
    $requiredPaths = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($PSHOME)) {
        $requiredPaths.Add([IO.Path]::Combine($PSHOME, 'Modules'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $requiredPaths.Add([IO.Path]::Combine($env:ProgramFiles, 'WindowsPowerShell', 'Modules'))
    }
    # Put the native host's module directory first.  This prevents a stale
    # PSModulePath inherited from pwsh or another user process from resolving
    # a same-named module before Windows PowerShell's built-in implementation.
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($requiredPaths.ToArray()) + @([string]$env:PSModulePath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        $alreadyAdded = $false
        foreach ($existing in $paths) {
            if ([string]::Equals($existing, $path, [StringComparison]::OrdinalIgnoreCase)) {
                $alreadyAdded = $true
                break
            }
        }
        if (-not $alreadyAdded) {
            $paths.Add($path)
        }
    }
    $env:PSModulePath = [string]::Join(';', $paths.ToArray())
    $nativeModuleRoot = if ([string]::IsNullOrWhiteSpace($PSHOME)) { $null } else { [IO.Path]::Combine($PSHOME, 'Modules') }
    foreach ($moduleName in @('Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Security')) {
        $manifest = if ($null -eq $nativeModuleRoot) { $null } else { [IO.Path]::Combine($nativeModuleRoot, $moduleName, ($moduleName + '.psd1')) }
        if (-not [string]::IsNullOrWhiteSpace($manifest) -and [IO.File]::Exists($manifest)) {
            Import-Module -Name $manifest -Global -Force -ErrorAction Stop | Out-Null
        }
        else {
            Import-Module -Name $moduleName -Global -Force -ErrorAction Stop | Out-Null
        }
    }
}

Initialize-AesPowerShellModules

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$script:ScriptPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Definition)
if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    $PackageRoot = $script:AppRoot
}
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot)
$script:PackageRoot = $PackageRoot

$bootstrapPath = Join-Path $script:AppRoot 'lib\Bootstrap.ps1'
if (-not (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) {
    throw ("缺少 Bootstrap 模块：{0}" -f $bootstrapPath)
}
. $bootstrapPath
$displayVerifierPath = Join-Path $script:PackageRoot 'lib\Verify-Display.ps1'
if (Test-Path -LiteralPath $displayVerifierPath -PathType Leaf) {
    # Dot-source at script scope so the function remains available to a later
    # worker action.  Dot-sourcing inside Import-AesDisplayVerifier would bind
    # it to that function's local scope and lose it on return.
    . $displayVerifierPath
}

function Get-AesUiRoot {
    param([string]$RequestedRoot)

    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        return [IO.Path]::GetFullPath($RequestedRoot)
    }
    return [IO.Path]::GetFullPath((Join-Path (Get-AesLocalAppDataRoot) 'AppleEmojiSwitcher\ui'))
}

function Get-AesDefaultCacheRoot {
    return [IO.Path]::GetFullPath((Join-Path (Get-AesLocalAppDataRoot) 'AppleEmojiSwitcher\cache'))
}

$script:DataRoot = Get-AesUiRoot -RequestedRoot $UiRoot
$script:LogRoot = Join-Path $script:DataRoot 'logs'
$script:ReportRoot = Join-Path $script:DataRoot 'reports'
$script:StatusPath = Join-Path $script:DataRoot 'status.json'
$script:UiWorker = $null
$script:CurrentLogPath = $null
$script:MainWindow = $null
$script:VerifyWorkerRequested = $false
$script:LastUiStateRefresh = [DateTime]::MinValue
$script:LastBuildCoveragePath = $null

function Initialize-AesAppDirectories {
    [IO.Directory]::CreateDirectory($script:DataRoot) | Out-Null
    [IO.Directory]::CreateDirectory($script:LogRoot) | Out-Null
    [IO.Directory]::CreateDirectory($script:ReportRoot) | Out-Null
}

function Get-AesTimestamp {
    return [DateTime]::UtcNow.ToString('o')
}

function Get-AesLogPath {
    param([string]$ActionName)

    Initialize-AesAppDirectories
    $safeAction = if ([string]::IsNullOrWhiteSpace($ActionName)) { 'ui' } else { $ActionName.ToLowerInvariant() }
    $name = '{0}-{1}.log' -f ([DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff')), $safeAction
    return (Join-Path $script:LogRoot $name)
}

function Write-AesLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = $script:CurrentLogPath
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-AesLogPath -ActionName $Action
        $script:CurrentLogPath = $Path
    }
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $line = '[{0}] [{1}] {2}{3}' -f (Get-AesTimestamp), $Level, $Message, [Environment]::NewLine
    [IO.File]::AppendAllText($Path, $line, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-AesStateSummary {
    param($State)

    if ($null -eq $State) {
        return $null
    }
    $summary = [ordered]@{}
    foreach ($name in @('Supported', 'Reason', 'WindowsVersion', 'Build', 'Architecture', 'IsElevated', 'Status', 'CurrentFont', 'CurrentHash', 'OriginalFont', 'BackupExists', 'BackupPath', 'SourceVersion', 'RenderVerificationPending', 'RestartRequired')) {
        $summary[$name] = Get-AesProperty -InputObject $State -Name $name
    }
    return $summary
}

function Write-AesStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$Percent = 0,
        [string]$ActionName,
        [bool]$PendingReboot = $false,
        [string]$CoveragePath,
        [string]$ReportFile,
        $State
    )

    Initialize-AesAppDirectories
    $payload = [ordered]@{
        Timestamp    = Get-AesTimestamp
        Action       = if ([string]::IsNullOrWhiteSpace($ActionName)) { $Action } else { $ActionName }
        Stage        = $Stage
        Status       = $Status
        Message      = $Message
        Percent      = [Math]::Max(0, [Math]::Min(100, $Percent))
        PendingReboot = $PendingReboot
        CoveragePath = $CoveragePath
        ReportPath   = $ReportFile
        State        = Get-AesStateSummary -State $State
    }
    $temporary = "$script:StatusPath.tmp.$([Guid]::NewGuid().ToString('N'))"
    $backup = "$script:StatusPath.backup.$([Guid]::NewGuid().ToString('N'))"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $payload -Depth 10), $encoding)
        if (Test-Path -LiteralPath $script:StatusPath -PathType Leaf) {
            [IO.File]::Replace($temporary, $script:StatusPath, $backup)
        }
        else {
            [IO.File]::Move($temporary, $script:StatusPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backup -PathType Leaf) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-AesStatus {
    if (-not (Test-Path -LiteralPath $script:StatusPath -PathType Leaf)) {
        return $null
    }
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        return ([IO.File]::ReadAllText($script:StatusPath, $encoding) | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-AesPowerShellPath {
    $candidate = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }
    $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    throw '找不到 Windows PowerShell 5.1 powershell.exe。'
}

function ConvertTo-AesCommandLineArgument {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return '""'
    }
    if ($Value.Length -eq 0) {
        return '""'
    }

    # Quote according to CommandLineToArgvW rules, including trailing
    # backslashes.  Start-Process joins the returned tokens into one command.
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $slashes++
            continue
        }
        if ($character -eq [char]34) {
            if ($slashes -gt 0) {
                [void]$builder.Append(('\' * ($slashes * 2)))
            }
            [void]$builder.Append('\"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) {
            [void]$builder.Append(('\' * $slashes))
            $slashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) {
        [void]$builder.Append(('\' * ($slashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Test-AesAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Import-AesTransaction {
    $modulePath = Join-Path $script:PackageRoot 'lib\SystemTransaction.psm1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw ("缺少系统事务模块：{0}" -f $modulePath)
    }
    Import-Module -Name $modulePath -Force -ErrorAction Stop | Out-Null
}

function Import-AesDisplayVerifier {
    return ($null -ne (Get-Command -Name 'Invoke-AesDisplayVerification' -CommandType Function -ErrorAction SilentlyContinue))
}

function Invoke-AesCore {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [hashtable]$Arguments
    )

    $command = Get-Command -Name $Name -CommandType Function,Cmdlet -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw ("事务模块未导出 {0}。" -f $Name)
    }
    if ($null -eq $Arguments) {
        return @(& $Name)
    }
    return @(& $Name @Arguments)
}

function Get-AesCurrentState {
    Import-AesTransaction
    # A transaction command normally returns one hashtable.  Capture it in a
    # real singleton array before using Count/[-1]; otherwise a hashtable can
    # be treated as its dictionary and the state lookup yields null in PS5.1.
    $result = @(Invoke-AesCore -Name 'Get-AesSystemState')
    if ($result.Count -eq 0) {
        throw 'Get-AesSystemState 未返回状态。'
    }
    return $result[-1]
}

function Get-AesStateValue {
    param($State, [string]$Name)
    return Get-AesProperty -InputObject $State -Name $Name
}

function Test-AesSupported {
    param($State)

    $supported = Get-AesStateValue -State $State -Name 'Supported'
    if ($null -eq $supported -or -not [bool]$supported) {
        $reason = [string](Get-AesStateValue -State $State -Name 'Reason')
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $reason = '系统状态不满足 Windows 10/11 x64 的支持条件。'
        }
        throw $reason
    }
}

function Get-AesOriginalFontPath {
    param($State)

    $value = [string](Get-AesStateValue -State $State -Name 'OriginalFont')
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw '系统状态未提供原生字体基线路径，已停止构建。'
    }
    try {
        $path = [IO.Path]::GetFullPath($value)
    }
    catch {
        throw ("原生字体基线路径无效：{0}" -f $value)
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw ("原生字体基线不存在：{0}" -f $path)
    }
    return $path
}

function Get-AesDefaultReportPath {
    param([string]$ActionName)
    Initialize-AesAppDirectories
    return (Join-Path $script:ReportRoot ('{0}-{1}.json' -f $ActionName.ToLowerInvariant(), [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff')))
}

function Start-AesCapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [scriptblock]$OutputLine,
        [scriptblock]$ErrorLine
    )

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-AesCommandLineArgument -Value $_ }) -join ' ')
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    $outputLines = New-Object System.Collections.Generic.List[string]
    $stderrTask = $null
    try {
        if (-not $process.Start()) {
            throw ("无法启动进程：{0}" -f $FilePath)
        }
        # Keep stdout in this worker runspace so callbacks can safely update
        # status/log files under Windows PowerShell 5.1.  The event based
        # DataReceived API invokes a PowerShell scriptblock on a ThreadPool
        # thread, where no Runspace is available and PS5.1 throws.  Drain
        # stderr through a .NET task at the same time so a diagnostic burst
        # cannot fill the error pipe and deadlock the child.
        $stderrTask = $process.StandardError.ReadToEndAsync()
        while ($true) {
            $line = $process.StandardOutput.ReadLine()
            if ($null -eq $line) {
                break
            }
            [void]$outputLines.Add($line)
            if ($null -ne $OutputLine) {
                & $OutputLine $line | Out-Null
            }
        }
        $process.WaitForExit()
        $stderr = [string]$stderrTask.Result
        if (-not [string]::IsNullOrEmpty($stderr)) {
            foreach ($line in ($stderr -split "`r?`n")) {
                if ($line.Length -eq 0) {
                    continue
                }
                if ($null -ne $ErrorLine) {
                    & $ErrorLine $line | Out-Null
                }
            }
        }
        return [ordered]@{
            ExitCode = $process.ExitCode
            Stdout   = [string]::Join([Environment]::NewLine, $outputLines.ToArray())
            Stderr   = $stderr
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-AesBuilder {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Resources,
        [Parameter(Mandatory = $true)][string]$OriginalFont,
        [Parameter(Mandatory = $true)][string]$BuildRoot,
        [scriptblock]$Progress,
        [string]$LogPath
    )

    $builder = Join-Path $script:PackageRoot 'builder\build_font.py'
    $renderer = Join-Path $script:PackageRoot 'bin\EmojiRender.exe'
    if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) {
        throw ("缺少字体构建器：{0}" -f $builder)
    }
    if (-not (Test-Path -LiteralPath $renderer -PathType Leaf)) {
        throw ("缺少表情渲染器：{0}" -f $renderer)
    }
    if (-not (Test-Path -LiteralPath $Resources.Python -PathType Leaf)) {
        throw ("Python 运行时不存在：{0}" -f $Resources.Python)
    }
    [IO.Directory]::CreateDirectory($BuildRoot) | Out-Null

    $arguments = @(
        '-I',
        '-B',
        '-X',
        'utf8',
        $builder,
        '--apple', [string]$Resources.AppleFont,
        '--windows', $OriginalFont,
        '--unicode-dir', [string]$Resources.UnicodeDir,
        '--renderer', $renderer,
        '--output', $BuildRoot
    )
    $coverage = Join-Path $BuildRoot 'coverage.json'
    $script:LastBuildCoveragePath = [IO.Path]::GetFullPath($coverage)
    Invoke-AesProgress -Progress $Progress -Stage 'build' -Percent 65 -Message '正在构建混合字体。'
    $outputLine = {
        param([string]$line)
        if ([string]::IsNullOrWhiteSpace($line)) {
            return
        }
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            Write-AesLog -Path $LogPath -Message ("builder stdout: {0}" -f $line)
        }
        try {
            $event = $line | ConvertFrom-Json
            $eventPercent = Get-AesProperty -InputObject $event -Name 'percent'
            if ($null -eq $eventPercent) {
                $eventPercent = Get-AesProperty -InputObject $event -Name 'Percent'
            }
            if ($null -eq $eventPercent) {
                $eventPercent = 65
            }
            $eventMessage = [string](Get-AesProperty -InputObject $event -Name 'message')
            if ([string]::IsNullOrWhiteSpace($eventMessage)) {
                $eventMessage = [string](Get-AesProperty -InputObject $event -Name 'Message')
            }
            if ([string]::IsNullOrWhiteSpace($eventMessage)) {
                $eventMessage = '字体构建器正在处理。'
            }
            Invoke-AesProgress -Progress $Progress -Stage 'build' -Percent ([int]$eventPercent) -Message $eventMessage
        }
        catch {
            # Non-JSON diagnostic lines remain in the detailed log.
        }
    }.GetNewClosure()
    $errorLine = {
        param([string]$line)
        if (-not [string]::IsNullOrWhiteSpace($LogPath) -and -not [string]::IsNullOrWhiteSpace($line)) {
            Write-AesLog -Path $LogPath -Message ("builder stderr: {0}" -f $line) -Level 'WARN'
        }
    }.GetNewClosure()
    # JSONL stdout is consumed line by line while the worker is still running;
    # stderr is drained independently so a diagnostic burst cannot deadlock
    # the child process.
    $result = Start-AesCapturedProcess -FilePath ([string]$Resources.Python) -Arguments $arguments -WorkingDirectory $script:PackageRoot -OutputLine $outputLine -ErrorLine $errorLine
    if ([int]$result.ExitCode -ne 0) {
        # The builder writes a failed coverage report before returning a
        # nonzero exit code. Preserve its actual error for the UI; localized
        # display differences are warnings in the current builder policy.
        $failureMessage = $null
        if (Test-Path -LiteralPath $coverage -PathType Leaf) {
            try {
                $encoding = New-Object System.Text.UTF8Encoding($false)
                $failedReport = [IO.File]::ReadAllText($coverage, $encoding) | ConvertFrom-Json
                $errorValue = Get-AesProperty -InputObject $failedReport -Name 'errors'
                $reportErrors = @()
                if ($null -ne $errorValue) {
                    $reportErrors = @($errorValue)
                }
                if ($reportErrors.Count -gt 0) {
                    $failureMessage = [string]$reportErrors[$reportErrors.Count - 1]
                }
            }
            catch {
                # A malformed or incomplete diagnostic report should retain
                # the generic process failure while the report remains visible.
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($failureMessage)) {
            throw $failureMessage
        }
        throw ("字体构建器失败，退出码 {0}。" -f $result.ExitCode)
    }

    $hybrid = Join-Path $BuildRoot 'hybrid.ttf'
    if (-not (Test-Path -LiteralPath $hybrid -PathType Leaf)) {
        throw '字体构建器未生成 hybrid.ttf，已停止系统变更。'
    }
    if (-not (Test-Path -LiteralPath $coverage -PathType Leaf)) {
        throw '字体构建器未生成 coverage.json，已停止系统变更。'
    }
    Invoke-AesProgress -Progress $Progress -Stage 'build' -Percent 80 -Message '混合字体与覆盖率文件已验证。'
    return [ordered]@{ FontPath = [IO.Path]::GetFullPath($hybrid); CoveragePath = [IO.Path]::GetFullPath($coverage); BuildRoot = [IO.Path]::GetFullPath($BuildRoot) }
}

function Invoke-AesProgress {
    param(
        [scriptblock]$Progress,
        [string]$Stage,
        [int]$Percent,
        [string]$Message
    )

    if ($null -ne $Progress) {
        & $Progress ([ordered]@{ Stage = $Stage; Percent = $Percent; Message = $Message })
    }
}

function Get-AesMutationResultStatus {
    param(
        [Parameter(Mandatory = $true)]$State,
        $CoreResult,
        [bool]$RestoreOperation = $false
    )

    $stateStatus = [string](Get-AesStateValue -State $State -Name 'Status')
    $pending = $false
    if ($stateStatus -match '(?i)pending|reboot|restart') {
        $pending = $true
    }
    foreach ($item in @($CoreResult)) {
        $coreStatus = [string](Get-AesProperty -InputObject $item -Name 'Status')
        if ($coreStatus -match '(?i)failed|denied|unsupported|error|drift|corrupt|interrupted') {
            return [ordered]@{ Status = 'failed'; PendingReboot = $false; Message = [string](Get-AesProperty -InputObject $item -Name 'Reason') }
        }
        $pendingValue = Get-AesProperty -InputObject $item -Name 'PendingReboot'
        if ($null -ne $pendingValue -and [bool]$pendingValue) {
            $pending = $true
        }
    }
    if ($stateStatus -match '(?i)failed|denied|unsupported|error|drift|corrupt|interrupted') {
        $reason = [string](Get-AesStateValue -State $State -Name 'Reason')
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $reason = '系统事务返回了失败状态。'
        }
        return [ordered]@{ Status = 'failed'; PendingReboot = $false; Message = $reason }
    }
    if ($pending) {
        return [ordered]@{
            Status = 'pending_reboot'
            PendingReboot = $true
            Message = '替换操作已安排，保存工作后重启电脑即可生效。重启后再次打开工具验证。'
        }
    }

    if ($stateStatus -match '(?i)installed|active|hybrid|restored|original') {
        $label = if ($RestoreOperation) { '原生字体恢复状态已确认。' } else { '字体状态已确认。' }
        return [ordered]@{ Status = 'installed'; PendingReboot = $false; Message = $label }
    }

    return [ordered]@{
        Status = 'awaiting_verification'
        PendingReboot = $false
        Message = '系统事务已返回，但当前状态尚未达到可确认状态；请重启后使用验证操作。'
    }
}

function Invoke-AesMutationCore {
    param(
        [Parameter(Mandatory = $true)][string]$ActionName,
        [string]$FontPath,
        [string]$ReportFile,
        [string]$CoverageFile,
        [string]$LogPath
    )

    if (-not (Test-AesAdministrator)) {
        throw '系统变更必须在管理员进程中执行。'
    }
    Import-AesTransaction
    $coreResult = $null
    switch ($ActionName) {
        'Apply' {
            if ([string]::IsNullOrWhiteSpace($FontPath) -or -not (Test-Path -LiteralPath $FontPath -PathType Leaf)) {
                throw '待安装的混合字体不存在。'
            }
            if ([string]::IsNullOrWhiteSpace($ReportFile)) {
                $ReportFile = Get-AesDefaultReportPath -ActionName 'apply'
            }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $ReportFile)) | Out-Null
            $coreResult = Invoke-AesCore -Name 'Install-AesFont' -Arguments @{ FontPath = $FontPath; ReportPath = $ReportFile }
        }
        'Restore' {
            $coreResult = Invoke-AesCore -Name 'Restore-AesFont'
        }
        'Cancel' {
            $coreResult = Invoke-AesCore -Name 'Undo-AesPendingOperation'
        }
        default {
            throw ("不支持的系统变更操作：{0}" -f $ActionName)
        }
    }

    $state = Get-AesCurrentState
    $summary = Get-AesMutationResultStatus -State $state -CoreResult $coreResult -RestoreOperation ($ActionName -eq 'Restore')
    if ($ActionName -eq 'Cancel' -and $summary.Status -notin @('pending_reboot','failed')) {
        $summary.Status = 'cancelled'
        $summary.Message = '待重启操作已取消；系统字体尚未被本程序自动重启或强制替换。'
    }
    $coverage = $null
    if ($ActionName -eq 'Apply' -and -not [string]::IsNullOrWhiteSpace($CoverageFile)) {
        $coverage = $CoverageFile
    }
    if ($summary.Status -eq 'installed') {
        $confirmation = Invoke-AesCore -Name 'Confirm-AesState'
        $confirmed = $false
            foreach ($item in @($confirmation)) {
                $confirmedStatus = [string](Get-AesProperty -InputObject $item -Name 'Status')
                if ($confirmedStatus -match '(?i)installed|original|restored') {
                    $confirmed = $true
                }
                elseif ($null -ne $item -and $item -is [bool] -and [bool]$item) {
                    $confirmed = $true
                }
            }
        if (-not $confirmed) {
            $summary.Status = 'awaiting_verification'
            $summary.Message = '事务状态已返回，但 Confirm-AesState 尚未确认当前字体。'
        }
    }

    Write-AesStatus -ActionName $ActionName -Stage 'mutation' -Status $summary.Status -Percent 100 -Message $summary.Message -PendingReboot ([bool]$summary.PendingReboot) -CoveragePath $coverage -ReportFile $ReportFile -State $state
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        Write-AesLog -Path $LogPath -Message $summary.Message
    }
    if ($summary.Status -eq 'failed') { throw $summary.Message }
    return $summary
}

function Assert-AesElevatedOutcome {
    param([int]$ExitCode, [string]$ActionName, [DateTime]$StartedUtc)
    if ($ExitCode -eq 0) { return }
    $childStatus = Get-AesStatus
    $failureMessage = $null
    if ($null -ne $childStatus) {
        $timestamp = [DateTime]::MinValue
        $isFresh = [DateTime]::TryParse([string](Get-AesProperty $childStatus 'Timestamp'), [ref]$timestamp) -and $timestamp.ToUniversalTime() -ge $StartedUtc.ToUniversalTime()
        if ($isFresh -and [string](Get-AesProperty $childStatus 'Action') -eq $ActionName -and [string](Get-AesProperty $childStatus 'Status') -eq 'failed') {
            $failureMessage = [string](Get-AesProperty $childStatus 'Message')
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($failureMessage)) { throw $failureMessage }
    throw ("管理员变更进程失败，退出码 {0}。" -f $ExitCode)
}

function Start-AesElevatedMutation {
    param(
        [Parameter(Mandatory = $true)][string]$ActionName,
        [string]$FontPath,
        [string]$ReportFile,
        [string]$CachePath,
        [string]$CoverageFile
    )

    $powershell = Get-AesPowerShellPath
    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($value in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:ScriptPath, '-Action', $ActionName, '-MutationOnly', '-PackageRoot', $script:PackageRoot, '-CacheRoot', $CachePath, '-UiRoot', $script:DataRoot)) {
        $arguments.Add([string]$value)
    }
    if (-not [string]::IsNullOrWhiteSpace($FontPath)) {
        $arguments.Add('-PreparedFontPath')
        $arguments.Add($FontPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($ReportFile)) {
        $arguments.Add('-ReportPath')
        $arguments.Add($ReportFile)
    }
    if (-not [string]::IsNullOrWhiteSpace($CoverageFile)) {
        $arguments.Add('-CoveragePath')
        $arguments.Add($CoverageFile)
    }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $powershell
    $info.Arguments = (($arguments | ForEach-Object { ConvertTo-AesCommandLineArgument -Value $_ }) -join ' ')
    $info.WorkingDirectory = $script:AppRoot
    $info.UseShellExecute = $true
    $info.Verb = 'runas'
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $process = $null
    try {
        $process = [Diagnostics.Process]::Start($info)
        if ($null -eq $process) {
            throw '管理员进程未启动。'
        }
        # Waiting occurs in the background worker, never on the WPF dispatcher.
        $process.WaitForExit()
        return $process.ExitCode
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Invoke-AesWorkerProgress {
    param(
        [Parameter(Mandatory = $true)][string]$ActionName,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    return {
        param($event)
        $stage = [string](Get-AesProperty -InputObject $event -Name 'Stage')
        $percent = [int](Get-AesProperty -InputObject $event -Name 'Percent')
        $message = [string](Get-AesProperty -InputObject $event -Name 'Message')
        Write-AesStatus -ActionName $ActionName -Stage $stage -Status 'running' -Percent $percent -Message $message
        Write-AesLog -Path $LogPath -Message $message
    }.GetNewClosure()
}

function Invoke-AesWorkerAction {
    param([Parameter(Mandatory = $true)][string]$ActionName)

    Initialize-AesAppDirectories
    $script:CurrentLogPath = Get-AesLogPath -ActionName $ActionName
    Write-AesLog -Path $script:CurrentLogPath -Message ("开始操作：{0}" -f $ActionName)
    Write-AesStatus -ActionName $ActionName -Stage 'start' -Status 'running' -Percent 0 -Message '正在读取系统状态。'

    try {
        if ($ActionName -eq 'Verify') {
            $state = Get-AesCurrentState
            $confirmation = Invoke-AesCore -Name 'Confirm-AesState'
            $confirmed = $false
            $confirmedState = $state
            foreach ($item in @($confirmation)) {
                $confirmedStatus = [string](Get-AesProperty -InputObject $item -Name 'Status')
                if ($confirmedStatus -match '(?i)installed|original|restored') {
                    $confirmed = $true
                    $confirmedState = $item
                }
                elseif ($null -ne $item -and $item -is [bool] -and [bool]$item) {
                    $confirmed = $true
                }
            }
            $stateStatus = [string](Get-AesStateValue -State $confirmedState -Name 'Status')
            $pending = $stateStatus -match '(?i)pending|reboot|restart'
            if ($pending) {
                $message = '当前状态为 pending_reboot；重启后才能确认是否已安装。'
                $finalStatus = 'pending_reboot'
            }
            elseif ($confirmed -and $stateStatus -match '(?i)^installed$' -and [bool](Get-AesStateValue -State $confirmedState -Name 'RenderVerificationPending')) {
                if (-not (Import-AesDisplayVerifier)) {
                    $message = '字体字节状态已确认，但显示验收模块尚未就绪。'
                    $finalStatus = 'installed_unverified'
                }
                else {
                    $verifyCache = if ([string]::IsNullOrWhiteSpace($CacheRoot)) { Get-AesDefaultCacheRoot } else { [IO.Path]::GetFullPath($CacheRoot) }
                    $verifyRoot = Join-Path $verifyCache 'display-verification'
                    [IO.Directory]::CreateDirectory($verifyRoot) | Out-Null
                    Write-AesStatus -ActionName $ActionName -Stage 'display_verify' -Status 'running' -Percent 50 -Message '正在调用实际显示验收。' -State $confirmedState
                    $displayResult = Invoke-AesDisplayVerification -PackageRoot $script:PackageRoot -State $confirmedState -OutputRoot $verifyRoot
                    $displayStatus = [string](Get-AesProperty -InputObject $displayResult -Name 'Status')
                    if ($displayStatus -in @('passed','passed_with_warnings')) {
                        $message = [string](Get-AesProperty -InputObject $displayResult -Name 'Message')
                        $finalStatus = 'verified'
                    }
                    else {
                        $displayMessage = [string](Get-AesProperty -InputObject $displayResult -Name 'Message')
                        if ([string]::IsNullOrWhiteSpace($displayMessage)) {
                            $displayMessage = '实际显示验收未通过。'
                        }
                        $message = '字体已安装，但显示验收未通过：' + $displayMessage
                        $finalStatus = 'installed_unverified'
                    }
                }
            }
            elseif ($confirmed) {
                if ($stateStatus -match '(?i)^original') {
                    $message = '当前为原生字体，Confirm-AesState 已确认。'
                    $finalStatus = 'original'
                }
                else {
                    $message = 'Confirm-AesState 已确认当前状态。'
                    $finalStatus = 'installed'
                }
            }
            else {
                $message = '当前状态尚未被 Confirm-AesState 确认。'
                $finalStatus = 'awaiting_verification'
            }
            Write-AesStatus -ActionName $ActionName -Stage 'verify' -Status $finalStatus -Percent 100 -Message $message -PendingReboot ([bool]$pending) -State $confirmedState
            Write-AesLog -Path $script:CurrentLogPath -Message $message
            return
        }

        if ($ActionName -eq 'Apply') {
            if ($MutationOnly) {
                $script:LastBuildCoveragePath = $CoveragePath
                $mutationReport = if ([string]::IsNullOrWhiteSpace($ReportPath)) { Get-AesDefaultReportPath -ActionName 'apply' } else { [IO.Path]::GetFullPath($ReportPath) }
                $summary = Invoke-AesMutationCore -ActionName 'Apply' -FontPath $PreparedFontPath -ReportFile $mutationReport -CoverageFile $CoveragePath -LogPath $script:CurrentLogPath
                return
            }
            $state = Get-AesCurrentState
            Test-AesSupported -State $state
            if ([string]$state.Status -in @('PendingInstall','PendingRestore','Installed')) {
                $existing = Get-AesMutationResultStatus -State $state -CoreResult $state
                Write-AesStatus -ActionName $ActionName -Stage 'mutation' -Status $existing.Status -Percent 100 -Message $existing.Message -PendingReboot ([bool]$existing.PendingReboot) -State $state
                return
            }
            $original = Get-AesOriginalFontPath -State $state
            $cachePath = if ([string]::IsNullOrWhiteSpace($CacheRoot)) { Get-AesDefaultCacheRoot } else { [IO.Path]::GetFullPath($CacheRoot) }
            $progress = Invoke-AesWorkerProgress -ActionName $ActionName -LogPath $script:CurrentLogPath
            $resources = Initialize-AesResources -PackageRoot $script:PackageRoot -CacheRoot $cachePath -Progress $progress
            $buildRoot = Join-Path $script:DataRoot ('build\' + [Guid]::NewGuid().ToString('N'))
            $build = Invoke-AesBuilder -Resources $resources -OriginalFont $original -BuildRoot $buildRoot -Progress $progress -LogPath $script:CurrentLogPath
            # The builder's coverage.json is the report that the core verifies
            # again against both input hashes.  Keep the full build bundle in
            # the per-user UI root so preview and report data never enter the
            # SYSTEM-owned transaction directory.
            $report = $build.CoveragePath
            Write-AesStatus -ActionName $ActionName -Stage 'elevation' -Status 'waiting_for_elevation' -Percent 85 -Message '资源已准备完成，等待系统变更所需的管理员授权。' -CoveragePath $build.CoveragePath -ReportFile $report -State $state
            if (Test-AesAdministrator) {
                $summary = Invoke-AesMutationCore -ActionName 'Apply' -FontPath $build.FontPath -ReportFile $report -CoverageFile $build.CoveragePath -LogPath $script:CurrentLogPath
                return
            }
            $mutationStartedUtc = [DateTime]::UtcNow
            $exitCode = Start-AesElevatedMutation -ActionName 'Apply' -FontPath $build.FontPath -ReportFile $report -CachePath $resources.CacheRoot -CoverageFile $build.CoveragePath
            Assert-AesElevatedOutcome -ExitCode $exitCode -ActionName 'Apply' -StartedUtc $mutationStartedUtc
            return
        }

        $cachePathForMutation = if ([string]::IsNullOrWhiteSpace($CacheRoot)) { Get-AesDefaultCacheRoot } else { [IO.Path]::GetFullPath($CacheRoot) }
        if ($MutationOnly -or (Test-AesAdministrator)) {
            $summary = Invoke-AesMutationCore -ActionName $ActionName -ReportFile $ReportPath -LogPath $script:CurrentLogPath
            return
        }
        Write-AesStatus -ActionName $ActionName -Stage 'elevation' -Status 'waiting_for_elevation' -Percent 10 -Message '等待系统变更所需的管理员授权。'
        $mutationStartedUtc = [DateTime]::UtcNow
        $exit = Start-AesElevatedMutation -ActionName $ActionName -ReportFile $ReportPath -CachePath $cachePathForMutation
        Assert-AesElevatedOutcome -ExitCode $exit -ActionName $ActionName -StartedUtc $mutationStartedUtc
    }
    catch [System.OperationCanceledException] {
        Write-AesStatus -ActionName $ActionName -Stage 'stopped' -Status 'cancelled' -Percent 0 -Message $_.Exception.Message
        Write-AesLog -Path $script:CurrentLogPath -Message $_.Exception.Message -Level 'WARN'
    }
    catch {
        $message = $_.Exception.Message
        try {
            $failureCoverage = $script:LastBuildCoveragePath
            if ([string]::IsNullOrWhiteSpace($failureCoverage) -or -not (Test-Path -LiteralPath $failureCoverage -PathType Leaf)) {
                $failureCoverage = $null
            }
            Write-AesStatus -ActionName $ActionName -Stage 'error' -Status 'failed' -Percent 0 -Message $message -CoveragePath $failureCoverage -ReportFile $failureCoverage
            Write-AesLog -Path $script:CurrentLogPath -Message $message -Level 'ERROR'
        }
        catch {
            # Preserve the original worker failure if ProgramData is unavailable.
        }
        throw
    }
}

function Start-AesBackgroundAction {
    param(
        [Parameter(Mandatory = $true)][string]$ActionName,
        [string]$CachePath
    )

    $powershell = Get-AesPowerShellPath
    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($value in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:ScriptPath, '-Action', $ActionName, '-PackageRoot', $script:PackageRoot, '-CacheRoot', $CachePath, '-UiRoot', $script:DataRoot)) {
        $arguments.Add([string]$value)
    }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $powershell
    $info.Arguments = (($arguments | ForEach-Object { ConvertTo-AesCommandLineArgument -Value $_ }) -join ' ')
    $info.WorkingDirectory = $script:AppRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $process = [Diagnostics.Process]::Start($info)
    if ($null -eq $process) {
        throw '后台 worker 未启动。'
    }
    return $process
}

function Get-AesOperatingSystemText {
    $name = 'Windows'
    $build = [string][Environment]::OSVersion.Version.Build
    try {
        $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if ($null -ne $currentVersion.ProductName) {
            $name = [string]$currentVersion.ProductName
        }
        if ($null -ne $currentVersion.CurrentBuild) {
            $build = [string]$currentVersion.CurrentBuild
        }
    }
    catch {
        # The OS version API above is enough for a read-only display.
    }
    $buildNumber = 0
    $null = [int]::TryParse($build, [ref]$buildNumber)
    if ($buildNumber -ge 22000) {
        if ($name -match '(?i)Windows\s+10') {
            $name = $name -replace '(?i)Windows\s+10', 'Windows 11'
        }
        elseif ($name -notmatch '(?i)Windows\s+11') {
            $name = 'Windows 11'
        }
    }
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    return ('{0}，Build {1}，{2}' -f $name, $build, $arch)
}

function Get-AesSourceVersionText {
    try {
        $lock = Get-AesPackageLock -PackageRoot $script:PackageRoot
        $font = Get-AesProperty -InputObject $lock -Name 'font'
        $version = Get-AesProperty -InputObject $font -Name 'version'
        if ($null -ne $version -and -not [string]::IsNullOrWhiteSpace([string]$version)) {
            return [string]$version
        }
    }
    catch {
    }
    return '未读取'
}

function Get-AesLatestFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Filter
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $null
    }
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter $Filter -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) {
        return $null
    }
    return $files[0].FullName
}

function Show-AesTextDialog {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    $dialog.Width = 820
    $dialog.Height = 600
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterOwner
    $dialog.Owner = $script:MainWindow
    $box = New-Object Windows.Controls.TextBox
    $box.Text = $Text
    $box.IsReadOnly = $true
    $box.AcceptsReturn = $true
    $box.AcceptsTab = $true
    $box.TextWrapping = [Windows.TextWrapping]::NoWrap
    $box.VerticalScrollBarVisibility = [Windows.Controls.ScrollBarVisibility]::Auto
    $box.HorizontalScrollBarVisibility = [Windows.Controls.ScrollBarVisibility]::Auto
    $box.Margin = New-Object Windows.Thickness(8)
    $dialog.Content = $box
    $dialog.ShowDialog() | Out-Null
}

function Get-AesCoverageText {
    $status = Get-AesStatus
    $coverage = $null
    if ($null -ne $status) {
        $coverage = [string](Get-AesProperty -InputObject $status -Name 'CoveragePath')
    }
    if ([string]::IsNullOrWhiteSpace($coverage) -or -not (Test-Path -LiteralPath $coverage -PathType Leaf)) {
        $coverage = Get-AesLatestFile -Root (Join-Path $script:DataRoot 'build') -Filter 'coverage.json'
    }
    if ([string]::IsNullOrWhiteSpace($coverage) -or -not (Test-Path -LiteralPath $coverage -PathType Leaf)) {
        return '尚未找到 coverage.json。请先完成一次字体构建。'
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $content = [IO.File]::ReadAllText($coverage, $encoding)
    return ("文件：{0}`r`n`r`n{1}" -f $coverage, $content)
}

function Start-AesCoverageView {
    $status = Get-AesStatus
    $coverage = $null
    if ($null -ne $status) {
        $coverage = [string](Get-AesProperty -InputObject $status -Name 'CoveragePath')
    }
    if (-not [string]::IsNullOrWhiteSpace($coverage) -and (Test-Path -LiteralPath $coverage -PathType Leaf)) {
        $preview = Join-Path (Split-Path -Parent $coverage) 'preview.html'
        if (Test-Path -LiteralPath $preview -PathType Leaf) {
            Start-Process -FilePath $preview | Out-Null
            return
        }
    }
    $preview = Get-AesLatestFile -Root (Join-Path $script:DataRoot 'build') -Filter 'preview.html'
    if (-not [string]::IsNullOrWhiteSpace($preview) -and (Test-Path -LiteralPath $preview -PathType Leaf)) {
        Start-Process -FilePath $preview | Out-Null
        return
    }
    Show-AesTextDialog -Title '表情覆盖' -Text (Get-AesCoverageText)
}

function Get-AesLogText {
    $path = Get-AesLatestFile -Root $script:LogRoot -Filter '*.log'
    if ([string]::IsNullOrWhiteSpace($path)) {
        return '尚未找到详细日志。'
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    return ("文件：{0}`r`n`r`n{1}" -f $path, ([IO.File]::ReadAllText($path, $encoding)))
}

function Start-AesUi {
    Add-Type -AssemblyName PresentationCore -ErrorAction Stop
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase -ErrorAction Stop

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="苹果 Emoji 一键切换" Width="820" Height="560" MinWidth="760" MinHeight="480"
        WindowStartupLocation="CenterScreen" Background="#FFF7F7F7">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto" />
      <RowDefinition Height="Auto" />
      <RowDefinition Height="Auto" />
      <RowDefinition Height="Auto" />
      <RowDefinition Height="Auto" />
      <RowDefinition Height="*" />
      <RowDefinition Height="Auto" />
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="苹果 Emoji 一键切换" FontSize="24" FontWeight="SemiBold" Margin="0,0,0,14" />
    <Grid Grid.Row="1" Margin="0,0,0,6">
      <Grid.ColumnDefinitions><ColumnDefinition Width="150" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="操作系统" FontWeight="SemiBold" />
      <TextBlock x:Name="OsText" Grid.Column="1" Text="读取中…" TextWrapping="Wrap" />
    </Grid>
    <Grid Grid.Row="2" Margin="0,0,0,6">
      <Grid.ColumnDefinitions><ColumnDefinition Width="150" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="当前字体" FontWeight="SemiBold" />
      <TextBlock x:Name="FontText" Grid.Column="1" Text="读取中…" TextWrapping="Wrap" />
    </Grid>
    <Grid Grid.Row="3" Margin="0,0,0,6">
      <Grid.ColumnDefinitions><ColumnDefinition Width="150" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="目标版本" FontWeight="SemiBold" />
      <TextBlock x:Name="VersionText" Grid.Column="1" Text="读取中…" />
    </Grid>
    <Grid Grid.Row="4" Margin="0,0,0,10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="150" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="备份" FontWeight="SemiBold" />
      <TextBlock x:Name="BackupText" Grid.Column="1" Text="读取中…" TextWrapping="Wrap" />
    </Grid>
    <Grid Grid.Row="5">
      <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /></Grid.RowDefinitions>
      <Grid Grid.Row="0" Margin="0,0,0,8">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
        <ProgressBar x:Name="ProgressBar" Grid.Column="0" Height="18" Minimum="0" Maximum="100" Value="0" />
        <TextBlock x:Name="ProgressText" Grid.Column="1" Width="230" Margin="12,0,0,0" Text="就绪" VerticalAlignment="Center" />
      </Grid>
      <TextBox x:Name="StatusText" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" BorderBrush="#FFD0D0D0" Background="White" Padding="8" />
    </Grid>
    <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button x:Name="ApplyButton" Content="一键替换" Width="104" Margin="0,0,8,0" Padding="8,5" />
      <Button x:Name="RestoreButton" Content="恢复原生" Width="104" Margin="0,0,8,0" Padding="8,5" />
      <Button x:Name="CancelButton" Content="取消待重启操作" Width="132" Margin="0,0,8,0" Padding="8,5" />
      <Button x:Name="CoverageButton" Content="查看表情覆盖" Width="120" Margin="0,0,8,0" Padding="8,5" />
      <Button x:Name="LogButton" Content="详细日志" Width="92" Padding="8,5" />
      <Button x:Name="RestartButton" Content="重启电脑" Width="96" Margin="8,0,0,0" Padding="8,5" Visibility="Collapsed" IsEnabled="False" />
    </StackPanel>
  </Grid>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $script:MainWindow = $window
    $osText = $window.FindName('OsText')
    $fontText = $window.FindName('FontText')
    $versionText = $window.FindName('VersionText')
    $backupText = $window.FindName('BackupText')
    $progressBar = $window.FindName('ProgressBar')
    $progressText = $window.FindName('ProgressText')
    $statusText = $window.FindName('StatusText')
    $applyButton = $window.FindName('ApplyButton')
    $restoreButton = $window.FindName('RestoreButton')
    $cancelButton = $window.FindName('CancelButton')
    $coverageButton = $window.FindName('CoverageButton')
    $logButton = $window.FindName('LogButton')
    $restartButton = $window.FindName('RestartButton')

    $osText.Text = Get-AesOperatingSystemText
    $versionText.Text = Get-AesSourceVersionText

    function Update-AesUiState {
        try {
            $state = Get-AesCurrentState
            $font = [string](Get-AesStateValue -State $state -Name 'CurrentFont')
            $hash = [string](Get-AesStateValue -State $state -Name 'CurrentHash')
            if ([string]::IsNullOrWhiteSpace($font)) {
                $font = '未读取'
            }
            $fontText.ToolTip = $font + [Environment]::NewLine + 'SHA-256: ' + $hash
            $currentStatus = [string](Get-AesStateValue -State $state -Name 'Status')
            $fontText.Text = if ($currentStatus -in @('Installed','PendingRestore')) { '苹果 Emoji + 原生补齐' }
                elseif ($currentStatus -in @('Original','OriginalWithBackup','PendingInstall')) { 'Segoe UI Emoji（Windows 原生）' }
                else { $font }
            $backupExists = [bool](Get-AesStateValue -State $state -Name 'BackupExists')
            $backupPath = [string](Get-AesStateValue -State $state -Name 'BackupPath')
            if ($backupExists) {
                $backupText.Text = if ([string]::IsNullOrWhiteSpace($backupPath)) { '存在' } else { '存在：' + $backupPath }
            }
            else {
                $backupText.Text = '不存在'
            }
            $statusValue = [string](Get-AesStateValue -State $state -Name 'Status')
            $reason = [string](Get-AesStateValue -State $state -Name 'Reason')
            $renderPending = [bool](Get-AesStateValue -State $state -Name 'RenderVerificationPending')
            $pending = $statusValue -in @('PendingInstall','PendingRestore')
            $restartButton.IsEnabled = $pending
            $restartButton.Visibility = if ($pending) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
            $cancelButton.IsEnabled = $pending
            $restoreButton.IsEnabled = $backupExists -and $statusValue -eq 'Installed'
            $applyButton.IsEnabled = [bool](Get-AesStateValue -State $state -Name 'Supported') -and $statusValue -in @('Original','OriginalWithBackup')
            if ($statusValue -match '(?i)pending|reboot|restart') {
                $statusText.Text = '操作已安排，等待重启。请先保存工作；重启后再次打开工具验证。'
            }
            elseif (-not [string]::IsNullOrWhiteSpace($reason) -and -not [bool](Get-AesStateValue -State $state -Name 'Supported')) {
                $statusText.Text = '系统不支持：' + $reason
            }
            elseif ($statusValue -match '(?i)^installed$' -and $renderPending -and -not (Test-AesUiBusy) -and -not $script:VerifyWorkerRequested) {
                $script:VerifyWorkerRequested = $true
                Start-AesUiWorker -ActionName 'Verify'
            }
            elseif (-not [string]::IsNullOrWhiteSpace($statusValue) -and $null -eq (Get-AesStatus)) {
                $stateLabel = switch ($statusValue) {
                    'Original' { '正在使用 Windows 原生字体。' }
                    'OriginalWithBackup' { '正在使用 Windows 原生字体，已有原始备份。' }
                    default { $statusValue + ' ' + $reason }
                }
                $statusText.Text = $stateLabel
            }
        }
        catch {
            $statusText.Text = '读取系统状态失败：' + $_.Exception.Message
        }
    }

    function Update-AesUiStatusFile {
        $status = Get-AesStatus
        if ($null -eq $status) {
            return
        }
        $percent = Get-AesProperty -InputObject $status -Name 'Percent'
        if ($null -ne $percent) {
            $progressBar.Value = [Math]::Max(0, [Math]::Min(100, [int]$percent))
        }
        $stage = [string](Get-AesProperty -InputObject $status -Name 'Stage')
        $message = [string](Get-AesProperty -InputObject $status -Name 'Message')
        $statusValue = [string](Get-AesProperty -InputObject $status -Name 'Status')
        if ([string]::IsNullOrWhiteSpace($stage)) {
            $stage = 'status'
        }
        $stageLabels = @{
            start = '启动'; lock = '锁文件'; download = '下载'; cache = '缓存'; runtime = '运行时'; unicode = 'Unicode 数据'; ready = '资源就绪'; build = '构建'; elevation = '管理员授权'; mutation = '系统事务'; verify = '验证'; display_verify = '显示验收'; error = '错误'; stopped = '已停止'; status = '状态'
        }
        $statusLabels = @{
            running = '运行中'; waiting_for_elevation = '等待授权'; pending_reboot = '待重启'; installed = '已安装'; verified = '已替换并验证'; original = '原生'; cancelled = '已取消'; failed = '失败'; awaiting_verification = '待验证'; installed_unverified = '待显示验收'
        }
        $stageLabel = if ($stageLabels.ContainsKey($stage)) { $stageLabels[$stage] } else { $stage }
        $statusLabel = if ($statusLabels.ContainsKey($statusValue)) { $statusLabels[$statusValue] } else { $statusValue }
        $progressText.Text = '{0}：{1}' -f $stageLabel, $statusLabel
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            $statusText.Text = $message
        }
        if ($statusValue -eq 'pending_reboot') {
            $statusText.Text = $message + ' 当前状态明确为 pending_reboot。'
        }
    }

    function Test-AesUiBusy {
        if ($null -eq $script:UiWorker) {
            return $false
        }
        if ($script:UiWorker.HasExited) {
            $script:UiWorker.Dispose()
            $script:UiWorker = $null
            return $false
        }
        return $true
    }

    function Start-AesUiWorker {
        param([string]$ActionName)
        if (Test-AesUiBusy) {
            $statusText.Text = '已有后台操作正在运行，请等待其结束。'
            return
        }
        try {
            Initialize-AesAppDirectories
            $cachePath = if ([string]::IsNullOrWhiteSpace($CacheRoot)) { Get-AesDefaultCacheRoot } else { [IO.Path]::GetFullPath($CacheRoot) }
            $script:UiWorker = Start-AesBackgroundAction -ActionName $ActionName -CachePath $cachePath
            $progressBar.Value = 0
            $progressText.Text = '启动：运行中'
            $statusText.Text = '后台操作已启动。系统变更会在需要时请求管理员授权。'
        }
        catch {
            if ($ActionName -eq 'Verify') {
                $script:VerifyWorkerRequested = $false
            }
            $statusText.Text = '启动后台操作失败：' + $_.Exception.Message
        }
    }

    $applyButton.Add_Click({ Start-AesUiWorker -ActionName 'Apply' })
    $restoreButton.Add_Click({ Start-AesUiWorker -ActionName 'Restore' })
    $cancelButton.Add_Click({ Start-AesUiWorker -ActionName 'Cancel' })
    $coverageButton.Add_Click({
        try { Start-AesCoverageView }
        catch { $statusText.Text = '读取覆盖率失败：' + $_.Exception.Message }
    })
    $logButton.Add_Click({
        try { Show-AesTextDialog -Title '详细日志' -Text (Get-AesLogText) }
        catch { $statusText.Text = '读取日志失败：' + $_.Exception.Message }
    })
    $restartButton.Add_Click({
        if (-not $restartButton.IsEnabled) { return }
        $choice = [Windows.MessageBox]::Show($window, '请先保存正在进行的工作。现在重启电脑吗？', '重启电脑', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
        if ($choice -eq [Windows.MessageBoxResult]::Yes) {
            Start-Process -FilePath ([IO.Path]::Combine($env:WINDIR,'System32','shutdown.exe')) -ArgumentList '/r /t 0' -WindowStyle Hidden | Out-Null
        }
    })

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = New-Object TimeSpan(0, 0, 0, 0, 500)
    $timer.Add_Tick({
        Update-AesUiStatusFile
        if (([DateTime]::UtcNow - $script:LastUiStateRefresh).TotalSeconds -ge 2) {
            $script:LastUiStateRefresh = [DateTime]::UtcNow
            Update-AesUiState
        }
    })
    $window.Add_Closed({ $timer.Stop() })
    Update-AesUiState
    Update-AesUiStatusFile
    $timer.Start()
    $window.ShowDialog() | Out-Null
}

if ($Action -eq 'Ui') {
    Start-AesUi
    return
}

if ($Action -eq 'Verify' -and $MutationOnly) {
    throw 'Verify 是只读操作，不应带 MutationOnly。'
}

Invoke-AesWorkerAction -ActionName $Action
