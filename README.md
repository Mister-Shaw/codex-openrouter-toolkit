# Codex OpenRouter Toolkit

**简体中文** | [English](README_EN.md)

一个面向 Windows 的社区工具，用 PowerShell 短命令切换 Codex Desktop 的默认模式与 OpenRouter 模式。当前版本：`0.1.10`。

> [!IMPORTANT]
> 本项目未经 OpenAI 或 OpenRouter 官方背书。Codex Desktop、自定义模型供应商和模型目录格式仍可能变化；更新 Codex 后请重新验证。

## 功能

| 命令 | 作用 |
| --- | --- |
| `cx` | 移除工具包托管的模型与 OpenRouter 配置，保留代理供已打开任务使用，并请求打开默认 Codex |
| `cx -StopProxy` | 返回默认 Codex，同时立即停止本地代理；已打开的 OpenRouter 任务随后无法继续调用该端口 |
| `cxor` | 同步 OpenRouter 最新 Codex 兼容目录，启动本地缓存感知代理，默认只显示 Claude 与 OpenAI 精选模型，切换到 OpenRouter，并请求重启桌面端 |
| `cxor -SetKey` | 通过隐藏输入设置或轮换当前 Windows 用户的 OpenRouter API Key，然后进入 OpenRouter 模式 |
| `cxor -AllModels` | 临时恢复完整 OpenRouter 模型列表；可与 `-SetKey` 组合 |

`cxor` 每次运行都会按当前 Codex CLI 三段版本号请求固定 HTTPS 地址 `https://openrouter.ai/api/v1/models`，请求包含 `client_version` 与 `originator: Codex Desktop`，禁用 HTTP 重定向，并且不使用 24 小时缓存。直连不可用或校验失败时依次检查 CLI stdout、provider 专用缓存、通用缓存、其他临时模型缓存和上次有效目录。候选目录只有通过结构、模型 ID、重复项、默认入口和提示字段校验后才会写入；复用旧目录时会显示警告，全部来源均不可用时会在修改 Codex 配置或关闭桌面端前中止切换。`-AllModels` 会把选中目录中的全部模型重新标记为可见。

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
3. 默认显示 9 个 Claude / OpenAI 精选入口，并隐藏其余目录条目。
4. 在随机本地环回端口启动缓存感知代理，并完成健康检查。
5. 更新 Codex 配置，并向 Windows 提交桌面端重启请求。
6. 在新的 Codex 任务中，从桌面模型选择器选择目录内模型。

目录必须包含官方入口 `~openai/gpt-latest`，它会作为初始模型；缺少该入口时，本次同步会在发布新目录前中止。精选模式保留完整目录对象，并用 `visibility = "hide"` 隐藏未精选项目，以兼容引用旧 slug 的历史任务。

默认精选模型：

- GPT Latest、GPT-5.6 Sol Pro、GPT-5.6 Sol、GPT-5.6 Terra、GPT-5.3 Codex
- Claude Opus Latest、Claude Opus 5、Claude Sonnet Latest、Claude Sonnet 5

需要完整列表时运行：

```powershell
cxor -AllModels
```

返回默认 Codex 模式：

```powershell
cx
```

`cx` 会从 `config.toml` 移除工具包托管的 `model`、`model_provider`、`model_reasoning_effort`、`model_catalog_json` 与 OpenRouter provider，同时保留其他配置，并请求重新打开 Codex Desktop。代理与状态文件默认保留，使已经打开且仍持有原环回地址的 OpenRouter 任务可以完成。需要立即结束代理时运行 `cx -StopProxy`。

需要轮换 Key 时运行：

```powershell
cxor -SetKey
```

Key 保存为当前 Windows 用户的 `OPENROUTER_API_KEY` 环境变量。OpenRouter provider 的持久 command-auth 会直接读取用户级环境变量，不依赖终端或 Explorer 继承旧环境。

## 空基础指令

`cxor` 每次同步目录后，都会把所有模型的 `base_instructions` 与 `model_messages.instructions_template` 明确写成空字符串。这会清除模型目录层携带的 Codex 基础提示；Codex Desktop 仍会向任务提供 developer 上下文、工具定义、Skills、权限和工作区信息。`cx` 打开的默认 Codex 继续使用官方提示。

不同模型对 Responses API 和工具调用的支持程度不同。清空基础指令可能降低部分模型的 Agent 稳定性；模型出现在选择器中，只代表目录兼容性校验通过。选择器的显示与加载仍受最新版 Codex Desktop 的上游兼容性约束，模型自报身份也不能作为实际路由证据。

## 全模型缓存感知代理

OpenRouter 模式下，Codex 发往 OpenRouter Responses API 的所有请求都会先经过工具包启动的本地环回代理。代理根据模型能力处理请求：

- Claude：模型 ID 为 `anthropic/claude-*` 或 `~anthropic/claude-*`，且请求中缺少 `cache_control` 属性时，代理注入 `{"type":"ephemeral"}`，请求 OpenRouter 按模型条件建立默认 5 分钟提示缓存。
- Claude 请求已经含有 `cache_control` 时，代理完整保留原值；值为 `null` 时也不会覆盖。
- OpenAI、DeepSeek、Grok、Moonshot、Groq、Z.AI、Gemini 等模型保持请求体原样，使用所选模型与下游供应商已有的自动缓存能力。
- 未知、未声明缓存能力或不兼容的模型同样保持原样转发。模型出现在目录中并不表示它支持提示缓存。
- Codex 发出的 `prompt_cache_key` 会原样保留。OpenRouter 可在没有 `session_id` 时把它用作粘性路由键，提高同一会话回到持有热缓存之供应商端点的概率。

本地代理不会建立本地提示内容缓存。每一轮完整请求仍会上传到 OpenRouter；上游命中缓存后复用的是模型已经计算的提示前缀。活动页首轮仍会显示完整输入 token，Claude 建立缓存时还可能产生高于普通输入的缓存写入费用。判断缓存是否生效时，请查看 Responses 用量中的 `usage.input_tokens_details.cached_tokens` 与 `cache_write_tokens`：前者大于 0 表示读取命中，后者大于 0 表示本轮写入缓存。总输入 token 不能单独证明缓存是否命中。

代理状态保存在 `<CODEX_HOME>\openrouter-cache-proxy.json`，默认位置为 `%USERPROFILE%\.codex\openrouter-cache-proxy.json`。状态文件记录进程、环回端口、随机本地访问令牌、启动时间和模块路径，不保存 OpenRouter API Key、提示或响应。电脑重启或代理退出后，OpenRouter provider 的 command-auth 会先校验并按原端口与令牌自愈代理，再读取当前用户的 API Key。`cx` 默认保留代理与状态，`cx -StopProxy` 和卸载器会停止代理并删除状态文件。

代理收到上游非成功状态时会保留 HTTP 状态，并把空白或旧式错误正文转换为 Codex 可读取的 `error` 对象。上游 5xx 会立即使用安全的状态消息完成响应，避免等待异常网关正文。本地转发异常会返回固定阶段码，例如 `send_upstream`、`copy_response_headers` 或 `read_upstream`，同时通过 `x-cxor-error-source` 标明来源。带本地令牌的健康检查会报告请求/失败计数、最近错误来源、固定阶段、上游状态、请求字节数和时间。诊断不包含模型、API Key、本地令牌、提示、响应正文、查询串或异常文本。

## 更新与卸载

```powershell
git pull --ff-only
pwsh -NoProfile -File .\scripts\Install-CodexOpenRouter.ps1
```

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-CodexOpenRouter.ps1
```

卸载器会停止本地代理，并移除代理状态、用户模块、工具包托管的 Codex 配置、OpenRouter 目录和旧 Profile 区块。OpenRouter Key 只有在使用 `-RemoveApiKey` 时才会删除。

## 常见问题

- 找不到 `cx` / `cxor`：确认安装使用 PowerShell 7.4+，并检查用户模块目录是否位于 `$env:PSModulePath`。
- 目录同步失败：检查 Key、余额、网络和 OpenRouter 服务状态。最后有效目录会保留；存在有效旧目录时会重新校验后复用并显示警告。无有效回退来源时，本次切换会在关闭桌面端前中止。
- 遇到 `Content` 为空、CLI JSON 损坏、系统临时目录 PATH alias 警告或持续显示旧目录告警：升级到 `0.1.8`；目录同步修复会固定使用 UTF-8 读取 CLI 输出，优先请求 OpenRouter Codex 专用目录，并在目录文件旁使用自动清理的短期 CLI home。
- 切换后仍显示旧模型：完全关闭 Codex Desktop，重新运行相应命令并创建新任务。
- 模型可见但调用失败：确认该模型支持 Codex 使用的 Responses API 与所需工具。
- 出现 `502 Bad Gateway`：升级到 `0.1.10`，再运行一次 `cxor`。V3 代理会优先按旧地址轮换代理，并把上游 5xx 转换为 Codex 可读取的错误对象；认证健康检查同时提供脱敏的最近失败来源、固定阶段和 HTTP 状态。
- `cached_tokens` 持续为 0：确认连续请求具有相同的长前缀、使用相同模型与稳定的 `prompt_cache_key`，并满足模型的最小可缓存长度和有效期要求。模型或下游不支持缓存时，代理会继续安全转发请求。

## 数据与安全

OpenRouter 模式下，对话请求会先经过仅监听 `127.0.0.1` 的本地代理，再通过固定 HTTPS 地址发送给 OpenRouter，并可能继续转发给所选模型的下游供应商。代理只接受带随机本地访问令牌的请求，只开放健康检查和 `/api/v1/responses`，禁用上游重定向，不向 OpenRouter 转发本地代理令牌，也不记录 API Key、提示或响应。请求体会在内存中解析以决定是否补充 Claude 缓存字段，响应按流式数据转发。API Key 与其他本地修改的说明见 [安全政策](SECURITY.md)。

## 测试

```powershell
pwsh -NoProfile -File .\tests\Run-Tests.ps1
pwsh -NoProfile -File .\tests\Run-ProxyIntegrationTests.ps1
```

自动测试不使用真实 API Key，也不执行联网推理或桌面端重启。代理集成测试使用真实本地环回 HTTP 连接和离线上游替身，验证错误回包、SSE 与脱敏诊断。

## 参考

- [OpenAI Codex：Advanced Configuration](https://developers.openai.com/codex/config-advanced)
- [OpenAI：Prompt Caching](https://developers.openai.com/api/docs/guides/prompt-caching)
- [OpenRouter：Codex CLI Integration](https://openrouter.ai/docs/cookbook/coding-agents/codex-cli)
- [OpenRouter：Prompt Caching](https://openrouter.ai/docs/guides/best-practices/prompt-caching)

## 许可证

[MIT](LICENSE)。OpenAI、Codex、OpenRouter 及相关名称归各自权利人所有。
