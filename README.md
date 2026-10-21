[English](./README.en.md)

<!-- codex-github-rules:bilingual-summary -->
> **中文简介**：Windows 上的代理 CLI 工具更新器
>
> **English summary**: A simple updater for agent CLI tools on Windows

---

# Agent CLI Updater

Windows 上用于更新 Agent CLI 工具的简单脚本。

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

首次使用需要注册计划任务，实现每天凌晨 2 点自动更新：

```powershell
.\register-agent-cli-updater-task.ps1
```
