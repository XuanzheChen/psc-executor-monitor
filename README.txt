PSC Executor 实时监视器 — Windows 使用说明
=============================================

全新 GitHub clone / pull 后：
  1. 双击仓库目录中的 start-monitor.vbs。
  2. 首次运行会自动编译 PSC-Monitor-Neon.exe，并创建 monitor-config.json。
  3. 在窗口顶部点“添加项目”，选择包含 .agentic-sdlc 的项目根目录。
  4. 以后运行直接双击 start-monitor.vbs；必要时自动重新编译。

说明：
- EXE 是构建产物，不上传 GitHub；这是正常现象。
- monitor-config.json 保存用户的本地项目路径，也不上传 GitHub。
- 编译仅依赖 Windows PowerShell 5.1 和 .NET Framework 4.x 的 csc.exe。
- 如果启动失败，检查 monitor-setup-error.log 或手动执行：
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ensure-monitor.ps1

使用：
- 每 30 秒从 PSC 文件读取一次状态；运行时间、心跳间隔和最近事件间隔每秒刷新。
- 最小化（—）保留在任务栏；关闭（×）隐藏到系统托盘。
- 左键点击托盘图标恢复；右键菜单可以退出程序。
- 点击“添加项目”支持管理多个 PSC 项目。
- 数据只读；不修改 Executor、Supervisor、PSC 工作流或重试预算。

开发与测试：
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-first-run.ps1

远程源码：https://github.com/XuanzheChen/psc-executor-monitor
