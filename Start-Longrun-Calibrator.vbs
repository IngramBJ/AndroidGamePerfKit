Option Explicit

Dim shell, fileSystem, kitRoot, calibratorPath, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

kitRoot = fileSystem.GetParentFolderName(WScript.ScriptFullName)
calibratorPath = fileSystem.BuildPath(kitRoot, "Longrun-Calibrator\Longrun-Calibrator.ps1")
shell.CurrentDirectory = kitRoot

command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File " & Chr(34) & calibratorPath & Chr(34)
shell.Run command, 1, False
