[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$bootstrap = Join-Path $scriptRoot 'lib\Bootstrap.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('aes-bootstrap-fixture-' + [Guid]::NewGuid().ToString('N'))
$oldLocalAppData = $env:LOCALAPPDATA

function Assert-AesTest {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
    $packageRoot = Join-Path $fixtureRoot 'package'
    $cacheRoot = Join-Path $fixtureRoot 'cache'
    $sourceRoot = Join-Path $fixtureRoot 'sources'
    $localRoot = Join-Path $fixtureRoot 'localappdata'
    [IO.Directory]::CreateDirectory($packageRoot) | Out-Null
    [IO.Directory]::CreateDirectory($cacheRoot) | Out-Null
    [IO.Directory]::CreateDirectory($sourceRoot) | Out-Null
    [IO.Directory]::CreateDirectory($localRoot) | Out-Null
    $env:LOCALAPPDATA = $localRoot

    . $bootstrap

    $runtimeSource = Join-Path $sourceRoot 'runtime-files'
    [IO.Directory]::CreateDirectory($runtimeSource) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $runtimeSource 'python.exe'), [byte[]](1, 2, 3, 4))
    $pthText = "python313.zip`r`n.`r`n#import site`r`n"
    [IO.File]::WriteAllText((Join-Path $runtimeSource 'python313._pth'), $pthText, (New-Object System.Text.UTF8Encoding($false)))
    $runtimeZip = Join-Path $sourceRoot 'runtime.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($runtimeSource, $runtimeZip)

    $wheelSource = Join-Path $sourceRoot 'wheel-files'
    [IO.Directory]::CreateDirectory((Join-Path $wheelSource 'fixturepkg')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $wheelSource 'fixturepkg\__init__.py'), 'fixture = 1', (New-Object System.Text.UTF8Encoding($false)))
    $wheelPath = Join-Path $sourceRoot 'fixture.whl'
    [IO.Compression.ZipFile]::CreateFromDirectory($wheelSource, $wheelPath)

    $unicodeSource = Join-Path $sourceRoot 'unicode-files'
    [IO.Directory]::CreateDirectory($unicodeSource) | Out-Null
    [IO.File]::WriteAllText((Join-Path $unicodeSource 'emoji-data.txt'), 'fixture unicode data', (New-Object System.Text.UTF8Encoding($false)))
    $unicodeZip = Join-Path $sourceRoot 'unicode.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($unicodeSource, $unicodeZip)

    $fontPath = Join-Path $sourceRoot 'AppleColorEmoji.ttf'
    [IO.File]::WriteAllBytes($fontPath, [byte[]](7, 8, 9, 10, 11))
    $runtimeHash = Get-AesSha256 -Path $runtimeZip
    $wheelHash = Get-AesSha256 -Path $wheelPath
    $unicodeHash = Get-AesSha256 -Path $unicodeZip
    $fontHash = Get-AesSha256 -Path $fontPath
    $runtimeUri = ([Uri]$runtimeZip).AbsoluteUri
    $wheelUri = ([Uri]$wheelPath).AbsoluteUri
    $unicodeUri = ([Uri]$unicodeZip).AbsoluteUri
    $fontUri = ([Uri]$fontPath).AbsoluteUri
    $lock = [ordered]@{
        font = [ordered]@{ url = $fontUri; sha256 = $fontHash; size = 5; filename = 'AppleColorEmoji.ttf'; version = 'fixture' }
        runtime = [ordered]@{ url = $runtimeUri; sha256 = $runtimeHash; filename = 'runtime.zip' }
        wheels = @([ordered]@{ url = $wheelUri; sha256 = $wheelHash; filename = 'fixture.whl' })
        unicode = @([ordered]@{ url = $unicodeUri; sha256 = $unicodeHash; filename = 'unicode.zip' })
        version = 1
    }
    [IO.File]::WriteAllText((Join-Path $packageRoot 'fonts.lock.json'), (ConvertTo-Json $lock -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

    $progressEvents = New-Object System.Collections.Generic.List[object]
    $progress = {
        param($event)
        $progressEvents.Add($event)
    }.GetNewClosure()
    $resources = Initialize-AesResources -PackageRoot $packageRoot -CacheRoot $cacheRoot -Progress $progress
    Assert-AesTest ($resources.ContainsKey('Python')) '返回值缺少 Python。'
    Assert-AesTest ($resources.ContainsKey('AppleFont')) '返回值缺少 AppleFont。'
    Assert-AesTest ($resources.ContainsKey('UnicodeDir')) '返回值缺少 UnicodeDir。'
    Assert-AesTest (Test-Path -LiteralPath $resources.Python -PathType Leaf) 'Python 运行时未准备。'
    Assert-AesTest ((Get-Content -LiteralPath (Join-Path (Split-Path -Parent $resources.Python) 'python313._pth') -Raw) -match '(?m)^Lib\\site-packages\s*$') 'python313._pth 未加入显式 site-packages。'
    Assert-AesTest ((Get-Content -LiteralPath (Join-Path (Split-Path -Parent $resources.Python) 'python313._pth') -Raw) -match '(?m)^import site\s*$') 'python313._pth 未启用 site。'
    Assert-AesTest (Test-Path -LiteralPath (Join-Path $resources.UnicodeDir 'emoji-data.txt') -PathType Leaf) 'Unicode ZIP 未解压。'
    Assert-AesTest (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $resources.Python) 'Lib\site-packages\fixturepkg\__init__.py') -PathType Leaf) 'wheel 未解压到 site-packages。'
    Assert-AesTest ((Get-AesSha256 -Path $resources.AppleFont) -eq $fontHash) '字体缓存校验错误。'
    Assert-AesTest ($progressEvents.Count -gt 0) 'Progress 回调未收到事件。'

    $second = Initialize-AesResources -PackageRoot $packageRoot -CacheRoot $cacheRoot -Progress $progress
    Assert-AesTest ($second.Python -eq $resources.Python) '重复初始化未复用运行时。'
    Assert-AesTest ($second.AppleFont -eq $resources.AppleFont) '重复初始化未复用字体缓存。'

    $cancelledDestination = Join-Path $cacheRoot 'cancel\cancel.bin'
    $cancelCaught = $false
    try {
        Invoke-AesDownloadVerified -Uri $fontUri -Destination $cancelledDestination -Sha256 $fontHash -Size 5 -Cancelled { return $true } | Out-Null
    }
    catch [System.OperationCanceledException] {
        $cancelCaught = $true
    }
    Assert-AesTest $cancelCaught '取消下载未报告 OperationCanceledException。'
    Assert-AesTest (-not (Test-Path -LiteralPath $cancelledDestination)) '取消下载留下了目标文件。'
    Assert-AesTest (-not (Test-Path -LiteralPath ($cancelledDestination + '.partial'))) '取消下载留下了 partial 文件。'

    Write-Output ('Bootstrap tests passed; progress events: {0}' -f $progressEvents.Count)
}
finally {
    if ($null -eq $oldLocalAppData) {
        Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue
    }
    else {
        $env:LOCALAPPDATA = $oldLocalAppData
    }
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        $safeTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not [IO.Path]::GetFullPath($fixtureRoot).StartsWith($safeTempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing fixture cleanup outside the temporary directory.' }
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
