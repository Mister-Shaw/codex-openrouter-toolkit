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

工具包只选择当前用户 `LocalAppData\OpenAI\Codex\bin` 下由 Codex Desktop 内置、Authenticode 签名有效且签发主体匹配 OpenAI 的 `codex.exe`。`PATH` 中的同名程序不会被采用。

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

脚本接受带 `sk-or-` 前缀的 OpenRouter Key，并拒绝空格或控制字符。使用默认 `User` 范围设置或轮换后，请关闭并重新打开 PowerShell。已有窗口可能保留旧的 `Process` 值；需要立即更新当前窗口时，可点号加载进程范围脚本：

```powershell
. .\scripts\Set-CodexOpenRouterKey.ps1 -Scope Process
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

## 直接请求 `/api/v1/models` 只看到 `data`

这是 OpenRouter 公开端点当前的响应结构。Codex Desktop 需要顶层 `models` 结构以及额外兼容字段。请使用工具包的刷新命令生成经过认证的 Codex 兼容目录，不要手动把公开响应改名后写入 `model_catalog_json`：

```powershell
cxor -ForceRefresh -NoRestart
```

持久化 provider 的 `env_key` 用于推理。刷新流程创建的隔离 `command` auth 只服务于目录刷新，临时 `CODEX_HOME` 会在流程结束后清理。

升级流程会清理旧版持久化 `[model_providers.openrouter.auth]` 表。若配置使用 inline 或 dotted `auth`，工具包会停止合并；先备份 `config.toml`，再手动移除该认证声明并重新安装。

## 模型列表为空或过旧

```powershell
cxor -ForceRefresh -NoRestart
Get-CodexOpenRouterStatus | Format-List
```

刷新结果会经过 JSON、数量、slug 唯一性、默认模型和提示字段检查。新目录未通过验证时，最后一个有效目录会保留。

每次运行 `cxor` 都会检查目录年龄。有效目录未达到 24 小时时会复用；达到阈值后会刷新。`-ForceRefresh` 会跳过年龄条件。

## 模型持续自称 Codex CLI

确认提示一致性：

```powershell
Get-CodexOpenRouterStatus | Select-Object LightweightPromptConsistent
Update-OpenRouterModelCatalog
```

如果状态仍为 `False`，检查安装后的 `lightweight-agent-prompt.txt` 是否为空，并运行强制刷新。

## 切换后仍显示旧模型

完全关闭并重新启动 Codex Desktop，然后创建新任务。模型列表和系统提示通常在新任务启动时载入。

## 卸载后仍显示 OpenRouter 模型

默认卸载会恢复安装时保存的 OpenAI 配置，并在存在快照时恢复 OpenAI 模型缓存。完全关闭并重新启动 Codex Desktop，再创建新任务。使用 `-KeepCurrentProvider` 卸载会保留当前 provider 配置。

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

回滚前保存当前配置变化，并关闭 Codex Desktop。恢复器会验证旧安装逐文件摘要及当前安装目录的工具包身份。若自动回滚遇到文件锁或权限问题，错误信息会给出保留的事务快照路径，请先复制该目录再处理故障。
