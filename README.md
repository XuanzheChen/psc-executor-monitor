# PSC Executor Monitor

Independent Windows GUI companion for [agentic-sdlc-contract-runtime](https://github.com/XuanzheChen/agentic-sdlc-contract-runtime).

Uses Windows PowerShell 5.1 WinForms and a small C# host executable for a native taskbar icon. **Read-only**: it does not control the Supervisor, Executor, retry budgets or workflow state.

## One-click start after GitHub clone / pull

**On Windows, double-click start-monitor.vbs in the repository folder.**

The first launch automatically:

1. Compiles PSC-Monitor-Neon.exe with Windows .NET Framework's C# compiler (build.ps1). The executable is intentionally **not checked into Git**.
2. Creates your private monitor-config.json from monitor-config.example.json if it does not exist. Personal project paths remain local and are ignored by Git.
3. Launches the GUI with the blue-green neon icon.

Click **添加项目 / Add project**, select your repository root (containing .agentic-sdlc), and the monitor can begin reading Executor progress files. You do not need to change CODEX_HOME.

**Long project paths:** Hover over the closed project dropdown to smoothly scroll the selected full path to its end and back. The animation pauses when the list opens, and resets on mouse exit, project change, or window resizing. This only redraws UI text: project selection and disk refresh frequency remain unchanged.

Later launches reuse the compiled executable. If a Git pull updates the C# launcher, icon or build script, it recompiles automatically. Changes to the PowerShell GUI are loaded on the next start; exit the current monitor through its tray menu to restart.

If setup fails, the launcher displays an error dialog. Check monitor-setup-error.log, or run this in the cloned folder for detailed diagnostics:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ensure-monitor.ps1

Requirements: Windows with Windows PowerShell 5.1 and .NET Framework 4.x C# compiler (%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe). No Python, Node.js or package installation is required.

Optional manual build:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
    .\PSC-Monitor-Neon.exe

Executor progress snapshots and newly appended operation events are checked **every second** (read-only), with a 90-second heartbeat staleness threshold. The operation pane preserves all non-heartbeat JSONL events for the currently selected Executor invocation; newly appended bytes are read incrementally without reloading the full log. A changed or truncated log resets the pane. Hover over the workflow label to see its complete name in a white tooltip. The model row includes Effort from the progress snapshot when available, otherwise `--` (older PSC writers do not emit it). The monitor is a normal, non-topmost window. Minimize to taskbar, close to tray, left click tray icon to restore, right click for menu.

## 实机使用（中文）

在 Windows 上下载或克隆仓库后，**双击 start-monitor.vbs**。首次运行自动生成 EXE 和本地配置文件；在 GUI 中点击「添加项目」选择你的 PSC 项目根目录。配置不会上传至 GitHub。

如果提示启动失败，可在仓库根目录运行以下命令查看原因，并检查 monitor-setup-error.log：

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ensure-monitor.ps1

## Live elapsed-time display

The GUI checks progress snapshots every **1 second**, and incrementally follows the active Executor invocation's JSONL log every **1 second**. The displayed elapsed time, heartbeat age and last-event age also update every second. Intervals use HH:mm:ss with correct hour flooring. On completion, elapsed time freezes and reconciles to the final elapsed_seconds value reported by PSC.

## Registry support

When <repository>\.agentic-sdlc\.psc-index\developing\ exists, the GUI reads active index files and last.json rather than scanning all historical workflows. Without a registry, it uses a legacy workflow scan.

Registry "active" does **not** prove Executor is running. The monitor separately checks the latest Executor heartbeat. All data is read from local PSC-generated files.

No absolute user paths, API credentials, live logs or local configuration belong in this repository.
