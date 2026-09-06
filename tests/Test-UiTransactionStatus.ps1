$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\lib\Bootstrap.ps1')
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\AppleEmojiSwitcher.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in @('Get-AesStateValue','Get-AesMutationResultStatus','Get-AesStatus','Assert-AesElevatedOutcome')) {
    $node=$ast.Find({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)
    if($null -eq $node){throw ('Missing production function: '+$name)}
    . ([scriptblock]::Create($node.Extent.Text))
}
$failed=Get-AesMutationResultStatus -State @{Status='Original'} -CoreResult @{Status='Failed';Reason='backup denied'}
if($failed.Status -ne 'failed' -or $failed.Message -ne 'backup denied'){throw 'A rolled-back failure was incorrectly presented as success.'}
$pending=Get-AesMutationResultStatus -State @{Status='PendingInstall'} -CoreResult @{Status='PendingInstall'}
if($pending.Status -ne 'pending_reboot' -or -not $pending.PendingReboot){throw 'Pending operation was not reported.'}
$start=[DateTime]::UtcNow
$script:childStatus=@{Timestamp=$start.AddSeconds(1).ToString('o');Action='Apply';Status='failed';Message='Actual queue verification error'}
$script:StatusPath=[IO.Path]::GetTempFileName()
try {
[IO.File]::WriteAllText($script:StatusPath,($script:childStatus | ConvertTo-Json))
$message=$null
try { Assert-AesElevatedOutcome -ExitCode 1 -ActionName 'Apply' -StartedUtc $start } catch { $message=$_.Exception.Message }
if($message -ne 'Actual queue verification error'){throw 'The elevated child error was replaced with a generic exit code.'}
$script:childStatus.Timestamp=$start.AddSeconds(-1).ToString('o')
[IO.File]::WriteAllText($script:StatusPath,($script:childStatus | ConvertTo-Json))
$message=$null
try { Assert-AesElevatedOutcome -ExitCode 1 -ActionName 'Apply' -StartedUtc $start } catch { $message=$_.Exception.Message }
if($message -eq 'Actual queue verification error' -or [string]::IsNullOrWhiteSpace($message)){throw 'A stale child status was accepted.'}
Assert-AesElevatedOutcome -ExitCode 0 -ActionName 'Apply' -StartedUtc $start
} finally { [IO.File]::Delete($script:StatusPath) }
'PASS UI transaction status: rollback failure retained; pending reboot correctly reported; fresh child error preserved and stale error ignored.'
