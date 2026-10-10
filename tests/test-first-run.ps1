$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ('PSC monitor fresh checkout ' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    foreach ($filename in @(
        'ensure-monitor.ps1', 'build.ps1', 'start-monitor.vbs',
        'PSC-Monitor.Launcher.cs', 'PSC-Monitor.ps1',
        'psc-monitor.ico', 'psc-monitor-neon.ico', 'monitor-config.example.json'
    )) {
        Copy-Item -LiteralPath (Join-Path $repo $filename) -Destination (Join-Path $fixture $filename)
    }
    $exe = Join-Path $fixture 'PSC-Monitor-Neon.exe'
    $config = Join-Path $fixture 'monitor-config.json'
    if ((Test-Path $exe) -or (Test-Path $config)) {
        throw 'Fixture was not a fresh checkout'
    }

    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $fixture 'ensure-monitor.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Fresh checkout bootstrap failed' }
    if (-not (Test-Path $exe) -or -not (Test-Path $config)) { throw 'Bootstrap did not create executable and config' }
    Write-Output 'FRESH_BUILD=PASS'

    $process = Start-Process -FilePath $exe -ArgumentList '--selftest' -PassThru -Wait
    if ($process.ExitCode -ne 0) { throw 'Fresh checkout executable failed selftest' }
    Write-Output 'FRESH_EXE_SELFTEST=PASS'

    $json = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($json.refresh_seconds -ne 1 -or @($json.repositories).Count -ne 0) { throw 'Unexpected initial config' }
    Write-Output 'INITIAL_CONFIG=PASS'

    $exeTime = (Get-Item $exe).LastWriteTimeUtc
    $json.refresh_seconds = 45
    $json | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $config -Encoding UTF8
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $fixture 'ensure-monitor.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Idempotent bootstrap failed' }
    if ((Get-Item $exe).LastWriteTimeUtc -ne $exeTime) { throw 'Existing up-to-date EXE was recompiled' }
    $saved = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($saved.refresh_seconds -ne 45) { throw 'Existing configuration was overwritten' }
    Write-Output 'IDEMPOTENT_CONFIG_PRESERVATION=PASS'

    (Get-Item (Join-Path $fixture 'PSC-Monitor.Launcher.cs')).LastWriteTimeUtc = $exeTime.AddSeconds(5)
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $fixture 'ensure-monitor.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Rebuild after source update failed' }
    if ((Get-Item $exe).LastWriteTimeUtc -le $exeTime) { throw 'EXE was not recompiled after source changed' }
    Write-Output 'AUTO_REBUILD_AFTER_PULL=PASS'
    Write-Output 'FRESH_INSTALL_TEST=PASS'
}
finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
