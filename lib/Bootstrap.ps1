Set-StrictMode -Version 2.0

<#
    AppleEmojiSwitcher resource bootstrap.

    This file deliberately contains no registry, service, font-directory, or
    elevation operations.  It only verifies and stages package resources for
    the caller.  All downloads are resumeless: a verified file is renamed from
    its .partial name into the cache only after its size and SHA-256 match.
#>

function Get-AesProperty {
    param(
        $InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Invoke-AesProgress {
    param(
        [scriptblock]$Progress,
        [string]$Stage,
        [int]$Percent,
        [string]$Message
    )

    if ($null -eq $Progress) {
        return
    }

    $payload = [ordered]@{
        Stage   = $Stage
        Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
        Message = $Message
    }
    & $Progress $payload | Out-Null
}

function Test-AesCancellation {
    param([scriptblock]$Cancelled)

    if ($null -eq $Cancelled) {
        return $false
    }

    try {
        $probe = @(& $Cancelled)
        if ($probe.Count -eq 0) {
            return $false
        }
        return [bool]$probe[-1]
    }
    catch {
        # A failed cancellation probe is treated as cancellation.  This is a
        # fail-closed boundary before any caller can mutate system state.
        return $true
    }
}

function Get-AesLocalAppDataRoot {
    $root = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    }
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw '无法确定 LOCALAPPDATA，不能准备私有 Python 运行时。'
    }
    return [IO.Path]::GetFullPath($root)
}

function Get-AesSafeFileName {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw '资源文件名为空。'
    }

    $leaf = [IO.Path]::GetFileName($Name)
    if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf -ne $Name -or $leaf -eq '.' -or $leaf -eq '..') {
        throw ("资源文件名包含非法路径：{0}" -f $Name)
    }
    return $leaf
}

function Get-AesExpectedSize {
    param($Entry)

    $value = Get-AesProperty -InputObject $Entry -Name 'size'
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
        return $null
    }

    try {
        $size = [Int64]$value
    }
    catch {
        throw ("资源 size 不是整数：{0}" -f $value)
    }
    if ($size -lt 0) {
        throw '资源 size 不能为负数。'
    }
    return $size
}

function Get-AesSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    $algorithm = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $algorithm = [Security.Cryptography.SHA256]::Create()
        $bytes = $algorithm.ComputeHash($stream)
        return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        if ($null -ne $algorithm) {
            $algorithm.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Test-AesArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Nullable[Int64]]$Size
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $item = Get-Item -LiteralPath $Path -Force
        if ($null -ne $Size -and $item.Length -ne [Int64]$Size) {
            return $false
        }
        return ((Get-AesSha256 -Path $Path) -eq ([string]$Sha256).ToLowerInvariant())
    }
    catch {
        return $false
    }
}

function Get-AesUri {
    param([Parameter(Mandatory = $true)][string]$Value)

    try {
        $uri = New-Object System.Uri -ArgumentList $Value
    }
    catch {
        throw ("资源 URL 无效：{0}" -f $Value)
    }
    if (-not $uri.IsAbsoluteUri) {
        throw ("资源 URL 必须是绝对 URL：{0}" -f $Value)
    }
    return $uri
}

function Invoke-AesDownloadVerified {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Nullable[Int64]]$Size,
        [scriptblock]$Progress,
        [scriptblock]$Cancelled
    )

    if ([string]::IsNullOrWhiteSpace($Sha256) -or $Sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw ("资源 SHA-256 无效：{0}" -f $Sha256)
    }
    $null = Get-AesUri -Value $Uri

    if (Test-AesCancellation -Cancelled $Cancelled) {
        throw (New-Object System.OperationCanceledException('资源下载已取消。'))
    }

    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }

    if (Test-AesArtifact -Path $Destination -Sha256 $Sha256 -Size $Size) {
        Invoke-AesProgress -Progress $Progress -Stage 'cache' -Percent 100 -Message ("使用已验证缓存：{0}" -f (Split-Path -Leaf $Destination))
        return [IO.Path]::GetFullPath($Destination)
    }

    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop
    }

    $partial = "$Destination.partial"
    if (Test-Path -LiteralPath $partial -PathType Leaf) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction Stop
    }

    Invoke-AesProgress -Progress $Progress -Stage 'download' -Percent 0 -Message ("下载资源：{0}" -f (Split-Path -Leaf $Destination))

    $request = $null
    $response = $null
    $sourceStream = $null
    $outputStream = $null
    $downloadFailed = $false
    try {
        # WebRequest keeps the operating system's configured proxy and normal
        # TLS certificate validation.  No proxy, PATH, pip, or global Python
        # setting is changed here.
        $request = [Net.WebRequest]::Create((Get-AesUri -Value $Uri))
        if ($request -is [Net.HttpWebRequest]) {
            $request.UserAgent = 'AppleEmojiSwitcher/1.0'
            $request.Timeout = 30000
            $request.ReadWriteTimeout = 30000
        }
        $response = $request.GetResponse()
        $sourceStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open($partial, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $totalBytes = [Int64]$response.ContentLength
        if ($totalBytes -lt 0) {
            $totalBytes = $null
        }
        $buffer = New-Object byte[] (1024 * 1024)
        $readBytes = [Int64]0
        $lastReportBytes = [Int64]0
        $lastPercent = -1
        while ($true) {
            if (Test-AesCancellation -Cancelled $Cancelled) {
                throw (New-Object System.OperationCanceledException('资源下载已取消。'))
            }
            $count = $sourceStream.Read($buffer, 0, $buffer.Length)
            if ($count -le 0) {
                break
            }
            $outputStream.Write($buffer, 0, $count)
            $readBytes += $count
            $percent = 0
            if ($null -ne $totalBytes -and $totalBytes -gt 0) {
                $percent = [int][Math]::Min(99, [Math]::Floor(100 * $readBytes / $totalBytes))
            }
            if ($percent -ne $lastPercent -or ($readBytes - $lastReportBytes) -ge (1024 * 1024)) {
                $detail = if ($null -ne $totalBytes) {
                    ('下载 {0}: {1:N1}% ({2:N1}/{3:N1} MiB)' -f (Split-Path -Leaf $Destination), $percent, ($readBytes / 1MB), ($totalBytes / 1MB))
                }
                else {
                    ('下载 {0}: 已读取 {1:N1} MiB' -f (Split-Path -Leaf $Destination), ($readBytes / 1MB))
                }
                Invoke-AesProgress -Progress $Progress -Stage 'download' -Percent $percent -Message $detail
                $lastPercent = $percent
                $lastReportBytes = $readBytes
            }
        }
        $outputStream.Flush()
    }
    catch {
        $downloadFailed = $true
        throw
    }
    finally {
        if ($null -ne $outputStream) {
            $outputStream.Dispose()
        }
        if ($null -ne $sourceStream) {
            $sourceStream.Dispose()
        }
        if ($null -ne $response) {
            $response.Dispose()
        }
        if ($null -ne $request -and $request -is [System.IDisposable]) {
            $request.Dispose()
        }
        if ($downloadFailed -and (Test-Path -LiteralPath $partial -PathType Leaf)) {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        }
    }

    try {
        if (Test-AesCancellation -Cancelled $Cancelled) {
            throw (New-Object System.OperationCanceledException('资源下载已取消。'))
        }

        if (-not (Test-AesArtifact -Path $partial -Sha256 $Sha256 -Size $Size)) {
            throw (New-Object System.IO.InvalidDataException('资源校验失败，系统未发生修改。'))
        }

        # The source and destination live in one cache directory, so this is
        # an atomic same-volume rename on Windows.
        [IO.File]::Move($partial, $Destination)
    }
    catch {
        if (Test-Path -LiteralPath $partial -PathType Leaf) {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        }
        throw
    }

    Invoke-AesProgress -Progress $Progress -Stage 'download' -Percent 100 -Message ("已验证资源：{0}" -f (Split-Path -Leaf $Destination))
    return [IO.Path]::GetFullPath($Destination)
}

function Get-AesZipDestination {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    $rootFull = [IO.Path]::GetFullPath($Root)
    if (-not $rootFull.EndsWith([string][IO.Path]::DirectorySeparatorChar)) {
        $rootFull += [IO.Path]::DirectorySeparatorChar
    }

    $portable = $EntryName.Replace('/', [IO.Path]::DirectorySeparatorChar).Replace('\', [IO.Path]::DirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $Root $portable))
    if (-not $candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw ("ZIP 条目越出目标目录：{0}" -f $EntryName)
    }
    return $candidate
}

function Expand-AesZipArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    }
    catch {
        throw '当前 Windows PowerShell 缺少 .NET ZipArchive 支持。'
    }

    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $archive = $null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.FullName)) {
                continue
            }
            $target = Get-AesZipDestination -Root $Destination -EntryName $entry.FullName
            $isDirectory = $entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')
            if ($isDirectory) {
                [IO.Directory]::CreateDirectory($target) | Out-Null
                continue
            }

            $targetParent = Split-Path -Parent $target
            [IO.Directory]::CreateDirectory($targetParent) | Out-Null
            $input = $null
            $output = $null
            try {
                $input = $entry.Open()
                $output = [IO.File]::Open($target, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $input.CopyTo($output)
            }
            finally {
                if ($null -ne $output) {
                    $output.Dispose()
                }
                if ($null -ne $input) {
                    $input.Dispose()
                }
            }
        }
    }
    finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }
}

function Write-AesJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $temporary = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    $backup = "$Path.backup.$([Guid]::NewGuid().ToString('N'))"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth 12
        [IO.File]::WriteAllText($temporary, $json, $encoding)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temporary, $Path, $backup)
        }
        else {
            [IO.File]::Move($temporary, $Path)
        }
    }
    catch {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backup -PathType Leaf) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Read-AesJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        return ([IO.File]::ReadAllText($Path, $encoding) | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-AesPackageLock {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)

    $lockPath = Join-Path $PackageRoot 'fonts.lock.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw ("缺少资源锁文件：{0}" -f $lockPath)
    }

    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $lock = [IO.File]::ReadAllText($lockPath, $encoding) | ConvertFrom-Json
    }
    catch {
        throw ("资源锁文件无法解析：{0}" -f $lockPath)
    }

    $version = Get-AesProperty -InputObject $lock -Name 'version'
    if ($null -eq $version -or [int]$version -ne 1) {
        throw 'fonts.lock.json 的 version 必须为 1。'
    }

    $font = Get-AesProperty -InputObject $lock -Name 'font'
    $runtime = Get-AesProperty -InputObject $lock -Name 'runtime'
    foreach ($required in @('font', 'runtime')) {
        $entry = if ($required -eq 'font') { $font } else { $runtime }
        if ($null -eq $entry) {
            throw ("资源锁缺少 {0} 条目。" -f $required)
        }
        foreach ($field in @('url', 'sha256', 'filename')) {
            $fieldValue = Get-AesProperty -InputObject $entry -Name $field
            if ([string]::IsNullOrWhiteSpace([string]$fieldValue)) {
                throw ("资源锁 {0}.{1} 为空。" -f $required, $field)
            }
        }
        $null = Get-AesSafeFileName -Name ([string](Get-AesProperty -InputObject $entry -Name 'filename'))
        if (([string](Get-AesProperty -InputObject $entry -Name 'sha256')) -notmatch '^[0-9a-fA-F]{64}$') {
            throw ("资源锁 {0}.sha256 无效。" -f $required)
        }
    }

    $wheels = @()
    $wheelValue = Get-AesProperty -InputObject $lock -Name 'wheels'
    if ($null -ne $wheelValue) {
        $wheels = @($wheelValue)
    }
    foreach ($entry in $wheels) {
        foreach ($field in @('url', 'sha256', 'filename')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-AesProperty -InputObject $entry -Name $field))) {
                throw ("资源锁 wheels 条目缺少 {0}。" -f $field)
            }
        }
        $null = Get-AesSafeFileName -Name ([string](Get-AesProperty -InputObject $entry -Name 'filename'))
        if (([string](Get-AesProperty -InputObject $entry -Name 'sha256')) -notmatch '^[0-9a-fA-F]{64}$') {
            throw '资源锁 wheels 条目的 sha256 无效。'
        }
    }

    $unicode = @()
    $unicodeValue = Get-AesProperty -InputObject $lock -Name 'unicode'
    if ($null -ne $unicodeValue) {
        $unicode = @($unicodeValue)
    }
    foreach ($entry in $unicode) {
        foreach ($field in @('url', 'sha256', 'filename')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-AesProperty -InputObject $entry -Name $field))) {
                throw ("资源锁 unicode 条目缺少 {0}。" -f $field)
            }
        }
        $null = Get-AesSafeFileName -Name ([string](Get-AesProperty -InputObject $entry -Name 'filename'))
        if (([string](Get-AesProperty -InputObject $entry -Name 'sha256')) -notmatch '^[0-9a-fA-F]{64}$') {
            throw '资源锁 unicode 条目的 sha256 无效。'
        }
    }

    return $lock
}

function Get-AesCacheArtifactPath {
    param(
        [Parameter(Mandatory = $true)][string]$CacheRoot,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $safeName = Get-AesSafeFileName -Name $FileName
    $categoryPath = Join-Path $CacheRoot $Category
    [IO.Directory]::CreateDirectory($categoryPath) | Out-Null
    return (Join-Path $categoryPath $safeName)
}

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

    $fontEntry = Get-AesProperty -InputObject $lock -Name 'font'
    $fontName = [string](Get-AesProperty -InputObject $fontEntry -Name 'filename')
    $fontSha = ([string](Get-AesProperty -InputObject $fontEntry -Name 'sha256')).ToLowerInvariant()
    $fontPath = Get-AesCacheArtifactPath -CacheRoot $cachePath -Category 'font' -FileName $fontName
    $fontSize = Get-AesExpectedSize -Entry $fontEntry
    Invoke-AesDownloadVerified -Uri ([string](Get-AesProperty -InputObject $fontEntry -Name 'url')) -Destination $fontPath -Sha256 $fontSha -Size $fontSize -Progress $Progress -Cancelled $Cancelled | Out-Null
    Invoke-AesProgress -Progress $Progress -Stage 'ready' -Percent 100 -Message '全部资源已通过校验。'

    $result = @{
        Python     = [IO.Path]::GetFullPath($python)
        AppleFont  = [IO.Path]::GetFullPath($fontPath)
        UnicodeDir = [IO.Path]::GetFullPath($unicodeRoot)
        CacheRoot  = [IO.Path]::GetFullPath($cachePath)
    }
    return $result
}
