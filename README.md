# Codex OpenRouter Toolkit

一个面向 Windows 的社区工具，用 PowerShell 短命令切换 Codex Desktop 的默认模式与 OpenRouter 模式。当前版本：`0.1.3`。

> [!IMPORTANT]
> 本项目未经 OpenAI 或 OpenRouter 官方背书。Codex Desktop、自定义模型供应商和模型目录格式仍可能变化；更新 Codex 后请重新验证。

## 功能

| 命令 | 作用 |
| --- | --- |
| `cx` | 移除工具包托管的模型与 OpenRouter 配置，请求打开默认 Codex |
| `cxor` | 同步 OpenRouter 最新 Codex 兼容目录，将目录内每个模型的基础指令字段清空，切换到 OpenRouter，并请求重启桌面端 |
| `cxor -SetKey` | 通过隐藏输入设置或轮换当前 Windows 用户的 OpenRouter API Key，然后进入 OpenRouter 模式 |

`cxor` 每次运行都会重新同步目录，不使用 24 小时缓存。新目录只有通过结构、模型 ID、重复项和提示字段校验后才会写入；同步失败会保留旧目录、中止本次切换，并让正在运行的 Codex Desktop 保持原状。

## 要求

- Windows 10/11
- PowerShell 7.4 或更高版本
- 已安装最新版 Codex Desktop，并至少启动过一次
- 有效的 OpenRouter API Key
- 网络能够访问 `https://openrouter.ai`

## 安装

```powershell
git clone https://github.com/Mister-Shaw/codex-openrouter-toolkit.git
Set-Location .\codex-openrouter-toolkit
pwsh -NoProfile -File .\scripts\Install-CodexOpenRouter.ps1
cxor -SetKey
```

安装器只把模块安装到当前用户的 PowerShell 模块目录，并清理旧版本遗留的 Profile 区块。它不会写入 Codex 配置、模型缓存、`settings.json` 或持续备份；安装后无需重新加载 `$PROFILE`。

## 使用

进入 OpenRouter 模式：

```powershell
cxor
```

执行顺序固定为：

1. 获取 OpenRouter 最新模型目录，并生成 Codex Desktop 可读取的兼容目录。
2. 将每个模型的 `base_instructions` 与 `model_messages.instructions_template` 写为空字符串。
3. 更新 Codex 配置，并向 Windows 提交桌面端重启请求。
4. 在新的 Codex 任务中，从桌面模型选择器选择目录内模型。

目录必须包含官方入口 `~openai/gpt-latest`，它会作为初始模型；缺少该入口时，本次同步会在发布新目录前中止。完整目录仍会加载到桌面模型选择器。

返回默认 Codex 模式：

```powershell
cx
```

`cx` 会从 `config.toml` 移除工具包托管的 `model`、`model_provider`、`model_reasoning_effort`、`model_catalog_json` 与 OpenRouter provider，同时保留其他配置，然后请求重新打开 Codex Desktop。

需要轮换 Key 时运行：

```powershell
cxor -SetKey
```

Key 保存为当前 Windows 用户的 `OPENROUTER_API_KEY` 环境变量。OpenRouter provider 的持久 command-auth 会直接读取用户级环境变量，不依赖终端或 Explorer 继承旧环境。

## 空基础指令

`cxor` 每次同步目录后，都会把所有模型的 `base_instructions` 与 `model_messages.instructions_template` 明确写成空字符串。这会清除模型目录层携带的 Codex 基础提示；Codex Desktop 仍会向任务提供 developer 上下文、工具定义、Skills、权限和工作区信息。`cx` 打开的默认 Codex 继续使用官方提示。

不同模型对 Responses API 和工具调用的支持程度不同。清空基础指令可能降低部分模型的 Agent 稳定性；模型出现在选择器中，只代表目录兼容性校验通过。选择器的显示与加载仍受最新版 Codex Desktop 的上游兼容性约束，模型自报身份也不能作为实际路由证据。

## 更新与卸载

```powershell
git pull --ff-only
pwsh -NoProfile -File .\scripts\Install-CodexOpenRouter.ps1
```

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-CodexOpenRouter.ps1
```

卸载器会移除用户模块、工具包托管的 Codex 配置、OpenRouter 目录和旧 Profile 区块。OpenRouter Key 只有在使用 `-RemoveApiKey` 时才会删除。

## 常见问题

- 找不到 `cx` / `cxor`：确认安装使用 PowerShell 7.4+，并检查用户模块目录是否位于 `$env:PSModulePath`。
- 目录同步失败：检查 Key、余额、网络和 OpenRouter 服务状态。最后有效目录文件会保留，本次切换会中止，正在运行的桌面端不会被关闭。
- 切换后仍显示旧模型：完全关闭 Codex Desktop，重新运行相应命令并创建新任务。
- 模型可见但调用失败：确认该模型支持 Codex 使用的 Responses API 与所需工具。

## 数据与安全

OpenRouter 模式下，对话请求会经过 OpenRouter，并可能转发给所选模型的下游供应商。API Key 与本地修改的说明见 [安全政策](SECURITY.md)。

## 测试

```powershell
pwsh -NoProfile -File .\tests\Run-Tests.ps1
```

自动测试不使用真实 API Key，也不执行联网推理或桌面端重启。

## 参考

- [OpenAI Codex：Advanced Configuration](https://developers.openai.com/codex/config-advanced)
- [OpenRouter：Codex CLI Integration](https://openrouter.ai/docs/cookbook/coding-agents/codex-cli)

## 许可证

[MIT](LICENSE)。OpenAI、Codex、OpenRouter 及相关名称归各自权利人所有。
