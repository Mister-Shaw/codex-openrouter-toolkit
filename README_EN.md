# Codex OpenRouter Toolkit

[简体中文](README.md) | **English**

A community-maintained Windows PowerShell toolkit that switches Codex Desktop between its default mode and OpenRouter mode with two short commands. Current version: `0.1.8`.

> [!IMPORTANT]
> This project is not endorsed by OpenAI or OpenRouter. Codex Desktop, custom model providers, and the model-catalog format may change. Revalidate the toolkit after updating Codex.

## Features

| Command | Description |
| --- | --- |
| `cx` | Removes the toolkit-managed model and OpenRouter settings, stops the local proxy, and requests that Codex Desktop open in its default mode. |
| `cxor` | Synchronizes the latest Codex-compatible OpenRouter catalog, starts the local cache-aware proxy, shows a curated set of Claude and OpenAI models, switches to OpenRouter, and requests a desktop restart. |
| `cxor -SetKey` | Securely prompts for and stores or rotates the current Windows user's OpenRouter API key, then enters OpenRouter mode. |
| `cxor -AllModels` | Makes every model in the selected validated OpenRouter catalog visible. May be combined with `-SetKey`. |

On every run, `cxor` queries the fixed HTTPS URL `https://openrouter.ai/api/v1/models` with the current Codex CLI three-part version as `client_version` and the `originator: Codex Desktop` header. HTTP redirects are disabled, and no 24-hour cache is used. If the direct response is unavailable or fails validation, the toolkit checks Codex CLI stdout, the provider-specific temporary cache, the generic temporary cache, other temporary model caches, and the last valid catalog. A candidate is published only after its structure, model IDs, duplicate entries, default entry, and prompt fields pass validation. Reusing the last valid catalog produces a warning. If every source fails, the switch stops before the Codex configuration is modified or the running desktop process is closed. `-AllModels` marks every entry in the selected catalog as visible.

## Requirements

- Windows 10 or 11
- PowerShell 7.4 or later
- The latest Codex Desktop, launched at least once
- A valid OpenRouter API key
- Network access to `https://openrouter.ai`

## Installation

```powershell
git clone https://github.com/Mister-Shaw/codex-openrouter-toolkit.git
Set-Location .\codex-openrouter-toolkit
pwsh -NoProfile -File .\scripts\Install-CodexOpenRouter.ps1
cxor -SetKey
```

The installer places the module only in the current user's PowerShell module directory and removes legacy toolkit blocks from the PowerShell profile. Installation does not modify Codex configuration, model caches, or `settings.json`, and it does not create persistent backups. Reloading `$PROFILE` is not required.

## Usage

Enter OpenRouter mode:

```powershell
cxor
```

The command performs these steps:

1. Retrieves the latest OpenRouter model catalog and generates a Codex Desktop-compatible catalog.
2. Sets every model's `base_instructions` and `model_messages.instructions_template` fields to empty strings.
3. Shows nine curated Claude and OpenAI entries by default and hides all other catalog entries.
4. Starts the cache-aware proxy on a random loopback port and verifies its health.
5. Updates the Codex configuration and asks Windows to restart Codex Desktop.
6. Lets you select a catalog model from the Desktop model selector in a new Codex task.

The catalog must contain exactly one `~openai/gpt-latest` entry, which is used as the initial model. Synchronization stops before publishing if that entry is missing. Curated mode retains the complete catalog and sets unselected entries to `visibility = "hide"`, preserving compatibility with existing tasks that reference older slugs.

Default curated models:

- GPT Latest, GPT-5.6 Sol Pro, GPT-5.6 Sol, GPT-5.6 Terra, GPT-5.3 Codex
- Claude Opus Latest, Claude Opus 5, Claude Sonnet Latest, Claude Sonnet 5

Show the complete validated catalog:

```powershell
cxor -AllModels
```

Return to default Codex mode:

```powershell
cx
```

`cx` removes the toolkit-managed `model`, `model_provider`, `model_reasoning_effort`, and `model_catalog_json` keys, together with the managed OpenRouter provider block. Other Codex settings are preserved. It then stops the local cache-aware proxy, removes its state file, and requests that Codex Desktop reopen.

Rotate the API key:

```powershell
cxor -SetKey
```

The key is stored in the current Windows user's `OPENROUTER_API_KEY` environment variable. The OpenRouter provider's persistent command authentication reads the user-scoped value directly, avoiding stale values inherited by Terminal or Explorer.

## Empty Base Instructions

After each synchronization, `cxor` explicitly sets every model's `base_instructions` and `model_messages.instructions_template` fields to empty strings. This removes catalog-level Codex base prompts. Codex Desktop continues to provide developer context, tool definitions, skills, permissions, and workspace information to the task. Default Codex mode opened by `cx` continues to use the official prompts.

Models vary in their support for the Responses API and tool calling. Clearing these fields may reduce agent reliability for some models. Presence in the selector confirms only that catalog validation succeeded. Actual selector loading and routing remain subject to upstream Codex Desktop compatibility, and a model's self-reported identity is not proof of the route used.

## Cache-Aware Proxy for All Models

In OpenRouter mode, every OpenRouter Responses API request from Codex first passes through the toolkit's local loopback proxy. The proxy applies a capability-aware policy:

- Claude: when the model ID is `anthropic/claude-*` or `~anthropic/claude-*` and the request has no `cache_control` property, the proxy injects `{"type":"ephemeral"}` so OpenRouter can establish the default five-minute prompt cache.
- If a Claude request already contains `cache_control`, the value is preserved exactly. This includes an explicit `null` value.
- Requests for OpenAI, DeepSeek, Grok, Moonshot, Groq, Z.AI, Gemini, and similar families are forwarded byte-for-byte in the request body and use any automatic caching supported by the selected model and upstream provider.
- Unknown models and models with undocumented or incompatible caching behavior are also forwarded unchanged. Catalog presence does not imply prompt-cache support.
- Codex's `prompt_cache_key` is preserved. When `session_id` is absent, OpenRouter can use that key for sticky routing, improving the chance that later requests in the same session return to the provider endpoint holding a warm cache.

The local proxy does not maintain a local prompt-content cache. Every turn still uploads the complete request to OpenRouter; an upstream cache hit reuses the model's previously computed prompt prefix. The first request still reports the complete input-token count, and creating a Claude cache can cost more than ordinary input. To verify actual cache activity, inspect `usage.input_tokens_details.cached_tokens` and `cache_write_tokens` in the Responses usage object. A positive `cached_tokens` value indicates a cache read, while a positive `cache_write_tokens` value indicates a write. Total input tokens alone do not establish whether a cache hit occurred.

Proxy state is stored at `<CODEX_HOME>\openrouter-cache-proxy.json`, which defaults to `%USERPROFILE%\.codex\openrouter-cache-proxy.json`. The file contains the process identity, loopback port, random local access token, start time, and module path. It contains no OpenRouter API key, prompt, or response data. If the computer restarts or the proxy exits, the OpenRouter provider's command authentication validates and self-heals the proxy on the configured port with the configured token before reading the current user's API key. Running `cx` stops the proxy and deletes the state file; the uninstaller performs the same cleanup.

## Updating and Uninstalling

```powershell
git pull --ff-only
pwsh -NoProfile -File .\scripts\Install-CodexOpenRouter.ps1
```

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-CodexOpenRouter.ps1
```

The uninstaller stops the local proxy and removes its state, the user module, toolkit-managed Codex configuration, OpenRouter catalog, and legacy profile blocks. The OpenRouter key is removed only when the uninstaller is run with `-RemoveApiKey`.

## Troubleshooting

- `cx` or `cxor` cannot be found: install with PowerShell 7.4 or later and confirm that the user module directory is present in `$env:PSModulePath`.
- Catalog synchronization fails: check the key, account balance, network connection, and OpenRouter service status. The last valid catalog is preserved. If no valid fallback is available, the switch stops before the running desktop process is closed.
- Empty `Content` errors, damaged CLI JSON, system-temp PATH alias warnings, or repeated stale-catalog warnings: update to version `0.1.8`. The catalog fixes force UTF-8 decoding for Codex CLI stdout and stderr, prioritize the direct OpenRouter catalog request, and use an automatically removed short-lived CLI home beside the catalog file.
- Old models remain visible after switching: fully close Codex Desktop, run the appropriate command again, and create a new task.
- A visible model fails when invoked: confirm that the model supports the Responses API and tools required by Codex.
- `cached_tokens` remains zero: confirm that successive requests have the same long prefix, use the same model and a stable `prompt_cache_key`, and satisfy the model's minimum cacheable length and lifetime. The proxy continues to forward requests safely when a model or upstream provider has no caching support.

## Data and Security

In OpenRouter mode, conversation requests first pass through a local proxy bound only to `127.0.0.1`, then go to OpenRouter through a fixed HTTPS endpoint and may continue to the selected model's downstream provider. The proxy accepts only requests carrying its random local access token, exposes only a health check and `/api/v1/responses`, disables upstream redirects, strips its local token before forwarding, and does not log API keys, prompts, or responses. It parses request bodies in memory only to decide whether to add the Claude cache field and streams response bytes back to Codex. See the [English security policy](SECURITY_EN.md) for API-key handling and other local changes.

## Testing

```powershell
pwsh -NoProfile -File .\tests\Run-Tests.ps1
```

The automated test suite does not use a real API key, perform network inference, or restart Codex Desktop.

## References

- [OpenAI Codex: Advanced Configuration](https://developers.openai.com/codex/config-advanced)
- [OpenAI: Prompt Caching](https://developers.openai.com/api/docs/guides/prompt-caching)
- [OpenRouter: Codex CLI Integration](https://openrouter.ai/docs/cookbook/coding-agents/codex-cli)
- [OpenRouter: Prompt Caching](https://openrouter.ai/docs/guides/best-practices/prompt-caching)

## License

[MIT](LICENSE). OpenAI, Codex, OpenRouter, and related names belong to their respective owners.
