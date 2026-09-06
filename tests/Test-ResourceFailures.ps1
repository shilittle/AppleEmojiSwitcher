$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\Bootstrap.ps1')
Add-Type -AssemblyName System.IO.Compression
$fixtureName = 'AesResourceFixtures-' + [guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) $fixtureName
[void][IO.Directory]::CreateDirectory($fixtureRoot)
function Assert-Resource($Condition, $Message) { if (-not $Condition) { throw $Message } }
try {
    $source = Join-Path $fixtureRoot 'source.bin'
    [IO.File]::WriteAllBytes($source, (New-Object byte[] (4MB)))
    $uri = ([uri]$source).AbsoluteUri
    $hash = Get-AesSha256 $source
    $destination = Join-Path $fixtureRoot 'cached.bin'
    [IO.File]::WriteAllText($destination, 'corrupt cache')
    [void](Invoke-AesDownloadVerified -Uri $uri -Destination $destination -Sha256 $hash -Size 4MB)
    Assert-Resource ((Get-AesSha256 $destination) -eq $hash) 'Corrupt cache was not repaired.'

    foreach ($mode in @('wrong-hash','wrong-size','interruption')) {
        $target = Join-Path $fixtureRoot ($mode + '.bin')
        $caught = $false
        try {
            if ($mode -eq 'wrong-hash') { [void](Invoke-AesDownloadVerified -Uri $uri -Destination $target -Sha256 ('0'*64) -Size 4MB) }
            elseif ($mode -eq 'wrong-size') { [void](Invoke-AesDownloadVerified -Uri $uri -Destination $target -Sha256 $hash -Size 99) }
            else {
                [void](Invoke-AesDownloadVerified -Uri $uri -Destination $target -Sha256 $hash -Size 4MB -Progress {
                    param($event)
                    if ($event.Stage -eq 'download' -and $event.Percent -gt 0) { throw (New-Object IO.IOException('Injected stream interruption after receiving bytes.')) }
                })
            }
        } catch { $caught = $true }
        Assert-Resource $caught ('Failure was accepted: ' + $mode)
        Assert-Resource (-not (Test-Path -LiteralPath $target)) ('Failed download left an accepted file: ' + $mode)
        Assert-Resource (-not (Test-Path -LiteralPath ($target+'.partial'))) ('Failed download left partial bytes: ' + $mode)
    }

    $archivePath = Join-Path $fixtureRoot 'escape.zip'
    $stream = [IO.File]::Create($archivePath)
    $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
    try { [void]$archive.CreateEntry('../escaped.txt') } finally { $archive.Dispose(); $stream.Dispose() }
    $caught = $false
    try { Expand-AesZipArchive -ArchivePath $archivePath -Destination (Join-Path $fixtureRoot 'unpacked') } catch { $caught=$true }
    Assert-Resource $caught 'ZIP traversal was accepted.'
    Assert-Resource (-not (Test-Path (Join-Path $fixtureRoot 'escaped.txt'))) 'ZIP escaped the destination.'

    $caught = $false
    try { Get-AesPackageLock -PackageRoot $fixtureRoot | Out-Null } catch { $caught=$true }
    Assert-Resource $caught 'Missing resource lock was accepted.'
    'PASS resource failures: corrupt cache repaired; bad hash/size, interrupted stream, ZIP traversal and missing lock rejected.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $expected = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) $fixtureName))
    if ($resolved -eq $expected -and $fixtureName -match '^AesResourceFixtures-[a-f0-9]{32}$') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
