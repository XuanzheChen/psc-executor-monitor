$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'PSC-Monitor.ps1'
$scriptText = [System.IO.File]::ReadAllText($source)
$match = [regex]::Match($scriptText, '(?s)\$script:ProjectCombo\.Add_DrawItem\(\{(.*?)\r?\n\}\)')
if (-not $match.Success) { throw 'Project ComboBox DrawItem handler not found' }
$drawItem = [scriptblock]::Create($match.Groups[1].Value)

$script:ProjectCombo = New-Object System.Windows.Forms.ComboBox
$script:ProjectCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$script:ProjectCombo.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
[void]$script:ProjectCombo.Items.Add('C:\repo')
$script:ProjectScrollHover = $false
$script:ProjectScrollOffset = 0
$script:ProjectScrollMaxOffset = 0

function Assert-Background([System.Windows.Forms.DrawItemState]$state, [System.Drawing.Color]$expected) {
    $bitmap = New-Object System.Drawing.Bitmap(320, 24)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::Magenta)
        $bounds = New-Object System.Drawing.Rectangle(0, 0, 320, 24)
        $args = [System.Windows.Forms.DrawItemEventArgs]::new(
            $graphics, $script:ProjectCombo.Font, $bounds, 0, $state)
        & $drawItem $script:ProjectCombo $args
        $actual = $bitmap.GetPixel(280, 12)
        if ($actual.ToArgb() -ne $expected.ToArgb()) {
            throw ("Unexpected background for state {0}: expected {1}, actual {2}" -f $state, $expected, $actual)
        }
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

try {
    # The closed ComboBox is often both ComboBoxEdit and Selected: it must not turn blue.
    Assert-Background ([System.Windows.Forms.DrawItemState]::ComboBoxEdit -bor
        [System.Windows.Forms.DrawItemState]::Selected) ([System.Drawing.SystemColors]::Window)
    Assert-Background ([System.Windows.Forms.DrawItemState]::ComboBoxEdit) ([System.Drawing.SystemColors]::Window)
    # Keep native blue selection when the list is open.
    Assert-Background ([System.Windows.Forms.DrawItemState]::Selected) ([System.Drawing.SystemColors]::Highlight)
    Write-Output 'PROJECT_PATH_COLORS_TEST=PASS'
} finally {
    $script:ProjectCombo.Dispose()
}
