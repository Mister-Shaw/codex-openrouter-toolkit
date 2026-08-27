# 故障排查

**简体中文** | [English](TROUBLESHOOTING_EN.md)

## `cx` 或 `cxor` 无法识别

```powershell
. $PROFILE
Get-Command cx, cxor
```

如果 Profile 有语法错误，先使用安装输出中的备份恢复。

## 找不到 Codex CLI

确认 Codex Desktop 已安装并启动过一次：

```powershell
Get-CodexCliPath
```

工具包依次检查 `PATH` 中的 `codex.exe` 和当前用户 `LocalAppData` 下的 Codex Desktop 安装目录。

## 无法读取 API Key

重新运行隐藏输入脚本：

```powershell
pwsh -NoProfile -File .\scripts\Set-CodexOpenRouterKey.ps1
. $PROFILE
```

检查状态时只会显示 Key 是否可用，不会输出正文：

```powershell
Get-CodexOpenRouterStatus
```

## 401

重新生成并轮换 Key，确认输入中没有空格。检查 OpenRouter 账户中的 Key 状态。

## 403

查看响应中的模型、地区、账户权限和策略信息，换用已知可访问模型复测。模型出现在目录里，不代表当前账户一定可以调用。

## 可以看到模型，调用仍然失败

依次检查：

1. OpenRouter 账户余额与限额。
2. 模型当前可用性和上游供应商状态。
3. 模型是否兼容 Responses 接口。
4. 模型是否支持当前任务需要的工具、图像或补丁调用。

## 模型列表为空或过旧

```powershell
cxor -ForceRefresh -NoRestart
Get-CodexOpenRouterStatus | Format-List
```

刷新结果会经过 JSON、数量、slug 唯一性、默认模型和提示字段检查。新目录未通过验证时，最后一个有效目录会保留。

## 模型持续自称 Codex CLI

确认提示一致性：

```powershell
Get-CodexOpenRouterStatus | Select-Object LightweightPromptConsistent
Update-OpenRouterModelCatalog
```

如果状态仍为 `False`，检查安装后的 `lightweight-agent-prompt.txt` 是否为空，并运行强制刷新。

## 切换后仍显示旧模型

完全关闭并重新启动 Codex Desktop，然后创建新任务。模型列表和系统提示通常在新任务启动时载入。

## 桌面端未自动重启

配置已经写入时可以手动启动 Codex Desktop。`-NoRestart` 会有意跳过自动重启。

## MCP 启动警告

MCP 警告需要单独检查对应程序和路径。供应商切换通常不会修改 MCP 配置。

## PowerShell 版本错误

安装 PowerShell 7.4 或更高版本，并通过 `pwsh` 运行脚本：

```powershell
$PSVersionTable.PSVersion
```

## 回滚

使用安装器输出的备份目录：

```powershell
pwsh -NoProfile -File .\scripts\Restore-CodexOpenRouterBackup.ps1 `
  -BackupPath '<备份目录>' `
  -Force
```

回滚前保存当前配置变化，并关闭 Codex Desktop。
