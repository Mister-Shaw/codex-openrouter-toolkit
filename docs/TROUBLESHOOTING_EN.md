# Troubleshooting

[简体中文](TROUBLESHOOTING.md) | **English**

## `cx` or `cxor` is not recognized

```powershell
. $PROFILE
Get-Command cx, cxor
```

If the profile contains a syntax error, restore it from the backup path printed by the installer.

## Codex CLI cannot be found

Confirm that Codex Desktop is installed and has been launched at least once:

```powershell
Get-CodexCliPath
```

The toolkit accepts only `codex.exe` bundled under the current user's `LocalAppData\OpenAI\Codex\bin` when its Authenticode signature is valid and its signer subject matches OpenAI. A same-named executable on `PATH` is ignored.

## The API key cannot be read

Run the hidden-input script again:

```powershell
pwsh -NoProfile -File .\scripts\Set-CodexOpenRouterKey.ps1
. $PROFILE
```

Status output reports only whether the key is available and never prints its value:

```powershell
Get-CodexOpenRouterStatus
```

The script accepts OpenRouter keys with the `sk-or-` prefix and rejects whitespace or control characters. After setting or rotating the default `User`-scoped value, close and reopen PowerShell. An existing window may retain an older `Process`-scoped value. To update the current window immediately, dot-source the process-scoped script:

```powershell
. .\scripts\Set-CodexOpenRouterKey.ps1 -Scope Process
```

## HTTP 401

Generate and rotate the key, confirm that the input contains no surrounding whitespace, and check the key status in your OpenRouter account.

## HTTP 403

Review the response for model, region, account-permission, and policy details. Retry with a model your account can access. Catalog visibility does not guarantee account-level access.

## A visible model still fails during use

Check these items in order:

1. OpenRouter account balance and limits.
2. Current model availability and upstream-provider status.
3. Compatibility with the Responses API.
4. Support for the tools, images, or patch operations required by the task.

## A direct `/api/v1/models` request contains only `data`

This is the current response shape of OpenRouter's public endpoint. Codex Desktop requires a top-level `models` structure and additional compatibility fields. Use the toolkit refresh to generate an authenticated Codex-compatible catalog. Do not rename the public response and write it to `model_catalog_json` manually:

```powershell
cxor -ForceRefresh -NoRestart
```

The persistent provider's `env_key` is used for inference. Isolated `command` authentication created by the refresh flow is limited to catalog refresh, and its temporary `CODEX_HOME` is removed when the flow ends.

Upgrade removes the legacy persistent `[model_providers.openrouter.auth]` table. Inline or dotted `auth` declarations stop the merge; back up `config.toml`, remove that authentication declaration manually, and rerun installation.

## The model list is empty or stale

```powershell
cxor -ForceRefresh -NoRestart
Get-CodexOpenRouterStatus | Format-List
```

The refreshed catalog is checked for valid JSON, model-count bounds, unique slugs, the configured default model, and supported instruction fields. If validation fails, the last valid catalog remains available.

Every `cxor` run checks catalog age. A valid catalog younger than 24 hours is reused, while a catalog at or beyond the threshold is refreshed. `-ForceRefresh` bypasses the age condition.

## Models keep identifying themselves as Codex CLI

Check instruction consistency:

```powershell
Get-CodexOpenRouterStatus | Select-Object LightweightPromptConsistent
Update-OpenRouterModelCatalog
```

If the status remains `False`, confirm that the installed `lightweight-agent-prompt.txt` contains valid text and force another refresh.

## The old model remains visible after switching

Close Codex Desktop completely, launch it again, and create a new task. Model lists and system instructions are generally loaded when a new task starts.

## OpenRouter models remain visible after uninstalling

Default removal restores the OpenAI configuration captured during installation and restores the OpenAI model cache when a snapshot is available. Close Codex Desktop completely, launch it again, and create a new task. Removal with `-KeepCurrentProvider` preserves the active provider configuration.

## Codex Desktop does not restart automatically

If the configuration was written successfully, launch Codex Desktop manually. The `-NoRestart` option intentionally skips the automatic restart.

## MCP startup warnings

Investigate the program and path named in each MCP warning. Provider switching generally leaves MCP configuration unchanged.

## Unsupported PowerShell version

Install PowerShell 7.4 or later and run the scripts through `pwsh`:

```powershell
$PSVersionTable.PSVersion
```

## Rollback

Use the backup directory printed by the installer:

```powershell
pwsh -NoProfile -File .\scripts\Restore-CodexOpenRouterBackup.ps1 `
  -BackupPath '<backup-directory>' `
  -Force
```

Preserve any current configuration changes and close Codex Desktop before rollback. Restore validates a per-file inventory of the previous installation and toolkit ownership of the current installation directory. If an automatic rollback encounters a file lock or permission failure, the error reports a retained transaction-snapshot path; copy that directory before further recovery work.
