# 安全政策

**简体中文** | [English](SECURITY_EN.md)

## 支持版本

安全修复只面向当前版本 `0.1.9`。旧版本用户应先更新，再确认问题是否仍然存在。

## API Key

- `cxor -SetKey` 使用隐藏输入设置或轮换 `OPENROUTER_API_KEY`。
- Key 保存为当前 Windows 用户的环境变量。OpenRouter provider 的 command-auth 在每次认证时直接读取该用户级变量，不依赖终端或 Explorer 的环境继承。
- 工具包不会把 Key 正文写入 Codex TOML、模型目录或日志。
- 目录直连只向固定 HTTPS 地址 `https://openrouter.ai/api/v1/models` 发送 Bearer Key，并禁用 HTTP 重定向；CLI 回退使用相同 OpenRouter provider 的短期 command-auth。
- 对话期间，Codex 把 Bearer Key 作为 `Authorization` 请求头交给仅监听 `127.0.0.1` 的缓存感知代理；代理只在内存中转发该请求头到固定 HTTPS 地址 `https://openrouter.ai/api/v1/responses`，禁用重定向，也不会记录请求头或请求正文。后台代理进程的环境变量中会移除 `OPENROUTER_API_KEY`。
- 用户级环境变量适合个人设备上的便捷使用，安全性低于专用凭据保险库。建议使用独立、低额度的 OpenRouter Key，并在账户中设置限额和监控用量。

## 网络与模型

- 每次运行 `cxor` 都会连接 OpenRouter，按当前 Codex CLI 版本尝试同步最新 Codex 专用模型信息，并生成和验证本地模型目录。
- 新目录必须包含官方入口 `~openai/gpt-latest`，缺失时会在发布前拒绝。
- OpenRouter 模式下，对话请求会经过 OpenRouter，并可能发送给所选模型的下游供应商。请按所选供应商的数据政策处理敏感内容。
- 所有 OpenRouter Responses 请求先经过本机缓存感知代理。代理只为缺少顶层 `cache_control` 的 Claude 请求加入 5 分钟 `ephemeral` 缓存提示；其他模型保持请求正文不变并使用上游支持的自动缓存。缓存会让提供商在其数据中心短期保留提示前缀，具体期限、计费与数据政策由模型和上游端点决定。
- 工具包会把目录内每个模型的 `base_instructions` 与 `model_messages.instructions_template` 写为空字符串。Codex Desktop 仍会提供 developer 上下文、工具定义和权限控制；不同模型对 Responses API 和工具调用的支持程度仍有差异。
- 新目录同步或校验失败时不会覆盖最后一个有效目录。存在有效旧目录时会重新校验后复用并显示警告；全部来源均不可用时中止切换，正在运行的 Codex Desktop 不会被关闭。

## 本地修改

安装器把模块写入当前用户的 PowerShell 模块目录，并清理旧版本遗留的 Profile 区块。安装阶段不会写入 Codex 配置。

运行 `cxor` 会写入 `<CODEX_HOME>/openrouter-model-catalog.json` 和 `<CODEX_HOME>/openrouter-cache-proxy.json`，启动一个仅绑定 `127.0.0.1` 随机高位端口的后台 PowerShell 代理，并在 `config.toml` 中加入工具包托管的 OpenRouter 配置。TOML 与代理状态文件会保存一个随机生成的 256 位本地代理令牌；该令牌只用于阻止其他本地进程误用监听端口，不具备 OpenRouter 账户权限。

运行 `cx` 会移除 `model`、`model_provider`、`model_reasoning_effort`、`model_catalog_json` 与 OpenRouter provider，同时保留其他配置；经过身份校验的后台代理与状态文件继续服务已经打开的 OpenRouter 任务。运行 `cx -StopProxy` 或卸载器会停止代理并清理状态文件，卸载器还会清理目录。

工具包不操作 `models_cache.json`，也不创建 `settings.json` 或持续备份。受管文本采用同目录临时文件替换，并在提交前检查并发修改。重要的自定义 Codex 配置仍建议由用户自行备份。

工具包只应在个人 Windows 账户下以常规权限运行。管理员、SYSTEM 或已经控制当前用户会话的程序位于本地信任边界内。

## 报告安全问题

普通问题可提交 GitHub Issue，但请先移除 API Key、用户名、邮箱、私人路径、配置正文、日志和请求内容。

敏感漏洞请使用仓库的 [Private Vulnerability Reporting](https://github.com/Mister-Shaw/codex-openrouter-toolkit/security/advisories/new)。若该入口不可用，可提交一条不含漏洞细节的 Issue，请求维护者提供私密联系渠道。
