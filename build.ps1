$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$csc=Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
$asm=[PSObject].Assembly.Location
if(-not (Test-Path $csc)){throw "Windows .NET Framework C# compiler not found"}
$source=Join-Path $root 'PSC-Monitor.Launcher.cs'
$ico=Join-Path $root 'psc-monitor-neon.ico'
$out=Join-Path $root 'PSC-Monitor-Neon.exe'
& $csc /nologo /target:winexe /platform:anycpu /optimize+ "/out:$out" "/win32icon:$ico" "/reference:$asm" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Core.dll "$source"
if($LASTEXITCODE -ne 0){throw "C# compiler failed: $LASTEXITCODE"}
Write-Host "Built $out"
