# Agent CLI Updater

在 Windows 上更新 Agent CLI 工具的简单工具。

## 用法

直接运行 PowerShell 脚本：

```powershell
.\update-agent-clis.ps1
```

或使用 CMD：

```cmd
run-update-agent-clis.cmd
```

## 首次使用

首次使用需要注册计划任务，实现定时自动更新（每6小时）：

```powershell
.\register-agent-cli-updater-task.ps1
```
