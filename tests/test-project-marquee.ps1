$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'PSC-Monitor.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw ("Monitor script parse failed: " + ($errors -join '; ')) }
$fn = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Step-ProjectPathMarquee'
}, $true)
if (-not $fn) { throw 'Missing marquee step function' }
. ([scriptblock]::Create($fn.Extent.Text))

function Assert-State($actual, $offset, $direction, $pause) {
    if ($actual.Offset -ne $offset -or $actual.Direction -ne $direction -or $actual.PauseTicks -ne $pause) {
        throw "Unexpected marquee state: $($actual | ConvertTo-Json -Compress)"
    }
}

Assert-State (Step-ProjectPathMarquee 8 0 -1 5) 0 1 0
Assert-State (Step-ProjectPathMarquee 8 20 1 3) 8 1 2
Assert-State (Step-ProjectPathMarquee 19 20 1 0) 20 -1 12
Assert-State (Step-ProjectPathMarquee 1 20 -1 0) 0 1 12
Assert-State (Step-ProjectPathMarquee 100 20 -1 0) 17 -1 0

$frame = [pscustomobject]@{Offset=0;Direction=1;PauseTicks=10}
$right = $false
$left = $false
for ($i = 0; $i -lt 150; $i++) {
    $frame = Step-ProjectPathMarquee $frame.Offset 101 $frame.Direction $frame.PauseTicks
    if ($frame.Offset -lt 0 -or $frame.Offset -gt 101) { throw 'Marquee scrolled outside bounds' }
    if ($frame.Offset -eq 101 -and $frame.Direction -eq -1) { $right = $true }
    if ($right -and $frame.Offset -eq 0 -and $frame.Direction -eq 1) { $left = $true; break }
}
if (-not ($right -and $left)) { throw 'Marquee did not visit both ends and return' }
Write-Output 'PROJECT_PATH_MARQUEE_TEST=PASS'
