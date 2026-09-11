# OpenAI-compatible AI provider for Kuku desktop, with full Gemini parity

Status: DRAFT v2, 2026-09-11. Author: Claude (mentor/overseer). Reviewer: Codex (adversarial, iterative). Implementer: Codex (OMSV mentee).

Changelog: v1 initial. v2 corrected D10/C-UPD (updater manifest needs a `darwin-aarch64` entry; verified in vendored plugin source) and sharpened C-RIG4 (status codes are available only on rig's streaming path) after the overseer's own source check, before the first Codex review verdict arrived.
Repo: `horizonthinking/kb-app` (fork of `kuku-mom/kuku`), branch `feat/openai-provider` off `main` (HEAD `458f34b`).

Out of scope, explicitly: any Codex app-server provider (the upstream `codex-cli-poc` branch), the Go server's hosted AI path (`apps/server/internal/ai`, Gemini-only, untouched), Windows/Linux packaging, the AI widgets plugin.

---

## 0. One-paragraph summary

Add `ProviderKind::OpenAi` to `crates/kuku-ai`, backed by `rig-core 0.32`'s OpenAI provider (already a dependency, not feature-gated), reachable at any OpenAI-compatible base URL (api.openai.com, Ollama, LM Studio, mlx_lm.server, OpenRouter). It must do everything the desktop Gemini provider does today: streaming text, native and proxy tool calls, the multi-round agent loop, approval-gated mutations, the three chat modes, history compaction, token usage, secure key storage, settings UI in three locales, and unit tests in the repo's style. Then ship it: a signed, notarized fork build in the private `horizonthinking/homebrew-h4` tap, installed and running on this Mac, 27-mac-mini and home-mac-mini.

---

## 1. Ground truth captured before any change (verbatim)

Captured on laptop-m3 (macOS 27.0, Xcode 27.0, cargo 1.98.0, node v26.8.1, pnpm 11.1.1) at HEAD `458f34b`, 2026-09-11T05:03Z, after `pnpm install --frozen-lockfile` (exit 0).

| Gate | Command | Observed |
|---|---|---|
| Rust kuku-ai tests | `cargo test -p kuku-ai` | `test result: ok. 22 passed; 0 failed` |
| Rust kuku-app tests | `cargo test -p kuku-app` | `test result: ok. 334 passed; 0 failed` |
| Rust fmt | `cargo fmt -p kuku-ai -p kuku-app -- --check` | no output (clean) |
| Rust clippy | `pnpm moon run kuku-ai:lint-check` | **RED, pre-existing**: `error: the Err-variant returned from this function is very large` x80, all in `crates/kuku-contract/src/generated/connect/*.rs`; `could not compile kuku-contract` |
| Desktop vitest | `pnpm moon run desktop:test-ts` | `Test Files 80 passed (80)` / `Tests 451 passed (451)` |
| Web vitest | `pnpm moon run web:test` | passed (Duration 167ms) |
| Desktop TS lint | `pnpm moon run desktop:lint-ts-check` | clean |
| Desktop TS format | `pnpm moon run desktop:format-ts-check` | **RED, pre-existing**: `src/plugins/builtin/mermaid/runtime_cache.ts` needs formatting (1 file) |

Both pre-existing reds are upstream state on a newer toolchain than upstream pins. They are fixed in Wave 0 so that every later wave has a green gate to regress against.

Live provider facts captured for tests:
- Ollama at `http://127.0.0.1:11434/v1` serves `qwen3.5:4b`; a non-streaming chat completion with a `list_files` tool returned `finish_reason: tool_calls`, `tool_calls[0].function.name == "list_files"`, and `usage.total_tokens == 359`. Streaming chunks carry a non-standard `delta.reasoning` field before content.
- Ollama also answers `POST /v1/responses` with HTTP 200 and a `reasoning` output item first.
- The vault key `OPENAI_API_KEY` exists and is exported (164 chars). `GET /v1/models` on api.openai.com listed 138 models including `gpt-5-mini` and `gpt-5-nano`.

---

## 2. Current architecture the change plugs into

- `crates/kuku-ai/src/provider/mod.rs` defines `CompletionBackend { stream_turn, list_models }`, `CompletionTurnRequest { model, system_prompt, messages, tools, authorization_header }`, and `CompletionEvent { TextDelta, ToolCalls, Finished { finish_reason, usage } }`. The session loop (`session.rs::run_turn_inner`) is provider-agnostic except for two `ProviderKind::Remote` branches (authorization header, 401 retry).
- `provider/gemini.rs` (325 lines) is the reference implementation: rig `gemini::Client`, `split_history`, `into_rig_message` (tool result and tool call ID round-trip, opaque signature bytes), `tool_definition_from`, `into_token_usage`, an `async_stream!` adapter that guarantees exactly one `Finished`, and three `#[test]`s.
- `state.rs::build_backend` matches `ProviderKind` and constructs the backend; `types.rs::AiConfig` is the serde config that the frontend sends via `plugin:kuku-ai|ai_set_config`.
- Frontend: `apps/desktop/src/plugins/builtin/ai_chat/{config.ts,types.ts,chat_store.ts,chat_panel.tsx,components/ai_settings.tsx}`. Secrets are stored through `plugin_save_settings_with_secrets` with `AI_CHAT_SECURE_KEYS = ["apiKey"]` (keychain via `plugin_secrets.rs`). `loadConfig()` pins `model` to `DEFAULT_MODEL` on every load (that pin must become provider-aware).
- i18n: `src/i18n/keys.ts` is the canonical key list; `__tests__/catalog.test.ts` already fails if any of en/ja/ko lacks a key or has an empty value.

---

## 3. Design decisions (each one is a review target)

D1. **Provider identity.** `ProviderKind::OpenAi` with `#[serde(rename = "openai")]`; TS `AiProvider = "gemini" | "remote" | "openai"`. Exhaustive `match`/`switch` everywhere a provider is branched on (compiler-enforced in Rust; a `never`-typed default in TS).

D2. **Config shape (flat, because secure keys are top-level names in the settings store).** `AiConfig` gains, all `#[serde(default)]` so existing saved configs deserialize unchanged:
- `openai_api_key: Option<String>` (secure key `openaiApiKey`, separate from the Gemini `apiKey` so switching providers never leaks one key into the other),
- `openai_base_url: Option<String>` (default `https://api.openai.com/v1`),
- `openai_model: Option<String>` (user-typed; no build-time pin),
- `openai_api: OpenAiApi` enum `{ Responses, ChatCompletions }` with `#[serde(rename_all = "snake_case")]`, default `Responses` when the base URL host is `api.openai.com`, else `ChatCompletions`. The user can override in settings.
The top-level `model` keeps its meaning (the model sent on the wire) and is derived per provider: `modelForProvider(provider, raw)` returns the pinned Gemini/remote default or the saved `openaiModel`.

D3. **Backend.** `provider/openai.rs`, `OpenAiBackend::new(api_key, base_url, model, api)`. Uses `rig::providers::openai::Client::builder().api_key(key).base_url(url).build()`; for `ChatCompletions` it calls `.completions_api()` first. Empty API key for local servers is sent as the literal `"local"` (many compatible servers reject an empty bearer; none reject a dummy). Base URL normalized: trim, strip trailing `/`, append `/v1` if the path is empty (test-covered).

D4. **Stream adapter parity.** Same contract as Gemini: emit `TextDelta` for text, one `ToolCalls` per complete tool call (`call_id` = provider call id, `tool_call_id` = item id where the Responses API distinguishes them, `signature: None`), ignore reasoning and tool-call deltas, exactly one `Finished` with `FinishReason::ToolCalls` if any tool call was seen, `usage` mapped from rig's `Usage` (input, output, total, cached input). If the stream ends without a final chunk, synthesize `Finished { usage: None }` exactly like Gemini.

D5. **Errors.** Map rig `CompletionError::HttpError` with status 401/403 to `AiError::Unauthorized` and 429 to `AiError::ProviderError("rate limited: ...")`; everything else stays `ProviderError`. The session's 401 retry remains Remote-only (there is no token to refresh for BYOK), which is today's Gemini behaviour. `AiError::NotConfigured`'s message becomes provider-neutral: "AI is not configured. Choose a connection in Settings and add its API key or model."

D6. **Model discovery.** New Tauri command `ai_list_models` (add to `COMMANDS` in `build.rs` and `generate_handler!`) calling `CompletionBackend::list_models`. For OpenAI it does `GET {base_url}/models` with the bearer key and returns sorted ids; Gemini/Remote keep their static lists. Frontend: a "Load models" button next to the model field that fills a `<datalist>`; failure shows the error inline. This doubles as the "test connection" affordance. Requires `reqwest` as a direct dependency of `kuku-ai` with the same features rig uses (`rustls-tls`, `json`, `stream`), so `Cargo.lock` does not gain a second reqwest.

D7. **Frontend readiness.** Extract the three predicates in `chat_panel.tsx` (`isApiKeyMissing`, `needsRemoteLogin`, `needsRemotePermission`) into `provider_readiness.ts` as pure functions of `(config, auth)` so they are unit-testable; add `openai` rules: key missing only when the base URL host is `api.openai.com`; model missing is always blocking.

D8. **Settings UI.** Third connection option "OpenAI-compatible API key". Rows: Base URL (text, placeholder api.openai.com, helper text listing Ollama/LM Studio/mlx examples), API key (secure, show/hide, optional for local servers), Model (text + datalist + Load models), API flavor (select, two options). Info banner with three steps. `shortModelLabel` returns the raw id for non-Gemini models.

D9. **i18n.** Every new string is a key in `keys.ts` with en/ja/ko values (ja/ko translated, not copied). Estimated 16 keys. `catalog.test.ts` enforces completeness.

D10. **Fork release identity.** New `apps/desktop/src-tauri/tauri.h4.conf.json` merged over `tauri.conf.json`: same `identifier` `mom.kuku.app` and `productName` `Kuku` (so `~/.kuku` and the `kuku://` auth scheme are unchanged), `version` `0.5.8-h4.1` (scheme: `<upstream>-h4.<n>`, valid semver, orders below the next upstream release, which never matters because the updater is neutralized), `bundle.targets: ["app"]`, `bundle.createUpdaterArtifacts: false` (no minisign key needed), `plugins.updater.endpoints: ["https://raw.githubusercontent.com/horizonthinking/kb-app/main/release/h4-release.json"]`. That file is committed in this repo with `"version": "0.5.8-h4.1"` **and a real `darwin-aarch64` platform entry** (`{"url": "https://github.com/horizonthinking/kb-app/releases", "signature": "unused: this manifest never advertises a newer version"}`). Verified in vendored `tauri-plugin-updater-2.10.1/src/updater.rs:530-538`: `check()` computes `should_update` (line 530) but calls `get_urls()` (line 536) **before** testing it (line 538), and `get_urls` errors with `TargetsNotFound` when neither `darwin-aarch64-app` nor `darwin-aarch64` is present. So an empty `platforms` map would surface as the red error pill (v1 of this plan got that wrong); with the entry present and an equal version, `check()` returns `Ok(None)` and the indicator stays `idle`. The URL and signature strings are never fetched because `should_update` is false. CLAIM C-UPD below is now stated in that corrected form and the mentee still confirms it by test.

D11. **Signing and publishing** follow the Adapt precedent exactly: build unsigned on 27-mac-mini (it has cargo, node, pnpm, Xcode 27, the Developer ID identity and the ASC key `AuthKey_CABZCFW333.p8`), then in one `gui/$UID` one-shot LaunchAgent deep-sign with `Developer ID Application: Michael Anthony Smith (8P9788YC9P)` + hardened runtime + `src-tauri/entitlements.plist`, notarize with notarytool (ASC key), staple, build a UDZO DMG, sign, notarize and staple the DMG. Publish `Kuku-<version>.dmg` to a GitHub Release tagged `kuku-v<version>` on `horizonthinking/homebrew-h4`; cask `Casks/kuku.rb` (source of truth in `~/projects/h4/deploy/homebrew-tap/Casks/kuku.rb`, mirrored into the tap clone) using `H4PrivateGitHubReleaseDownloadStrategy`. Scripts live in this repo under `scripts/h4/` to stay clear of upstream files.

D12. **Spend.** Parity tests run against Ollama (free). Exactly one scripted smoke turn runs against api.openai.com with `gpt-5-nano` (cheapest listed) to prove real-OpenAI connectivity; nothing else calls a billed API. The goal statement is the specific authorization for that call.

---

## 4. Feature-parity matrix (Gemini today vs OpenAI target) with the test that proves each row

| # | Capability | Gemini today | OpenAI target | Proof |
|---|---|---|---|---|
| P1 | Streaming text deltas | rig `StreamedAssistantContent::Text` | same via rig openai | live test asserts >= 1 `TextDelta` before `Finished` |
| P2 | Tool calls, native + proxy | `ToolCalls` event, IDs round-tripped | same; IDs from Responses `call_id`/`id` or chat `tool_calls[].id` | unit: `into_rig_message` ID tests (mirrors gemini.rs); live: tool round-trip with `list_files` |
| P3 | Multi-round agent loop to `round_limit` | session.rs, provider-agnostic | unchanged | existing `session::tests` + live 2-round turn |
| P4 | Approval-gated mutations | `MutationPlan` path, provider-agnostic | unchanged | existing tests; manual proof in Wave 5 |
| P5 | Ask / Agent / Inline modes | prompt + tool gating | unchanged | existing tests |
| P6 | History compaction | provider-agnostic | unchanged | existing `compact_history_*` tests |
| P7 | Token usage in `DonePayload` | mapped from rig | mapped from rig `Usage` (incl. cached) | unit `into_token_usage`; live asserts `usage.is_some()` |
| P8 | Exactly one `Finished`, synthesized if absent | yes | yes | unit test with a hand-built stream (see T-R6) |
| P9 | Model selection | pinned default, 3 static ids | free text + `ai_list_models` | unit + live `list_models` returns >= 1 |
| P10 | Secure key storage | `apiKey` via keychain | `openaiApiKey` via keychain | `chat_store.test.ts` save/clear paths |
| P11 | Settings UI + i18n (en/ja/ko) | yes | yes | `catalog.test.ts`, `config.test.ts`, `provider_readiness.test.ts` |
| P12 | Chat panel readiness banners | key-missing banner | key/model-missing banners | `provider_readiness.test.ts` |
| P13 | Error surfacing to UI | `ErrorPayload` | 401/429 mapped | unit `map_completion_error` |
| P14 | Reset / clear persisted config | clears `apiKey` | clears both secure keys | `chat_store.test.ts` |
| P15 | Backward-compatible saved config | n/a | old JSON without new fields loads | unit `ai_config_deserializes_without_openai_fields` |
| P16 | Compatible providers (non-OpenAI hosts) | n/a | base-URL normalization, dummy key, chat-completions flavor | unit + live (Ollama) |

---

## 5. Test pre-plan (written before code; names are binding)

Conventions observed and followed: Rust tests are inline `#[cfg(test)] mod tests` with plain `#[test]` (async via `tokio::runtime::Runtime` where needed, as no `#[tokio::test]` exists in the crate today), Go-style env-gated integration tests (`t.Skip` unless `KUKU_TEST_*`), vitest files colocated as `*.test.ts` with `vi.mock("@tauri-apps/api/core")` and `vi.resetModules()` per import, snake_case filenames.

### 5.1 Rust, `crates/kuku-ai`
- `src/provider/openai.rs::tests`
  - T-R1 `tool_result_uses_original_tool_call_ids` (mirror of gemini)
  - T-R2 `tool_result_without_provider_call_id_still_uses_tool_call_id`
  - T-R3 `assistant_tool_call_round_trips_ids_without_signature`
  - T-R4 `normalize_base_url_appends_v1_and_strips_trailing_slash` (cases: `https://api.openai.com`, `http://127.0.0.1:11434/`, `http://127.0.0.1:11434/v1/`, `https://openrouter.ai/api/v1`)
  - T-R5 `default_api_flavor_is_responses_only_for_openai_host`
  - T-R6 `adapter_synthesizes_finished_when_stream_ends_early` and `adapter_reports_tool_calls_finish_reason` using a hand-built `Vec<Result<StreamedAssistantContent, _>>` stream fed through the same adapter function the backend uses (factor the adapter into `adapt_stream(impl Stream) -> CompletionTurnStream` so it is testable without a network).
  - T-R7 `into_token_usage_maps_cached_input_tokens`
  - T-R8 `map_completion_error_classifies_401_403_429`
  - T-R9 `empty_api_key_uses_local_placeholder`
- `src/types.rs::tests`
  - T-R10 `provider_kind_openai_serializes_as_openai`
  - T-R11 `ai_config_deserializes_without_openai_fields` (JSON from before this change)
- `src/state.rs::tests`
  - T-R12 `build_backend_openai_requires_model` (returns `Ok(None)` when model empty; `Some` when base URL + model present and key empty)
- `crates/kuku-ai/tests/openai_compatible_live.rs` (integration, env-gated exactly like the Go server's `KUKU_TEST_DATABASE_URL`):
  - skips (prints `skipped: KUKU_TEST_OPENAI_BASE_URL unset`) unless `KUKU_TEST_OPENAI_BASE_URL` is set; optional `KUKU_TEST_OPENAI_API_KEY`, `KUKU_TEST_OPENAI_MODEL` (default `qwen3.5:4b`), `KUKU_TEST_OPENAI_API` (`responses|chat_completions`).
  - T-L1 `streams_text_and_single_finished`: user prompt "Reply with exactly: pong"; asserts count(TextDelta) >= 1, count(Finished) == 1, `finish_reason == Stop`, `usage.is_some()`.
  - T-L2 `streams_tool_call_for_list_files`: one `list_files` descriptor; asserts count(ToolCalls) == 1, tool name == `list_files`, `finish_reason == ToolCalls`.
  - T-L3 `list_models_returns_at_least_one`.
  - Regression command, documented in AGENTS.md: `KUKU_TEST_OPENAI_BASE_URL=http://127.0.0.1:11434/v1 cargo test -p kuku-ai --test openai_compatible_live -- --nocapture`.

### 5.2 TypeScript, `apps/desktop`
- `src/plugins/builtin/ai_chat/config.test.ts` (new)
  - T-T1 `normalizes openai provider with defaults` (baseUrl default, api flavor default by host, model preserved)
  - T-T2 `derives top-level model from openaiModel for openai and pins default for gemini/remote`
  - T-T3 `keeps legacy configs without openai fields loadable`
  - T-T4 `rejects unknown provider values to the default`
- `src/plugins/builtin/ai_chat/chat_store.test.ts` (extend, same mocking style)
  - T-T5 `loads openai settings without pinning the model to the build default`
  - T-T6 `saves openai config with both secure keys and syncs runtime config` (asserts the `plugin_save_settings_with_secrets` call carries `secureKeys: ["apiKey","openaiApiKey"]` and `ai_set_config` receives `provider: "openai"`)
  - T-T7 `clearPersistedConfig clears both secure keys`
- `src/plugins/builtin/ai_chat/provider_readiness.test.ts` (new): T-T8..T-T11 covering gemini key missing, openai key missing only for api.openai.com host, openai model missing, remote login/permission unchanged.
- `src/plugins/builtin/ai_chat/components/model_label.test.ts` (new, after extracting `shortModelLabel`): T-T12 gemini labels unchanged, openai ids pass through.
- `src/i18n/__tests__/catalog.test.ts`: unchanged, must stay green with the new keys.
- `chat_store.test.ts` also gains T-T13 `ai_list_models results populate the model suggestions`.

### 5.3 Commands that must be green after every wave
`pnpm moon run kuku-ai:test kuku-ai:lint-check kuku-ai:format-check desktop:test-ts desktop:lint-ts-check desktop:format-ts-check desktop:test-rust desktop:lint-rust-check desktop:format-rust-check web:test`, plus the live test against Ollama.

---

## 6. Work breakdown (OMSV waves; each wave ends with the mentee's claim validation and the overseer's audit)

### Wave 0, baseline hygiene (tiny, separate commit)
- `crates/kuku-contract/src/lib.rs`: add `#![allow(clippy::result_large_err)]` with a comment (generated Connect code; upstream lints nothing in this crate). Re-run `kuku-ai:lint-check` and `desktop:lint-rust-check`: expected green.
- `apps/desktop/src/plugins/builtin/mermaid/runtime_cache.ts`: `oxfmt --write` that one file. Expected `desktop:format-ts-check` green.
- Acceptance: all commands in 5.3 green (live test not yet present). Commit `chore: make lint and format gates green on the current toolchain`.

### Wave 1, Rust backend
- Files: `crates/kuku-ai/Cargo.toml` (+reqwest), `src/types.rs` (ProviderKind, AiConfig fields, OpenAiApi), `src/provider/mod.rs` (`pub mod openai`), `src/provider/openai.rs` (new), `src/state.rs` (build_backend arm), `src/error.rs` (message, `map_completion_error`), `src/commands.rs` + `src/lib.rs` + `build.rs` COMMANDS (`ai_list_models`), tests T-R1..T-R12, `tests/openai_compatible_live.rs` T-L1..T-L3.
- The desktop crate's `generate_handler!` in `apps/desktop/src-tauri/src/lib.rs` does not list plugin commands (they are registered by `kuku_ai::init()`), so no change there; the mentee confirms by grep.
- Acceptance: unit tests pass; live tests pass against Ollama with both API flavors; `cargo clippy -p kuku-ai --all-targets -- -D warnings` clean.

### Wave 2, frontend
- Files: `types.ts`, `config.ts`, `chat_store.ts` (loadConfig/saveConfig/clearPersistedConfig, `listModels()` action), `provider_readiness.ts` (new) + `chat_panel.tsx` wiring, `components/ai_settings.tsx`, `components/model_label.ts` (extracted), `index.ts` description ("Chat with your AI provider from the right panel"), `src/i18n/keys.ts` + `locales/{en,ja,ko}.ts`, tests T-T1..T-T13.
- Acceptance: `desktop:test-ts`, `desktop:lint-ts-check` (type-aware), `desktop:format-ts-check` green; `tsc && vite build` green.

### Wave 3, docs, fork build config, packaging scripts
- `apps/desktop/src-tauri/tauri.h4.conf.json` (D10), `release/h4-release.json`, moon task `desktop:tauri-build-h4` in `apps/desktop/moon.yml` (env `VITE_KUKU_API_URL`/`KUKU_API_URL` = prod, `--config src-tauri/tauri.h4.conf.json`), `scripts/h4/build_h4.sh` (pnpm install, moon build, prints the .app path), `scripts/h4/sign_notarize_dmg.sh` (Adapt pattern, parameterized for Kuku.app + `src-tauri/entitlements.plist`), `scripts/h4/release_h4.sh` (driver: preconditions, ssh to build host, LaunchAgent, scp DMG back, sha256, publish), and in `~/projects/h4`: `deploy/homebrew-tap/Casks/kuku.rb` + `deploy/homebrew-tap/publish_kuku_cask.sh` (copy of the Adapt publisher with names swapped).
- Docs: `AGENTS.md` (providers section, live-test command, fork release procedure), `crates/kuku-ai/README.md` (provider list), `docs/development.md` (one line on the OpenAI-compatible option and the live test).
- Acceptance: `bash -n` on every script; `--dry-run` of the release driver prints the full plan; `tauri build --config tauri.h4.conf.json` on this Mac produces `target/release/bundle/macos/Kuku.app` that launches.

### Wave 4, release (overseer-driven; needs the GUI LaunchAgent on 27-mac-mini)
1. Merge `feat/openai-provider` to `main`, push.
2. On 27-mac-mini: `git pull`, `pnpm install --frozen-lockfile`, `pnpm moon run desktop:tauri-build-h4` (unsigned).
3. One `gui/$UID` LaunchAgent runs `scripts/h4/sign_notarize_dmg.sh target/release/bundle/macos/Kuku.app release-artifacts/h4/`; poll `launchctl print` for the exit code; require 0 and `Gatekeeper ACCEPTED`.
4. `scp` the DMG here; verify sha256 equals the remote's; `spctl -a -t open --context context:primary-signature -vv Kuku.dmg` accepts.
5. `publish_kuku_cask.sh 0.5.8-h4.1 <sha> Kuku-0.5.8-h4.1.dmg`: release `kuku-v0.5.8-h4.1` on homebrew-h4, cask rewritten in both places, tap pushed, monorepo committed and pushed.

### Wave 5, install and prove on three Macs
- On each of laptop-m3, 27-mac-mini, home-mac-mini: `brew trust horizonthinking/h4` (already tapped on all three), `HOMEBREW_GITHUB_API_TOKEN="$(gh auth token)" brew install --cask kuku` (fall back to `h4 env get GITHUB_PAT` where `gh` is not logged in), then `brew list --cask kuku`, `codesign -dvvv /Applications/Kuku.app` (expect `Authority=Developer ID Application`, `TeamIdentifier=8P9788YC9P`, `flags=0x10000(runtime)`), `spctl -a -vv -t exec /Applications/Kuku.app` (accepted, source=Notarized Developer ID), `xcrun stapler validate`, `open -a Kuku` then after 10 s `pgrep -x Kuku` returns one pid and `lsappinfo info -only pid,bundleid <pid>` shows `mom.kuku.app`.
- On this Mac additionally: configure Settings → AI Chat → OpenAI-compatible with Ollama, run an Agent-mode turn that lists vault files (tool round trip) and a real-OpenAI smoke with `gpt-5-nano` (D12); screenshot of the chat panel + settings; the live-test output block.

---

## 7. Definition-of-Done proof (the 5-item contract)

1. Ground truth: section 1 of this document (verbatim, captured before the run).
2. Observed values: every command in 5.3 re-run on the final `main` with output pasted verbatim into `docs/plans/2026-09-11-openai-provider-proof.md`; install checks from Wave 5 pasted per machine.
3. Expected-vs-observed table: one row per parity item P1..P16 and per Wave 5 check on each of the three Macs; a missing row is a failure.
4. Visual artifact: screenshots of the settings pane (OpenAI selected, models loaded) and of an Agent turn with a tool call and an approval diff, saved under `docs/plans/proof/`; the DMG notarization log excerpt; `brew list --cask` output per Mac.
5. Explicit unknowns: listed in the proof file (at minimum: Windows/Linux untested; LM Studio and mlx_lm.server only spot-checked if time permits; ja/ko translations machine-drafted, not native-reviewed).

Banned words apply: nothing is called done, verified or fixed without the row that proves it.

---

## 8. Doc-cleansing plan (ships with the change, not later)

| Artifact | Edit |
|---|---|
| `AGENTS.md` | Architecture: providers are Remote, Gemini, OpenAI-compatible; add the live-test regression command; add "Fork release (H4 tap)" section pointing at `scripts/h4/`. |
| `crates/kuku-ai/README.md` | List the three provider adapters and the `openai_compatible_live` test. |
| `crates/kuku-ai/src/error.rs` | Provider-neutral `NotConfigured` message (the string "Set a Gemini API key first" is stale once there are two BYOK providers). |
| `apps/desktop/src/plugins/builtin/ai_chat/index.ts` | Plugin description no longer names Gemini. |
| `docs/development.md` | One paragraph: OpenAI-compatible provider, Ollama example, live test env vars. |
| `apps/desktop/src/i18n/locales/*.ts` | Existing `gemini_banner` / `api_key` copy stays Gemini-specific (it is under the Gemini branch); new keys are OpenAI-specific. No shared string may say "Gemini" when shown for the OpenAI provider (`api_key.label` is currently "Gemini API key" and is reused: split into `api_key.label_gemini` and `api_key.label_openai`). |
| `~/projects/h4/deploy/homebrew-tap/README.md` | Add the `kuku` cask row and its tag namespace `kuku-v<version>`. |
| This plan | Superseded sections are struck, never deleted; the proof file is appended, not merged in. |

No document may describe current state (hosts, versions) except the proof file, which is dated.

---

## 9. Sustainability and enforcement plan (deterministic where possible)

| Mechanism | Type | What it catches |
|---|---|---|
| Exhaustive `match config.provider` in Rust (`build_backend`, `session.rs`, `list_models`) | compiler, blocking | a new provider that forgets a code path |
| `assertNever(provider)` default branches in `modelForProvider`, `providerReadiness`, `ai_settings` option list derived from a single `AI_PROVIDERS` const | tsc via `lint-ts-check --type-check`, blocking | same, on the TS side |
| `catalog.test.ts` | vitest in `desktop:check`, blocking | a locale missing a key or an empty string |
| T-R11 / T-T3 legacy-config tests | unit, blocking | a config field added without `#[serde(default)]` |
| `tests/openai_compatible_live.rs` + `scripts/h4/verify_ai_provider.sh` (runs it against Ollama, fails if Ollama is down rather than skipping) | pre-release gate in `release_h4.sh` preconditions, blocking | a provider regression before anything is published |
| `release_h4.sh` fail-closed preconditions: clean tree, on `main`, gates in 5.3 green, `release/h4-release.json` version == `tauri.h4.conf.json` version | script, blocking | shipping from a dirty or red tree, updater manifest drift |
| `publish_kuku_cask.sh` refuses a sha256 that does not match the DMG it uploads | script, blocking | cask pointing at the wrong artifact |
| AGENTS.md documents the one regression command | prose, weakest | forgotten live test (backed by the script above) |

---

## 10. OMSV protocol for this work

- **Overseer** (Claude, this session): frames the work, owns this plan, runs every audit, holds the final 5-item proof, drives Wave 4/5 (GUI LaunchAgent, ssh to the minis).
- **Mentor** (Claude): authored this plan and the draft claims in section 11. Claims are unproven until the mentee confirms them at a green point.
- **Mentee** (Codex, via `H4_CODEX_RUN_ID=$(uuidgen) bash ~/projects/h4/scripts/codex_exec_guard.sh exec ...`, in the worktree `~/projects/apps/kb-app-worktrees/openai-provider` on branch `feat/openai-provider`, sandbox `workspace-write` with `-c sandbox_workspace_write.network_access=true` so cargo can fetch): implements one wave per dispatch, runs the wave's gates, and returns a `WAVE_REPORT.md` with: files touched, verbatim gate output, and a claim table (CONFIRMS / CONTRADICTS / MISSING-LESSON + evidence) for every claim in section 11 that the wave touches. The mentee may REJECT a claim; a contradicted claim blocks the wave until the plan is amended.
- **Adversarial review loop (before Wave 0):** Codex reviews this document read-only and returns JSON `{verdict: "AGREE"|"REVISE", blocking: [...], major: [...], minor: [...]}`. The overseer amends the plan for every blocking and major finding (or records a written rejection with rationale) and re-submits. Loop until `AGREE` or four rounds, after which unresolved items are listed in the plan as accepted risks with rationale.
- **Audit per wave:** overseer re-runs the wave's gates independently, diffs the branch, checks every claim row against the evidence, and only then dispatches the next wave.

---

## 11. Draft claims (unvalidated until the mentee confirms with compile facts)

- C-RIG1: `rig::providers::openai::Client::builder().api_key(k).base_url(u).build()` compiles against rig-core 0.32.0 and yields a client whose `completion_model(id)` streams with tools via the Responses API.
- C-RIG2: `client.completions_api().completion_model(id)` yields the Chat Completions variant with the same `stream()` surface, and `StreamedAssistantContent::{Text, ToolCall, ToolCallDelta, Reasoning, ReasoningDelta, Final}` are the same enum variants Gemini already matches on.
- C-RIG3: rig's `Usage` for OpenAI populates `cached_input_tokens` from `prompt_tokens_details.cached_tokens` (Chat) / `input_tokens_details.cached_tokens` (Responses).
- C-RIG4 (sharpened in v2): on the STREAMING path, which is the only path `stream_turn` uses, rig's `http_client` returns `Error::InvalidStatusCodeWithMessage(StatusCode, String)` for any non-2xx (`src/http_client/mod.rs:146-384`), wrapped as `CompletionError::HttpError`, so 401/403/429 are classified by matching the `StatusCode` value, never by substring. On the non-streaming path rig returns `CompletionError::ProviderError(body_text)` without a status (`providers/openai/completion/mod.rs:1266`, `responses_api/mod.rs:1206`); `list_models` does not go through rig at all (own reqwest call, status read directly). The classifier's unit test constructs `HttpError(InvalidStatusCodeWithMessage(StatusCode::UNAUTHORIZED, ..))` directly.
- C-OLL1: Ollama's `/v1/chat/completions` stream delivers tool calls in a form rig's Chat streaming parser assembles into one `ToolCall` (the earlier curl probe showed `finish_reason: tool_calls` non-streaming; streaming assembly is the claim).
- C-OLL2: Ollama's non-standard `delta.reasoning` field does not break rig's chat streaming deserializer (unknown fields ignored).
- C-OLL3: Ollama's `/v1/responses` implementation works with rig's Responses streaming parser for text and tool calls; if it does not, the default flavor for non-OpenAI hosts stays `ChatCompletions` and the plan records the limitation.
- C-CFG1: adding `#[serde(default)]` fields to `AiConfig` keeps every previously saved config loading (T-R11).
- C-SEC1: `plugin_save_settings_with_secrets` handles two secure keys with no Rust change (`strip_secure_values_for_save` iterates the list).
- C-CMD1: adding `ai_list_models` requires updating `COMMANDS` in `crates/kuku-ai/build.rs` and the `generate_handler!` in `crates/kuku-ai/src/lib.rs`, and the desktop crate needs no change; the plugin's default permission set (`permissions/default.toml` or generated) must allow the new command or the frontend gets "not allowed".
- C-UPD (corrected in v2): `tauri-plugin-updater` 2.10.1 `check()` calls `get_urls()` before it tests `should_update`, so the manifest MUST carry a `darwin-aarch64` entry with `url` and `signature` strings; given that entry and a manifest `version` equal to the running version, `check()` returns `Ok(None)` and the updater store stays `idle`. Proven by a Rust unit test in the desktop crate that deserializes `release/h4-release.json` into the plugin's `RemoteRelease` shape and asserts the target key is present, plus the Wave 5 observation that a fresh install shows no updater pill.
- C-BLD1: `tauri build --config src-tauri/tauri.h4.conf.json` with `createUpdaterArtifacts: false` and no `APPLE_SIGNING_IDENTITY` produces an unsigned or ad-hoc-signed `Kuku.app` that a later deep `codesign --force` can re-sign with the hardened runtime and `entitlements.plist` and that then passes notarization.
- C-BLD2: 27-mac-mini's Homebrew `cargo 1.98.0` (no rustup) builds the Tauri app for `aarch64-apple-darwin` without a rustup target install.
- C-TAP1: the private cask pattern (`H4PrivateGitHubReleaseDownloadStrategy`, `HOMEBREW_GITHUB_API_TOKEN`) installs `Kuku.app` on a Mac where `gh auth token` is valid; on a Mac where it is not, `h4 env get GITHUB_PAT` is the sanctioned substitute.

---

## 12. Risks and accepted decisions

- R1 Billed API use: one `gpt-5-nano` smoke turn plus one `/v1/models` listing; everything else local. Accepted by the goal statement.
- R2 Reasoning models: `gpt-5*` may return no text for a tool-only round; the adapter must not treat "no TextDelta" as an error (already true for Gemini).
- R3 Local servers without tool support: the UI cannot detect it; the model simply answers in prose. Documented in the banner text.
- R4 Upstream merge friction: all fork-only files live under `scripts/h4/`, `release/`, `tauri.h4.conf.json`, and the plan directory; shared-file edits are minimal and idiomatic so they could be upstreamed.
- R5 Keychain/GUI: signing only works inside the GUI LaunchAgent on the mini; if 27-mac-mini has no console session the driver stops with a clear message and the fallback host is home-mac-mini (needs `cargo` installed there first).
- R6 The `h4-release.json` manifest must be bumped in the same commit as the version, enforced by the release-script precondition.

## 13. Rollback

- Code: revert the merge commit of `feat/openai-provider`; saved configs with `provider: "openai"` fall back to the default provider through `normalizeAiConfig`.
- Tap: `brew uninstall --cask kuku` on each Mac; delete the `kuku-v<version>` release and revert `Casks/kuku.rb` in the tap and the monorepo. User data in `~/.kuku` is never touched by uninstall (the cask has no `zap` for it).
