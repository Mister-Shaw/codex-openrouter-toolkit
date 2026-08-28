# Security Policy

[简体中文](SECURITY.md) | **English**

## Supported Version

Security fixes apply only to the current version, `0.1.7`. Users of older versions should update before checking whether an issue still occurs.

## API Key

- `cxor -SetKey` securely prompts for and stores or rotates `OPENROUTER_API_KEY`.
- The key is stored in the current Windows user's environment variables. The OpenRouter provider's command authentication reads that user-scoped value directly each time, avoiding stale values inherited by Terminal or Explorer.
- The toolkit does not write the key value to Codex TOML, the model catalog, or logs.
- The direct catalog request sends the bearer key only to the fixed HTTPS URL `https://openrouter.ai/api/v1/models`; HTTP redirects are disabled. The CLI fallback uses short-lived command authentication for the same OpenRouter provider.
- A user-scoped environment variable is convenient on a personal device but provides less protection than a dedicated credential vault. Use a separate low-limit OpenRouter key and configure account limits and usage monitoring.

## Network and Models

- Every `cxor` run connects to OpenRouter, attempts to synchronize the latest Codex-specific model information for the current Codex CLI version, and generates and validates a local model catalog.
- A new catalog must contain exactly one `~openai/gpt-latest` entry. A catalog that does not meet this requirement is rejected before publication.
- In OpenRouter mode, conversation requests pass through OpenRouter and may be sent to the downstream provider of the selected model. Handle sensitive data according to the policies of both services.
- The toolkit sets every model's `base_instructions` and `model_messages.instructions_template` fields to empty strings. Codex Desktop continues to provide developer context, tool definitions, and permission controls. Responses API and tool support still vary by model.
- A failed refresh or validation never overwrites the last valid catalog. When a valid previous catalog exists, it is revalidated, reused, and accompanied by a warning. If every source fails, the switch is aborted before the running Codex Desktop process is closed.

## Local Changes

The installer places the module in the current user's PowerShell module directory and removes legacy toolkit blocks from the PowerShell profile. Installation does not modify Codex configuration.

Running `cxor` writes `<CODEX_HOME>/openrouter-model-catalog.json` and adds the toolkit-managed OpenRouter configuration to `config.toml`. Running `cx` removes `model`, `model_provider`, `model_reasoning_effort`, `model_catalog_json`, and the managed OpenRouter provider while preserving other configuration.

The toolkit does not modify `models_cache.json`, create `settings.json`, or maintain persistent backups. Managed text is replaced with a temporary file in the same directory, and concurrent modification is checked before commit. Back up important custom Codex configuration separately.

Use the toolkit only under a regular personal Windows account. Administrators, SYSTEM, and programs that already control the current user session are inside the local trust boundary.

## Reporting a Security Issue

General issues may be reported through GitHub Issues after removing API keys, usernames, email addresses, private paths, configuration contents, logs, and request data.

For sensitive vulnerabilities, use the repository's [Private Vulnerability Reporting](https://github.com/Mister-Shaw/codex-openrouter-toolkit/security/advisories/new). If that option is unavailable, open an issue without vulnerability details and ask the maintainer for a private contact channel.
