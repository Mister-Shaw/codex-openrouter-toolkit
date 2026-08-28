# Codex OpenRouter Toolkit

[简体中文](README.md) | **English**

A community-maintained Windows PowerShell toolkit that switches Codex Desktop between its default mode and OpenRouter mode with two short commands. Current version: `0.1.7`.

> [!IMPORTANT]
> This project is not endorsed by OpenAI or OpenRouter. Codex Desktop, custom model providers, and the model-catalog format may change. Revalidate the toolkit after updating Codex.

## Features

| Command | Description |
| --- | --- |
| `cx` | Removes the toolkit-managed model and OpenRouter settings, then requests that Codex Desktop open in its default mode. |
| `cxor` | Synchronizes the latest Codex-compatible OpenRouter catalog, shows a curated set of Claude and OpenAI models, switches to OpenRouter, and requests a desktop restart. |
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
4. Updates the Codex configuration and asks Windows to restart Codex Desktop.
5. Lets you select a catalog model from the Desktop model selector in a new Codex task.

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

`cx` removes the toolkit-managed `model`, `model_provider`, `model_reasoning_effort`, and `model_catalog_json` keys, together with the managed OpenRouter provider block. Other Codex settings are preserved, and Codex Desktop is requested to reopen.

Rotate the API key:

```powershell
cxor -SetKey
```

The key is stored in the current Windows user's `OPENROUTER_API_KEY` environment variable. The OpenRouter provider's persistent command authentication reads the user-scoped value directly, avoiding stale values inherited by Terminal or Explorer.

## Empty Base Instructions

After each synchronization, `cxor` explicitly sets every model's `base_instructions` and `model_messages.instructions_template` fields to empty strings. This removes catalog-level Codex base prompts. Codex Desktop continues to provide developer context, tool definitions, skills, permissions, and workspace information to the task. Default Codex mode opened by `cx` continues to use the official prompts.

Models vary in their support for the Responses API and tool calling. Clearing these fields may reduce agent reliability for some models. Presence in the selector confirms only that catalog validation succeeded. Actual selector loading and routing remain subject to upstream Codex Desktop compatibility, and a model's self-reported identity is not proof of the route used.

## Updating and Uninstalling

```powershell
git pull --ff-only
pwsh -NoProfile -File .\scripts\Install-CodexOpenRouter.ps1
```

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-CodexOpenRouter.ps1
```

The uninstaller removes the user module, toolkit-managed Codex configuration, OpenRouter catalog, and legacy profile blocks. The OpenRouter key is removed only when the uninstaller is run with `-RemoveApiKey`.

## Troubleshooting

- `cx` or `cxor` cannot be found: install with PowerShell 7.4 or later and confirm that the user module directory is present in `$env:PSModulePath`.
- Catalog synchronization fails: check the key, account balance, network connection, and OpenRouter service status. The last valid catalog is preserved. If no valid fallback is available, the switch stops before the running desktop process is closed.
- Empty `Content` errors, damaged CLI JSON, system-temp PATH alias warnings, or repeated stale-catalog warnings: update to version `0.1.7`. This release forces UTF-8 decoding for Codex CLI stdout and stderr, prioritizes the direct OpenRouter catalog request, and uses an automatically removed short-lived CLI home beside the catalog file.
- Old models remain visible after switching: fully close Codex Desktop, run the appropriate command again, and create a new task.
- A visible model fails when invoked: confirm that the model supports the Responses API and tools required by Codex.

## Data and Security

In OpenRouter mode, conversation requests pass through OpenRouter and may be forwarded to the downstream provider of the selected model. See the [English security policy](SECURITY_EN.md) for API-key handling and local changes.

## Testing

```powershell
pwsh -NoProfile -File .\tests\Run-Tests.ps1
```

The automated test suite does not use a real API key, perform network inference, or restart Codex Desktop.

## References

- [OpenAI Codex: Advanced Configuration](https://developers.openai.com/codex/config-advanced)
- [OpenRouter: Codex CLI Integration](https://openrouter.ai/docs/cookbook/coding-agents/codex-cli)

## License

[MIT](LICENSE). OpenAI, Codex, OpenRouter, and related names belong to their respective owners.
