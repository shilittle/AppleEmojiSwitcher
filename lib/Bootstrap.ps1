Set-StrictMode -Version 2.0

<#
    AppleEmojiSwitcher resource bootstrap.

    This file deliberately contains no registry, service, font-directory, or
    elevation operations.  It only verifies and stages package resources for
    the caller.  All downloads are resumeless: a verified file is renamed from
    its .partial name into the cache only after its size and SHA-256 match.
#>

$commonPath = Join-Path $PSScriptRoot 'Common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw ("缺少共享模块：{0}" -f $commonPath)
}
. $commonPath

function Get-AesRuntimePth {
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)

    $preferred = Join-Path $RuntimeRoot 'python313._pth'
    if (Test-Path -LiteralPath $preferred -PathType Leaf) {
        return $preferred
    }

    $candidates = @(Get-ChildItem -LiteralPath $RuntimeRoot -Filter '*._pth' -File -ErrorAction SilentlyContinue)
    if ($candidates.Count -eq 0) {
        throw ("嵌入式 Python 缺少 ._pth 文件：{0}" -f $RuntimeRoot)
    }
    return $candidates[0].FullName
}

function Enable-AesPythonSite {
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)

    $pth = Get-AesRuntimePth -RuntimeRoot $RuntimeRoot
    $text = [IO.File]::ReadAllText($pth)
    $rawLines = $text -split "`r?`n"
    $lines = New-Object System.Collections.Generic.List[string]
    $siteImport = $false
    $sitePath = $false
    foreach ($line in $rawLines) {
        if ($line -match '^\s*#\s*import\s+site\s*$') {
            $lines.Add('import site')
            $siteImport = $true
            continue
        }
        if ($line.Trim() -eq 'Lib\site-packages' -or $line.Trim() -eq 'Lib/site-packages') {
            $sitePath = $true
        }
        $lines.Add($line)
    }
    if (-not $sitePath) {
        $lines.Add('Lib\site-packages')
    }
    if (-not $siteImport) {
        $lines.Add('import site')
    }

    $newText = [string]::Join("`r`n", $lines.ToArray())
    if (-not $newText.EndsWith("`r`n")) {
        $newText += "`r`n"
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($pth, $newText, $encoding)
    return $pth
}

function Get-AesWheelVersion {
    param([Parameter(Mandatory = $true)]$Entry)

    $version = [string](Get-AesProperty -InputObject $Entry -Name 'version')
    if (-not [string]::IsNullOrWhiteSpace($version)) {
        return $version
    }

    $filename = [IO.Path]::GetFileNameWithoutExtension([string](Get-AesProperty -InputObject $Entry -Name 'filename'))
    if ($filename -match '^[^-]+-(\d[^-]*)-') {
        return [string]$matches[1]
    }
    return $null
}

function Test-AesPrivateRuntimeImports {
    param(
        [Parameter(Mandatory = $true)][string]$Python,
        [Parameter(Mandatory = $true)]$Lock,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot
    )

    # The lock intentionally contains only the three direct builder
    # dependencies.  Probe both the import name and distribution version so a
    # stale marker cannot hide a deleted or replaced wheel.
    $required = @(
        [ordered]@{ Prefix = 'fonttools-'; Module = 'fontTools'; Distribution = 'fonttools' },
        [ordered]@{ Prefix = 'uharfbuzz-'; Module = 'uharfbuzz'; Distribution = 'uharfbuzz' },
        [ordered]@{ Prefix = 'pillow-'; Module = 'PIL'; Distribution = 'Pillow' }
    )
    $expectations = New-Object System.Collections.Generic.List[object]
    $lockWheels = @(Get-AesProperty -InputObject $Lock -Name 'wheels')
    foreach ($requirement in $required) {
        $entry = $null
        foreach ($wheel in $lockWheels) {
            $wheelName = [string](Get-AesProperty -InputObject $wheel -Name 'filename')
            if ($wheelName.ToLowerInvariant().StartsWith([string]$requirement.Prefix)) {
                $entry = $wheel
                break
            }
        }
        if ($null -eq $entry) {
            return $false
        }
        $version = Get-AesWheelVersion -Entry $entry
        if ([string]::IsNullOrWhiteSpace($version)) {
            return $false
        }
        $expectations.Add([ordered]@{
                module       = [string]$requirement.Module
                distribution = [string]$requirement.Distribution
                version      = [string]$version
            })
    }

    $expectedJson = ConvertTo-Json -InputObject @($expectations.ToArray()) -Compress -Depth 5
    $probeSource = @"
import importlib
import importlib.metadata as metadata
expected = $expectedJson
for item in expected:
    importlib.import_module(item["module"])
    actual = metadata.version(item["distribution"])
    if actual != item["version"]:
        raise RuntimeError("version mismatch for " + item["distribution"])
print("AES_RUNTIME_OK")
"@
    $encoded = [Convert]::ToBase64String((New-Object System.Text.UTF8Encoding($false)).GetBytes($probeSource))
    # The base64 alphabet excludes single quotes, so keep those delimiters
    # inside the quoted -c argument without confusing Windows argument parsing.
    $probeCommand = "import base64;exec(base64.b64decode('$encoded').decode('utf-8'))"
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Python
    $info.Arguments = ('-I -B -X utf8 -c "{0}"' -f $probeCommand)
    $info.WorkingDirectory = $RuntimeRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    $stdoutTask = $null
    $stderrTask = $null
    try {
        if (-not $process.Start()) {
            return $false
        }
        # Read both redirected pipes asynchronously; the probe is tiny, but
        # this keeps diagnostics from ever blocking process completion.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = [string]$stdoutTask.Result
        $null = [string]$stderrTask.Result
        return ($process.ExitCode -eq 0 -and $stdout -match '(?m)^AES_RUNTIME_OK\s*$')
    }
    catch {
        return $false
    }
    finally {
        $process.Dispose()
    }
}

function Test-AesRuntimeReady {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)]$Lock,
        [Parameter(Mandatory = $true)][string]$RuntimeSha256
    )

    $python = Join-Path $RuntimeRoot 'python.exe'
    $markerPath = Join-Path $RuntimeRoot '.aes-runtime.json'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf) -or -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return $false
    }
    $marker = Read-AesJson -Path $markerPath
    if ($null -eq $marker) {
        return $false
    }
    $version = Get-AesProperty -InputObject $Lock -Name 'version'
    if ([string](Get-AesProperty -InputObject $marker -Name 'Version') -ne [string]$version) {
        return $false
    }
    if ([string](Get-AesProperty -InputObject $marker -Name 'RuntimeSha256') -ne ([string]$RuntimeSha256).ToLowerInvariant()) {
        return $false
    }

    $markerWheels = @(Get-AesProperty -InputObject $marker -Name 'Wheels')
    $lockWheels = @(Get-AesProperty -InputObject $Lock -Name 'wheels')
    if ($markerWheels.Count -ne $lockWheels.Count) {
        return $false
    }
    for ($index = 0; $index -lt $lockWheels.Count; $index++) {
        $expectedName = [string](Get-AesProperty -InputObject $lockWheels[$index] -Name 'filename')
        $expectedSha = ([string](Get-AesProperty -InputObject $lockWheels[$index] -Name 'sha256')).ToLowerInvariant()
        $actual = $markerWheels | Where-Object {
            ([string](Get-AesProperty -InputObject $_ -Name 'Filename') -eq $expectedName) -and
            ([string](Get-AesProperty -InputObject $_ -Name 'Sha256') -eq $expectedSha)
        }
        if ($null -eq $actual) {
            return $false
        }
    }
    if (-not (Test-AesPrivateRuntimeImports -Python $python -Lock $Lock -RuntimeRoot $RuntimeRoot)) {
        return $false
    }
    return $true
}

function Replace-AesDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Staging,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $parent = Split-Path -Parent $Destination
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $old = "$Destination.old.$([Guid]::NewGuid().ToString('N'))"
    $movedOld = $false
    try {
        if (Test-Path -LiteralPath $Destination -PathType Container) {
            Move-Item -LiteralPath $Destination -Destination $old -Force -ErrorAction Stop
            $movedOld = $true
        }
        Move-Item -LiteralPath $Staging -Destination $Destination -Force -ErrorAction Stop
        if ($movedOld -and (Test-Path -LiteralPath $old -PathType Container)) {
            Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        if ($movedOld -and -not (Test-Path -LiteralPath $Destination -PathType Container) -and (Test-Path -LiteralPath $old -PathType Container)) {
            Move-Item -LiteralPath $old -Destination $Destination -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Install-AesRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeArchive,
        [Parameter(Mandatory = $true)]$Lock,
        [Parameter(Mandatory = $true)][string]$RuntimeSha256,
        [Parameter(Mandatory = $true)][string]$CacheRoot,
        [scriptblock]$Progress,
        [scriptblock]$Cancelled
    )

    $runtimeRoot = Join-Path (Get-AesLocalAppDataRoot) 'AppleEmojiSwitcher\runtime'
    if ((Test-AesRuntimeReady -RuntimeRoot $runtimeRoot -Lock $Lock -RuntimeSha256 $RuntimeSha256)) {
        $pth = Enable-AesPythonSite -RuntimeRoot $runtimeRoot
        Invoke-AesProgress -Progress $Progress -Stage 'runtime' -Percent 35 -Message '使用已验证的嵌入式 Python 运行时。'
        return (Join-Path $runtimeRoot 'python.exe')
    }

    if (Test-AesCancellation -Cancelled $Cancelled) {
        throw (New-Object System.OperationCanceledException('运行时准备已取消。'))
    }

    $localRoot = Split-Path -Parent $runtimeRoot
    [IO.Directory]::CreateDirectory($localRoot) | Out-Null
    $staging = Join-Path $localRoot ('.runtime-stage-' + [Guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        Invoke-AesProgress -Progress $Progress -Stage 'runtime' -Percent 15 -Message '解压嵌入式 Python 运行时。'
        Expand-AesZipArchive -ArchivePath $RuntimeArchive -Destination $staging
        $python = Join-Path $staging 'python.exe'
        if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
            throw '嵌入式 Python 压缩包缺少 python.exe。'
        }

        $sitePackages = Join-Path $staging 'Lib\site-packages'
        [IO.Directory]::CreateDirectory($sitePackages) | Out-Null
        $wheelRecords = New-Object System.Collections.Generic.List[object]
        $lockWheels = @(Get-AesProperty -InputObject $Lock -Name 'wheels')
        $wheelIndex = 0
        foreach ($wheelEntry in $lockWheels) {
            if (Test-AesCancellation -Cancelled $Cancelled) {
                throw (New-Object System.OperationCanceledException('Python wheel 准备已取消。'))
            }
            $wheelName = [string](Get-AesProperty -InputObject $wheelEntry -Name 'filename')
            $wheelSha = ([string](Get-AesProperty -InputObject $wheelEntry -Name 'sha256')).ToLowerInvariant()
            $wheelPath = Get-AesCacheArtifactPath -CacheRoot $CacheRoot -Category 'wheels' -FileName $wheelName
            $wheelSize = Get-AesExpectedSize -Entry $wheelEntry
            Invoke-AesDownloadVerified -Uri ([string](Get-AesProperty -InputObject $wheelEntry -Name 'url')) -Destination $wheelPath -Sha256 $wheelSha -Size $wheelSize -Progress $Progress -Cancelled $Cancelled | Out-Null
            Expand-AesZipArchive -ArchivePath $wheelPath -Destination $sitePackages
            $wheelRecords.Add([ordered]@{ Filename = $wheelName; Sha256 = $wheelSha })
            $wheelIndex++
            $wheelPercent = 15 + [int](20 * $wheelIndex / [Math]::Max(1, $lockWheels.Count))
            Invoke-AesProgress -Progress $Progress -Stage 'runtime' -Percent $wheelPercent -Message ("已解压 Python wheel：{0}" -f $wheelName)
        }

        $null = Enable-AesPythonSite -RuntimeRoot $staging
        $marker = [ordered]@{
            Version       = [int](Get-AesProperty -InputObject $Lock -Name 'version')
            RuntimeSha256 = $RuntimeSha256.ToLowerInvariant()
            Wheels        = @($wheelRecords.ToArray())
        }
        Write-AesJsonAtomic -Path (Join-Path $staging '.aes-runtime.json') -Value $marker
        Replace-AesDirectory -Staging $staging -Destination $runtimeRoot
        $staging = $null
        Invoke-AesProgress -Progress $Progress -Stage 'runtime' -Percent 35 -Message '嵌入式 Python 已准备完成。'
        return (Join-Path $runtimeRoot 'python.exe')
    }
    finally {
        if ($null -ne $staging -and (Test-Path -LiteralPath $staging -PathType Container)) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-AesUnicodeReady {
    param(
        [Parameter(Mandatory = $true)][string]$UnicodeRoot,
        [Parameter(Mandatory = $true)]$Lock
    )

    $marker = Read-AesJson -Path (Join-Path $UnicodeRoot '.aes-unicode.json')
    if ($null -eq $marker) {
        return $false
    }
    if ([string](Get-AesProperty -InputObject $marker -Name 'Version') -ne [string](Get-AesProperty -InputObject $Lock -Name 'version')) {
        return $false
    }
    $markerArtifacts = @(Get-AesProperty -InputObject $marker -Name 'Artifacts')
    $lockArtifacts = @(Get-AesProperty -InputObject $Lock -Name 'unicode')
    if ($markerArtifacts.Count -ne $lockArtifacts.Count) {
        return $false
    }
    foreach ($entry in $lockArtifacts) {
        $name = [string](Get-AesProperty -InputObject $entry -Name 'filename')
        $sha = ([string](Get-AesProperty -InputObject $entry -Name 'sha256')).ToLowerInvariant()
        $found = $markerArtifacts | Where-Object {
            ([string](Get-AesProperty -InputObject $_ -Name 'Filename') -eq $name) -and
            ([string](Get-AesProperty -InputObject $_ -Name 'Sha256') -eq $sha)
        }
        if ($null -eq $found) {
            return $false
        }
    }
    return $true
}

function Install-AesUnicodeData {
    param(
        [Parameter(Mandatory = $true)]$Lock,
        [Parameter(Mandatory = $true)][string]$CacheRoot,
        [scriptblock]$Progress,
        [scriptblock]$Cancelled
    )

    $unicodeRoot = Join-Path $CacheRoot 'unicode'
    $unicodeEntries = @(Get-AesProperty -InputObject $Lock -Name 'unicode')
    if ((Test-AesUnicodeReady -UnicodeRoot $unicodeRoot -Lock $Lock)) {
        Invoke-AesProgress -Progress $Progress -Stage 'unicode' -Percent 60 -Message '使用已验证的 Unicode 数据缓存。'
        return [IO.Path]::GetFullPath($unicodeRoot)
    }

    $staging = Join-Path $CacheRoot ('.unicode-stage-' + [Guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        $records = New-Object System.Collections.Generic.List[object]
        $index = 0
        foreach ($entry in $unicodeEntries) {
            if (Test-AesCancellation -Cancelled $Cancelled) {
                throw (New-Object System.OperationCanceledException('Unicode 数据准备已取消。'))
            }
            $name = [string](Get-AesProperty -InputObject $entry -Name 'filename')
            $sha = ([string](Get-AesProperty -InputObject $entry -Name 'sha256')).ToLowerInvariant()
            $artifact = Get-AesCacheArtifactPath -CacheRoot $CacheRoot -Category 'unicode' -FileName $name
            $size = Get-AesExpectedSize -Entry $entry
            Invoke-AesDownloadVerified -Uri ([string](Get-AesProperty -InputObject $entry -Name 'url')) -Destination $artifact -Sha256 $sha -Size $size -Progress $Progress -Cancelled $Cancelled | Out-Null

            if ($name.ToLowerInvariant().EndsWith('.zip')) {
                Expand-AesZipArchive -ArchivePath $artifact -Destination $staging
            }
            else {
                Copy-Item -LiteralPath $artifact -Destination (Join-Path $staging (Get-AesSafeFileName -Name $name)) -Force -ErrorAction Stop
            }
            $records.Add([ordered]@{ Filename = $name; Sha256 = $sha })
            $index++
            $percent = 40 + [int](20 * $index / [Math]::Max(1, $unicodeEntries.Count))
            Invoke-AesProgress -Progress $Progress -Stage 'unicode' -Percent $percent -Message ("已准备 Unicode 数据：{0}" -f $name)
        }

        $marker = [ordered]@{
            Version   = [int](Get-AesProperty -InputObject $Lock -Name 'version')
            Artifacts = @($records.ToArray())
        }
        Write-AesJsonAtomic -Path (Join-Path $staging '.aes-unicode.json') -Value $marker
        Replace-AesDirectory -Staging $staging -Destination $unicodeRoot
        $staging = $null
        Invoke-AesProgress -Progress $Progress -Stage 'unicode' -Percent 60 -Message 'Unicode 数据已准备完成。'
        return [IO.Path]::GetFullPath($unicodeRoot)
    }
    finally {
        if ($null -ne $staging -and (Test-Path -LiteralPath $staging -PathType Container)) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Initialize-AesResources {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [string]$CacheRoot,
        [scriptblock]$Progress,
        [scriptblock]$Cancelled
    )

    $packagePath = [IO.Path]::GetFullPath($PackageRoot)
    if (-not (Test-Path -LiteralPath $packagePath -PathType Container)) {
        throw ("PackageRoot 不存在：{0}" -f $packagePath)
    }
    if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
        $CacheRoot = Join-Path (Get-AesLocalAppDataRoot) 'AppleEmojiSwitcher\cache'
    }
    $cachePath = [IO.Path]::GetFullPath($CacheRoot)
    [IO.Directory]::CreateDirectory($cachePath) | Out-Null

    $lock = Get-AesPackageLock -PackageRoot $packagePath
    $null = Assert-AesFullPackageLock -Lock $lock
    Invoke-AesProgress -Progress $Progress -Stage 'lock' -Percent 5 -Message '已读取并校验 fonts.lock.json。'
    if (Test-AesCancellation -Cancelled $Cancelled) {
        throw (New-Object System.OperationCanceledException('资源准备已取消。'))
    }

    $runtimeEntry = Get-AesProperty -InputObject $lock -Name 'runtime'
    $runtimeName = [string](Get-AesProperty -InputObject $runtimeEntry -Name 'filename')
    $runtimeSha = ([string](Get-AesProperty -InputObject $runtimeEntry -Name 'sha256')).ToLowerInvariant()
    $runtimeArchive = Get-AesCacheArtifactPath -CacheRoot $cachePath -Category 'runtime' -FileName $runtimeName
    $runtimeSize = Get-AesExpectedSize -Entry $runtimeEntry
    Invoke-AesDownloadVerified -Uri ([string](Get-AesProperty -InputObject $runtimeEntry -Name 'url')) -Destination $runtimeArchive -Sha256 $runtimeSha -Size $runtimeSize -Progress $Progress -Cancelled $Cancelled | Out-Null
    $python = Install-AesRuntime -RuntimeArchive $runtimeArchive -Lock $lock -RuntimeSha256 $runtimeSha -CacheRoot $cachePath -Progress $Progress -Cancelled $Cancelled

    $unicodeRoot = Install-AesUnicodeData -Lock $lock -CacheRoot $cachePath -Progress $Progress -Cancelled $Cancelled

    # Keep the GUI's font preparation on the same pinned, mutex-protected
    # path used by the lightweight CLI.  Runtime and Unicode remain GUI-only.
    $fontResource = Initialize-AesFontResource -PackageRoot $packagePath -CacheRoot $cachePath -Progress $Progress -Cancelled $Cancelled
    $fontPath = [string]$fontResource.AppleFont
    Invoke-AesProgress -Progress $Progress -Stage 'ready' -Percent 100 -Message '全部资源已通过校验。'

    $result = @{
        Python     = [IO.Path]::GetFullPath($python)
        AppleFont  = [IO.Path]::GetFullPath($fontPath)
        UnicodeDir = [IO.Path]::GetFullPath($unicodeRoot)
        CacheRoot  = [IO.Path]::GetFullPath($cachePath)
    }
    return $result
}
