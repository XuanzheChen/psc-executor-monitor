PSC Executor 实时监视器（Windows）
===================================

启动：双击桌面快捷方式（运行 PSC-Monitor-Neon.exe），或双击 start-monitor.vbs。
当前图标为截图指定的深蓝底 + 青绿色霓虹监护仪（中间有心电波形和爱心）。
图标资源：psc-monitor-neon.ico（包含 16/20/24/32/40/48/64/128/256 多种尺寸）。
本轮替换之前的程序和图标备份于 backup-before-neon-20261009-112058。
首次启动显示独立悬浮窗口，默认置顶。
点击最小化（—）：保留在底部任务栏，可从任务栏恢复。
点击关闭（X）：隐藏到系统托盘（右下角通知区域），继续监视。
左键单击托盘图标：立即恢复窗口（双击同样有效）。图标可能藏在 ^ 隐藏图标菜单中。
右击托盘图标：显示窗口 / 立即刷新 / 始终置顶 / 退出监视器。
要真正结束监视器，请使用托盘菜单「退出监视器」。

默认每 30 秒刷新一次，90 秒没有心跳将标记「疑似中断」。
可在 GUI 的「添加项目」选择更多仓库，或修改 monitor-config.json
中的 repositories 列表（文件保存到本目录）。

只读取：
  <仓库>\.agentic-sdlc\developing\<工作流>\runtime\executor-progress.json
  <仓库>\.agentic-sdlc\developing\<工作流>\runtime\executor-progress\<run_id>.jsonl
不调用 Executor，不更改 PSC 工作流、预算或代码仓库。

诊断命令：
 powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "D:\Tools\PSC-Monitor\PSC-Monitor.ps1" -SelfTest

提示：脚本使用 UTF-8 with BOM，兼容 Windows PowerShell 5.1。
