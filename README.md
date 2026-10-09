# PSC Executor Monitor

Independent Windows GUI companion for [agentic-sdlc-contract-runtime](https://github.com/XuanzheChen/agentic-sdlc-contract-runtime).

Uses PowerShell 5.1 WinForms and a small C# host executable for a native taskbar icon. The app **only reads** PSC status and progress data. It does not control the Supervisor, Executor, retry budgets or workflows.

## Build and run

1. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1`.
2. Run `PSC-Monitor-Neon.exe` or double-click `start-monitor.vbs`.
3. Add project root folders in the GUI, or copy `monitor-config.example.json` to `monitor-config.json` and fill `repositories`.

The refresh period defaults to 30 seconds and heartbeat staleness threshold to 90 seconds. Minimize to the taskbar, close to tray, left click the tray icon to restore, and right click it for the menu.

## Registry support

When `<repository>\.agentic-sdlc\.psc-index\developing\` exists, the GUI lists only active index files and `last.json` instead of scanning historical workflows. It reads actual E steps, tool calls and recent JSONL events from the referenced progress path. Without a registry, it falls back to legacy workflow scans.

A registry entry is not proof that an E process is still running. The GUI checks `last_heartbeat_at` separately.

No absolute user paths, API credentials, live logs or local configuration belong in this repository. The default blue/green/neon icon assets are part of the companion UI source.
