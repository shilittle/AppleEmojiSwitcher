[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('enable', 'disable', 'status', 'uninstall', 'help')]
    [string]$Command = '',
    [string]$PackageRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:PanelRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    $PackageRoot = $script:PanelRoot
}
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot)

$commonPath = Join-Path $script:PanelRoot 'lib\Common.ps1'
$panelPath = Join-Path $script:PanelRoot 'lib\Panel.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) { throw ('缺少共享模块：' + $commonPath) }
if (-not (Test-Path -LiteralPath $panelPath -PathType Leaf)) { throw ('缺少面板模块：' + $panelPath) }
. $commonPath
. $panelPath

function Show-AesPanelHelp {
    Write-Host 'AppleEmojiSwitcher 面板扩展'
    Write-Host '用法：panel.cmd [enable|disable|status|uninstall|help]'
    Write-Host '  enable    安装并启用面板扩展，注册当前用户登录启动'
    Write-Host '  disable   停止增强面板并恢复系统快捷键'
    Write-Host '  status    查看增强面板和登录启动状态'
    Write-Host '  uninstall 卸载扩展及登录启动项，保留字体事务和备份'
    Write-Host '  help      显示本帮助'
    Write-Host ''
    Write-Host '启用后 Win + . 打开独立增强面板；停用即可恢复 Windows 原生面板。'
}

function Resolve-AesPanelMenuChoice {
    param([Parameter(Mandatory = $true)][string]$Choice)
    switch ($Choice.Trim()) {
        '1' { return 'enable' }
        '2' { return 'disable' }
        '3' { return 'status' }
        '4' { return 'uninstall' }
        '5' { return 'help' }
        '0' { return 'exit' }
        default { return $null }
    }
}

function Invoke-AesPanelCommand {
    param([Parameter(Mandatory = $true)][string]$RequestedCommand)
    if ($RequestedCommand -eq 'help') {
        Show-AesPanelHelp
        return 0
    }
    if ($RequestedCommand -eq 'exit') { return 0 }
    try {
        $result = Invoke-AesPanelController -Command $RequestedCommand -PackageRoot $PackageRoot
        Show-AesPanelResult -Result $result
        return [int](Get-AesPanelMember $result 'ExitCode' 1)
    }
    catch {
        [Console]::Error.WriteLine('面板操作失败：' + $_.Exception.Message)
        return 1
    }
}

function Invoke-AesPanelMenu {
    while ($true) {
        Write-Host ''
        Write-Host 'AppleEmojiSwitcher 面板扩展'
        Write-Host '1. 启用面板增强'
        Write-Host '2. 停用面板增强'
        Write-Host '3. 查看状态'
        Write-Host '4. 卸载面板扩展'
        Write-Host '5. 查看帮助'
        Write-Host '0. 退出'
        $choice = Read-Host '请选择'
        $command = Resolve-AesPanelMenuChoice -Choice $choice
        if ($null -eq $command) {
            Write-Host '请输入 0 至 5。'
            continue
        }
        if ($command -eq 'exit') { return 0 }
        $exitCode = Invoke-AesPanelCommand -RequestedCommand $command
        if ($command -ne 'help') {
            Write-Host ('退出码：' + $exitCode)
            [void](Read-Host '按回车返回菜单')
        }
    }
}

if ([string]::IsNullOrWhiteSpace($Command)) {
    exit (Invoke-AesPanelMenu)
}
if ($Command -eq 'help') {
    Show-AesPanelHelp
    exit 0
}
exit (Invoke-AesPanelCommand -RequestedCommand $Command)
