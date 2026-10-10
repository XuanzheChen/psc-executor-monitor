$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PscMonitorNative {
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr handle, int message, IntPtr wParam, IntPtr lParam);
}
"@

$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'PSC-Monitor.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw ($errors -join '; ') }
foreach ($name in @('Format-Event','Get-ModelEffort','Reset-EventLog','Update-EventLog')) {
    $fn = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }.GetNewClosure(), $true)
    if (-not $fn) { throw "Missing function: $name" }
    . ([scriptblock]::Create($fn.Extent.Text))
}

function Assert-True([bool]$test, [string]$message) {
    if (-not $test) { throw $message }
}
Assert-True ((Get-ModelEffort ([pscustomobject]@{ model='example'; reasoning_effort='high' })) -eq 'high') 'effort high not shown'
Assert-True ((Get-ModelEffort ([pscustomobject]@{ effort='xhigh' })) -eq 'xhigh') 'effort xhigh not shown'
Assert-True ((Get-ModelEffort ([pscustomobject]@{ model='example' })) -eq '--') 'missing effort must not be guessed'

# Runtime configurations may be nested (DSH routing) or flat (Codex).
$configRepo = Join-Path ([System.IO.Path]::GetTempPath()) ('PSC-monitor-effort-' + [guid]::NewGuid().ToString('N'))
$configDir = Join-Path $configRepo '.agentic-sdlc'
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
$configFile = Join-Path $configDir 'runtime.json'
$runtimeEncoding = New-Object System.Text.UTF8Encoding($false)
function Write-TestRuntime([object]$data) {
    [System.IO.File]::WriteAllText($configFile, ($data | ConvertTo-Json -Depth 8), $runtimeEncoding)
}
try {
    $dshState = [pscustomobject]@{ status='running'; adapter='dsh'; model='deepseek-v4.1-flash' }
    Write-TestRuntime @{ executor=@{ adapter='dsh'; routing=@{ provider='opencode-go'; model='deepseek-v4.1-flash'; effort='high' } } }
    Assert-True ((Get-ModelEffort $dshState $configRepo) -eq 'high') 'DSH routing effort should resolve'
    $dshOverride = [pscustomobject]@{ status='running'; adapter='dsh'; model='deepseek-v4.1-flash'; effort='max' }
    Assert-True ((Get-ModelEffort $dshOverride $configRepo) -eq 'max') 'invocation effort must override runtime config'
    Assert-True ((Get-ModelEffort ([pscustomobject]@{adapter='dsh';model='other-model'}) $configRepo) -eq '--') 'model mismatch must not reuse effort'
    Assert-True ((Get-ModelEffort ([pscustomobject]@{adapter='codex';model='deepseek-v4.1-flash'}) $configRepo) -eq '--') 'adapter mismatch must not reuse effort'

    Write-TestRuntime @{ executor=@{ adapter='codex'; model='gpt-6-astra'; effort='xhigh' } }
    $codexState = [pscustomobject]@{ status='running'; adapter='codex'; model='gpt-6-astra' }
    Assert-True ((Get-ModelEffort $codexState $configRepo) -eq 'xhigh') 'flat Codex effort should resolve'
    Assert-True ((Get-ModelEffort $dshState $configRepo) -eq '--') 'switching runtime config must not leave stale effort'
    [System.IO.File]::WriteAllText($configFile, '{bad json', $runtimeEncoding)
    Assert-True ((Get-ModelEffort $codexState $configRepo) -eq '--') 'malformed runtime must degrade to unknown'
    Remove-Item -LiteralPath $configFile -Force
    Assert-True ((Get-ModelEffort $codexState $configRepo) -eq '--') 'missing runtime must degrade to unknown'
    Write-Output 'RUNTIME_EFFORT_TEST=PASS'
} finally {
    Remove-Item -LiteralPath $configRepo -Recurse -Force -ErrorAction SilentlyContinue
}

$base = Join-Path ([System.IO.Path]::GetTempPath()) ('PSC-monitor-live-' + [guid]::NewGuid().ToString('N'))
$folder = Join-Path $base 'executor-progress'
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$path = Join-Path $folder 'run1.jsonl'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$script:HistoryText = New-Object System.Windows.Forms.TextBox
$script:HistoryText.Multiline = $true
$script:EventLogPath = ''
$script:EventLogPosition = [long]0
$script:EventLogPending = [byte[]]@()
$script:EventLogCreatedUtc = [datetime]::MinValue
$run = [pscustomobject]@{
    File = [pscustomobject]@{ DirectoryName=$base }
    State = [pscustomobject]@{ run_id='run1' }
}
function EventJson([string]$kind,[string]$message) {
    return (@{at='2026-10-10T10:00:00+08:00';kind=$kind;message=$message} | ConvertTo-Json -Compress)
}
try {
    $many = @()
    for($i=1; $i -le 150; $i++) { $many += (EventJson 'tool_call' ('read: operation-' + $i)) }
    $many += (EventJson 'heartbeat' 'heartbeat')
    $many += (EventJson 'tool_call' 'write: 中文路径')
    [System.IO.File]::WriteAllText($path, (($many -join "`n") + "`n"), $utf8)
    Update-EventLog $run
    $text = $script:HistoryText.Text
    Assert-True ($text -match 'operation-1(?:\r|\n)') 'first event missing'
    Assert-True ($text -match 'operation-150') 'last event missing'
    Assert-True ($text -match '中文路径') 'Unicode event missing'
    Assert-True (-not ($text -match '执行器心跳')) 'heartbeat should not clutter operations'
    $original = $script:HistoryText.Text
    Update-EventLog $run
    Assert-True ($script:HistoryText.Text -eq $original) 'duplicate on unchanged file'

    $partial = EventJson 'tool_call' 'edit: split-event'
    [System.IO.File]::AppendAllText($path, $partial.Substring(0,$partial.Length-4), $utf8)
    Update-EventLog $run
    Assert-True ($script:HistoryText.Text -eq $original) 'partial JSON line displayed early'
    [System.IO.File]::AppendAllText($path, ($partial.Substring($partial.Length-4) + "`n"), $utf8)
    Update-EventLog $run
    Assert-True ($script:HistoryText.Text -match 'split-event') 'completed partial event not shown'
    Assert-True (([regex]::Matches($script:HistoryText.Text,'split-event')).Count -eq 1) 'split event duplicated'

    [System.IO.File]::WriteAllText($path, ((EventJson 'tool_call' 'read: rotated-log') + "`n"), $utf8)
    Update-EventLog $run
    Assert-True ($script:HistoryText.Text -match 'rotated-log') 'rotated file not read'
    Assert-True (-not ($script:HistoryText.Text -match 'operation-150')) 'old rotated log retained'
    $run.State.run_id='run2'
    [System.IO.File]::WriteAllText((Join-Path $folder 'run2.jsonl'), ((EventJson 'tool_call' 'read: another-run') + "`n"), $utf8)
    Update-EventLog $run
    Assert-True ($script:HistoryText.Text -match 'another-run') 'new run not shown'
    Assert-True (-not ($script:HistoryText.Text -match 'rotated-log')) 'old invocation remained'
    Write-Output 'LIVE_MONITOR_TEST=PASS'
} finally {
    $script:HistoryText.Dispose()
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
