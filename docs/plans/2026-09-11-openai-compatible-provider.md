# OpenAI-compatible AI provider for Kuku desktop, with full Gemini parity

Status: DRAFT v3, 2026-09-11. Author: Claude (mentor/overseer). Reviewer: Codex (adversarial, iterative, running on 27-mac-mini). Implementer: Codex (OMSV mentee).
Repo: `horizonthinking/kb-app` (fork of `kuku-mom/kuku`). Implementation base: `main` at `458f34b` (the last code commit; later commits on `main` are this plan). Branch `feat/openai-provider`.

Changelog: v1 initial. v2 corrected the updater manifest claim and sharpened the status-code claim after the author's own source check. v3 responds to Codex review round 1 (10 blocking, 9 major, 3 minor; every item dispositioned in section 14). The largest v3 change is scope: the provider speaks the **Chat Completions API only**; the Responses API is deferred to a filed follow-up because rig-core's Responses path forces strict tool schemas and requires reasoning-state replay, neither of which the current session history can carry.

Out of scope, explicitly: any Codex app-server provider (the upstream `codex-cli-poc` branch), the Go server's hosted AI path (`apps/server/internal/ai`, Gemini-only, untouched), the OpenAI Responses API (deferred, see section 12 R7), Windows/Linux packaging, the AI widgets plugin.

---

## 0. One-paragraph summary

Add `ProviderKind::OpenAi` to `crates/kuku-ai`, backed by `rig-core 0.32`'s OpenAI provider in its Chat Completions mode (`client.completions_api()`), reachable at any base URL that implements `POST /v1/chat/completions` with streaming and tools. It must do everything the desktop Gemini provider does today: streaming text, native and proxy tool calls with IDs that survive a second turn, the multi-round agent loop, approval-gated mutations, the three chat modes, history compaction, token usage, secure key storage, settings UI in three locales, and unit tests in the repo's style. Then ship it: a signed, notarized fork build in the private `horizonthinking/homebrew-h4` tap, installed and running on laptop-m3, 27-mac-mini and home-mac-mini.

Supported-provider claim (narrowed in v3): **gated** = api.openai.com (Chat Completions) and Ollama; **expected but not gated** = LM Studio, mlx_lm.server, OpenRouter and other servers that implement streaming Chat Completions with tools. The settings copy says exactly this.

---

## 1. Ground truth captured before any change (verbatim, dated)

Captured 2026-09-11T05:03Z at `458f34b` after `pnpm install --frozen-lockfile` (exit 0). Toolchain and machine inventory live in the dated proof file, not here.

| Gate | Command | Observed |
|---|---|---|
| Rust kuku-ai tests | `cargo test -p kuku-ai` | `test result: ok. 22 passed; 0 failed` |
| Rust kuku-app tests | `cargo test -p kuku-app` | `test result: ok. 334 passed; 0 failed` |
| Rust fmt | `cargo fmt -p kuku-ai -p kuku-app -- --check` | clean |
| Rust clippy | `pnpm moon run kuku-ai:lint-check` | **RED, pre-existing**: `error: the Err-variant returned from this function is very large` x80, all under `crates/kuku-contract/src/generated/connect/` |
| Desktop vitest | `pnpm moon run desktop:test-ts` | `Test Files 80 passed (80)` / `Tests 451 passed (451)` |
| Web vitest | `pnpm moon run web:test` | passed |
| Desktop TS lint | `pnpm moon run desktop:lint-ts-check` | clean |
| Desktop TS format | `pnpm moon run desktop:format-ts-check` | **RED, pre-existing**: `src/plugins/builtin/mermaid/runtime_cache.ts` |

Both reds are upstream state on a newer toolchain and are fixed in Wave 0 so every later wave regresses against green.

Live provider facts used by the test design: Ollama `qwen3.5:4b` answered a non-streaming chat completion with a `list_files` tool as `finish_reason: tool_calls`, `usage.total_tokens == 359`; its streaming chunks carry a non-standard `delta.reasoning` field. Ollama runs as a brew service on 27-mac-mini with the same model (a chat completion returned `pong`).

---

## 2. Current architecture the change plugs into

- `crates/kuku-ai/src/provider/mod.rs`: `CompletionBackend { stream_turn, list_models }`, `CompletionTurnRequest { model, system_prompt, messages, tools, authorization_header }`, `CompletionEvent { TextDelta, ToolCalls, Finished { finish_reason, usage } }`. `session.rs::run_turn_inner` is provider-agnostic except two `ProviderKind::Remote` branches (authorization header, 401 retry). The `provider` module is private to the crate (`lib.rs`), which is why the live tests live inline (section 5.1).
- `provider/gemini.rs` (325 lines) is the reference: rig `gemini::Client`, `split_history`, `into_rig_message`, `tool_definition_from`, `into_token_usage`, an `async_stream!` adapter that guarantees exactly one `Finished`, three `#[test]`s. Its three-way ID contract (`gemini.rs:82-99`): `call_id = internal_call_id` (rig correlation id), `tool_call_id = Some(tool_call.id)`, `provider_call_id = tool_call.call_id`; `session.rs:392-404` replays them into `ToolResult`.
- `state.rs::build_backend` matches `ProviderKind`; `types.rs::AiConfig` is the serde config sent via `plugin:kuku-ai|ai_set_config`.
- Frontend: `apps/desktop/src/plugins/builtin/ai_chat/{config.ts,types.ts,chat_store.ts,chat_panel.tsx,components/ai_settings.tsx}`. Secrets: `plugin_save_settings_with_secrets` with `AI_CHAT_SECURE_KEYS`, keychain-backed (`plugin_secrets.rs`); `plugin_settings.rs:75-116` iterates every supplied secure key. Today `saveConfig(provider, apiKey, serverUrl)` rebuilds the config from three positional args, `isUnsaved` ignores `model`, and `AccessPrompt` in `chat_panel.tsx:14-20` calls that narrow save when switching to Remote.
- Updater: `app.tsx:146-150` calls `checkForUpdates()` on every PROD launch; `updater.ts:84-97` turns any failure into `status: "error"`, which `update_indicator.tsx:76-85` renders as a red pill.
- i18n: `keys.ts` canonical list; `__tests__/catalog.test.ts` enforces key parity, non-empty values and placeholder parity across en/ja/ko (structural only; it cannot judge translation quality).
- Tool schemas registered by the desktop crate use optional properties (`ai_tools/file_tools.rs:78-105,127-152,203-219`, `search_tools.rs:21-48`), e.g. `list_files.path`, `search_vault.max_results`. rig's Chat Completions conversion sends them unchanged with `strict: None` (`providers/openai/completion/mod.rs:351-362`); rig's Responses conversion sets `strict: true` and rewrites every property as required (`responses_api/mod.rs:498-514`, `openai/mod.rs:32-59`). That asymmetry is why v3 uses Chat Completions only.

---

## 3. Design decisions (each one is a review target)

D1. **Provider identity.** `ProviderKind::OpenAi` with `#[serde(rename = "openai")]`; TS `AiProvider = "gemini" | "remote" | "openai"`, derived from one `AI_PROVIDERS` const. Exhaustive `match` in Rust; `assertNever` defaults in TS.

D2. **Config shape (flat, because secure keys are top-level names in the settings store).** `AiConfig` gains, each `#[serde(default)]` so previously saved configs deserialize unchanged: `openai_api_key: Option<String>` (secure key `openaiApiKey`, separate from Gemini's `apiKey`), `openai_base_url: Option<String>` (default `https://api.openai.com/v1`), `openai_model: Option<String>`. No API-flavor field (v3). The top-level `model` keeps its wire meaning and is derived by `modelForProvider(provider, raw)`: the pinned default for Gemini/Remote, the saved `openaiModel` for OpenAI.

D3. **Backend.** `provider/openai.rs`, `OpenAiBackend::new(api_key, base_url, model)`: `rig::providers::openai::Client::builder().api_key(key).base_url(normalized).build()?.completions_api()`, then `completion_model(model)`. Base URL normalization (`normalize_base_url`): trim, strip trailing `/`, append `/v1` when the path is empty. **Authentication policy (v3, replaces the "dummy key" idea):** `key_requirement(host)` returns `Required` unless the host is loopback (`localhost`, `127.0.0.0/8`, `::1`), RFC1918 private, `*.local`, or `*.ts.net` (tailnet), in which case an empty key is allowed and the literal `local` is sent as the bearer because rig's builder requires a non-empty key. Hosts that require a key (api.openai.com, openrouter.ai, everything public) block readiness until one is entered. This is a policy statement, not a claim that anonymous public endpoints exist.

D4. **Stream adapter parity.** Same contract as Gemini, through a pure `adapt_stream(impl Stream<Item = Result<StreamedAssistantContent, CompletionError>>) -> CompletionTurnStream` used by both the backend and the unit tests: `TextDelta` for text; one `ToolCalls` per complete `ToolCall` with the **existing three-way mapping** `call_id = internal_call_id`, `tool_call_id = Some(tool_call.id)`, `provider_call_id = tool_call.call_id`, `signature: None`; `ToolCallDelta`, `Reasoning`, `ReasoningDelta` ignored (Chat Completions does not require reasoning replay); exactly one `Finished` with `FinishReason::ToolCalls` if any tool call was seen, `usage` from rig's `Usage` (input, output, total, cached input); a synthesized `Finished { usage: None }` if the stream ends without `Final`, exactly like Gemini.

D5. **Errors.** `map_completion_error(CompletionError) -> AiError`: `HttpError(InvalidStatusCode(s) | InvalidStatusCodeWithMessage(s, _))` with `s` 401/403 -> `Unauthorized`, 429 -> `ProviderError("rate limited: ...")`, everything else `ProviderError`. Per rig's reqwest client both `send` and `send_streaming` reject non-2xx with `InvalidStatusCodeWithMessage` (`http_client/mod.rs:143-149, 381-387`), so the classifier matches on `StatusCode`, never on text. The session's 401 retry stays Remote-only. `AiError::NotConfigured` message becomes: "AI is not configured. Choose a connection in Settings and add its API key or model."

D6. **Model discovery, independent of a configured backend (v3).** New Tauri command `ai_list_models(base_url: String, api_key: Option<String>) -> Vec<String>` that calls a standalone `openai::list_models(base_url, api_key)` (own reqwest `GET {base}/models`, bearer only when a key is present, status read directly, ids sorted). It needs no `AiState` backend, so it works before a model is chosen and on unsaved settings. Registered in `build.rs` `COMMANDS`, `lib.rs` `generate_handler!`, **and `permissions/default.toml`** (Tauri autogenerates `allow-ai-list-models` but does not add it to the default set; the desktop capability grants only `kuku-ai:default`). Requires `reqwest = { version = "0.13", default-features = false, features = ["rustls", "charset", "json", "stream"] }`, the same features rig-core enables, so `Cargo.lock` keeps a single reqwest 0.13.4.

D7. **Frontend readiness.** `provider_readiness.ts` exports pure functions of `(config, auth)`: `isApiKeyMissing` (Gemini: no key; OpenAI: no key and `key_requirement(host) == Required`, using the same host classification ported to TS), `isModelMissing` (OpenAI: empty model), `needsRemoteLogin`, `needsRemotePermission`. `chat_panel.tsx` renders the existing banner component from them.

D8. **Settings state (v3, one object).** The settings pane edits a single `AiSettingsDraft` object holding every provider's fields (`provider, apiKey, openaiApiKey, openaiBaseUrl, openaiModel, serverUrl`); `isUnsaved` compares every field; `saveConfig(draft)` takes the whole draft, so inactive-provider fields and secrets are preserved across provider switches; `AccessPrompt`'s switch-to-Remote path calls `saveConfig({...currentDraft, provider: "remote"})`. Rows for OpenAI: Base URL, API key (show/hide, required-or-optional label driven by `key_requirement`), Model (text input + `<datalist>` from `loadModelSuggestions()` + "Load models" button, which is also the connection test). The Quick guide and the chat-panel setup prompt become provider-aware (they currently link Google AI Studio and say "Gemini or Kuku" unconditionally, `ai_settings.tsx:102-149`, `en.ts:205-224, 612-619`).

D9. **i18n.** Every new string is a key in `keys.ts` with en/ja/ko values; the shared `api_key.label` splits into `api_key.label_gemini` / `api_key.label_openai`. `catalog.test.ts` is **structural** enforcement (parity, non-empty, placeholders); translation quality is listed as an explicit unknown in the proof for a human review.

D10. **Fork release identity and updater (v3).** `apps/desktop/src-tauri/tauri.h4.conf.json` merged over `tauri.conf.json`: `identifier` and `productName` inherited (`mom.kuku.app`, `Kuku`, so `~/.kuku` and the `kuku://` auth scheme are unchanged), `"version": "0.5.8-h4.1"` (scheme `<upstream>-h4.<n>`), `bundle.targets: ["app"]`, `bundle.createUpdaterArtifacts: false`. **The updater is disabled deterministically at build time, not by a manifest:** the moon task `desktop:tauri-build-h4` sets `VITE_KUKU_UPDATER=off`; `app.tsx` calls `checkForUpdates()` only when `shouldCheckForUpdates({ prod: import.meta.env.PROD, updater: import.meta.env.VITE_KUKU_UPDATER })` is true (new pure helper in `stores/updater.ts`, unit-tested: prod+unset -> true, prod+off -> false, dev -> false). No manifest file, no fake signature, nothing mutable; upgrades happen through `brew upgrade --cask`. The plugin stays registered (inherited config) but is never invoked in the H4 build.

D11. **Signing and publishing.** Build unsigned on 27-mac-mini (cargo 1.98 via Homebrew, node, pnpm, Xcode 27, the Developer ID identity and ASC key `AuthKey_CABZCFW333.p8` are present; the tap is already tapped there), then in one `gui/$UID` one-shot LaunchAgent deep-sign with `Developer ID Application: Michael Anthony Smith (8P9788YC9P)` + hardened runtime + `src-tauri/entitlements.plist`, notarize, staple, build/sign/notarize/staple a UDZO DMG (Adapt's `sign_notarize_dmg.sh` is the **structural** reference; the Kuku copy also signs any Mach-O under `Contents/MacOS` and nested `.framework/.dylib/.app/.xpc`). Publish `Kuku-<version>.dmg` to release tag `kuku-v<version>` on `horizonthinking/homebrew-h4`; cask `Casks/kuku.rb` (source of truth `~/projects/h4/deploy/homebrew-tap/Casks/kuku.rb`, mirrored into the tap clone) with `H4PrivateGitHubReleaseDownloadStrategy`, `app "Kuku.app"`, `uninstall quit: "mom.kuku.app"`, no `zap` of `~/.kuku`. `publish_kuku_cask.sh` is NOT a literal copy of the Adapt publisher: it hashes the DMG itself and refuses a mismatching sha argument, fails on a dirty or diverged tap clone, syncs with `git pull --ff-only`, stages with `git add -A`, and has a temp-repo test (`publish_kuku_cask_test.sh`, fake `gh` on PATH) proving the mismatch and dirty-tree failures. Fork-only files live under `scripts/h4/`, `docs/plans/` and the single `tauri.h4.conf.json`.

D12. **Spend (v3, attributable).** Authorization is Michael's goal statement of 2026-09-11, quoted verbatim: "please author an exhaustive plan to activate the openai api (to open ai and to other compliant api providers) with full gemini feature parity. ... Dod is a test working app running locall yon this mac". Bound: model `gpt-5-nano`, at most 3 chat-completion requests (one two-round tool turn plus one Ask turn) and 1 `GET /v1/models`, expected cost well under one US cent; recorded in the proof with the exact request count. Everything else runs against Ollama.

---

## 4. Feature-parity matrix (Gemini today vs OpenAI target) and the proof for each row

| # | Capability | Gemini today | OpenAI target | Proof |
|---|---|---|---|---|
| P1 | Streaming text deltas | rig `Text` | same | T-L1 count(TextDelta) >= 1 |
| P2 | Tool calls, native + proxy, IDs survive turn 2 | three-way ID mapping | identical mapping (D4) | T-R1..T-R3 unit; T-L2 two-round live replay |
| P3 | Multi-round agent loop to `round_limit` | provider-agnostic | unchanged | existing session tests; T-L2 exercises round 1 -> tool result -> round 2 |
| P4 | Approval-gated mutations | `MutationPlan`, provider-agnostic | unchanged | existing tests; Wave 5 manual proof (screenshot of an approval diff) |
| P5 | Ask / Agent / Inline modes | prompt + tool gating | unchanged | existing tests |
| P6 | History compaction | provider-agnostic | unchanged | existing `compact_history_*` tests |
| P7 | Token usage in `DonePayload` | mapped from rig | mapped incl. cached input | T-R7 exact synthetic values; T-L1 identities `input > 0`, `output > 0`, `total == input + output` |
| P8 | Exactly one `Finished`, synthesized if absent | yes | yes | T-R6 |
| P9 | Model selection | pinned default, static list | free text + discovery before a model exists | T-R12, T-L3, T-T13 |
| P10 | Secure key storage | `apiKey` | `openaiApiKey` | T-T6, T-T7 |
| P11 | Settings UI + i18n | yes | yes, one draft object | T-T1..T-T4, T-T14, T-T15, catalog test |
| P12 | Chat panel readiness banners | key missing | key/model missing with host policy | T-T8..T-T11 |
| P13 | Error surfacing | `ErrorPayload` | 401/403/429 classified | T-R8 |
| P14 | Reset / clear persisted config | clears `apiKey` | clears both secure keys | T-T7 |
| P15 | Backward-compatible saved config | n/a | old JSON loads | T-R11, T-T3 |
| P16 | Compatible non-OpenAI hosts | n/a | normalization, keyless local policy | T-R4, T-R5, T-R9; T-L1..T-L3 on Ollama |
| P17 | Provider-aware guide and setup copy | Gemini-only copy | provider-aware | T-T16 |

---

## 5. Test pre-plan (names are binding; styles follow the repo)

Conventions: Rust tests are inline `#[cfg(test)] mod tests` with plain `#[test]` (async through `tokio::runtime::Builder::new_current_thread()` since the crate enables `rt` and `macros`); env-gated live tests mirror the Go server's `KUKU_TEST_*` skip pattern; vitest files are colocated `*.test.ts` using `vi.mock("@tauri-apps/api/core")` and `vi.resetModules()`; snake_case filenames.

### 5.1 Rust, `crates/kuku-ai` (all inline; the `provider` module is private, so no `tests/` directory)
- `src/provider/openai.rs::tests`
  - T-R1 `tool_result_uses_original_tool_call_ids`
  - T-R2 `tool_result_without_provider_call_id_still_uses_tool_call_id`
  - T-R3 `assistant_tool_call_round_trips_all_three_ids_without_signature`
  - T-R4 `normalize_base_url_appends_v1_and_strips_trailing_slash` (`https://api.openai.com`, `http://127.0.0.1:11434/`, `http://127.0.0.1:11434/v1/`, `https://openrouter.ai/api/v1`)
  - T-R5 `key_requirement_classifies_hosts` (api.openai.com Required, openrouter.ai Required, localhost/127.0.0.1/192.168.1.5/mac.local/mini.tail211fb5.ts.net Optional)
  - T-R6 `adapt_stream_synthesizes_finished_when_stream_ends_early` and `adapt_stream_reports_tool_calls_finish_reason_and_three_ids` (hand-built `futures::stream::iter(vec![Ok(StreamedAssistantContent::...)])`)
  - T-R7 `into_token_usage_maps_cached_input_tokens` (exact: 120 input, 30 output, 150 total, 100 cached)
  - T-R8 `map_completion_error_classifies_401_403_429` (constructs `CompletionError::HttpError(http_client::Error::InvalidStatusCodeWithMessage(StatusCode::UNAUTHORIZED, ..))` etc.)
  - T-R9 `empty_key_is_allowed_only_for_local_hosts_and_sends_local_placeholder`
  - Live, env-gated (`KUKU_TEST_OPENAI_BASE_URL`; optional `KUKU_TEST_OPENAI_API_KEY`, `KUKU_TEST_OPENAI_MODEL` default `qwen3.5:4b`), each printing `skipped: KUKU_TEST_OPENAI_BASE_URL unset` and returning when unset:
    - T-L1 `live_streams_text_with_usage_identities`: prompt "Reply with exactly: pong"; count(Finished) == 1, `finish_reason == Stop`, count(TextDelta) >= 1, usage present with the three identities.
    - T-L2 `live_two_round_tool_call_replays_ids`: round 1 with one `list_files` descriptor and `tool_choice = required` (rig `CompletionRequestBuilder::tool_choice`, claim C-RIG5); assert count(ToolCalls) == 1, name == `list_files`, `finish_reason == ToolCalls`, `tool_call_id.is_some()`; append the Assistant message and a `ToolResult` whose output is `{"files":["alpha.md"]}` with the three IDs replayed; round 2 with no tools and the instruction "Reply with exactly the file name from the tool result"; assert count(Finished) == 1, `finish_reason == Stop`, and the concatenated text, trimmed of whitespace and a trailing period, `== "alpha.md"`. If the local model cannot satisfy the exact-text assertion reliably, the mentee reports CONTRADICTS and the text assertion moves to the gpt-5-nano smoke (the structural assertions stay on Ollama).
    - T-L3 `live_list_models_returns_the_configured_model`: result contains exactly one entry equal to `KUKU_TEST_OPENAI_MODEL` (count of matches == 1).
  - Regression command (documented in AGENTS.md): `KUKU_TEST_OPENAI_BASE_URL=http://127.0.0.1:11434/v1 cargo test -p kuku-ai openai::tests::live_ -- --nocapture`.
- `src/types.rs::tests`: T-R10 `provider_kind_openai_serializes_as_openai`; T-R11 `ai_config_deserializes_without_openai_fields`.
- `src/state.rs::tests`: T-R12 `build_backend_openai_requires_model_and_key_policy` (`Ok(None)` when model empty; `Ok(None)` when host requires a key and none given; `Some` for a local host with empty key).
- `src/lib.rs::tests` (or `build.rs`-adjacent): T-R13 `every_command_has_a_default_permission`: parses `include_str!("../build.rs")` for the quoted `COMMANDS`, parses `include_str!("../permissions/default.toml")`, asserts each command has `allow-<kebab>` in the default set (count of missing == 0).

### 5.2 TypeScript, `apps/desktop`
- `src/plugins/builtin/ai_chat/config.test.ts` (new): T-T1 normalizes openai provider with defaults; T-T2 derives top-level model per provider; T-T3 legacy configs without openai fields load; T-T4 unknown provider falls back to the default.
- `src/plugins/builtin/ai_chat/chat_store.test.ts` (extend): T-T5 loads openai settings without pinning the model to the build default; T-T6 saves the whole draft with `secureKeys: ["apiKey","openaiApiKey"]` and syncs `ai_set_config` with `provider: "openai"`; T-T7 clearPersistedConfig clears both secure keys; T-T13 `loadModelSuggestions` invokes `plugin:kuku-ai|ai_list_models` with the draft's base URL and key and stores the ids; T-T14 provider round trip openai -> gemini -> openai keeps both keys, both models and the base URL; T-T15 `AccessPrompt`'s switch to remote preserves openai fields.
- `src/plugins/builtin/ai_chat/provider_readiness.test.ts` (new): T-T8 gemini key missing; T-T9 openai key missing only for key-required hosts; T-T10 openai model missing; T-T11 remote login/permission unchanged.
- `src/plugins/builtin/ai_chat/components/model_label.test.ts` (new): T-T12.
- `src/plugins/builtin/ai_chat/components/ai_settings.test.ts` (new, node environment, renders nothing): T-T16 `guideCopyFor(provider)` and `setupPromptFor(provider)` return provider-specific keys (pure helpers extracted from the component).
- `src/stores/updater.test.ts` (new): T-T17 `shouldCheckForUpdates` truth table (D10).
- `src/i18n/__tests__/catalog.test.ts`: unchanged, must stay green.

### 5.3 Shell, `scripts/h4`
- `publish_kuku_cask_test.sh`: temp git repos + fake `gh`; asserts non-zero exit on sha mismatch, on a dirty tap clone, and success with `git add -A` staging on the happy path.

### 5.4 Commands that must be green after every wave
`pnpm moon run kuku-ai:test kuku-ai:lint-check kuku-ai:format-check desktop:test-ts desktop:lint-ts-check desktop:format-ts-check desktop:test-rust desktop:lint-rust-check desktop:format-rust-check web:test`, plus the live tests against Ollama, plus (from Wave 3) `scripts/h4/publish_kuku_cask_test.sh`.

---

## 6. Work breakdown (OMSV waves)

### Wave 0, baseline hygiene
`crates/kuku-contract/src/lib.rs`: `#![allow(clippy::result_large_err)]` with a comment (generated Connect code, never linted upstream). `oxfmt --write` on `mermaid/runtime_cache.ts`. Acceptance: every command in 5.4 that exists is green. Commit `chore: make lint and format gates green on the current toolchain`.

### Wave 1, Rust backend
Files: `crates/kuku-ai/Cargo.toml` (+reqwest per D6), `src/types.rs`, `src/provider/mod.rs`, `src/provider/openai.rs` (new), `src/state.rs`, `src/error.rs`, `src/commands.rs`, `src/lib.rs`, `build.rs`, `permissions/default.toml`, tests T-R1..T-R13 and T-L1..T-L3. Acceptance: unit tests pass; live tests pass against Ollama; `cargo clippy -p kuku-ai --all-targets -- -D warnings` clean; `cargo test -p kuku-app` still green.

### Wave 2, frontend
Files: `types.ts`, `config.ts`, `chat_store.ts`, `provider_readiness.ts` (new), `chat_panel.tsx`, `components/ai_settings.tsx`, `components/model_label.ts` (new), `components/settings_copy.ts` (new; `guideCopyFor`, `setupPromptFor`), `index.ts`, `stores/updater.ts` (`shouldCheckForUpdates`) + `app.tsx`, `i18n/keys.ts` + three locales, tests T-T1..T-T17. Acceptance: `desktop:test-ts`, `desktop:lint-ts-check`, `desktop:format-ts-check`, `desktop:build` green.

### Wave 3, docs, fork build config, packaging
Files: `tauri.h4.conf.json`, `apps/desktop/moon.yml` (`tauri-build-h4` with `VITE_KUKU_UPDATER=off`), `scripts/h4/{build_h4.sh, sign_notarize_dmg.sh, release_h4.sh, verify_ai_provider.sh, publish_kuku_cask_test.sh}`, in `~/projects/h4`: `deploy/homebrew-tap/Casks/kuku.rb`, `deploy/homebrew-tap/publish_kuku_cask.sh`, one README row; docs per section 8. Acceptance: `bash -n` on every script; `release_h4.sh --dry-run` prints every step; `publish_kuku_cask_test.sh` green; `pnpm moon run desktop:tauri-build-h4` on the build host yields `target/release/bundle/macos/Kuku.app` that launches, with `codesign -dv` reporting whatever Tauri applied (recorded, not asserted).

### Wave 4, release (overseer-driven)
1. Merge `feat/openai-provider` into `main` (fast-forward or merge commit), push.
2. 27-mac-mini: `git pull`, `pnpm install --frozen-lockfile`, `scripts/h4/verify_ai_provider.sh`, `pnpm moon run desktop:tauri-build-h4`.
3. One `gui/$UID` LaunchAgent runs `scripts/h4/sign_notarize_dmg.sh`; poll `launchctl print` for `last exit code`; require 0 and `Gatekeeper ACCEPTED`.
4. `scp` the DMG to laptop-m3; sha256 must equal the remote's; `spctl -a -t open --context context:primary-signature -vv` accepts.
5. `publish_kuku_cask.sh 0.5.8-h4.1 <sha> Kuku-0.5.8-h4.1.dmg` (from laptop-m3, whose `gh` is logged in as horizonthinking): release `kuku-v0.5.8-h4.1`, cask rewritten in monorepo and tap, both pushed.

### Wave 5, install and prove on three Macs
On laptop-m3, 27-mac-mini, home-mac-mini, in a **login shell** (which exports `HOMEBREW_GITHUB_API_TOKEN` from the fleet's rendered `~/.env`; verified present, 40 chars, on all three; no command substitution, no `op` on the minis):
1. `brew tap horizonthinking/h4` (idempotent; already present on all three) and `brew trust horizonthinking/h4` (do not suppress a failure).
2. If a non-Homebrew `/Applications/Kuku.app` exists, move it to `~/Desktop/Kuku.app.pre-brew-<date>` (recoverable), as the Adapt driver does.
3. `brew list --cask horizonthinking/h4/kuku >/dev/null 2>&1 && brew upgrade --cask horizonthinking/h4/kuku || brew install --cask horizonthinking/h4/kuku`.
4. Verify: `brew list --cask` shows `kuku`; `codesign -dvvv /Applications/Kuku.app` shows `Authority=Developer ID Application`, `TeamIdentifier=8P9788YC9P`, `flags=0x10000(runtime)`; `spctl -a -vv -t exec` accepted with `source=Notarized Developer ID`; `xcrun stapler validate` ok; `open -a Kuku`, after 10 s `pgrep -x Kuku` returns exactly one pid and `lsappinfo info -only bundleid <pid>` shows `mom.kuku.app`; no updater pill (status stays idle; observed via the dev-console store on laptop-m3, and by absence of the pill in the screenshot).
5. laptop-m3 only: configure OpenAI-compatible with Ollama, run an Agent turn that lists vault files (tool round trip), an approval-diff edit, and the bounded gpt-5-nano smoke (D12); screenshots; live-test output block.

---

## 7. Definition-of-Done proof (5 items)

1. Ground truth: section 1 (dated) plus the machine/toolchain inventory in `docs/plans/2026-09-11-openai-provider-proof.md`.
2. Observed values: every command in 5.4 re-run on final `main`, output verbatim in the proof; Wave 5 checks verbatim per machine.
3. Expected-vs-observed table: one row per P1..P17 and per Wave 5 check per Mac; a missing row is a failure.
4. Visual artifacts under `docs/plans/proof/`: settings pane (OpenAI selected, models loaded), an Agent turn with a tool call and an approval diff, no updater pill; notarization log excerpt; `brew list --cask` per Mac.
5. Explicit unknowns: Windows/Linux untested; LM Studio, mlx_lm.server, OpenRouter not gated; Responses API deferred; ja/ko strings machine-drafted pending human review; anything the mentee marked MISSING-LESSON.

---

## 8. Doc-cleansing plan (ships with the change)

| Artifact | Edit |
|---|---|
| `AGENTS.md` | Providers are Remote, Gemini, OpenAI-compatible (Chat Completions); live-test regression command; "Fork release (H4 tap)" section pointing at `scripts/h4/`. |
| `crates/kuku-ai/README.md` | Provider adapters list and the live-test command. |
| `crates/kuku-ai/src/error.rs` | Provider-neutral `NotConfigured` message. |
| `apps/desktop/src/plugins/builtin/ai_chat/index.ts` | Description no longer names Gemini. |
| `ai_settings.tsx` Quick guide (`:102-149`) and `en/ja/ko` `guide.*` keys | Provider-aware: Gemini branch links AI Studio; OpenAI branch links platform.openai.com and names Ollama as the local option. |
| `en/ja/ko` chat setup prompt keys (`en.ts:612-619`) | Provider-neutral wording ("Sign in to Kuku or add your own API key"). |
| `en/ja/ko` `api_key.label` | Split per provider (D9). |
| `docs/development.md` | OpenAI-compatible option, Ollama example, live-test env vars; "Release Notes" section distinguishes upstream metadata (`prod_release.ts`, `tauri.conf.json`) from the H4 fork (`tauri.h4.conf.json`, `scripts/h4/`). |
| `~/projects/h4/deploy/homebrew-tap/README.md` | `kuku` cask row, tag namespace `kuku-v<version>`. |
| This plan | Superseded content is struck or moved to section 14, never deleted; the proof is a separate dated file. |

---

## 9. Sustainability and enforcement (deterministic where possible)

| Mechanism | Type | Catches |
|---|---|---|
| Exhaustive `match config.provider` in Rust | compiler, blocking | provider added without a code path |
| `assertNever` in TS provider switches; option list derived from `AI_PROVIDERS` | tsc (type-aware lint), blocking | same, TS side |
| T-R13 command/permission parity test | unit, blocking | a command without a default permission |
| T-R11 / T-T3 legacy-config tests | unit, blocking | a field added without `#[serde(default)]` / normalization |
| T-T14 / T-T15 round-trip tests | unit, blocking | a save path that drops inactive-provider fields or secrets |
| T-T17 updater truth table | unit, blocking | an H4 build that starts checking for upstream updates |
| `catalog.test.ts` | vitest, blocking | missing/empty locale keys (structural only) |
| Live tests + `scripts/h4/verify_ai_provider.sh` (fails when Ollama is down rather than skipping) | pre-release gate in `release_h4.sh`, blocking | provider regression before publishing |
| `release_h4.sh` preconditions (clean tree, on `main`, gates green) | script, blocking | shipping from a dirty or red tree |
| `publish_kuku_cask.sh` self-hashing + dirty/diverged refusal + `publish_kuku_cask_test.sh` | script + test, blocking | cask pointing at the wrong artifact, clobbered tap |
| AGENTS.md documents the one regression command | prose | forgotten live test (backed by the script above) |

---

## 10. OMSV protocol

- Overseer (Claude): owns this plan, audits every wave (re-runs gates independently, diffs the branch, checks every claim row), drives Waves 4 and 5.
- Mentor (Claude): authored the plan and the draft claims (section 11); a claim is unproven until the mentee confirms it at a green point.
- Mentee (Codex, on 27-mac-mini via `codex_exec_guard.sh`, worktree `~/projects/apps/kb-app-worktrees/openai-provider`, sandbox `workspace-write` with network for cargo): one wave per dispatch; returns `WAVE_REPORT.md` with files touched, verbatim gate output, and a CONFIRMS / CONTRADICTS / MISSING-LESSON row per claim the wave touches; may REJECT a claim, which blocks the wave until the plan is amended.
- Adversarial review loop: Codex reviews read-only and returns `{verdict, previous, blocking, major, minor, confirmed}`; the overseer amends or rejects with rationale (section 14) and re-submits; stop at AGREE or after four rounds, listing unresolved items as accepted risks.

---

## 11. Draft claims (unvalidated until the mentee confirms)

- C-RIG1: `rig::providers::openai::Client::builder().api_key(k).base_url(u).build()?.completions_api().completion_model(id)` compiles against rig-core 0.32.0 and streams with tools.
- C-RIG2: the Chat Completions stream yields `StreamedAssistantContent::{Text, ToolCall, ToolCallDelta, Reasoning, ReasoningDelta, Final}`, the same variants Gemini matches on, and its `ToolCall` carries `id` and `call_id`.
- C-RIG3: rig's `Usage` populates `cached_input_tokens` from `prompt_tokens_details.cached_tokens` on Chat Completions.
- C-RIG4: both `send` and `send_streaming` of rig's reqwest client reject non-2xx with `http_client::Error::InvalidStatusCodeWithMessage(StatusCode, String)`.
- C-RIG5: rig's `CompletionRequestBuilder` exposes `tool_choice(...)` for Chat Completions and Ollama honours `tool_choice: "required"`.
- C-RIG6: rig's Chat Completions tool conversion sends `parameters` unchanged with `strict: None`, so optional Kuku tool properties keep their contract.
- C-OLL1: Ollama's streaming Chat Completions assemble into exactly one rig `ToolCall` for a forced single tool call.
- C-OLL2: Ollama's non-standard `delta.reasoning` field is ignored by rig's deserializer.
- C-CFG1: `#[serde(default)]` on the new fields keeps every previously saved config loading.
- C-SEC1: `plugin_save_settings_with_secrets` handles two secure keys with no Rust change.
- C-SEC2: the keychain item for `openaiApiKey` is addressable for the rollback cleanup (service `mom.kuku.desktop.plugin-secrets`, account naming per `plugin_secrets.rs`; the mentee records the exact `security delete-generic-password` invocation).
- C-CMD1: `ai_list_models` needs `build.rs` `COMMANDS`, `lib.rs` `generate_handler!` and `permissions/default.toml`; nothing in the desktop crate.
- C-UPD (v3): with `VITE_KUKU_UPDATER=off` baked in by the `tauri-build-h4` task, `checkForUpdates()` is never called and the indicator stays `idle`.
- C-BLD1: `tauri build --config src-tauri/tauri.h4.conf.json` with `createUpdaterArtifacts: false` and no `APPLE_SIGNING_IDENTITY` produces a `Kuku.app` that a later deep `codesign --force` re-signs with the hardened runtime and `entitlements.plist` and that then passes notarization.
- C-BLD2: 27-mac-mini's Homebrew `cargo 1.98.0` builds the Tauri app for `aarch64-apple-darwin` without rustup.
- C-TAP1: in a login shell on each Mac, `brew install --cask horizonthinking/h4/kuku` resolves the private asset through `H4PrivateGitHubReleaseDownloadStrategy` using the exported `HOMEBREW_GITHUB_API_TOKEN`.

---

## 12. Risks and accepted decisions

- R1 Billed API use: bounded per D12, authorized by the quoted goal statement.
- R2 Reasoning models over Chat Completions may return no text in a tool-only round; the adapter does not treat that as an error (already true for Gemini).
- R3 Local servers without tool support answer in prose; the settings banner says so.
- R4 Upstream merge friction: fork-only files isolated; shared-file edits minimal.
- R5 Signing needs a GUI session on the build host; fallback host home-mac-mini needs `cargo` installed first.
- R6 (v3) No mutable manifest exists any more; nothing to drift.
- R7 Responses API deferred: filed as a follow-up Action ("Kuku: OpenAI Responses API flavor with nullable-schema conversion and reasoning-state replay") so the decision is visible, not lost.
- R8 Live-test flakiness with a 4B model: structural assertions are deterministic under `tool_choice: required`; the exact-text assertion has the fallback in T-L2.

## 13. Rollback

- Code: revert the merge commit; saved configs with `provider: "openai"` fall back to the default provider through `normalizeAiConfig`.
- Credentials (v3): before reverting on a Mac that saved an OpenAI key, open Settings -> AI Chat -> Reset (which clears both secure keys while the new code is still installed), or run the `security delete-generic-password` invocation recorded under C-SEC2.
- Tap: `brew uninstall --cask horizonthinking/h4/kuku` per Mac; delete the `kuku-v<version>` release; revert `Casks/kuku.rb` in the tap and the monorepo. `~/.kuku` is never touched.

---

## 14. Review log

### Round 1 (Codex on 27-mac-mini, plan v2) -> REVISE. Dispositions:
- B1 reqwest features: AMENDED (D6: `rustls`, `charset`, `json`, `stream`, default-features off; verified against reqwest 0.13.4 and rig's `reqwest-rustls` feature).
- B2 ID mapping: AMENDED (D4, T-R3, T-L2 replay).
- B3 Responses reasoning state: AMENDED by scope (Chat Completions only; Responses deferred, R7).
- B4 Responses strict schemas: AMENDED by scope (verified: Chat conversion `strict: None`, Responses `strict: true` + required rewrite).
- B5 discovery unreachable: AMENDED (D6 standalone `list_models(base_url, key)`, T-R12, T-T13).
- B6 permissions: AMENDED (D6, T-R13).
- B7 live-test placement: AMENDED (inline env-gated tests in `openai.rs`).
- B8 updater: AMENDED (D10 build-time disable, T-T17; manifest approach removed).
- B9 credentials: AMENDED (Wave 5 uses the login-shell export from the fleet's `~/.env`, verified present on all three Macs; `h4 env get` confirmed nonexistent; no command substitution).
- B10 tap sequence: AMENDED (idempotent tap + trust, fully qualified name, install-vs-upgrade, move-aside). Factual note: `brew tap` in a login shell on both minis does list `horizonthinking/h4`; the reviewer's sandbox shell did not, so the step is idempotent rather than conditional.
- M1 flavor default: RESOLVED by removal of the flavor field.
- M2 auth policy: AMENDED (D3 `key_requirement`, T-R5, T-R9, T-T9).
- M3 live-test strength: AMENDED (T-L2 two-round with `tool_choice: required`, usage identities, T-L3 exact match; the paid smoke exercises the two-round flow).
- M4 settings state: AMENDED (D8 single draft, T-T14, T-T15).
- M5 Gemini-only copy: AMENDED (section 8 rows, D8, T-T16; development.md release-note split).
- M6 publisher: AMENDED (D11 non-literal copy with self-hashing, ff-only, dirty refusal, `git add -A`, temp-repo test).
- M7 rollback credential: AMENDED (section 13, C-SEC2).
- M8 compatibility claim: AMENDED (section 0 gated vs expected).
- M9 spend authorization: AMENDED (D12 quotes the goal statement verbatim with a request bound).
- m1 C-RIG4 wording: AMENDED.
- m2 translation enforcement: AMENDED (D9 structural; explicit unknown).
- m3 volatile state in the plan: AMENDED (inventory moved to the proof; baseline commit labelled as implementation base).
