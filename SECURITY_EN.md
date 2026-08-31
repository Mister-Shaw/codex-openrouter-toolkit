# Security Policy

[简体中文](SECURITY.md) | **English**

## Supported Version

Security fixes target the current source version, `0.1.11`. See the [changelog](CHANGELOG.md) for release status. Users of older versions should update before checking whether an issue still occurs.

## API Key

- `cxor -SetKey` securely prompts for and stores or rotates `OPENROUTER_API_KEY`.
- The key is stored in the current Windows user's environment variables. The OpenRouter provider's command authentication reads that user-scoped value directly each time, avoiding stale values inherited by Terminal or Explorer.
- The toolkit does not write the key value to Codex TOML, the model catalog, or logs.
- The direct catalog request sends the bearer key only to the fixed HTTPS URL `https://openrouter.ai/api/v1/models`; HTTP redirects are disabled. The CLI fallback uses short-lived command authentication for the same OpenRouter provider.
- During inference, Codex sends the bearer key in the `Authorization` header to a cache-aware proxy that listens only on `127.0.0.1`. The proxy forwards that header in memory only to the fixed HTTPS URL `https://openrouter.ai/api/v1/responses`, disables redirects, and does not log request headers or bodies. `OPENROUTER_API_KEY` is removed from the background proxy process environment.
- A user-scoped environment variable is convenient on a personal device but provides less protection than a dedicated credential vault. Use a separate low-limit OpenRouter key and configure account limits and usage monitoring.

## Network and Models

- Except for read-only `cxor -CacheStatus`, every `cxor` run connects to OpenRouter, attempts to synchronize the latest Codex-specific model information for the current Codex CLI version, and generates and validates a local model catalog.
- A new catalog must contain exactly one `~openai/gpt-latest` entry. A catalog that does not meet this requirement is rejected before publication.
- In OpenRouter mode, conversation requests pass through OpenRouter and may be sent to the downstream provider of the selected model. Handle sensitive data according to the policies of both services.
- Every OpenRouter Responses request first passes through the local cache-aware proxy. Claude requests without a custom cache policy receive top-level default five-minute `ephemeral` caching and up to two breakpoints on the first and last eligible messages in the initial consecutive system/developer section. Prompt text, roles, ordering, `instructions`, and tools are preserved. Claude requests with existing cache policies and other model requests retain their original bodies. Provider-side prompt caching temporarily retains prompt prefixes in provider infrastructure; retention, billing, and data-policy details vary by model and endpoint.
- Existing body `session_id`, header `x-session-id`, and `prompt_cache_key` are preserved. A Claude request without a routing identifier can receive an HMAC-derived routing header based on the model, `instructions`, the first system message, and tools, keyed by the local proxy token. The derived value contains no plaintext prompt, and the local token is never sent directly upstream. The proxy never automatically prewarms or retries inference. Cache markers and routing keys provide no guarantee of a hit or a particular charge.
- The toolkit sets every model's `base_instructions` and `model_messages.instructions_template` fields to empty strings. Codex Desktop continues to provide developer context, tool definitions, and permission controls. Responses API and tool support still vary by model.
- A failed refresh or validation never overwrites the last valid catalog. When a valid previous catalog exists, it is revalidated, reused, and accompanied by a warning. If every source fails, the switch is aborted before the running Codex Desktop process is closed.

## Local Changes

The installer places the module in the current user's PowerShell module directory and removes legacy toolkit blocks from the PowerShell profile. Installation does not modify Codex configuration.

Except with `-CacheStatus`, running `cxor` writes `<CODEX_HOME>/openrouter-model-catalog.json` and `<CODEX_HOME>/openrouter-cache-proxy.json`, starts a background PowerShell proxy bound only to a random high port on `127.0.0.1`, and adds the toolkit-managed OpenRouter configuration to `config.toml`. The TOML and proxy state file contain a randomly generated 256-bit local proxy token. This token protects the loopback listener and keys the fallback Claude routing HMAC; it carries no OpenRouter account authority.

`cxor -CacheStatus` only reads the current proxy's authenticated health endpoint. It calls no model, refreshes no catalog, and does not start or restart the proxy or Desktop. The V4 proxy performs bounded in-memory response parsing while forwarding the original bytes. Health diagnostics retain aggregate counters, the latest numeric token/cost values, and fixed statuses, with no model IDs, prompts, response bodies, or per-request history. Statistics disappear when the proxy exits and are never written to its state file. Missing or unparseable usage remains unknown; aggregate statistics cannot prove that the entire system prompt was cached.

Running `cx` removes `model`, `model_provider`, `model_reasoning_effort`, `model_catalog_json`, and the managed OpenRouter provider while preserving other configuration. The verified background proxy and state file remain available to OpenRouter tasks that are already open. Running `cx -StopProxy` or the uninstaller stops the proxy and removes its state; the uninstaller also removes the catalog.

The toolkit does not modify `models_cache.json`, create `settings.json`, or maintain persistent backups. Managed text is replaced with a temporary file in the same directory, and concurrent modification is checked before commit. Back up important custom Codex configuration separately.

Use the toolkit only under a regular personal Windows account. Administrators, SYSTEM, and programs that already control the current user session are inside the local trust boundary.

## Reporting a Security Issue

General issues may be reported through GitHub Issues after removing API keys, usernames, email addresses, private paths, configuration contents, logs, and request data.

For sensitive vulnerabilities, use the repository's [Private Vulnerability Reporting](https://github.com/Mister-Shaw/codex-openrouter-toolkit/security/advisories/new). If that option is unavailable, open an issue without vulnerability details and ask the maintainer for a private contact channel.
