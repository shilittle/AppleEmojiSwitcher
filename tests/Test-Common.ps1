[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
. (Join-Path $repoRoot 'lib\Common.ps1')

function Assert-AesCommon {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('Aes Common Fixture ' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
try {
    $packageRoot = Join-Path $fixtureRoot 'package'
    $cacheRoot = Join-Path $fixtureRoot 'cache with spaces'
    $sourceRoot = Join-Path $fixtureRoot 'source'
    [IO.Directory]::CreateDirectory($packageRoot) | Out-Null
    [IO.Directory]::CreateDirectory($cacheRoot) | Out-Null
    [IO.Directory]::CreateDirectory($sourceRoot) | Out-Null

    $realLock = Get-AesPackageLock -PackageRoot $repoRoot
    $pinned = Get-AesPinnedFontSpec -PackageRoot $repoRoot
    Assert-AesCommon ([string](Get-AesProperty $pinned 'sha256') -eq '18e48f1785564fbf511241e0963b265057bfe742036d8543406c6ce07e48ec0b') '固定字体 SHA-256 不匹配。'
    Assert-AesCommon ([Int64](Get-AesProperty $pinned 'size') -eq 256391076) '固定字体大小不匹配。'

    $minimalLock = [ordered]@{ version = 1; font = $pinned }
    [IO.File]::WriteAllText((Join-Path $packageRoot 'fonts.lock.json'), (ConvertTo-Json $minimalLock -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    $minimalSpec = Get-AesPinnedFontSpec -PackageRoot $packageRoot
    Assert-AesCommon ([string](Get-AesProperty $minimalSpec 'filename') -eq 'AppleColorEmoji-Windows.ttf') 'CLI 裁剪锁文件未被接受。'
    $fullRejected = $false
    try { $null = Assert-AesFullPackageLock -Lock (Get-AesPackageLock -PackageRoot $packageRoot) } catch { $fullRejected = $true }
    Assert-AesCommon $fullRejected 'CLI 裁剪锁文件被错误视为完整 GUI 锁。'

    $badLock = [ordered]@{ version = 1; font = [ordered]@{
            url = [string](Get-AesProperty $pinned 'url')
            sha256 = ('0' * 64)
            size = 256391076
            filename = 'AppleColorEmoji-Windows.ttf'
        } }
    $badRoot = Join-Path $fixtureRoot 'bad-package'
    [IO.Directory]::CreateDirectory($badRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $badRoot 'fonts.lock.json'), (ConvertTo-Json $badLock -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    $badRejected = $false
    try { $null = Get-AesPinnedFontSpec -PackageRoot $badRoot } catch { $badRejected = $true }
    Assert-AesCommon $badRejected '错误 SHA-256 的字体锁文件被接受。'

    $source = Join-Path $sourceRoot 'fixture source.bin'
    [IO.File]::WriteAllBytes($source, (New-Object byte[] (2MB)))
    $sourceUri = ([Uri]$source).AbsoluteUri
    $sourceHash = Get-AesSha256 -Path $source
    $destination = Join-Path $cacheRoot 'font cache.bin'
    [IO.File]::WriteAllText($destination, 'corrupt')
    $events = New-Object System.Collections.Generic.List[object]
    $progress = { param($event) $events.Add($event) }.GetNewClosure()
    $resolved = Invoke-AesDownloadVerified -Uri $sourceUri -Destination $destination -Sha256 $sourceHash -Size 2MB -Progress $progress
    Assert-AesCommon ($resolved -eq [IO.Path]::GetFullPath($destination)) '带空格路径没有返回规范缓存路径。'
    Assert-AesCommon (Test-AesArtifact -Path $destination -Sha256 $sourceHash -Size 2MB) '缓存下载后二次校验失败。'
    Assert-AesCommon ($events.Count -gt 0) '共享下载没有产生进度事件。'

    # Hold the exact cache mutex and make the waiting caller cancel.  This
    # exercises the bounded wait path without downloading a large resource.
    $heldDestination = Join-Path $cacheRoot 'held.bin'
    $heldMutex = New-Object System.Threading.Mutex($false, (Get-AesDownloadMutexName -Path $heldDestination))
    $held = $false
    try { $held = $heldMutex.WaitOne(1000); Assert-AesCommon $held '测试无法取得缓存互斥锁。'
        $poll = 0
        $waitCancelled = $false
        try {
            Invoke-AesDownloadVerified -Uri $sourceUri -Destination $heldDestination -Sha256 $sourceHash -Size 2MB -Cancelled {
                $script:poll++
                return ($script:poll -ge 2)
            } | Out-Null
        } catch [System.OperationCanceledException] { $waitCancelled = $true }
        Assert-AesCommon $waitCancelled '等待缓存互斥锁时取消未生效。'
    }
    finally {
        if ($held) { $heldMutex.ReleaseMutex() }
        $heldMutex.Dispose()
    }
    $null = Invoke-AesDownloadVerified -Uri $sourceUri -Destination $heldDestination -Sha256 $sourceHash -Size 2MB
    Assert-AesCommon (Test-AesArtifact -Path $heldDestination -Sha256 $sourceHash -Size 2MB) '取消等待后缓存锁没有正确释放。'

    # Two independent Windows PowerShell 5.1 processes target one cache path;
    # one downloads while the other waits and then reuses the verified file.
    $helperPath = Join-Path $fixtureRoot 'parallel helper.ps1'
    $config = [ordered]@{ Common = (Join-Path $repoRoot 'lib\Common.ps1'); Uri = $sourceUri; Destination = (Join-Path $cacheRoot 'parallel.bin'); Sha256 = $sourceHash }
    $configText = ConvertTo-Json $config -Compress
    $configB64 = [Convert]::ToBase64String((New-Object System.Text.UTF8Encoding($false)).GetBytes($configText))
    $helperText = @"
`$ErrorActionPreference = 'Stop'
`$cfg = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$configB64')) | ConvertFrom-Json
. `$cfg.Common
`$null = Invoke-AesDownloadVerified -Uri ([string]`$cfg.Uri) -Destination ([string]`$cfg.Destination) -Sha256 ([string]`$cfg.Sha256) -Size 2MB
"@
    [IO.File]::WriteAllText($helperPath, $helperText, (New-Object System.Text.UTF8Encoding($true)))
    $powershell = Get-AesPowerShellPath
    $children = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($unused in 1..2) {
            $info = New-Object System.Diagnostics.ProcessStartInfo
            $info.FileName = $powershell
            $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-AesCommandLineArgument $helperPath)
            $info.WorkingDirectory = $repoRoot
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $info
            Assert-AesCommon $process.Start() '并发测试子进程未启动。'
            $children.Add($process)
        }
        foreach ($process in $children) {
            $process.WaitForExit()
            Assert-AesCommon ($process.ExitCode -eq 0) ('并发缓存测试子进程失败：' + $process.ExitCode)
        }
    }
    finally {
        foreach ($process in $children) {
            if ($null -eq $process) { continue }
            try {
                if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            } catch { }
            try { $process.Dispose() } catch { }
        }
    }
    Assert-AesCommon (Test-AesArtifact -Path (Join-Path $cacheRoot 'parallel.bin') -Sha256 $sourceHash -Size 2MB) '并发下载没有留下已验证缓存。'

    Write-Output ('PASS common resources: pinned lock, minimal lock, corrupt cache, cancellation and parallel mutex; progress events: {0}' -f $events.Count)
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        $safeTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolved = [IO.Path]::GetFullPath($fixtureRoot)
        if (-not $resolved.StartsWith($safeTempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing fixture cleanup outside the temporary directory.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
