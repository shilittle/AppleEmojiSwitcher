Set-StrictMode -Version 2.0

<##
    Common, non-WPF invocation helpers for the optional native emoji-panel
    extension.  This file deliberately does not load Bootstrap, Python, the
    font transaction module, or any WPF assemblies.  The standalone panel
    command and the GUI use the same controller selection and JSON handling.
##>

$script:AesPanelControllerInvoker = $null

function Get-AesPanelLocalRoot {
    $root = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($root)) {
        try { $root = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData) } catch { $root = $null }
    }
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw '无法确定 LOCALAPPDATA，不能定位面板扩展。'
    }
    return [IO.Path]::GetFullPath((Join-Path $root 'AppleEmojiSwitcher\panel'))
}

function Get-AesPanelInstalledControllerPath {
    return [IO.Path]::Combine((Get-AesPanelLocalRoot), 'PanelController.exe')
}

function Get-AesPanelPortableControllerPath {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)
    return [IO.Path]::Combine([IO.Path]::GetFullPath($PackageRoot), 'bin', 'PanelController.exe')
}

function Resolve-AesPanelControllerPath {
    param(
        [string]$PackageRoot,
        [Parameter(Mandatory = $true)][ValidateSet('enable', 'disable', 'status', 'uninstall')][string]$Command
    )

    $portable = $null
    if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
        $portable = Get-AesPanelPortableControllerPath -PackageRoot $PackageRoot
    }
    $installed = Get-AesPanelInstalledControllerPath

    # An upgrade must use the controller shipped with the package when it is
    # present.  Lifecycle/status operations prefer the installed copy so that
    # disabling or uninstalling remains possible after the ZIP is removed.
    if ($Command -eq 'enable') {
        if ($null -ne $portable -and (Test-Path -LiteralPath $portable -PathType Leaf)) { return $portable }
        if (Test-Path -LiteralPath $installed -PathType Leaf) { return $installed }
    }
    else {
        if (Test-Path -LiteralPath $installed -PathType Leaf) { return $installed }
        if ($null -ne $portable -and (Test-Path -LiteralPath $portable -PathType Leaf)) { return $portable }
    }
    return $null
}

function Get-AesPanelMember {
    param($InputObject, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    if ($null -eq $property.Value) { return $Default }
    return $property.Value
}

function New-AesPanelResult {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [bool]$Success = $false,
        [string]$State = 'unavailable',
        [string]$Message = '',
        [string]$ManualAcceptance = 'pending',
        [bool]$Installed = $false,
        [bool]$Enabled = $false,
        [bool]$Running = $false,
        [bool]$StartupRegistered = $false,
        [int]$InjectedCount = 0,
        [string]$FailureReason = '',
        [int]$ExitCode = 1,
        [string]$ControllerPath = '',
        [string]$RawOutput = ''
    )
    return [pscustomobject][ordered]@{
        Success          = $Success
        Command          = $Command
        State            = $State
        Message          = $Message
        ManualAcceptance = $ManualAcceptance
        Installed        = $Installed
        Enabled          = $Enabled
        Running          = $Running
        StartupRegistered = $StartupRegistered
        InjectedCount    = $InjectedCount
        FailureReason    = $FailureReason
        ExitCode         = $ExitCode
        ControllerPath   = $ControllerPath
        RawOutput        = $RawOutput
    }
}

function ConvertFrom-AesPanelJson {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string]$RawOutput,
        [int]$ProcessExitCode = 1,
        [string]$ControllerPath = ''
    )

    $payload = $null
    $parseError = $null
    if (-not [string]::IsNullOrWhiteSpace($RawOutput)) {
        # The controller contract is one JSON object on stdout.  Accept a
        # single leading/trailing diagnostic line so a future signed wrapper
        # cannot make status unreadable, while still requiring a JSON object.
        $candidates = @($RawOutput.Trim())
        foreach ($line in ($RawOutput -split "`r?`n")) {
            if ($line.Trim().StartsWith('{')) { $candidates += $line.Trim() }
        }
        foreach ($candidate in ($candidates | Select-Object -Unique)) {
            try {
                $payload = $candidate | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $payload) { break }
            }
            catch { $parseError = $_.Exception.Message }
        }
    }
    if ($null -eq $payload) {
        $reason = if ($parseError) { '控制器返回的 JSON 无法解析：' + $parseError } else { '控制器没有返回 JSON。' }
        return New-AesPanelResult -Command $Command -Message $reason -FailureReason $reason -ExitCode $(if ($ProcessExitCode -eq 0) { 1 } else { $ProcessExitCode }) -ControllerPath $ControllerPath -RawOutput $RawOutput
    }

    $success = [bool](Get-AesPanelMember $payload 'success' $false)
    $state = [string](Get-AesPanelMember $payload 'state' $(if ($success) { 'ok' } else { 'failed' }))
    $message = [string](Get-AesPanelMember $payload 'message' '')
    $failure = [string](Get-AesPanelMember $payload 'failureReason' '')
    $exitCode = if ($success -and $ProcessExitCode -eq 0) { 0 } elseif ($ProcessExitCode -eq 0) { 1 } else { $ProcessExitCode }
    return New-AesPanelResult `
        -Command ([string](Get-AesPanelMember $payload 'command' $Command)) `
        -Success ($success -and $ProcessExitCode -eq 0) `
        -State $state `
        -Message $message `
        -ManualAcceptance ([string](Get-AesPanelMember $payload 'manualAcceptance' 'pending')) `
        -Installed ([bool](Get-AesPanelMember $payload 'installed' $false)) `
        -Enabled ([bool](Get-AesPanelMember $payload 'enabled' $false)) `
        -Running ([bool](Get-AesPanelMember $payload 'running' $false)) `
        -StartupRegistered ([bool](Get-AesPanelMember $payload 'startupRegistered' $false)) `
        -InjectedCount ([int](Get-AesPanelMember $payload 'injectedCount' 0)) `
        -FailureReason $failure `
        -ExitCode $exitCode `
        -ControllerPath $ControllerPath `
        -RawOutput $RawOutput
}

function Invoke-AesPanelController {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('enable', 'disable', 'status', 'uninstall')][string]$Command,
        [string]$PackageRoot
    )

    $controller = Resolve-AesPanelControllerPath -PackageRoot $PackageRoot -Command $Command
    if ([string]::IsNullOrWhiteSpace($controller)) {
        $message = '增强面板组件缺失，请重新解压完整的 v1.3.0 面板包。'
        return New-AesPanelResult -Command $Command -Message $message -FailureReason 'controller_missing'
    }

    if ($null -ne $script:AesPanelControllerInvoker) {
        try {
            $mock = & $script:AesPanelControllerInvoker $Command $controller
            if ($mock -is [string]) {
                return ConvertFrom-AesPanelJson -Command $Command -RawOutput ([string]$mock) -ProcessExitCode 0 -ControllerPath $controller
            }
            return ConvertFrom-AesPanelJson -Command $Command -RawOutput (($mock | ConvertTo-Json -Depth 8 -Compress)) -ProcessExitCode 0 -ControllerPath $controller
        }
        catch {
            $message = '调用面板控制器失败：' + $_.Exception.Message
            return New-AesPanelResult -Command $Command -Message $message -FailureReason 'controller_exception' -ControllerPath $controller
        }
    }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $controller
    $info.Arguments = (ConvertTo-AesCommandLineArgument -Value $Command) + ' --json'
    $info.WorkingDirectory = Split-Path -Parent $controller
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = $null
    try {
        $process = [Diagnostics.Process]::Start($info)
        if ($null -eq $process) { throw '进程未启动。' }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $raw = $stdout
        if ([string]::IsNullOrWhiteSpace($raw) -and -not [string]::IsNullOrWhiteSpace($stderr)) { $raw = $stderr }
        return ConvertFrom-AesPanelJson -Command $Command -RawOutput $raw -ProcessExitCode $process.ExitCode -ControllerPath $controller
    }
    catch {
        $message = '调用面板控制器失败：' + $_.Exception.Message
        return New-AesPanelResult -Command $Command -Message $message -FailureReason 'controller_exception' -ControllerPath $controller
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Start-AesPanelControllerProcess {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('enable', 'disable', 'status', 'uninstall')][string]$Command,
        [string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$ErrorPath
    )

    $controller = Resolve-AesPanelControllerPath -PackageRoot $PackageRoot -Command $Command
    if ([string]::IsNullOrWhiteSpace($controller)) {
        throw '增强面板组件缺失，请重新解压完整的 v1.3.0 面板包。'
    }
    $outputParent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
    $errorParent = Split-Path -Parent ([IO.Path]::GetFullPath($ErrorPath))
    if (-not [string]::IsNullOrWhiteSpace($outputParent)) { [IO.Directory]::CreateDirectory($outputParent) | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($errorParent)) { [IO.Directory]::CreateDirectory($errorParent) | Out-Null }
    [IO.File]::WriteAllText($OutputPath, '', (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($ErrorPath, '', (New-Object System.Text.UTF8Encoding($false)))
    $process = Start-Process -FilePath $controller -ArgumentList @($Command, '--json') -WorkingDirectory (Split-Path -Parent $controller) -WindowStyle Hidden -RedirectStandardOutput $OutputPath -RedirectStandardError $ErrorPath -PassThru -ErrorAction Stop
    return [pscustomobject][ordered]@{ Process = $process; Command = $Command; ControllerPath = $controller; OutputPath = $OutputPath; ErrorPath = $ErrorPath }
}

function Format-AesPanelResultMessage {
    param([Parameter(Mandatory = $true)]$Result)
    $lines = New-Object System.Collections.Generic.List[string]
    $message = [string](Get-AesPanelMember $Result 'Message' '')
    if (-not [string]::IsNullOrWhiteSpace($message)) { $lines.Add($message) }
    $state = [string](Get-AesPanelMember $Result 'State' '')
    if (-not [string]::IsNullOrWhiteSpace($state)) { $lines.Add('面板状态：' + $state) }
    $installed = [bool](Get-AesPanelMember $Result 'Installed' $false)
    $enabled = [bool](Get-AesPanelMember $Result 'Enabled' $false)
    $running = [bool](Get-AesPanelMember $Result 'Running' $false)
    $startup = [bool](Get-AesPanelMember $Result 'StartupRegistered' $false)
    if ($installed -or $enabled -or $running) {
        $installedLabel = if ($installed) { '已安装' } else { '未安装' }
        $runningLabel = if ($running) { '运行中' } else { '未运行' }
        $startupLabel = if ($startup) { '已启用' } else { '未启用' }
        $lines.Add(('增强面板：{0}；当前会话：{1}；登录启动：{2}' -f $installedLabel, $runningLabel, $startupLabel))
    }
    $injected = [int](Get-AesPanelMember $Result 'InjectedCount' 0)
    if ($injected -gt 0) { $lines.Add('当前注入宿主数：' + $injected) }
    $manual = [string](Get-AesPanelMember $Result 'ManualAcceptance' 'pending')
    if ($manual -eq 'pending') { $lines.Add('不同应用的输入和显示仍需手工验收。') }
    $failure = [string](Get-AesPanelMember $Result 'FailureReason' '')
    if (-not [string]::IsNullOrWhiteSpace($failure)) { $lines.Add('失败原因：' + $failure) }
    if ($lines.Count -eq 0) { $lines.Add('面板控制器未提供状态信息。') }
    return ($lines -join [Environment]::NewLine)
}

function Show-AesPanelResult {
    param([Parameter(Mandatory = $true)]$Result)
    $message = Format-AesPanelResultMessage -Result $Result
    if ([bool](Get-AesPanelMember $Result 'Success' $false)) { Write-Host $message } else { [Console]::Error.WriteLine($message) }
}
