# Codex OpenRouter Toolkit

一个面向 Windows 的社区工具包，用于在 Codex Desktop 保存的 OpenAI 配置与 OpenRouter 之间快速切换、自动维护 OpenRouter 模型目录，并给 OpenRouter 模型应用轻量 Agent 提示。

工具包保留工具调用、权限边界、审批、补丁、验证和结果真实性规则，同时减少固定身份、固定文风与固定输出格式，让不同模型更充分地展现自身能力和中文写作风格。

> [!IMPORTANT]
> 这是实验性社区项目，没有获得 OpenAI 或 OpenRouter 官方背书。Codex Desktop、自定义模型供应商接口、模型目录格式和 Windows 应用入口都可能随版本变化。安装前请阅读脚本，并保留安装器生成的备份。

## 功能

- `cxor`：准备模型目录、应用轻量提示、切换到 OpenRouter，并可重启 Codex Desktop。
- `cx`：恢复安装时记录的 OpenAI 模型与推理强度。
- 每 24 小时自动检查 OpenRouter 模型目录，也可强制刷新。
- 同时兼容 `model_messages.instructions_template` 与 `base_instructions` 两种目录结构。
- 下载失败时保留最后一个有效目录。
- API Key 通过隐藏输入设置，脚本、TOML、目录和日志均不保存密钥正文。
- 安装、升级、切换、卸载前采用备份或原子写入。
- 支持 `-NoRestart`，便于保留当前桌面任务。
- 提供自包含测试，无需 Pester。

## 适用范围

- Windows 10/11
- PowerShell 7.4 或更高版本
- 已安装并启动过 Codex Desktop
- 有效的 OpenRouter API Key
- 网络能够访问 `https://openrouter.ai`

当前版本基于 Codex Desktop/CLI `0.150.0-alpha.8` 验证。Windows PowerShell 5.1 不在支持范围内。

## 快速安装

先克隆仓库并查看脚本：

```powershell
git clone https://github.com/Mister-Shaw/codex-openrouter-toolkit.git
Set-Location .\codex-openrouter-toolkit
Get-Content .\scripts\Install-CodexOpenRouter.ps1
```

运行安装器：

```powershell
pwsh -NoProfile -File .\scripts\Install-CodexOpenRouter.ps1
```

安装器会完成以下操作：

1. 动态解析当前用户的 PowerShell Profile、`.codex` 目录和 Codex CLI。
2. 把 Profile、Codex 配置、目录和缓存快照留在 `.codex\codex-openrouter-toolkit-backups`。
3. 安装 PowerShell 模块。
4. 在 Profile 中加入一段带明确标记的 `Import-Module`。
5. 合并 OpenRouter provider 配置，同时保留其他 TOML 表。
6. 记录安装前的 OpenAI 模型和推理强度，供 `cx` 恢复。

已有早期版本的 `Codex desktop provider shortcuts` 标记区块会在备份后迁移到模块方案。Profile 的其他内容会保留。

### 自定义默认模型

```powershell
pwsh -NoProfile -File .\scripts\Install-CodexOpenRouter.ps1 `
  -OpenRouterModel 'anthropic/claude-opus-5' `
  -OpenRouterReasoningEffort 'high'
```

默认 OpenRouter 模型必须存在于下载后的目录中。模型下架或改名时，可以重新运行安装器并传入新的模型 ID。

## 设置或轮换 API Key

```powershell
pwsh -NoProfile -File .\scripts\Set-CodexOpenRouterKey.ps1
```

脚本会隐藏输入，并默认把 Key 保存到当前 Windows 用户的环境变量中，同时让当前安装进程立即可用。Key 不会出现在命令历史里。

只让当前 PowerShell 进程使用：

```powershell
. .\scripts\Set-CodexOpenRouterKey.ps1 -Scope Process
```

`Process` 范围需要点号加载到准备运行 `cxor` 的同一个 PowerShell 会话中；关闭窗口后自动失效。

轮换时重新运行同一个脚本。删除 Key 需要显式指定：

```powershell
pwsh -NoProfile -File .\scripts\Set-CodexOpenRouterKey.ps1 -Remove
```

Windows 用户级环境变量属于便捷凭据存储。建议创建专用、低额度 Key，定期轮换，并在 OpenRouter 账户中监控用量。

## 日常使用

安装或更新后，在当前 PowerShell 中重新加载 Profile：

```powershell
. $PROFILE
```

切换到 OpenRouter：

```powershell
cxor
```

切换成功后，进入 Codex Desktop 的新任务，从模型列表中选择目录里的模型。

恢复安装时记录的 OpenAI 配置：

```powershell
cx
```

只更新配置，保留当前桌面进程：

```powershell
cxor -NoRestart
cx -NoRestart
```

强制刷新模型目录：

```powershell
cxor -ForceRefresh
```

查看状态：

```powershell
Get-CodexOpenRouterStatus | Format-List
```

`cxor` 默认会关闭并重新启动 Codex Desktop。请先保存尚未发送的输入；也可以先使用 `-NoRestart`，随后手动重启。

## 轻量 Agent 提示

提示文件位于：

```text
src/CodexOpenRouter/lightweight-agent-prompt.txt
```

安装后位于：

```text
<CODEX_HOME>/codex-openrouter-toolkit/CodexOpenRouter/lightweight-agent-prompt.txt
```

它保留以下规则：

- 遵循用户要求的语言、语气、结构和篇幅。
- 遵循高优先级规则与 `AGENTS.md`。
- 区分只读任务与明确授权的修改任务。
- 严格使用当前可用工具及其参数结构。
- 遵守权限、审批和用户授权范围。
- 破坏性操作、外部写入、付费、凭据变更和范围扩张前请求确认。
- 保护现有文件与无关修改。
- 修改后进行适当验证。
- 以真实工具结果为证据，准确报告成功、失败与限制。

提示文件必须保留有效内容。空字符串可能触发 Codex 客户端的内置提示。修改安装后的提示文件后，运行以下命令把它重新应用到现有目录：

```powershell
Update-OpenRouterModelCatalog
```

轻量提示仅作用于工具包维护的 OpenRouter 目录。`cx` 恢复的 Codex 默认模式继续使用官方提示。

OpenAI Docs 建议删除重复指令、简化工具说明、保留紧凑的授权边界，并使用代表性任务验证变化：[Model guidance](https://developers.openai.com/api/docs/guides/latest-model)。

## 更新

```powershell
git pull --ff-only
pwsh -NoProfile -File .\scripts\Install-CodexOpenRouter.ps1
```

重复安装会更新同一受管 Profile 区块，并创建新的时间戳备份。

## 卸载

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-CodexOpenRouter.ps1
```

默认流程会恢复保存的 OpenAI 模型配置、移除受管 Profile 区块，并把安装文件移动到可恢复目录。OpenRouter Key 会保留。

保留当前供应商配置：

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-CodexOpenRouter.ps1 -KeepCurrentProvider
```

同时移除用户级 Key：

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-CodexOpenRouter.ps1 -RemoveApiKey
```

## 恢复安装前备份

先查看安装器输出的 `BackupPath` 和其中的 `manifest.json`，确认目标后执行：

```powershell
pwsh -NoProfile -File .\scripts\Restore-CodexOpenRouterBackup.ps1 `
  -BackupPath '<备份目录>' `
  -Force
```

恢复操作会覆盖清单列出的 Profile、Codex 配置、目录与缓存。执行前请关闭 Codex Desktop，并保存安装后的重要配置变化。

## 数据流与隐私

- 使用 OpenRouter 模型时，对话内容和模型请求会经过 OpenRouter，并可能传输给所选模型的下游供应商。请阅读各方的数据政策。
- 文件、终端、补丁和审批等本机工具继续由 Codex 客户端执行；具体工具能力取决于 Codex 版本和所选模型。
- OpenRouter 模型出现在列表中，只表示目录可见。Responses 接口、图像、搜索、结构化工具和补丁支持仍需分别验证。
- 本地备份可能继承原 Codex 配置中的敏感内容。备份留在 `.codex` 下，严禁提交到 Git 或发送给他人。
- 仓库不包含 API Key、真实配置、模型目录、缓存、日志、SQLite、安装 ID、原始 Codex 系统提示或个人路径。

## 测试

```powershell
pwsh -NoProfile -File .\tests\Run-Tests.ps1
```

测试覆盖：

- 所有 PowerShell 文件的 AST 解析。
- API Key 与个人路径扫描。
- 新旧目录结构的提示写入、复读和幂等性。
- 重复模型 slug 拒绝。
- OpenRouter provider 表合并与其他 TOML 表保留。
- OpenAI/OpenRouter 顶层配置切换。
- 带空格路径下的安装、重复安装与卸载。
- Profile 既有内容保护与旧版受管区块迁移。

联网目录刷新和桌面端重启保持为人工测试，避免 CI 产生费用或受外部服务波动影响。

## 故障排查

常见问题见 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。

## 许可证

MIT。许可证只覆盖本仓库的原创代码与文档。OpenAI、Codex、OpenRouter 及相关名称归各自权利人所有。

