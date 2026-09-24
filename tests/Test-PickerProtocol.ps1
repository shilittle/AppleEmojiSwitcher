Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$controller = Join-Path $root 'bin\PanelController.exe'
$marker = [string][char]0x9762 + [char]0x677f + [char]::ConvertFromUtf32(0x1FAEB)
foreach ($codePage in @(936, 1252, 65001)) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $controller
    $info.Arguments = 'status --json --' + $marker
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.StandardOutputEncoding = [Text.Encoding]::GetEncoding($codePage)
    $process = [Diagnostics.Process]::Start($info)
    try {
        $raw = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 1) { throw 'Invalid argument must fail' }
        foreach ($character in $raw.ToCharArray()) {
            if ([int]$character -gt 127) { throw 'Machine protocol must be ASCII-safe' }
        }
        $result = $raw | ConvertFrom-Json
        if ($result.success -or $result.failureReason -ne 'invalid_argument') { throw 'Incorrect failure result' }
        if (-not $result.message.EndsWith('--' + $marker)) { throw ('Chinese/emoji JSON roundtrip failed for code page ' + $codePage) }
    }
    finally { $process.Dispose() }
}
'PASS picker protocol: Chinese and supplementary-plane emoji roundtrip through CP936, CP1252 and UTF-8.'
