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

The toolkit checks for `codex.exe` on `PATH`, followed by the Codex Desktop installation directory under the current user's `LocalAppData`.

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

## The model list is empty or stale

```powershell
cxor -ForceRefresh -NoRestart
Get-CodexOpenRouterStatus | Format-List
```

The refreshed catalog is checked for valid JSON, model-count bounds, unique slugs, the configured default model, and supported instruction fields. If validation fails, the last valid catalog remains available.

## Models keep identifying themselves as Codex CLI

Check instruction consistency:

```powershell
Get-CodexOpenRouterStatus | Select-Object LightweightPromptConsistent
Update-OpenRouterModelCatalog
```

If the status remains `False`, confirm that the installed `lightweight-agent-prompt.txt` contains valid text and force another refresh.

## The old model remains visible after switching

Close Codex Desktop completely, launch it again, and create a new task. Model lists and system instructions are generally loaded when a new task starts.

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

Preserve any current configuration changes and close Codex Desktop before rollback.
