Set-StrictMode -Version 2.0

<#
    Shared resource and process helpers.

    This file is deliberately independent of Bootstrap, Python, WPF, and the
    native renderer.  The GUI and the small CLI may dot-source it and then use
    the same verified cache and download implementation.
#>

$script:AesPinnedFontSha256 = '18e48f1785564fbf511241e0963b265057bfe742036d8543406c6ce07e48ec0b'
$script:AesPinnedFontSize = [Int64]256391076
$script:AesPinnedFontFileName = 'AppleColorEmoji-Windows.ttf'

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

    if ($null -eq $Value -or $Value.Length -eq 0) {
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
        throw '无法确定 LOCALAPPDATA，不能准备资源缓存。'
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
    try { $size = [Int64]$value } catch { throw ("资源 size 不是整数：{0}" -f $value) }
    if ($size -lt 0) { throw '资源 size 不能为负数。' }
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
        if ($null -ne $algorithm) { $algorithm.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Test-AesArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Nullable[Int64]]$Size
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if ($null -ne $Size -and $item.Length -ne [Int64]$Size) { return $false }
        return ((Get-AesSha256 -Path $Path) -eq ([string]$Sha256).ToLowerInvariant())
    }
    catch { return $false }
}

function Get-AesUri {
    param([Parameter(Mandatory = $true)][string]$Value)
    try { $uri = New-Object System.Uri -ArgumentList $Value } catch { throw ("资源 URL 无效：{0}" -f $Value) }
    if (-not $uri.IsAbsoluteUri) { throw ("资源 URL 必须是绝对 URL：{0}" -f $Value) }
    return $uri
}

function Get-AesDownloadMutexName {
    param([Parameter(Mandatory = $true)][string]$Path)
    $canonical = [IO.Path]::GetFullPath($Path).ToUpperInvariant()
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($canonical)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $digest = $algorithm.ComputeHash($bytes) } finally { $algorithm.Dispose() }
    return 'Local\AppleEmojiSwitcher-Download-' + ([BitConverter]::ToString($digest)).Replace('-', '')
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

    $destinationFull = [IO.Path]::GetFullPath($Destination)
    $parent = Split-Path -Parent $destinationFull
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }

    $mutex = $null
    $ownsMutex = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, (Get-AesDownloadMutexName -Path $destinationFull))
        while (-not $ownsMutex) {
            if (Test-AesCancellation -Cancelled $Cancelled) {
                throw (New-Object System.OperationCanceledException('等待资源缓存锁时已取消。'))
            }
            try { $ownsMutex = $mutex.WaitOne(250) }
            catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
        }

        # Another GUI/CLI process may have completed the same cache item while
        # this invocation waited.  Always recheck after acquiring the mutex.
        if (Test-AesArtifact -Path $destinationFull -Sha256 $Sha256 -Size $Size) {
            Invoke-AesProgress -Progress $Progress -Stage 'cache' -Percent 100 -Message ("使用已验证缓存：{0}" -f (Split-Path -Leaf $destinationFull))
            return $destinationFull
        }

        if (Test-Path -LiteralPath $destinationFull -PathType Leaf) { Remove-Item -LiteralPath $destinationFull -Force -ErrorAction Stop }
        $partial = "$destinationFull.partial"
        if (Test-Path -LiteralPath $partial -PathType Leaf) { Remove-Item -LiteralPath $partial -Force -ErrorAction Stop }

        $request = $null
        $response = $null
        $sourceStream = $null
        $outputStream = $null
        $downloadFailed = $false
        try {
            Invoke-AesProgress -Progress $Progress -Stage 'download' -Percent 0 -Message ("下载资源：{0}" -f (Split-Path -Leaf $destinationFull))
            # WebRequest keeps the operating system's configured proxy and
            # normal TLS certificate validation.  No global setting changes.
            $request = [Net.WebRequest]::Create((Get-AesUri -Value $Uri))
            if ($request -is [Net.HttpWebRequest]) {
                $request.UserAgent = 'AppleEmojiSwitcher/1.2'
                $request.Timeout = 30000
                $request.ReadWriteTimeout = 30000
            }
            $response = $request.GetResponse()
            $sourceStream = $response.GetResponseStream()
            $outputStream = [IO.File]::Open($partial, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $totalBytes = [Int64]$response.ContentLength
            if ($totalBytes -lt 0) { $totalBytes = $null }
            $buffer = New-Object byte[] (1024 * 1024)
            $readBytes = [Int64]0
            $lastReportBytes = [Int64]0
            $lastPercent = -1
            while ($true) {
                if (Test-AesCancellation -Cancelled $Cancelled) { throw (New-Object System.OperationCanceledException('资源下载已取消。')) }
                $count = $sourceStream.Read($buffer, 0, $buffer.Length)
                if ($count -le 0) { break }
                $outputStream.Write($buffer, 0, $count)
                $readBytes += $count
                $percent = 0
                if ($null -ne $totalBytes -and $totalBytes -gt 0) { $percent = [int][Math]::Min(99, [Math]::Floor(100 * $readBytes / $totalBytes)) }
                if ($percent -ne $lastPercent -or ($readBytes - $lastReportBytes) -ge (1024 * 1024)) {
                    $detail = if ($null -ne $totalBytes) {
                        ('下载 {0}: {1:N1}% ({2:N1}/{3:N1} MiB)' -f (Split-Path -Leaf $destinationFull), $percent, ($readBytes / 1MB), ($totalBytes / 1MB))
                    } else { ('下载 {0}: 已读取 {1:N1} MiB' -f (Split-Path -Leaf $destinationFull), ($readBytes / 1MB)) }
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
            if ($null -ne $outputStream) { $outputStream.Dispose() }
            if ($null -ne $sourceStream) { $sourceStream.Dispose() }
            if ($null -ne $response) { $response.Dispose() }
            if ($null -ne $request -and $request -is [System.IDisposable]) { $request.Dispose() }
            if ($downloadFailed -and (Test-Path -LiteralPath $partial -PathType Leaf)) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
        }

        try {
            if (Test-AesCancellation -Cancelled $Cancelled) { throw (New-Object System.OperationCanceledException('资源下载已取消。')) }
            if (-not (Test-AesArtifact -Path $partial -Sha256 $Sha256 -Size $Size)) { throw (New-Object System.IO.InvalidDataException('资源校验失败，系统未发生修改。')) }
            [IO.File]::Move($partial, $destinationFull)
        }
        catch {
            if (Test-Path -LiteralPath $partial -PathType Leaf) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
            throw
        }

        if (-not (Test-AesArtifact -Path $destinationFull -Sha256 $Sha256 -Size $Size)) {
            throw (New-Object System.IO.InvalidDataException('资源落盘后二次校验失败。'))
        }
        Invoke-AesProgress -Progress $Progress -Stage 'download' -Percent 100 -Message ("已验证资源：{0}" -f (Split-Path -Leaf $destinationFull))
        return $destinationFull
    }
    finally {
        if ($ownsMutex -and $null -ne $mutex) { try { $mutex.ReleaseMutex() } catch {} }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

function Get-AesZipDestination {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$EntryName
    )
    $rootFull = [IO.Path]::GetFullPath($Root)
    if (-not $rootFull.EndsWith([string][IO.Path]::DirectorySeparatorChar)) { $rootFull += [IO.Path]::DirectorySeparatorChar }
    $portable = $EntryName.Replace('/', [IO.Path]::DirectorySeparatorChar).Replace('\', [IO.Path]::DirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $Root $portable))
    if (-not $candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw ("ZIP 条目越出目标目录：{0}" -f $EntryName) }
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
    catch { throw '当前 Windows PowerShell 缺少 .NET ZipArchive 支持。' }
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $archive = $null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.FullName)) { continue }
            $target = Get-AesZipDestination -Root $Destination -EntryName $entry.FullName
            $isDirectory = $entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')
            if ($isDirectory) { [IO.Directory]::CreateDirectory($target) | Out-Null; continue }
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
                if ($null -ne $output) { $output.Dispose() }
                if ($null -ne $input) { $input.Dispose() }
            }
        }
    }
    finally { if ($null -ne $archive) { $archive.Dispose() } }
}

function Write-AesJsonAtomic {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $temporary = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    $backup = "$Path.backup.$([Guid]::NewGuid().ToString('N'))"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 12), $encoding)
        if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Replace($temporary, $Path, $backup) } else { [IO.File]::Move($temporary, $Path) }
    }
    catch {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backup -PathType Leaf) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Read-AesJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return ([IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json) } catch { return $null }
}

function Get-AesPackageLock {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)
    $lockPath = Join-Path $PackageRoot 'fonts.lock.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { throw ("缺少资源锁文件：{0}" -f $lockPath) }
    try { $lock = [IO.File]::ReadAllText($lockPath, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json } catch { throw ("资源锁文件无法解析：{0}" -f $lockPath) }

    $version = Get-AesProperty -InputObject $lock -Name 'version'
    if ($null -eq $version -or [int]$version -ne 1) { throw 'fonts.lock.json 的 version 必须为 1。' }
    $font = Get-AesProperty -InputObject $lock -Name 'font'
    if ($null -eq $font) { throw '资源锁缺少 font 条目。' }
    foreach ($field in @('url', 'sha256', 'filename')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-AesProperty -InputObject $font -Name $field))) { throw ("资源锁 font.{0} 为空。" -f $field) }
    }
    $null = Get-AesSafeFileName -Name ([string](Get-AesProperty -InputObject $font -Name 'filename'))
    if (([string](Get-AesProperty -InputObject $font -Name 'sha256')) -notmatch '^[0-9a-fA-F]{64}$') { throw '资源锁 font.sha256 无效。' }
    $null = Get-AesExpectedSize -Entry $font

    # The CLI lock intentionally contains only version+font.  A complete GUI
    # lock has runtime and may have wheels/unicode; validate every present
    # entry here and let Initialize-AesResources require the complete set.
    foreach ($kind in @('runtime', 'wheels', 'unicode')) {
        $value = Get-AesProperty -InputObject $lock -Name $kind
        if ($null -eq $value) { continue }
        $entries = if ($kind -eq 'runtime') { @($value) } else { @($value) }
        foreach ($entry in $entries) {
            foreach ($field in @('url', 'sha256', 'filename')) {
                if ([string]::IsNullOrWhiteSpace([string](Get-AesProperty -InputObject $entry -Name $field))) { throw ("资源锁 {0}.{1} 为空。" -f $kind, $field) }
            }
            $null = Get-AesSafeFileName -Name ([string](Get-AesProperty -InputObject $entry -Name 'filename'))
            if (([string](Get-AesProperty -InputObject $entry -Name 'sha256')) -notmatch '^[0-9a-fA-F]{64}$') { throw ("资源锁 {0}.sha256 无效。" -f $kind) }
            $null = Get-AesExpectedSize -Entry $entry
        }
    }
    return $lock
}

function Get-AesPinnedFontSpec {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)
    $lock = Get-AesPackageLock -PackageRoot ([IO.Path]::GetFullPath($PackageRoot))
    $font = Get-AesProperty -InputObject $lock -Name 'font'
    $sha = ([string](Get-AesProperty -InputObject $font -Name 'sha256')).ToLowerInvariant()
    $size = Get-AesExpectedSize -Entry $font
    $filename = [string](Get-AesProperty -InputObject $font -Name 'filename')
    if ($sha -ne $script:AesPinnedFontSha256 -or $null -eq $size -or [Int64]$size -ne $script:AesPinnedFontSize -or $filename -ne $script:AesPinnedFontFileName) {
        throw '资源锁中的苹果字体不是已固定并验证的发布版本。'
    }
    return $font
}

function Assert-AesFullPackageLock {
    param([Parameter(Mandatory = $true)]$Lock)
    foreach ($kind in @('runtime', 'wheels', 'unicode')) {
        $value = Get-AesProperty -InputObject $Lock -Name $kind
        if ($null -eq $value) {
            throw ("完整 GUI 资源锁缺少 {0} 条目。" -f $kind)
        }
    }
    return $true
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

function Initialize-AesFontResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [string]$CacheRoot,
        [scriptblock]$Progress,
        [scriptblock]$Cancelled
    )
    $packagePath = [IO.Path]::GetFullPath($PackageRoot)
    if (-not (Test-Path -LiteralPath $packagePath -PathType Container)) { throw ("PackageRoot 不存在：{0}" -f $packagePath) }
    if ([string]::IsNullOrWhiteSpace($CacheRoot)) { $CacheRoot = Join-Path (Get-AesLocalAppDataRoot) 'AppleEmojiSwitcher\cache' }
    $cachePath = [IO.Path]::GetFullPath($CacheRoot)
    [IO.Directory]::CreateDirectory($cachePath) | Out-Null
    $font = Get-AesPinnedFontSpec -PackageRoot $packagePath
    if (Test-AesCancellation -Cancelled $Cancelled) { throw (New-Object System.OperationCanceledException('字体准备已取消。')) }
    $fontName = [string](Get-AesProperty -InputObject $font -Name 'filename')
    $fontSha = ([string](Get-AesProperty -InputObject $font -Name 'sha256')).ToLowerInvariant()
    $fontSize = Get-AesExpectedSize -Entry $font
    $fontPath = Get-AesCacheArtifactPath -CacheRoot $cachePath -Category 'font' -FileName $fontName
    Invoke-AesDownloadVerified -Uri ([string](Get-AesProperty -InputObject $font -Name 'url')) -Destination $fontPath -Sha256 $fontSha -Size $fontSize -Progress $Progress -Cancelled $Cancelled | Out-Null
    Invoke-AesProgress -Progress $Progress -Stage 'ready' -Percent 100 -Message '苹果字体已通过校验。'
    return @{ AppleFont = [IO.Path]::GetFullPath($fontPath); CacheRoot = [IO.Path]::GetFullPath($cachePath) }
}
