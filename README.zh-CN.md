# PSC Executor Monitor（中文说明）

[English](README.md) | 简体中文

[agentic-sdlc-contract-runtime](https://github.com/XuanzheChen/agentic-sdlc-contract-runtime) 的独立 Windows 图形界面（GUI）伴随监视工具。

基于 Windows PowerShell 5.1 WinForms 和一个轻量级 C# 宿主可执行文件实现，提供原生任务栏图标。**完全只读**：不会控制或修改 Supervisor、Executor、重试预算或任何工作流状态。

## 克隆 / 拉取后一键启动

**在 Windows 上，直接双击仓库根目录中的 `start-monitor.vbs`。**

首次启动会自动完成以下步骤：

1. 调用 Windows .NET Framework 内置的 C# 编译器（`build.ps1`）编译生成 `PSC-Monitor-Neon.exe`。该可执行文件为本地构建产物，**不会提交到 Git 仓库**。
2. 如果本地不存在 `monitor-config.json`，则根据 `monitor-config.example.json` 自动创建。个人项目路径仅保存在本地，并被 Git 忽略。
3. 使用蓝绿霓虹图标启动 GUI 监视窗口。

启动后，点击 **添加项目 / Add project**，选择你的 PSC 项目根目录（包含 `.agentic-sdlc` 目录），监视器即可开始读取 Executor 进度文件。无需修改 `CODEX_HOME`。

**超长项目路径展示：** 当项目下拉框处于收起状态时，将鼠标悬停在下拉框上即可平滑横向滚动查看完整路径并自动回滚。打开下拉列表时动画暂停，鼠标移出、切换项目或调整窗口大小时自动重置。该效果仅重绘界面文字，不影响项目选择与磁盘刷新频率。

后续启动会直接复用已编译的可执行文件。如果通过 `git pull` 更新了 C# 启动器、图标或构建脚本，启动时会自动重新编译。PowerShell GUI 脚本的更新会在下次启动时生效；可通过系统托盘右键菜单退出当前监视器后重新启动。

如果初始化或启动失败，启动器会弹出错误提示框。请查看 `monitor-setup-error.log`，或在仓库根目录运行以下命令获取详细诊断信息：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ensure-monitor.ps1
```

**运行环境要求：** Windows 系统，内置 Windows PowerShell 5.1 与 .NET Framework 4.x C# 编译器（`%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe`）。无需安装 Python、Node.js 或其他第三方依赖包。

**可选的手动编译与启动方式：**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
.\PSC-Monitor-Neon.exe
```

## 核心功能与界面行为

- **每秒只读轮询与日志增量追踪**：每秒检查一次 Executor 进度快照以及新追加的操作事件（只读），心跳超时阈值为 90 秒。操作日志面板会保留当前所选 Executor 调用的所有非心跳 JSONL 事件，并按字节增量读取新内容而无需重新加载整个日志；当日志文件切换或被截断时，面板会自动重置。
- **工作流名称提示**：将鼠标悬停在工作流标签上，可通过白色提示框（tooltip）查看完整名称。
- **Effort（推理强度）显示**：模型信息行优先显示当前调用进度快照中的 **Effort**；若快照中未提供，则回退读取所选仓库的 `.agentic-sdlc/runtime.json`（DSH 配置读取 `executor.routing.effort`，扁平 Codex 配置读取 `executor.effort`）。仅当运行时配置中的 adapter 与 model 与当前显示的 Executor 一致时才会采用，否则显示 `--`。需注意：从 `runtime.json` 解析出的 Effort 仅反映**当前配置**，不代表历史调用的实际设置。
- **窗口与系统托盘交互**：监视器为普通非置顶窗口。点击最小化会保留在任务栏；点击关闭会隐藏到系统托盘；左键点击托盘图标可恢复窗口，右键点击可打开托盘菜单（含退出程序）。

## 实时耗时显示

GUI 每 **1 秒**检查一次进度快照，并每 **1 秒**增量追踪当前活跃 Executor 调用的 JSONL 日志。界面展示的已运行时间（elapsed time）、心跳间隔（heartbeat age）与最近事件间隔（last-event age）同样每秒刷新，时间间隔采用 `HH:mm:ss` 格式（小时数向下取整）。任务完成后，运行时间会冻结，并与 PSC 报告的最终 `elapsed_seconds` 数值对齐。

## Registry 索引支持

当 `<repository>\.agentic-sdlc\.psc-index\developing\` 目录存在时，GUI 会直接读取活跃索引文件与 `last.json`，而不会全量扫描所有历史工作流。如果不存在该索引目录，则自动回退至传统的全量工作流扫描方式。

需注意：Registry 中标记为 `active` **并不等同于** Executor 正在运行。监视器会单独校验最新的 Executor 心跳状态。所有展示数据均来自本地 PSC 生成的文件。

## 隐私与仓库规范

本仓库不包含任何本地绝对路径、API 凭据、实时日志或个人本地配置文件。
