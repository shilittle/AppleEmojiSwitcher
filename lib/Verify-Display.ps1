function Invoke-AesDisplayVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$PackageRoot,
        [Parameter(Mandatory=$true)]$State,
        [string]$OutputRoot
    )
    $result = @{ Status='failed'; Message=''; ReportPath=$null; Warnings=@() }
    try {
        if ($State.Status -ne 'Installed') { throw '只有系统文件已替换后才能进行显示验收。' }
        $target = Join-Path ([Environment]::GetFolderPath('Windows')) 'Fonts\seguiemj.ttf'
        $before = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($before -ne ([string]$State.CurrentHash).ToLowerInvariant()) { throw '字体在验证前发生变化，请重新检测。' }
        if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
            $OutputRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AppleEmojiSwitcher\verification'
        }
        $directory = Join-Path $OutputRoot ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($directory)
        $requests = Join-Path $directory 'requests.tsv'
        $rows = @(
            "face`t1F600", "skin_zwj`t1F468 1F3FD 200D 1F4BB", "flag`t1F1E8 1F1F3",
            "keycap`t0023 FE0F 20E3", "heart_emoji`t2764 FE0F", "heart_text`t2764 FE0E",
            "female`t2640 FE0F", "medical`t2695 FE0F", "black_flag`t1F3F4",
            "england`t1F3F4 E0067 E0062 E0065 E006E E0067 E007F",
            "scotland`t1F3F4 E0067 E0062 E0073 E0063 E0074 E007F",
            "wales`t1F3F4 E0067 E0062 E0077 E006C E0073 E007F"
        )
        [IO.File]::WriteAllLines($requests, $rows, (New-Object Text.UTF8Encoding($false)))
        $renderer = Join-Path $PackageRoot 'bin\EmojiRender.exe'
        if (-not (Test-Path -LiteralPath $renderer -PathType Leaf)) { throw '随包字体渲染组件缺失。' }
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $renderer
        $info.Arguments = '--font @system --requests "' + $requests + '" --out "' + $directory + '" --sizes 16,32,64'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $info
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) {
            $process.Kill()
            throw '字体显示验收超时。'
        }
        if ($process.ExitCode -ne 0) { throw ('字体显示验收失败：' + $stderr.Result) }
        $render = Get-Content -LiteralPath (Join-Path $directory 'render.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($render.status -ne 'passed' -or -not $render.fontMatched -or @($render.items).Count -ne $rows.Count) { throw '字体显示验收没有完整通过。' }
        $warnings = New-Object 'System.Collections.Generic.List[string]'
        foreach ($item in $render.items) {
            if (@($item.images).Count -ne 3) { throw ('字号验收不完整：' + $item.id) }
            foreach ($image in $item.images) {
                if ($image.inkPixels -le 0) { throw ('表情显示为空：' + $item.id) }
                if ($image.visibleGlyphCount -ne 1) { $warnings.Add('组合显示被拆开：' + $item.id) }
                if ($item.id -eq 'heart_text') {
                    if ($image.colorPixels -ne 0) { $warnings.Add('文字形态的心形符号存在颜色差异。') }
                } elseif ($item.id -notin @('black_flag','england','scotland','wales') -and $image.colorPixels -le 0) { $warnings.Add('彩色表情没有颜色：' + $item.id) }
            }
        }
        $baseFlag = @($render.items | Where-Object { $_.id -eq 'black_flag' })[0]
        $baseIds = (@($baseFlag.images)[1].glyphIndices -join ',')
        foreach ($item in @($render.items | Where-Object { $_.id -in @('england','scotland','wales') })) {
            if ((@($item.images)[1].glyphIndices -join ',') -eq $baseIds) { $warnings.Add('地区旗显示为黑旗：' + $item.id) }
        }
        $after = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($before -ne $after) { throw '字体在验证过程中发生变化，请重新检测。' }
        $status = if ($warnings.Count) { 'passed_with_warnings' } else { 'passed' }
        $report = @{ schemaVersion=1; status=$status; warnings=@($warnings); compatibilityPolicy='warn-on-local-display-differences-v1'; fontSha256=$after; verifiedUtc=[DateTime]::UtcNow.ToString('o'); renderer='DirectWrite/Direct2D system collection'; images=($rows.Count*3); manifest=(Join-Path $directory 'render.json') }
        $reportPath = Join-Path $directory 'display-verification.json'
        [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $result.Status = $status
        $result.Warnings = @($warnings)
        $result.Message = if ($warnings.Count) { '系统字体已替换，基本显示验证通过；局部兼容性差异已保留为提示，详见报告。' } else { '系统字体已替换，彩色表情、组合和文字形态均通过显示验收。' }
        $result.ReportPath = $reportPath
    } catch {
        $result.Message = $_.Exception.Message
    }
    return $result
}
