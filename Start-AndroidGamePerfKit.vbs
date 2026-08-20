Option Explicit

Dim shell, fileSystem, kitRoot, launcherPath, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

kitRoot = fileSystem.GetParentFolderName(WScript.ScriptFullName)
launcherPath = fileSystem.BuildPath(kitRoot, "AndroidGamePerfKit-Launcher.ps1")
shell.CurrentDirectory = kitRoot

command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File " & Chr(34) & launcherPath & Chr(34)
shell.Run command, 1, False
