param(
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:BaseDir = if ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { [AppDomain]::CurrentDomain.BaseDirectory.TrimEnd("\") }
$script:ConfigPath = Join-Path $script:BaseDir "monitor-config.json"
$script:ExitRequested = $false
$script:Config = $null
$script:LastUiError = ""

function Read-Config {
    $defaults = [PSCustomObject]@{
        refresh_seconds = 30
        stale_seconds = 90
        always_on_top = $true
        repositories = @()
    }
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return $defaults }
    try {
        $cfg = Get-Content -LiteralPath $script:ConfigPath -Encoding UTF8 -Raw | ConvertFrom-Json
        $repos = @($cfg.repositories | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ } | Select-Object -Unique)
        $seconds = 30
        if ($cfg.refresh_seconds -ge 5 -and $cfg.refresh_seconds -le 3600) { $seconds = [int]$cfg.refresh_seconds }
        $stale = 90
        if ($cfg.stale_seconds -ge 30 -and $cfg.stale_seconds -le 3600) { $stale = [int]$cfg.stale_seconds }
        return [PSCustomObject]@{
            refresh_seconds = $seconds
            stale_seconds = $stale
            always_on_top = ($cfg.always_on_top -ne $false)
            repositories = $repos
        }
    } catch {
        throw "监视器配置文件解析失败：$($script:ConfigPath)。$($_.Exception.Message)"
    }
}

function Save-Config {
    $json = $script:Config | ConvertTo-Json -Depth 4
    $tmp = Join-Path $script:BaseDir ("monitor-config.json." + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [System.IO.File]::WriteAllText($tmp, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $script:ConfigPath -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-AgeSeconds([object]$timestamp) {
    if (-not $timestamp) { return [double]::PositiveInfinity }
    try {
        $dt = [DateTimeOffset]::Parse([string]$timestamp)
        return [math]::Max(0, ([DateTimeOffset]::UtcNow - $dt.ToUniversalTime()).TotalSeconds)
    } catch { return [double]::PositiveInfinity }
}

function Add-IndexedRun {
    param([System.Collections.ArrayList]$Runs,[string]$Repository,[string]$Workflow,[string]$ProgressPath)
    $s = $null
    $file = $null
    if (Test-Path -LiteralPath $ProgressPath -PathType Leaf) {
        try {
            $file = Get-Item -LiteralPath $ProgressPath -ErrorAction Stop
            $s = Get-Content -LiteralPath $ProgressPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        } catch { return }
    }
    if (-not $s -or -not $s.status -or -not $s.run_id) {
        $s = [PSCustomObject]@{
            status = "not_started"; run_id = ""; task = "--"; retry_kind = "--"
            adapter = "--"; model = "--"; steps = 0; tool_calls = 0
            elapsed_seconds = 0; last_heartbeat_at = $null; last_executor_event_at = $null
        }
        $file = [PSCustomObject]@{ LastWriteTimeUtc = [DateTime]::UtcNow; DirectoryName = (Split-Path -Parent $ProgressPath) }
    }
    $time = $s.last_heartbeat_at
    if (-not $time) { $time = $s.last_executor_event_at }
    if (-not $time) { $time = $s.started_at }
    [void]$Runs.Add([PSCustomObject]@{
        Repository = $Repository
        Workflow = $Workflow
        File = $file
        State = $s
        HeartbeatAge = (Get-AgeSeconds $time)
        EventAge = (Get-AgeSeconds $s.last_executor_event_at)
    })
}

function Get-AllRuns {
    $runs = New-Object System.Collections.ArrayList
    foreach ($repo in @($script:Config.repositories)) {
        $registry = Join-Path ([string]$repo) ".agentic-sdlc\.psc-index\developing"
        $activeIndex = Join-Path $registry "active"
        if (Test-Path -LiteralPath $registry -PathType Container) {
            # Fast path: process active registry records only, not historical workflows.
            if (Test-Path -LiteralPath $activeIndex -PathType Container) {
                foreach ($entry in @(Get-ChildItem -LiteralPath $activeIndex -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
                    try {
                        $record = Get-Content -LiteralPath $entry.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
                        if (-not $record -or -not $record.project_path) { continue }
                        $path = [string]$record.executor_progress_path
                        if (-not $path) { $path = Join-Path ([string]$record.project_path) "runtime\executor-progress.json" }
                        Add-IndexedRun $runs ([string]$repo) ([string]$record.workflow_id) $path
                    } catch { }
                }
            }
            # One pointer to the most recently finished/closed workflow; no scan of all history.
            $lastPath = Join-Path $registry "last.json"
            if (Test-Path -LiteralPath $lastPath -PathType Leaf) {
                try {
                    $record = Get-Content -LiteralPath $lastPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
                    $path = [string]$record.executor_progress_path
                    if (-not $path) { $path = Join-Path ([string]$record.project_path) "runtime\executor-progress.json" }
                    Add-IndexedRun $runs ([string]$repo) ([string]$record.workflow_id) $path
                } catch { }
            }
            continue
        }

        # Legacy fallback for Skill releases without registry support.
        $root = Join-Path ([string]$repo) ".agentic-sdlc\developing"
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($project in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            Add-IndexedRun $runs ([string]$repo) ([string]$project.Name) (Join-Path $project.FullName "runtime\executor-progress.json")
        }
    }
    return @($runs.ToArray())
}

function Pick-Run([object[]]$all, [string]$repoFilter, [int]$staleSeconds) {
    $runs = @($all)
    if ($repoFilter) { $runs = @($runs | Where-Object { $_.Repository -eq $repoFilter }) }
    if ($runs.Count -eq 0) { return [PSCustomObject]@{ Kind="WAITING"; Run=$null; ActiveCount=0; StaleCount=0 } }
    $active = @($runs | Where-Object { $_.State.status -eq "running" -and $_.HeartbeatAge -le $staleSeconds })
    $stale  = @($runs | Where-Object { $_.State.status -eq "running" -and $_.HeartbeatAge -gt $staleSeconds })
    if ($active.Count -gt 0) {
        $selected = $active | Sort-Object { $_.File.LastWriteTimeUtc } -Descending | Select-Object -First 1
        $kind = "RUNNING"
    } elseif ($stale.Count -gt 0) {
        $selected = $stale | Sort-Object { $_.File.LastWriteTimeUtc } -Descending | Select-Object -First 1
        $kind = "STALE"
    } else {
        $selected = $runs | Sort-Object { $_.File.LastWriteTimeUtc } -Descending | Select-Object -First 1
        $kind = "IDLE"
    }
    return [PSCustomObject]@{ Kind=$kind; Run=$selected; ActiveCount=$active.Count; StaleCount=$stale.Count }
}

function Format-Event([object]$e) {
    $kind = [string]$e.kind
    $message = [string]$e.message
    switch ($kind) {
        "step_end" { return "模型步骤已完成" }
        "step_start" { return "模型步骤开始" }
        "finalizing" { return "Executor 生成最终回复" }
        "finished" {
            if ($message -match "scope_violation") { return "Executor 结束：范围校验未通过" }
            if ($message -match "completed") { return "Executor 已完成" }
            if ($message -match "timeout") { return "Executor 已超时" }
            return "Executor 结束：" + $message
        }
        "heartbeat" { return "执行器心跳" }
        "tool_call" {
            if ($message -eq "job_output") { return "读取后台任务输出" }
            if ($message -eq "pwsh") { return "运行 PowerShell 命令" }
            if ($message -match "^([^:]+):\s*(.*)$") {
                $verb = switch ($Matches[1]) {
                    "read" { "读取" }
                    "write" { "写入" }
                    "grep" { "搜索" }
                    "edit" { "编辑" }
                    default { "工具 " + $Matches[1] }
                }
                return $verb + " " + $Matches[2]
            }
            return "工具调用：" + $message
        }
    }
    if ($message -eq "turn_start") { return "模型开始新一轮" }
    if ($message -eq "turn_end") { return "模型本轮结束" }
    return $message
}

function Get-RecentEvents([object]$run) {
    $file = Join-Path $run.File.DirectoryName ("executor-progress\" + [string]$run.State.run_id + ".jsonl")
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return @() }
    try {
        $entries = @(Get-Content -LiteralPath $file -Encoding UTF8 -Tail 100 -ErrorAction Stop | ForEach-Object {
            try { $_ | ConvertFrom-Json } catch { $null }
        } | Where-Object { $_ -and $_.kind -ne "heartbeat" } | Select-Object -Last 6)
        $lines = @()
        foreach ($e in $entries) {
            $time = ""
            try { $time = ([DateTimeOffset]::Parse([string]$e.at)).ToLocalTime().ToString("HH:mm:ss") } catch {}
            $lines += ("[{0}] {1}" -f $time, (Format-Event $e))
        }
        return $lines
    } catch { return @() }
}

function Format-Duration([double]$seconds) {
    if ($seconds -lt 0) { $seconds = 0 }
    $span = [TimeSpan]::FromSeconds($seconds)
    if ($span.Days -gt 0) { return "{0}天 {1:D2}:{2:D2}:{3:D2}" -f $span.Days,$span.Hours,$span.Minutes,$span.Seconds }
    # PowerShell 的 [int] 转换会四舍五入，例如 0.57 小时会变成 1 小时。
    # 因此必须向下取整，否则运行超过 30 分钟时会凭空多显示 1 小时。
    return "{0:D2}:{1:D2}:{2:D2}" -f ([long][math]::Floor($span.TotalHours)),$span.Minutes,$span.Seconds
}

# 仅计算窗口展示数据，不访问磁盘。执行中的计时依据 started_at 实时推算，
# 结束后以 PSC 记录的 monotonic elapsed_seconds 作为最终运行时长。
function Get-DisplayElapsed([object]$state) {
    $recorded = [math]::Max(0, [double]$state.elapsed_seconds)
    if ($state.status -ne "running") { return $recorded }
    try {
        $start = [DateTimeOffset]::Parse([string]$state.started_at)
        $wall = ([DateTimeOffset]::UtcNow - $start.ToUniversalTime()).TotalSeconds
        if ($wall -ge 0) { return [math]::Max($recorded, $wall) }
    } catch {}
    return $recorded
}

function Format-ClockAge([object]$timestamp) {
    $age = Get-AgeSeconds $timestamp
    if ([double]::IsInfinity($age) -or [double]::IsNaN($age)) { return "尚无记录" }
    # HH 可超过 24：例如 28:03:15，不折算为日期。
    $seconds = [long][math]::Floor([math]::Max(0, $age))
    return "{0:D2}:{1:D2}:{2:D2}" -f ([long][math]::Floor($seconds / 3600)),([long][math]::Floor(($seconds % 3600) / 60)),([long]($seconds % 60))
}

# 以下函数每秒调用一次，只使用上次磁盘刷新缓存的状态快照。
function Update-LiveClocks {
    if (-not $script:DisplayedRun) { return }
    $r = $script:DisplayedRun
    $s = $r.State
    $duration = Get-DisplayElapsed $s
    $script:StatsLabel.Text = "步骤：" + $s.steps + "     工具调用：" + $s.tool_calls + "     已运行：" + (Format-Duration $duration)

    if ($s.status -ne "running") {
        $script:HealthLabel.Text = "本次已结束；等待下一次 Executor 调用。"
        return
    }

    $heartbeat = $s.last_heartbeat_at
    $effective = $heartbeat
    if (-not $effective) { $effective = $s.last_executor_event_at }
    if (-not $effective) { $effective = $s.started_at }
    $isStale = (Get-AgeSeconds $effective) -gt [int]$script:Config.stale_seconds
    if ($isStale) {
        $script:StatusLabel.Text = "状态：疑似中断：心跳超时"
        $script:StatusLabel.ForeColor = [System.Drawing.Color]::Firebrick
    } else {
        $script:StatusLabel.Text = "状态：执行中"
        $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(30,130,80)
    }

    $script:HealthLabel.Text = "距上次心跳：" + (Format-ClockAge $heartbeat) +
        "    |    距最近实际事件：" + (Format-ClockAge $s.last_executor_event_at)
    if ($script:DisplayedActiveCount -gt 1) {
        $script:HealthLabel.Text += "    |    同时执行：" + $script:DisplayedActiveCount
    }
    if ($script:DisplayedStaleCount -gt 0 -and -not $isStale) {
        $script:HealthLabel.Text += "    |    其他异常：" + $script:DisplayedStaleCount
    }
}

if ($SelfTest) {
    $base=[PSCustomObject]@{ Repository="X:\a"; Workflow="example"; State=[PSCustomObject]@{ status="completed" }; File=[PSCustomObject]@{ LastWriteTimeUtc=[datetime]::UtcNow }; HeartbeatAge=3.0; EventAge=3.0 }
    $expected = @(
        @("WAITING",@(Pick-Run @() "" 90).Kind),
        @("IDLE",@(Pick-Run @($base) "" 90).Kind)
    )
    $base.State.status="running"
    $expected += ,@("RUNNING",(Pick-Run @($base) "" 90).Kind)
    $base.HeartbeatAge=91
    $expected += ,@("STALE",(Pick-Run @($base) "" 90).Kind)
    $other=[PSCustomObject]@{ Repository="X:\b"; Workflow="other"; State=[PSCustomObject]@{ status="running" }; File=[PSCustomObject]@{ LastWriteTimeUtc=[datetime]::UtcNow }; HeartbeatAge=4.0; EventAge=4.0 }
    $expected += ,@("X:\b",(Pick-Run @($base,$other) "" 90).Run.Repository)
    $expected += ,@("STALE",(Pick-Run @($base,$other) "X:\a" 90).Kind)
    $expected += ,@("RUNNING",(Pick-Run @($base,$other) "X:\b" 90).Kind)
    $fails=0
    foreach ($case in $expected) {
        $ok=($case[0] -eq $case[1])
        Write-Output ("状态测试 {0}: {1}" -f $case[0], $(if($ok){"通过"}else{"失败：" + $case[1]}))
        if(-not $ok){$fails++}
    }
    # 不访问任何真实项目文件，验证每秒计时及结束冻结行为。
    $clockState = [PSCustomObject]@{
        status="running"; elapsed_seconds=17.0
        started_at=([DateTimeOffset]::UtcNow.AddSeconds(-18).ToString("o"))
        last_heartbeat_at=([DateTimeOffset]::UtcNow.AddSeconds(-5).ToString("o"))
        last_executor_event_at=([DateTimeOffset]::UtcNow.AddSeconds(-9).ToString("o"))
        steps=4; tool_calls=6
    }
    $first = Get-DisplayElapsed $clockState
    Start-Sleep -Milliseconds 1150
    $second = Get-DisplayElapsed $clockState
    $clockChecks = [ordered]@{}
    # 边界回归：防止 [int] TotalHours 在 30~59 分钟时错误进位。
    $clockChecks["未满30分钟"] = ((Format-Duration 1799) -eq "00:29:59")
    $clockChecks["30分钟边界"] = ((Format-Duration 1800) -eq "00:30:00")
    $clockChecks["截图34分钟样例"] = ((Format-Duration 2053) -eq "00:34:13")
    $clockChecks["59分59秒"] = ((Format-Duration 3599) -eq "00:59:59")
    $clockChecks["整1小时"] = ((Format-Duration 3600) -eq "01:00:00")
    $clockChecks["1小时30分钟"] = ((Format-Duration 5401) -eq "01:30:01")
    $clockChecks["跨天显示"] = ((Format-Duration 90000) -eq "1天 01:00:00")
    $clockChecks["执行中耗时自然增长"] = (($second - $first) -ge 0.9)
    $clockChecks["心跳HH:mm:ss"] = ((Format-ClockAge $clockState.last_heartbeat_at) -match "^\d{2}:\d{2}:\d{2}$")
    $clockChecks["实际事件HH:mm:ss"] = ((Format-ClockAge $clockState.last_executor_event_at) -match "^\d{2}:\d{2}:\d{2}$")
    $clockChecks["长时计数不回绕"] = ((Format-ClockAge ([DateTimeOffset]::UtcNow.AddHours(-26).ToString("o"))) -match "^26:\d{2}:\d{2}$")
    $script:Config = [PSCustomObject]@{ stale_seconds=90 }
    $script:DisplayedRun = [PSCustomObject]@{ State=$clockState }
    $script:DisplayedActiveCount=1
    $script:DisplayedStaleCount=0
    $script:StatsLabel=New-Object System.Windows.Forms.Label
    $script:StatusLabel=New-Object System.Windows.Forms.Label
    $script:HealthLabel=New-Object System.Windows.Forms.Label
    Update-LiveClocks
    $clockChecks["窗口实时显示"] = ($script:StatsLabel.Text -match "已运行：\d{2}:\d{2}:\d{2}" -and
        $script:HealthLabel.Text -match "距上次心跳：\d{2}:\d{2}:\d{2}" -and
        $script:HealthLabel.Text -match "距最近实际事件：\d{2}:\d{2}:\d{2}")
    $clockState.status="completed"
    $clockState.elapsed_seconds=17.3
    $stopped1=Get-DisplayElapsed $clockState
    Start-Sleep -Milliseconds 1100
    $stopped2=Get-DisplayElapsed $clockState
    Update-LiveClocks
    $clockChecks["结束时停止增长"] = ($stopped1 -eq $stopped2 -and $stopped2 -eq 17.3)
    $clockChecks["结束时显示最终耗时"] = ($script:StatsLabel.Text -match "已运行：00:00:17")
    foreach ($name in $clockChecks.Keys) {
        if($clockChecks[$name]) { Write-Output ("计时测试 {0}：通过" -f $name) }
        else { Write-Output ("计时测试 {0}：失败" -f $name); $fails++ }
    }
    if($fails -gt 0){exit 1}
    exit 0
}

$script:Config = Read-Config
$mutexCreated = $false
$script:Mutex = New-Object System.Threading.Mutex($true, "Local\PSC-Executor-Monitor-2026", [ref]$mutexCreated)
if (-not $mutexCreated) {
    [System.Windows.Forms.MessageBox]::Show("PSC 监视器已经在运行，请查看系统托盘。", "PSC Executor Monitor") | Out-Null
    exit 0
}

$fontName = "Microsoft YaHei UI"
$script:AppIcon = [System.Drawing.Icon]::new((Join-Path $script:BaseDir "psc-monitor.ico"))
$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Icon = $script:AppIcon
$script:Form.ShowIcon = $true
$script:Form.ShowInTaskbar = $true
$script:Form.Text = "PSC Executor 实时监视器"
$script:Form.StartPosition = "CenterScreen"
$script:Form.Size = New-Object System.Drawing.Size(660,550)
$script:Form.MinimumSize = New-Object System.Drawing.Size(640,510)
$script:Form.Font = New-Object System.Drawing.Font($fontName,9)
$script:Form.BackColor = [System.Drawing.Color]::FromArgb(246,248,251)
$script:Form.TopMost = [bool]$script:Config.always_on_top

function Make-Label([string]$text,[int]$x,[int]$y,[int]$w,[int]$h,[int]$size,[bool]$bold) {
    $c = New-Object System.Windows.Forms.Label
    $c.Text = $text
    $c.Location = New-Object System.Drawing.Point($x,$y)
    $c.Size = New-Object System.Drawing.Size($w,$h)
    $style = if($bold){[System.Drawing.FontStyle]::Bold}else{[System.Drawing.FontStyle]::Regular}
    $c.Font = New-Object System.Drawing.Font($fontName,$size,$style)
    $c.ForeColor = [System.Drawing.Color]::FromArgb(35,45,58)
    $c.AutoEllipsis=$true
    $script:Form.Controls.Add($c)
    return $c
}
function Make-Button([string]$text,[int]$x,[int]$y,[int]$w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text=$text
    $b.Location=New-Object System.Drawing.Point($x,$y)
    $b.Size=New-Object System.Drawing.Size($w,30)
    $b.FlatStyle="System"
    $script:Form.Controls.Add($b)
    return $b
}

$script:TitleLabel = Make-Label "PSC Executor 实时监视器" 18 15 490 34 15 $true
$script:StatusLabel = Make-Label "状态：正在加载..." 20 117 570 32 14 $true
$script:WorkflowLabel = Make-Label "工作流：--" 20 156 603 23 10 $false
$script:TaskLabel = Make-Label "任务：--" 20 185 603 23 10 $false
$script:ModelLabel = Make-Label "执行器：--" 20 215 603 22 9 $false
$script:StatsLabel = Make-Label "步骤：--  |  工具调用：--  |  耗时：--" 20 246 603 27 11 $true
$script:HealthLabel = Make-Label "心跳：--" 20 280 603 24 9 $false
$historyLabel = Make-Label "最近操作" 20 314 240 26 11 $true
$script:FooterLabel = Make-Label "每 30 秒刷新 · 仅本地只读" 20 475 606 24 9 $false
$script:FooterLabel.ForeColor = [System.Drawing.Color]::Gray

$script:ProjectCombo = New-Object System.Windows.Forms.ComboBox
$script:ProjectCombo.DropDownStyle="DropDownList"
$script:ProjectCombo.Location=New-Object System.Drawing.Point(20,64)
$script:ProjectCombo.Size=New-Object System.Drawing.Size(370,28)
$script:ProjectCombo.Anchor="Top,Left,Right"
$script:ProjectCombo.DrawMode=[System.Windows.Forms.DrawMode]::OwnerDrawFixed
$script:Form.Controls.Add($script:ProjectCombo)

# WinForms DropDownList 不允许改写 Text；仅对关闭状态的选中项进行滚动绘制。
$script:ProjectScrollHover=$false
$script:ProjectScrollOffset=0
$script:ProjectScrollMaxOffset=0
$script:ProjectScrollDirection=1
$script:ProjectScrollPauseTicks=10
function Reset-ProjectPathScroll {
    $script:ProjectScrollOffset=0
    $script:ProjectScrollDirection=1
    $script:ProjectScrollPauseTicks=10
    $script:ProjectCombo.Invalidate()
}
function Step-ProjectPathMarquee([int]$Offset,[int]$MaxOffset,[int]$Direction,[int]$PauseTicks) {
    $MaxOffset=[math]::Max(0,$MaxOffset)
    $Offset=[math]::Min($MaxOffset,[math]::Max(0,$Offset))
    if($MaxOffset -eq 0){return [pscustomobject]@{Offset=0;Direction=1;PauseTicks=0}}
    if($PauseTicks -gt 0){return [pscustomobject]@{Offset=$Offset;Direction=$Direction;PauseTicks=($PauseTicks-1)}}
    $step=if($Direction -lt 0){-3}else{3}
    $next=[math]::Min($MaxOffset,[math]::Max(0,$Offset+$step))
    if($next -eq $MaxOffset){return [pscustomobject]@{Offset=$next;Direction=-1;PauseTicks=12}}
    if($next -eq 0){return [pscustomobject]@{Offset=0;Direction=1;PauseTicks=12}}
    return [pscustomobject]@{Offset=$next;Direction=$Direction;PauseTicks=0}
}
$script:ProjectCombo.Add_DrawItem({
    param($sender,$e)
    if($e.Index -lt 0){return}
    $value=[string]$script:ProjectCombo.Items[$e.Index]
    $isEdit=($e.State -band [System.Windows.Forms.DrawItemState]::ComboBoxEdit) -ne 0
    $e.DrawBackground()
    $offset=0
    if($isEdit){
        $width=[math]::Ceiling($e.Graphics.MeasureString($value,$script:ProjectCombo.Font,[int]::MaxValue,[System.Drawing.StringFormat]::GenericTypographic).Width)
        $script:ProjectScrollMaxOffset=[math]::Max(0,$width-[math]::Max(1,$e.Bounds.Width-7))
        $script:ProjectScrollOffset=[math]::Min($script:ProjectScrollOffset,$script:ProjectScrollMaxOffset)
        if($script:ProjectScrollHover -and -not $script:ProjectCombo.DroppedDown){$offset=$script:ProjectScrollOffset}
    }
    $foreground=if(($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0){[System.Drawing.SystemColors]::HighlightText}else{[System.Drawing.SystemColors]::WindowText}
    $brush=New-Object System.Drawing.SolidBrush($foreground)
    $saved=$e.Graphics.Save()
    try {
        $e.Graphics.SetClip($e.Bounds)
        $y=$e.Bounds.Top+[math]::Max(0,($e.Bounds.Height-$script:ProjectCombo.Font.Height)/2)
        $e.Graphics.DrawString($value,$script:ProjectCombo.Font,$brush,[single]($e.Bounds.Left+3-$offset),[single]$y,[System.Drawing.StringFormat]::GenericTypographic)
    } finally {
        $e.Graphics.Restore($saved)
        $brush.Dispose()
    }
    $e.DrawFocusRectangle()
})
$script:AddButton = Make-Button "添加项目" 404 62 100
$script:RemoveButton = Make-Button "移除项目" 510 62 110
$script:AddButton.Anchor="Top,Right"
$script:RemoveButton.Anchor="Top,Right"

$script:HistoryText=New-Object System.Windows.Forms.TextBox
$script:HistoryText.Location=New-Object System.Drawing.Point(20,344)
$script:HistoryText.Size=New-Object System.Drawing.Size(600,121)
$script:HistoryText.Multiline=$true
$script:HistoryText.ReadOnly=$true
$script:HistoryText.ScrollBars="Vertical"
$script:HistoryText.Font=New-Object System.Drawing.Font("Consolas",9)
$script:HistoryText.BackColor=[System.Drawing.Color]::White
$script:HistoryText.Anchor="Top,Bottom,Left,Right"
$script:Form.Controls.Add($script:HistoryText)
$script:FooterLabel.Anchor="Bottom,Left"
$script:FooterLabel.Location=New-Object System.Drawing.Point(20,478)

$script:TopCheck=New-Object System.Windows.Forms.CheckBox
$script:TopCheck.Text="始终置顶"
$script:TopCheck.Location=New-Object System.Drawing.Point(508,19)
$script:TopCheck.Size=New-Object System.Drawing.Size(112,27)
$script:TopCheck.Anchor="Top,Right"
$script:TopCheck.Checked=[bool]$script:Config.always_on_top
$script:Form.Controls.Add($script:TopCheck)

$script:Tray=New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon=$script:AppIcon
$script:Tray.Text="PSC Executor 实时监视器"
$script:Tray.Visible=$true
$script:TrayMenu=New-Object System.Windows.Forms.ContextMenuStrip
$script:ShowMenu=$script:TrayMenu.Items.Add("显示监视窗口")
$script:RefreshMenu=$script:TrayMenu.Items.Add("立即刷新")
$script:TopMenu=New-Object System.Windows.Forms.ToolStripMenuItem("始终置顶")
$script:TopMenu.CheckOnClick=$true
$script:TopMenu.Checked=$script:TopCheck.Checked
[void]$script:TrayMenu.Items.Add($script:TopMenu)
[void]$script:TrayMenu.Items.Add("-")
$script:ExitMenu=$script:TrayMenu.Items.Add("退出监视器")
$script:Tray.ContextMenuStrip=$script:TrayMenu

function Sync-Projects {
    $old = ""
    if ($script:ProjectCombo.SelectedIndex -gt 0) { $old=[string]$script:ProjectCombo.SelectedItem }
    $script:ProjectCombo.Items.Clear()
    [void]$script:ProjectCombo.Items.Add("自动选择（所有项目）")
    foreach ($repo in @($script:Config.repositories)) { [void]$script:ProjectCombo.Items.Add([string]$repo) }
    $idx=$script:ProjectCombo.Items.IndexOf($old)
    if($idx -lt 0){$idx=0}
    $script:ProjectCombo.SelectedIndex=$idx
    $script:RemoveButton.Enabled=($idx -gt 0)
}
function Show-Status {
    $filter=""
    if($script:ProjectCombo.SelectedIndex -gt 0){$filter=[string]$script:ProjectCombo.SelectedItem}
    $selection=Pick-Run (Get-AllRuns) $filter ([int]$script:Config.stale_seconds)
    $r=$selection.Run
    $script:DisplayedRun=$r
    $script:DisplayedActiveCount=$selection.ActiveCount
    $script:DisplayedStaleCount=$selection.StaleCount
    $script:HistoryText.Text=""
    if(-not $r){
        $script:StatusLabel.Text="状态：等待首次执行"
        $script:StatusLabel.ForeColor=[System.Drawing.Color]::DarkGoldenrod
        $script:WorkflowLabel.Text="尚无 Executor 进度记录"
        $script:TaskLabel.Text="等待 Supervisor 下一次调用 Executor..."
        $script:ModelLabel.Text="监视项目数：" + @($script:Config.repositories).Count
        $script:StatsLabel.Text="步骤：--  |  工具调用：--  |  耗时：--"
        $script:HealthLabel.Text="可点击【添加项目】配置其他工作目录。"
        $script:Tray.Text="PSC Monitor · 等待执行"
        return
    }
    $s=$r.State
    $color=[System.Drawing.Color]::FromArgb(30,130,80)
    $stateText="执行中"
    if($selection.Kind -eq "IDLE"){
        $stateText="空闲（最近任务：" + [string]$s.status + "）"
        $color=[System.Drawing.Color]::DimGray
    } elseif($selection.Kind -eq "STALE"){
        $stateText="疑似中断：心跳超时"
        $color=[System.Drawing.Color]::Firebrick
    }
    $script:StatusLabel.Text="状态：" + $stateText
    $script:StatusLabel.ForeColor=$color
    $script:WorkflowLabel.Text="项目：" + (Split-Path -Leaf $r.Repository) + "    |    工作流：" + $r.Workflow
    $script:TaskLabel.Text="任务：" + $s.task + "    |    类型：" + $s.retry_kind
    $script:ModelLabel.Text="执行器：" + $s.adapter + "    |    模型：" + $s.model
    # 状态快照通过 30 秒磁盘刷新获取；时钟通过 1 秒 UI Timer 单独刷新。
    Update-LiveClocks
    $lines=@(Get-RecentEvents $r)
    if($lines.Count -eq 0){$script:HistoryText.Text="暂无操作事件"}
    else {$script:HistoryText.Text=$lines -join [Environment]::NewLine}
    $script:Tray.Text="PSC Monitor · " + $stateText
}
function Safe-Refresh {
    try {
        Show-Status
        $script:LastUiError=""
        $script:FooterLabel.Text="每 " + $script:Config.refresh_seconds + " 秒刷新  ·  最后检查：" + (Get-Date -Format "HH:mm:ss") + "  ·  仅本地只读"
    } catch {
        $script:LastUiError=$_.Exception.Message
        $script:StatusLabel.Text="读取异常（稍后自动重试）"
        $script:StatusLabel.ForeColor=[System.Drawing.Color]::Firebrick
        $script:FooterLabel.Text=$script:LastUiError
    }
}
function Restore-Window {
    $script:Form.Show()
    $script:Form.WindowState=[System.Windows.Forms.FormWindowState]::Normal
    $script:Form.ShowInTaskbar=$true
    $script:Form.Activate()
    Safe-Refresh
}
function Hide-Window {
    $script:Form.Hide()
    $script:Form.ShowInTaskbar=$false
}
function Exit-Monitor {
    $script:ExitRequested=$true
    $script:Timer.Stop()
    $script:ClockTimer.Stop()
    $script:ProjectScrollTimer.Stop()
    $script:Tray.Visible=$false
    $script:Tray.Dispose()
    $script:Form.Close()
}

$script:Timer=New-Object System.Windows.Forms.Timer
$script:Timer.Interval=[int]$script:Config.refresh_seconds * 1000
$script:Timer.Add_Tick({ Safe-Refresh })
# 不额外访问磁盘，每秒仅更新缓存快照对应的界面计时。
$script:ClockTimer=New-Object System.Windows.Forms.Timer
$script:ClockTimer.Interval=1000
$script:ClockTimer.Add_Tick({
    try { Update-LiveClocks } catch { $script:LastUiError=$_.Exception.Message }
})
# 悬停时仅做 WinForms 重绘，不读取 PSC 数据；离开、展开和切换项目均复位。
$script:ProjectScrollTimer=New-Object System.Windows.Forms.Timer
$script:ProjectScrollTimer.Interval=40
$script:ProjectScrollTimer.Add_Tick({
    if(-not $script:ProjectScrollHover -or $script:ProjectCombo.DroppedDown){
        $script:ProjectScrollTimer.Stop()
        return
    }
    if($script:ProjectScrollMaxOffset -le 0){return}
    $frame=Step-ProjectPathMarquee $script:ProjectScrollOffset $script:ProjectScrollMaxOffset $script:ProjectScrollDirection $script:ProjectScrollPauseTicks
    $script:ProjectScrollOffset=$frame.Offset
    $script:ProjectScrollDirection=$frame.Direction
    $script:ProjectScrollPauseTicks=$frame.PauseTicks
    $script:ProjectCombo.Invalidate()
})
$script:ProjectCombo.Add_MouseEnter({
    $script:ProjectScrollHover=$true
    Reset-ProjectPathScroll
    if(-not $script:ProjectCombo.DroppedDown){$script:ProjectScrollTimer.Start()}
})
$script:ProjectCombo.Add_MouseLeave({
    $script:ProjectScrollHover=$false
    $script:ProjectScrollTimer.Stop()
    Reset-ProjectPathScroll
})
$script:ProjectCombo.Add_DropDown({
    $script:ProjectScrollTimer.Stop()
    Reset-ProjectPathScroll
})
$script:ProjectCombo.Add_DropDownClosed({
    if($script:ProjectCombo.ClientRectangle.Contains($script:ProjectCombo.PointToClient([System.Windows.Forms.Cursor]::Position))){
        $script:ProjectScrollHover=$true
        Reset-ProjectPathScroll
        $script:ProjectScrollTimer.Start()
    }
})
$script:ProjectCombo.Add_SizeChanged({Reset-ProjectPathScroll})
$script:ProjectCombo.Add_SelectedIndexChanged({
    Reset-ProjectPathScroll
    $script:RemoveButton.Enabled=($script:ProjectCombo.SelectedIndex -gt 0)
    Safe-Refresh
})
$script:AddButton.Add_Click({
    $dialog=New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description="请选择包含 .agentic-sdlc 的项目根目录"
    $dialog.ShowNewFolderButton=$false
    if($dialog.ShowDialog($script:Form) -eq [System.Windows.Forms.DialogResult]::OK){
        $path=[System.IO.Path]::GetFullPath($dialog.SelectedPath).TrimEnd('\')
        if(@($script:Config.repositories) -notcontains $path){
            $script:Config.repositories=@($script:Config.repositories)+@($path)
            Save-Config
            Sync-Projects
            $script:ProjectCombo.SelectedItem=$path
            Safe-Refresh
        } else {
            $script:ProjectCombo.SelectedItem=$path
        }
    }
    $dialog.Dispose()
})
$script:RemoveButton.Add_Click({
    if($script:ProjectCombo.SelectedIndex -le 0){return}
    $path=[string]$script:ProjectCombo.SelectedItem
    $script:Config.repositories=@($script:Config.repositories | Where-Object { $_ -ne $path })
    Save-Config
    Sync-Projects
    Safe-Refresh
})
$script:TopCheck.Add_CheckedChanged({
    $script:Form.TopMost=$script:TopCheck.Checked
    $script:TopMenu.Checked=$script:TopCheck.Checked
    $script:Config.always_on_top=$script:TopCheck.Checked
    Save-Config
})
$script:TopMenu.Add_Click({
    $script:TopCheck.Checked=$script:TopMenu.Checked
})
$script:ShowMenu.Add_Click({ Restore-Window })
$script:RefreshMenu.Add_Click({ Safe-Refresh })
$script:ExitMenu.Add_Click({ Exit-Monitor })
$script:Tray.Add_MouseClick({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Restore-Window }
})
$script:Tray.Add_DoubleClick({ Restore-Window })
# 最小化保留在任务栏；只有关闭窗口时才隐藏到托盘。
$script:Form.Add_FormClosing({
    param($sender,$eventArgs)
    if(-not $script:ExitRequested){
        $eventArgs.Cancel=$true
        Hide-Window
    }
})
$script:Form.Add_Shown({ Sync-Projects; Safe-Refresh; $script:Timer.Start(); $script:ClockTimer.Start() })
try {
    [System.Windows.Forms.Application]::Run($script:Form)
} finally {
    $script:Timer.Dispose()
    $script:ClockTimer.Dispose()
    $script:ProjectScrollTimer.Dispose()
    $script:Tray.Visible=$false
    $script:Tray.Dispose()
    $script:Form.Dispose()
    $script:AppIcon.Dispose()
    if($mutexCreated){$script:Mutex.ReleaseMutex()}
    $script:Mutex.Dispose()
}
