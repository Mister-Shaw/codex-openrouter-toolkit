# Codex OpenRouter Toolkit

[简体中文](README.md) | **English**

A community toolkit for Windows that switches Codex Desktop between its saved OpenAI configuration and OpenRouter, keeps the OpenRouter model catalog up to date, and applies lightweight agent instructions to OpenRouter models.

The toolkit retains tool use, permission boundaries, approvals, patching, verification, and truthful reporting rules. It reduces fixed identity, writing style, and output-format constraints so each model can express more of its native capabilities and writing style.

> [!IMPORTANT]
> This is an experimental community project with no official endorsement from OpenAI or OpenRouter. Codex Desktop, custom model-provider interfaces, model-catalog formats, and Windows application entry points may change. Review the scripts before installation and keep the backups created by the installer.

## Features

- `cxor`: prepares the model catalog, applies the lightweight instructions, switches to OpenRouter, and can restart Codex Desktop.
- `cx`: restores the OpenAI model and reasoning effort captured during installation.
- Checks the OpenRouter model catalog age every time `cxor` runs, refreshes it after 24 hours, and supports a forced refresh at any time.
- Supports both `model_messages.instructions_template` and `base_instructions` catalog structures.
- Keeps the last valid catalog when a download or validation fails.
- Accepts API keys through hidden input and never stores their value in scripts, TOML, catalogs, or logs.
- Creates timestamped backups during installation and upgrades, and replaces managed text configuration through temporary files.
- Supports `-NoRestart` to keep the current desktop task open.
- Includes self-contained tests with no Pester dependency.

## Requirements

- Windows 10 or Windows 11
- PowerShell 7.4 or later
- Codex Desktop installed and launched at least once
- A valid OpenRouter API key
- Network access to `https://openrouter.ai`

Toolkit `0.1.1` was validated with Codex Desktop/CLI `0.150.0-alpha.8`. Windows PowerShell 5.1 is outside the supported range.

## Quick installation

Clone the repository and review the installer:

```powershell
git clone https://github.com/Mister-Shaw/codex-openrouter-toolkit.git
Set-Location .\codex-openrouter-toolkit
Get-Content .\scripts\Install-CodexOpenRouter.ps1
```

Run the installer:

```powershell
pwsh -NoProfile -File .\scripts\Install-CodexOpenRouter.ps1
```

The installer performs the following operations:

1. Resolves the current user's PowerShell profile and `.codex` directory dynamically; catalog refresh accepts only the signed CLI bundled with Codex Desktop.
2. Saves snapshots of the profile, Codex configuration, catalog, and caches under `<CODEX_HOME>\codex-openrouter-toolkit-backups`.
3. Installs the PowerShell module.
4. Adds one clearly marked `Import-Module` block to the PowerShell profile.
5. Merges the OpenRouter provider configuration while preserving non-conflicting custom fields and unrelated TOML tables.
6. Records the pre-installation OpenAI model and reasoning effort so `cx` can restore them.

An older managed block marked `Codex desktop provider shortcuts` is migrated after backup. All other profile content remains in place.

### Choose a different default model

```powershell
pwsh -NoProfile -File .\scripts\Install-CodexOpenRouter.ps1 `
  -OpenRouterModel 'anthropic/claude-opus-5' `
  -OpenRouterReasoningEffort 'high'
```

The default OpenRouter model must exist in the downloaded catalog. If a model is removed or renamed, run the installer again with a current model ID.

### Catalog format and authentication roles

OpenRouter's public `GET /api/v1/models` endpoint currently returns a top-level `data` array. Codex Desktop expects a catalog with a top-level `models` structure and additional compatibility fields. The toolkit makes an authenticated request to the fixed catalog endpoint; when it detects the `data` shape, it immediately switches to a trusted Codex CLI compatibility refresh and validates the resulting Codex-readable catalog. The public response is never written directly to `model_catalog_json`.

The persistent OpenRouter provider configuration uses `env_key = "OPENROUTER_API_KEY"` for inference requests. Catalog refresh creates isolated `command` authentication inside a temporary `CODEX_HOME`; that authentication is available only to the catalog-refresh process, and the temporary directory is removed after the refresh. During upgrade, a legacy persistent `[model_providers.openrouter.auth]` table is removed and migrated to `env_key`. Inline or dotted `auth` declarations fail closed and must be reviewed manually.

## Set or rotate the API key

```powershell
pwsh -NoProfile -File .\scripts\Set-CodexOpenRouterKey.ps1
```

The script accepts OpenRouter keys with the `sk-or-` prefix, hides input, and saves the key to the current Windows user's environment variables by default. It also makes the key available to the installation process. The key value stays out of command history.

To use the key only in the current PowerShell process:

```powershell
. .\scripts\Set-CodexOpenRouterKey.ps1 -Scope Process
```

The `Process` scope must be dot-sourced in the same PowerShell session that will run `cxor`. Closing that window removes the process-scoped value.

Run the same script again to rotate the key. After rotating the default `User`-scoped value, close and reopen PowerShell before running `cxor`; an existing window may still hold an older `Process`-scoped value. To update the current window immediately, use the dot-sourced `-Scope Process` command above.

Removal requires an explicit option:

```powershell
pwsh -NoProfile -File .\scripts\Set-CodexOpenRouterKey.ps1 -Remove
```

This command removes the Windows user-scoped key. Close every existing PowerShell window and Codex Desktop before reopening them because those processes may still retain an inherited value. To remove the process-scoped key from the current PowerShell session immediately, use:

```powershell
. .\scripts\Set-CodexOpenRouterKey.ps1 -Scope Process -Remove
```

A Windows user-level environment variable is convenient credential storage. Use a dedicated low-limit key, rotate it regularly, and monitor usage in your OpenRouter account.

## Daily use

Reload the PowerShell profile in the current session after installation or an update:

```powershell
. $PROFILE
```

Switch to OpenRouter:

```powershell
cxor
```

Every `cxor` invocation checks whether the catalog exists, passes validation, and remains within the age limit. A valid catalog younger than 24 hours is reused. A stale or invalid catalog, or `-ForceRefresh`, starts a refresh.

After the switch, create a new task in Codex Desktop and choose a model from the refreshed model list.

Restore the OpenAI model and reasoning effort captured during installation:

```powershell
cx
```

Update the configuration while leaving Codex Desktop running:

```powershell
cxor -NoRestart
cx -NoRestart
```

Force a model-catalog refresh:

```powershell
cxor -ForceRefresh
```

Inspect the current status:

```powershell
Get-CodexOpenRouterStatus | Format-List
```

By default, `cxor` closes and relaunches Codex Desktop. Save any unsent input first. You can also use `-NoRestart` and restart the app manually.

## Lightweight agent instructions

The source instructions are located at:

```text
src/CodexOpenRouter/lightweight-agent-prompt.txt
```

After installation, the file is located at:

```text
<CODEX_HOME>/codex-openrouter-toolkit/CodexOpenRouter/lightweight-agent-prompt.txt
```

The instructions preserve these rules:

- Follow the user's requested language, tone, structure, and length.
- Follow higher-priority rules and `AGENTS.md`.
- Distinguish read-only tasks from explicitly authorized modification tasks.
- Use only currently available tools and their declared parameter schemas.
- Respect permissions, approvals, and the scope authorized by the user.
- Request confirmation before destructive actions, external writes, purchases, credential changes, or scope expansion.
- Preserve existing files and unrelated changes.
- Perform proportionate verification after modifications.
- Treat actual tool results as evidence and report success, failure, and limitations accurately.

The instruction file must contain valid text. An empty string may cause the Codex client to apply built-in instructions. After editing the installed file, apply it to the current catalog with:

```powershell
Update-OpenRouterModelCatalog
```

The lightweight instructions apply only to the OpenRouter catalog managed by this toolkit. The Codex default mode restored by `cx` continues to use the official instructions.

OpenAI Docs recommends removing duplicated guidance, keeping tool instructions concise, retaining compact authorization boundaries, and validating changes with representative tasks: [Model guidance](https://developers.openai.com/api/docs/guides/latest-model).

Instruction and tool-following behavior can vary across OpenRouter models. Validate each model with representative tasks before relying on it.

## Updating

```powershell
git pull --ff-only
pwsh -NoProfile -File .\scripts\Install-CodexOpenRouter.ps1
```

Running the installer again updates the same managed profile block and creates another timestamped backup.

If the initial installation used a custom `-ProfilePath`, pass that same path explicitly during every update. The upgrade validates it so a modified settings file cannot redirect the managed block into another script.

## Uninstalling

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-CodexOpenRouter.ps1
```

The default removal process restores the saved OpenAI model, reasoning effort, and any available OpenAI model cache; removes the managed profile block; and moves installed files into a recoverable directory. The OpenRouter key remains available.

An installation that used a custom profile must pass the same path during removal:

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-CodexOpenRouter.ps1 `
  -ProfilePath 'D:\PowerShell\Microsoft.PowerShell_profile.ps1'
```

Keep the currently selected provider configuration:

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-CodexOpenRouter.ps1 -KeepCurrentProvider
```

Remove the user-scoped key as well:

```powershell
pwsh -NoProfile -File .\scripts\Uninstall-CodexOpenRouter.ps1 -RemoveApiKey
```

The uninstaller removes the Windows user-scoped key. After removal, close existing PowerShell sessions and Codex Desktop, or dot-source the `-Scope Process -Remove` command above in the current PowerShell session, to clear any inherited process-scoped value.

## Restoring a pre-installation backup

Review the `BackupPath` printed by the installer and its `manifest.json`, then run:

```powershell
pwsh -NoProfile -File .\scripts\Restore-CodexOpenRouterBackup.ps1 `
  -BackupPath '<backup-directory>' `
  -Force
```

For a backup created with a custom Codex home or profile, also pass the original `-CodexHome` and `-ProfilePath`. The restore script accepts only a direct child of the fixed backup root and validates all five managed files, a per-file inventory of the previous installation, toolkit ownership, installation state, and target paths. Mutable state is checked again under the same cross-process lock; an incomplete rollback preserves its transaction snapshot and reports the recovery path.

Restoration overwrites the profile, Codex configuration, catalog, and caches listed in the manifest. Close Codex Desktop first and preserve any important configuration changes made after installation.

## Data flow and privacy

- When an OpenRouter model is active, conversation content and model requests pass through OpenRouter and may be sent to the selected model's downstream provider. Review the relevant data policies.
- The persistent provider's `env_key` handles inference authentication. Isolated temporary `command` authentication is used only to obtain the Codex-compatible model catalog.
- Local tools for files, terminals, patches, and approvals continue to run through the Codex client. Exact tool capabilities depend on the Codex version and selected model.
- A model appearing in the list confirms catalog visibility. Responses API, image, search, structured tool, and patch support still require individual verification.
- Local backups may inherit sensitive data from an existing Codex configuration. Keep backups under `.codex`; never commit or share them.
- The repository contains no API keys, real configurations, model catalogs, caches, logs, SQLite databases, installation IDs, original Codex system instructions, or personal paths.

## Testing

```powershell
pwsh -NoProfile -File .\tests\Run-Tests.ps1
```

The test suite covers:

- AST parsing for every PowerShell file.
- API-key and personal-path scanning, plus pre-write rejection of key-shaped parameter values.
- Instruction rewriting, post-write read-back validation, and idempotence for current and legacy catalog structures.
- Rejection of duplicate model slugs.
- Idempotent OpenRouter provider-table merging with preservation of unrelated TOML tables.
- Top-level OpenAI/OpenRouter configuration switching.
- TOML injection, semantic duplicate keys, quoted/dotted/inline/array-table conflicts, fake headers, and valid multiline-string and nested-array boundaries.
- Rejection of malformed catalogs, Unicode-escaped sensitive values, oversized child-process output, and PATH-shadowed executables.
- Empty-file handling plus installation, repeated installation, schema 2 inventory restoration, and removal under paths containing spaces.
- Rejection of malicious restore manifests, modified previous installations, unowned installation directories, partial directory copies, and modified settings paths.
- Transaction rollback after failed switching and OpenAI cache restoration during removal.
- Protection of existing profile and here-string content, plus migration of the legacy managed block.
- Atomic replacement and missing-file restoration under protected Windows ACLs, plus cross-process lock equivalence for trailing separators.

Automated tests use only local fixtures and temporary directories. CI receives no OpenRouter API key and does not perform network catalog refresh, live inference, or Codex Desktop restart.

### Manual live smoke test

Run the live smoke test only from a controlled local PowerShell session. It may consume billable OpenRouter tokens:

1. Set or rotate a dedicated low-limit key. Open a new PowerShell window when using `User` scope.
2. Run `cxor -ForceRefresh`, then inspect provider state, catalog age, and instruction consistency with `Get-CodexOpenRouterStatus | Format-List`.
3. Create a new Codex Desktop task, select the target model, try a normal question, and optionally run one low-risk read-only tool task.
4. Run `cx` when finished to restore the Codex default configuration.

GitHub Actions never runs this flow. Do not add a real key to repository Secrets for this project's CI.

## Troubleshooting

See [Troubleshooting](docs/TROUBLESHOOTING_EN.md). The Chinese version is available at [中文故障排查](docs/TROUBLESHOOTING.md).

## License

MIT. The license covers original code and documentation in this repository. OpenAI, Codex, OpenRouter, and related names belong to their respective owners.
