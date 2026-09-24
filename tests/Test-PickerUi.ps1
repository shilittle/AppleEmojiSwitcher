Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $root '.build'
[IO.Directory]::CreateDirectory($buildRoot) | Out-Null
$library = Join-Path $buildRoot ('PickerUiTests-' + [Guid]::NewGuid().ToString('N') + '.dll')
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$source = Join-Path $root 'native\picker\*.cs'
& $compiler /nologo /target:library /langversion:5 /r:System.Core.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll ("/out:" + $library) $source (Join-Path $PSScriptRoot 'PickerUiTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Picker UI test build failed' }
Add-Type -Path $library
[AesPicker.Tests.PickerUiTests]::RunAll()
'PASS picker UI: exact UTF-16, search/categories/recents, form construction, minimum layout and arrow navigation across four widths.'
