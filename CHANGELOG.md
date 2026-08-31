# Changelog

## 0.1.11 - 2026-08-31

- 优化无自定义缓存策略的 Claude 请求：保留顶层默认 5 分钟 `ephemeral`，并为 `input` 最前方连续系统/开发者消息的首尾可标记消息补充最多两个 `prompt_cache_breakpoint`。保留 `instructions`、工具、角色、文本和顺序；没有可标记系统消息时回退到顶层自动缓存。
- 完整保留已有 `cache_control`（含 `null` 和一小时策略）、`prompt_cache_options` 或块级缓存标记请求的原始正文，非 Claude 请求继续原样转发。
- 保留调用方的 `session_id`、`x-session-id` 和 `prompt_cache_key`；缺少路由标识时，为 Claude 生成基于模型、`instructions`、首条系统消息与工具的 HMAC 路由请求头，使用本地代理令牌作密钥，不保存提示明文。
- 新增 `cxor -CacheStatus`，只读查询本地代理的 Claude 缓存分类累计计数、最近 token 用量、费用和响应完成状态；不调用模型、不刷新目录、不启动或重启代理及桌面端。
- 用量缺失保持 `null`；`system_cache_coverage` 保持 `unknown`，避免把聚合缓存读取量解释为完整系统提示命中。统计仅驻留内存，不保存逐条历史，代理重启后清零。
- 增加有界响应旁路解析，保持原始流转发；解析失败不会触发重试、预热或额外模型调用。代理实现与健康 schema 升级到 V4。
- 增加离线 Claude 缓存回归测试，并同步中英文使用与安全说明。未进行真实付费推理验证；首次写入、缓存过期、前缀/工具变化、供应商切换和最小长度限制均可能影响实际命中，`402` 额度拒绝也不能单独证明缓存失败。

## 0.1.10 - 2026-08-31

- 修复上游 502 已到达本地代理、下游却收到零字节正文并显示 `Unknown error` 的响应提交缺陷。
- 上游 5xx 不再等待可能挂起或提前断开的错误正文；代理会一次性完成带标准 `error` 对象的响应，并保留原 HTTP 状态。
- 错误响应头逐项容错后使用固定小型正文一次性完成，首次提交失败会保留本地阶段诊断。
- 流式响应开始后若读取、写入或刷新失败，代理会中止下游连接，避免把截断的 SSE 标记为正常结束。
- 认证健康检查增加脱敏计数与最近错误来源、固定阶段、上游状态、请求字节数和时间；不包含模型、密钥、令牌、提示、查询串、响应正文或异常文本。
- 代理实现与健康 schema 升级到 V3；升级时优先复用旧环回端口并保留随机本地令牌，端口可用时已打开的任务无需更换代理地址。

## 0.1.9 - 2026-08-28

- 修复本地代理与上游 OpenRouter 错误共用空 502 的问题；错误响应现在使用 Codex 可读取的 OpenAI `error` 对象。
- 上游空白、旧式字符串或非 JSON 错误会转换为带 HTTP 状态码的安全错误对象；已有标准错误对象继续保留。
- 本地代理错误增加 `x-cxor-error-source` 与 `x-cxor-error-code` 脱敏诊断头，并仅报告固定处理阶段，不记录异常原文、密钥、请求体或响应体。
- 代理启动前增加 OpenRouter HTTPS 预检，提前识别受限启动环境中的 TLS 或网络故障。
- 响应头逐项容错，忽略无关的 `Set-Cookie`，并在流式响应开始后避免尝试覆盖已提交响应。
- 代理实现与健康 schema 升级到 V2；`cxor` 会识别并轮换仍在运行的 0.1.8 V1 代理。
- `cx` 默认保留代理以支持已打开的 OpenRouter 任务；需要立即结束代理时可运行 `cx -StopProxy`。

## 0.1.8 - 2026-08-28

- 新增仅监听 `127.0.0.1` 的缓存感知代理，OpenRouter 模式下所有 Responses API 请求都会经过该代理并发送到固定 HTTPS 上游。
- Claude 请求缺少 `cache_control` 时注入默认 5 分钟 `ephemeral` 缓存指令；请求已有该属性时完整保留，包括显式 `null`。
- OpenAI、DeepSeek、Grok、Moonshot、Groq、Z.AI、Gemini、未知模型和缓存行为不兼容的模型保持请求体原样，继续使用各自上游能力。
- 原样保留 Codex 的 `prompt_cache_key`，供 OpenRouter 用于同一会话的供应商粘性路由。
- 增加代理状态、健康检查与 command-auth 自愈；状态文件位于 `<CODEX_HOME>\openrouter-cache-proxy.json`，`cx` 和卸载器会停止代理并删除状态。
- 加固本地代理边界：随机访问令牌、固定时间校验、固定上游、禁用重定向、严格端点与 JSON 检查、有界请求体、响应流式透传，并避免记录密钥和对话内容。
- 文档补充缓存费用与验证方法；首次请求仍报告完整输入 token，Claude 缓存写入可能增加本轮输入费用，实际命中应查看 `cached_tokens` 与 `cache_write_tokens`。

## 0.1.7 - 2026-08-28

- 修复中文 Windows 代码页将 Codex CLI 的 UTF-8 stdout 误解码，导致 `instructions_template` 附近 JSON 转义损坏的问题。
- 根据当前 CLI 三段版本号直接请求 OpenRouter Codex 专用 `/models` 目录，并发送 `originator: Codex Desktop`。
- 直连目录通过完整校验后跳过 CLI 刷新；直连失败时继续使用 CLI、临时缓存和上次有效目录回退。
- 临时 CLI home 改为目录文件旁的私有短期目录，避免系统临时目录触发 PATH alias 告警。
- 增加 UTF-8、请求结构、版本提取和直连优先级回归测试。

## 0.1.6 - 2026-08-28

- 修复 `cxor -AllModels` 在 Codex CLI stdout JSON 损坏且临时缓存缺失时无法使用现有有效目录的问题。
- 全量模式复用旧目录时，将目录内每个模型的 `visibility` 统一写为 `list`。
- 增加全量旧目录回退与 417 项全部可见的回归验证。

## 0.1.5 - 2026-08-28

- 修复 Codex CLI stdout 为空且未生成 `models_cache.json` 时暴露 PowerShell `Content` 参数绑定错误的问题。
- 依次验证 CLI stdout、provider 专用缓存、通用缓存和其他临时模型缓存，首个完整有效的目录才会发布。
- 精选模式下，新目录来源均不可用时会复用上次有效 OpenRouter 目录并给出明确告警。
- 全部来源不可用时输出经过密钥脱敏的聚合诊断，同时保留现有目录与 Codex 配置。
- 增加空来源、缓存回退、旧目录回退、非零 CLI 退出和诊断脱敏测试。

## 0.1.4 - 2026-08-28

- `cxor` 默认只显示 9 个 Claude 与 OpenAI 精选模型，减少桌面模型选择器的视觉拥挤。
- 精选条目使用简短显示名和固定顺序；未精选条目保留在目录中并设为隐藏。
- 新增 `cxor -AllModels`，可恢复上游完整模型列表，并可与 `-SetKey` 组合。
- 增加精选筛选、全量可见性保留、大小写匹配、排序和参数透传测试。

## 0.1.3 - 2026-08-28

- 删除模块内嵌的 1,362 字符轻量 Agent 提示。
- `cxor` 将每个模型的 `base_instructions` 与 `model_messages.instructions_template` 明确写为空字符串。
- 加强目录测试，分别验证两个指令字段存在、值为空并保持幂等。
- 补充说明 Codex Desktop 的 developer 上下文、工具定义、Skills 和权限控制仍会继续注入。

## 0.1.2 - 2026-08-27

- 修复 TOML 字符串编码器重复追加转义字符，导致 Windows 路径生成 `\\\` 并使 `cxor` 同步失败的问题。
- `cx` 通过移除工具包托管的模型键与 OpenRouter provider 打开默认 Codex，不再依赖安装时快照。
- `cxor` 每次启动 OpenRouter 模式前都会同步并校验最新 Codex 兼容模型目录，不再使用 24 小时缓存。
- OpenRouter 初始模型固定使用官方入口 `~openai/gpt-latest`；目录缺失该项时拒绝发布，桌面选择器继续加载完整目录。
- 轻量系统提示改为模块内嵌；`cxor` 同步后统一改写目录内每个模型，再让桌面模型选择器加载目录。
- 新增 `cxor -SetKey`，通过隐藏输入设置或轮换 Windows 用户级 OpenRouter API Key。
- 目录同步失败时保留旧目录文件并中止本次切换，Codex Desktop 会保持运行。
- 安装器只安装用户级 PowerShell 模块并清理旧 Profile 区块；运行时不操作模型缓存、`settings.json` 或持续备份。
- 重写中文文档，移除重复的英文和独立故障排查副本。

## 0.1.1 - 2026-08-27

- 改用经过认证的 Codex CLI 兼容目录刷新流程，并区分目录刷新与推理认证。
- 加固 TOML 合并、目录校验、敏感值检查、进程发现和 Profile 区块迁移。
- 为安装、切换、恢复和卸载增加有界文件处理、跨进程锁、备份与事务回滚。
- 加强 Windows 私有目录权限、恢复清单校验及并发修改保护。
- 修复空文件、异常目录结构、缓存恢复、PowerShell 7.4 ACL 和桌面端已关闭等边界问题。
- CI 增加 PowerShell 7.4/当前稳定版矩阵；联网 smoke test 保持手动执行。

## 0.1.0 - 2026-08-27

- 提供 `cx` / `cxor` Codex Desktop 供应商切换。
- 动态发现 PowerShell Profile、Codex Home 和 Codex CLI。
- 自动刷新和验证 OpenRouter 模型目录。
- 支持新旧两种 Agent 提示字段。
- 提供 1,362 字符轻量 Agent 提示。
- 提供隐藏输入的 API Key 设置与轮换。
- 提供安装、备份、卸载、恢复、状态和测试流程。
- 加入远端目录大小、重定向、slug 和重复项检查。
