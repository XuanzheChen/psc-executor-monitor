$ErrorActionPreference="Stop"
$source=Join-Path (Split-Path -Parent $PSScriptRoot) 'PSC-Monitor.ps1'
$text=[IO.File]::ReadAllText($source,[Text.Encoding]::UTF8)
$a=$text.IndexOf("function Get-AgeSeconds")
$b=$text.IndexOf("function Pick-Run", $a)
if($a -lt 0 -or $b -lt 0){throw "GUI function boundaries missing"}
Invoke-Expression $text.Substring($a,$b-$a)
$root=Join-Path $env:TEMP ('psc-gui-index-test-'+[guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $root|Out-Null
    $repo=Join-Path $root 'sample-repo'
    $runtime=Join-Path $repo '.agentic-sdlc'
    $index=Join-Path $runtime '.psc-index\developing'
    $active=Join-Path $index 'active'
    New-Item -ItemType Directory -Force -Path $active|Out-Null
    $project=Join-Path $runtime 'developing\A'
    $progress=Join-Path $project 'runtime\executor-progress.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $progress)|Out-Null
    $time=[DateTimeOffset]::UtcNow.ToString("o")
    @{
        run_id="gui-test";status="running";task="T-001";adapter="dsh";model="test"
        steps=9;tool_calls=12;elapsed_seconds=42;last_heartbeat_at=$time
        last_executor_event_at=$time
    } | ConvertTo-Json | Set-Content -LiteralPath $progress -Encoding UTF8
    @{
        workflow_id="A";project_path=$project;executor_progress_path=$progress
    }|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $active 'A.json') -Encoding UTF8
    $script:Config=[PSCustomObject]@{repositories=@($repo)}
    $results=@(Get-AllRuns)
    if($results.Count -ne 1 -or $results[0].State.steps -ne 9){throw "Active registry hot path failed"}
    Write-Output "REGISTRY_ACTIVE=PASS"
    Remove-Item -LiteralPath (Join-Path $active 'A.json')
    @{
        workflow_id="A";project_path=$project;executor_progress_path=$progress
    }|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $index 'last.json') -Encoding UTF8
    $results=@(Get-AllRuns)
    if($results.Count -ne 1){throw "Recent pointer path failed"}
    Write-Output "REGISTRY_LAST=PASS"
    Remove-Item -LiteralPath $index -Recurse -Force
    $results=@(Get-AllRuns)
    if($results.Count -ne 1){throw "Legacy fallback failed"}
    Write-Output "LEGACY_FALLBACK=PASS"
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
