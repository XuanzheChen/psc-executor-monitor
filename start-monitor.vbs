Option Explicit
Dim sh, fso, base, exe
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
exe = fso.BuildPath(base, "PSC-Monitor-Neon.exe")
sh.Run """" & exe & """", 1, False
