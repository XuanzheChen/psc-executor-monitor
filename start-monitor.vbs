Option Explicit
Dim sh, fso, base, exe, bootstrap, command, exitCode
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
exe = fso.BuildPath(base, "PSC-Monitor-Neon.exe")
bootstrap = fso.BuildPath(base, "ensure-monitor.ps1")
If Not fso.FileExists(bootstrap) Then
    MsgBox "Missing ensure-monitor.ps1 in " & base, vbCritical, "PSC Executor Monitor"
    WScript.Quit 1
End If
command = """" & sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & bootstrap & """"
exitCode = sh.Run(command, 0, True)
If exitCode <> 0 Or Not fso.FileExists(exe) Then
    MsgBox "PSC Monitor setup failed. See monitor-setup-error.log in:" & vbCrLf & base & vbCrLf & "You can also run ensure-monitor.ps1 in PowerShell to inspect the error.", vbCritical, "PSC Executor Monitor"
    WScript.Quit 1
End If
sh.Run """" & exe & """", 1, False
