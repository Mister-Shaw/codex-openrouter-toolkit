# Changelog

## 0.1.2 - 2026-08-27

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
