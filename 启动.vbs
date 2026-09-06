Option Explicit

Dim shell, fso, scriptFolder, windir, powershell, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptFolder = fso.GetParentFolderName(WScript.ScriptFullName)
windir = shell.ExpandEnvironmentStrings("%WINDIR%")
powershell = windir & "\System32\WindowsPowerShell\v1.0\powershell.exe"

' A 32-bit WScript on a 64-bit OS must launch the native x64 Windows PowerShell.
If shell.ExpandEnvironmentStrings("%PROCESSOR_ARCHITEW6432%") <> "%PROCESSOR_ARCHITEW6432%" Then
    If fso.FileExists(windir & "\Sysnative\WindowsPowerShell\v1.0\powershell.exe") Then
        powershell = windir & "\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    End If
End If
If Not fso.FileExists(powershell) Then
    powershell = "powershell.exe"
End If

command = QuoteArgument(powershell) & " -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File " & QuoteArgument(fso.BuildPath(scriptFolder, "AppleEmojiSwitcher.ps1"))
' Window style 0 keeps both the launcher and its PowerShell host invisible.
shell.Run command, 0, False

Function QuoteArgument(value)
    QuoteArgument = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
