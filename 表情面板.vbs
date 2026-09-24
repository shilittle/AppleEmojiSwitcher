Option Explicit
Dim sh, fs, root, exe
Set sh = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
root = fs.GetParentFolderName(WScript.ScriptFullName)
exe = fs.BuildPath(root, "bin\PanelController.exe")
If Not fs.FileExists(exe) Then
  MsgBox "Missing bin\PanelController.exe", 16, "AppleEmojiSwitcher"
  WScript.Quit 1
End If
sh.Run Chr(34) & exe & Chr(34) & " show", 0, False
