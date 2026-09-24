$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Load presentation markup alone; never execute the application or its system actions.
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\AppleEmojiSwitcher.ps1'))
$xaml = [regex]::Match($source, '(?s)function Start-AesUi.*?\$xaml = @''\r?\n(.*?)\r?\n''@').Groups[1].Value
if ([string]::IsNullOrWhiteSpace($xaml)) { throw 'Main UI markup not found' }
$actions = @('ApplyButton', 'RestoreButton', 'CancelButton', 'RestartButton', 'PanelEnableButton', 'PanelDisableButton', 'PanelStatusButton')

foreach ($scenario in @('default', 'minimum', 'pending-long-text')) {
    $window = [Windows.Markup.XamlReader]::Parse($xaml)
    try {
        $window.WindowStartupLocation = 'Manual'
        $window.Left = -20000
        $window.Top = -20000
        $window.ShowInTaskbar = $false
        $window.ShowActivated = $false
        if ($scenario -ne 'default') {
            $window.Width = $window.MinWidth
            $window.Height = $window.MinHeight
        }
        $restart = $window.FindName('RestartButton')
        if ($restart.Visibility -ne 'Collapsed' -or $restart.IsEnabled) { throw 'Initial reboot action is exposed' }
        if ($scenario -eq 'pending-long-text') {
            $restart.Visibility = 'Visible'
            $restart.IsEnabled = $true
            $window.FindName('BackupText').Text = 'C:\backup\' + ('long-folder-name\' * 16) + 'seguiemj.ttf'
            $window.FindName('PanelStatusText').Text = ('Panel status message. ' * 20)
            $window.FindName('StatusText').Text = ('Detailed operation message.' + [Environment]::NewLine) * 100
        }
        $window.Show()
        $window.UpdateLayout()
        $scroll = $window.FindName('MainScroll')
        if ($scroll.ViewportHeight -lt 100) { throw 'Main viewport is too short' }
        foreach ($name in $actions) {
            $control = $window.FindName($name)
            if ($null -eq $control) { throw "Missing action: $name" }
            if ($control.Visibility -eq 'Collapsed') { continue }
            $control.BringIntoView()
            $window.UpdateLayout()
            $point = $control.TransformToAncestor($scroll).Transform([Windows.Point]::new(0, 0))
            if ($point.X -lt -1 -or $point.Y -lt -1 -or
                ($point.X + $control.ActualWidth) -gt ($scroll.ViewportWidth + 1) -or
                ($point.Y + $control.ActualHeight) -gt ($scroll.ViewportHeight + 1)) {
                throw "Action cannot be reached in $scenario`: $name"
            }
        }
        foreach ($name in @('CoverageButton', 'LogButton')) {
            $control = $window.FindName($name)
            $point = $control.TransformToAncestor($window.Content).Transform([Windows.Point]::new(0, 0))
            if ($point.Y -lt 0 -or ($point.Y + $control.ActualHeight) -gt ($window.Content.ActualHeight + 1)) {
                throw "Footer clipped in $scenario`: $name"
            }
        }
    }
    finally { $window.Close() }
}
'PASS WPF layout: default/minimum windows, reboot controls, long text, scroll reachability and fixed footer.'
