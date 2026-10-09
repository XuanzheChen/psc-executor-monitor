# Bootstrap a fresh GitHub checkout without requiring a prebuilt binary.
# This script deliberately leaves existing user configuration untouched.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $root 'PSC-Monitor-Neon.exe'
$config = Join-Path $root 'monitor-config.json'
$template = Join-Path $root 'monitor-config.example.json'
$build = Join-Path $root 'build.ps1'
$log = Join-Path $root 'monitor-setup-error.log'

try {
    foreach ($path in @($template, $build, (Join-Path $root 'PSC-Monitor.Launcher.cs'), (Join-Path $root 'psc-monitor-neon.ico'), (Join-Path $root 'PSC-Monitor.ps1'))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required file is missing: $path"
        }
    }

    $needsBuild = -not (Test-Path -LiteralPath $exe -PathType Leaf)
    if (-not $needsBuild) {
        $binaryTime = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
        # PSC-Monitor.ps1 is loaded on every launch; only compiled host/icon
        # changes require rebuilding the executable.
        foreach ($source in @('PSC-Monitor.Launcher.cs', 'psc-monitor-neon.ico', 'build.ps1')) {
            if ((Get-Item -LiteralPath (Join-Path $root $source)).LastWriteTimeUtc -gt $binaryTime) {
                $needsBuild = $true
                break
            }
        }
    }

    if ($needsBuild) {
        Write-Output 'Building PSC-Monitor-Neon.exe...'
        & $build
        if ($LASTEXITCODE -ne 0) { throw "Compiler returned exit code $LASTEXITCODE" }
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
            throw "Build did not produce $exe"
        }
        $check = Start-Process -FilePath $exe -ArgumentList '--selftest' -WorkingDirectory $root -PassThru -Wait
        if ($check.ExitCode -ne 0) { throw "Compiled monitor self-test failed: $($check.ExitCode)" }
        Write-Output 'Executable built and verified.'
    } else {
        Write-Output 'Existing executable is current.'
    }

    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
        Copy-Item -LiteralPath $template -Destination $config
        Write-Output 'Created monitor-config.json. Add a repository using the GUI.'
    } else {
        Write-Output 'Preserved existing monitor-config.json.'
    }

    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }
    exit 0
} catch {
    $message = $_ | Out-String
    try {
        [System.IO.File]::WriteAllText($log, $message, (New-Object System.Text.UTF8Encoding($true)))
    } catch {}
    [Console]::Error.WriteLine($message)
    exit 1
}
