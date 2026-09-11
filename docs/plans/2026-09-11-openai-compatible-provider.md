# OpenAI-compatible AI provider for Kuku desktop, with full Gemini parity

Status: DRAFT v5, 2026-09-11. Author: Claude (mentor/overseer). Reviewer: Codex (adversarial, iterative, on 27-mac-mini). Implementer: Codex (OMSV mentee, on 27-mac-mini).
Repo: `horizonthinking/kb-app` (fork of `kuku-mom/kuku`). Implementation base: `main` at `458f34b` (last code commit; later commits on `main` are this plan and its proof file). Branch `feat/openai-provider`. Companion proof file: `docs/plans/2026-09-11-openai-provider-proof.md` (all dated, machine-specific observations live there).

Changelog: v1 initial. v2 author's own source corrections. v3 dispositions for review round 1 (scope narrowed to Chat Completions). v4 dispositions for review round 2 (section 14): production `tool_choice` path, cached-token mapping from the concrete streaming response, updater proof bound to the moon task and the built bundle, tap bootstrap with the SSH URL, single release entry point, h4 worktree for the cask work, shared draft ownership in the store, full goal quotation, proof file committed. v5 dispositions for review round 3: updater guarded at the action boundary, two-tier error classifier proven through a stub server on the real streaming path, `settingsDraft` naming, explicit promotion wave and versioned release command, post-publication cask commit, marker consumed in the About pane, sections 10 and 11 made self-contained.

Out of scope, explicitly: any Codex app-server provider (upstream `codex-cli-poc`), the Go server's hosted AI path (`apps/server/internal/ai`, Gemini-only, untouched), the OpenAI Responses API (deferred, Action `9055402d`, section 12 R7), Windows/Linux packaging, the AI widgets plugin.

---

## 0. One-paragraph summary

Add `ProviderKind::OpenAi` to `crates/kuku-ai`, backed by `rig-core 0.32`'s OpenAI provider in Chat Completions mode (`client.completions_api()`), reachable at any base URL that implements streaming `POST /v1/chat/completions` with tools. It must do everything the desktop Gemini provider does today: streaming text, native and proxy tool calls whose IDs survive a second turn, the multi-round agent loop, approval-gated mutations, the three chat modes, history compaction, token usage, secure key storage, settings UI in three locales, and tests in the repo's style. Then ship it: a signed, notarized fork build in the private `horizonthinking/homebrew-h4` tap, installed and running on the laptop (laptop-m3), 27-mac-mini and home-mac-mini.

Supported-provider claim: **gated before publication** = api.openai.com (Chat Completions, `gpt-5-nano`, run by the release script from the laptop) and Ollama (`qwen3.5:4b`, run on the build host); **expected but not gated** = LM Studio, mlx_lm.server, OpenRouter and other servers implementing streaming Chat Completions with tools. The settings copy says exactly this.

---

## 1. Ground truth captured before any change

Verbatim command output, timestamps and the machine inventory are in the proof file, section A (committed with this plan). Summary of the eight gates at `458f34b`:

| Gate | Result |
|---|---|
| `cargo test -p kuku-ai` | 22 passed, 0 failed (A1) |
| `cargo test -p kuku-app` | 334 passed, 0 failed (A2) |
| `cargo fmt -p kuku-ai -p kuku-app -- --check` | exit 0, no output (A4) |
| `pnpm moon run kuku-ai:lint-check` | **RED, pre-existing**: 80 x `result_large_err` under `crates/kuku-contract/src/generated/connect/` (A3) |
| `pnpm moon run desktop:test-ts` | 80 files, 451 tests passed (A5) |
| `pnpm moon run web:test` | passed (A6) |
| `pnpm moon run desktop:lint-ts-check` | 343 files, 263 rules, no findings (A7) |
| `pnpm moon run desktop:format-ts-check` | **RED, pre-existing**: `src/plugins/builtin/mermaid/runtime_cache.ts` (A8) |

Both reds are upstream state on a newer toolchain and are fixed in Wave 0 so every later wave regresses against green. Live provider observations that shaped the tests are in proof A9.

---

## 2. Current architecture the change plugs into

- `crates/kuku-ai/src/provider/mod.rs`: `CompletionBackend { stream_turn, list_models }`, `CompletionTurnRequest { model, system_prompt, messages, tools, authorization_header }`, `CompletionEvent { TextDelta, ToolCalls, Finished { finish_reason, usage } }`. `session.rs::run_turn_inner` is provider-agnostic except two `ProviderKind::Remote` branches. The `provider` module is private to the crate (`lib.rs`), so live tests live inline.
- `provider/gemini.rs` (325 lines) is the reference; its three-way ID contract (`gemini.rs:82-99`): `call_id = internal_call_id`, `tool_call_id = Some(tool_call.id)`, `provider_call_id = tool_call.call_id`; `session.rs:392-404` replays them into `ToolResult`. `list_models` on the trait is `#[allow(dead_code)]` and unused.
- `state.rs::build_backend`, `types.rs::AiConfig`, secrets via `plugin_save_settings_with_secrets` (`plugin_settings.rs:75-116` iterates every secure key; `plugin_secrets.rs` + `variant.rs` derive service `mom.kuku.desktop.plugin-secrets`, account `ai-chat:openaiApiKey` for the new key).
- Frontend: `ai_settings.tsx` owns local signals and `isUnsaved` ignores `model`; `saveConfig(provider, apiKey, serverUrl)` rebuilds the config from three args; `AccessPrompt` (private in `chat_panel.tsx:14-20`) calls it when switching to Remote.
- Updater: `app.tsx:146-150` calls `checkForUpdates()` on every PROD launch; `updater.ts:84-97` maps failures to `status: "error"` (red pill); `window.__kukuUpdater` exists only under `import.meta.env.DEV`, so a production bundle cannot be inspected that way.
- i18n: `keys.ts` canonical; `catalog.test.ts` enforces structural parity across en/ja/ko. `docs/development.md` and `docs/development_ko.md` are a maintained pair.
- Tool schemas registered by the desktop crate contain optional properties; rig's Chat Completions conversion sends them unchanged with `strict: None` (`providers/openai/completion/mod.rs:351-362`); rig's Responses conversion forces `strict: true` and rewrites `required` (`responses_api/mod.rs:498-514`), which is why Responses is out of scope.
- rig's streaming Chat Completions path (`providers/openai/completion/streaming.rs:72-79`) maps prompt/output/total tokens but **not** `prompt_tokens_details.cached_tokens`; the non-streaming conversion (`completion/mod.rs:836-848`) does. The final streaming event carries the concrete `StreamingCompletionResponse` whose raw `usage` still has the details.
- Existing store tests live under `apps/desktop/src/stores/__tests__/`.

---

## 3. Design decisions

D1. **Provider identity.** `ProviderKind::OpenAi` (`#[serde(rename = "openai")]`); TS `AI_PROVIDERS = ["remote", "gemini", "openai"] as const` is the single source of the option list; exhaustive `match` in Rust, `assertNever` in TS.

D2. **Config shape (flat).** `AiConfig` gains `openai_api_key`, `openai_base_url`, `openai_model` (all `Option<String>`, `#[serde(default)]`). No API-flavor field. Top-level `model` is derived by `modelForProvider(provider, raw)`.

D3. **Backend.** `provider/openai.rs`, `OpenAiBackend::new(api_key: Option<&str>, base_url: &str, model: &str)`: `Client::builder().api_key(key).base_url(normalize_base_url(base_url)).build()?.completions_api()`, `completion_model(model)`. `normalize_base_url`: trim, strip trailing `/`, append `/v1` when the path is empty; **shared by chat and discovery**. **Authentication policy:** `key_requirement(host) -> Required | Optional`; Optional only for loopback (`localhost`, `127.0.0.0/8`, `::1`), RFC1918 (`10/8`, `172.16/12`, `192.168/16`), `*.local`, `*.ts.net` (suffix match on a dot boundary, so `evil-local` and `ts.net.example` are Required); when Optional and the key is empty, the literal `local` is sent because rig's builder needs a non-empty key. Public hosts (api.openai.com, openrouter.ai, everything else) require a key. Host classification fixtures are one shared JSON file (`crates/kuku-ai/fixtures/host_policy.json`) consumed by both the Rust and TS tests.

D4. **Stream adapter and request.** `CompletionTurnRequest` gains `tool_choice: ToolChoice` (`Auto | Required | None`, default `Auto`); the session always sends `Auto`; `OpenAiBackend` maps it to rig's `tool_choice(..)` on the request builder; `GeminiBackend` and `RemoteBackend` ignore it (documented). A pure `adapt_stream(...)` (shared by backend and tests) emits: `TextDelta` per text; one `ToolCalls` per complete `ToolCall` with the three-way ID mapping and `signature: None`; ignores `ToolCallDelta`, `Reasoning`, `ReasoningDelta`; exactly one `Finished` with `ToolCalls` if any tool call was seen; **usage from the concrete `Final(StreamingCompletionResponse)`'s raw `usage`, including `prompt_tokens_details.cached_tokens`** (the generic `GetTokenUsage` path loses it, section 2); a synthesized `Finished { usage: None }` if the stream ends without `Final`.

D5. **Errors (v5).** rig's reqwest client raises `http_client::Error::InvalidStatusCodeWithMessage(StatusCode, String)` for any non-2xx (`http_client/mod.rs:143-149, 381-387`), but the OpenAI Chat streaming adapter erases it: every SSE-path error is re-emitted as `CompletionError::ProviderError(error.to_string())` (`providers/openai/completion/streaming.rs:284-290`), whose text begins with rig's fixed Display prefix `Invalid status code <code> <reason> with message: ...` (`http_client/mod.rs:20-21`). `map_completion_error` therefore classifies in two tiers: (a) structured, `HttpError(InvalidStatusCode(s) | InvalidStatusCodeWithMessage(s, _))` by `StatusCode`; (b) textual, constrained to rig's own prefix: a `ProviderError(text)` matching `^Invalid status code (\d{3})\b` is classified by that three-digit code. 401/403 -> `Unauthorized`; 429 -> `ProviderError("rate limited: <text>")`; everything else `ProviderError`. The textual tier depends on rig 0.32's Display format, which is pinned by `Cargo.lock`; **the real streaming path is proven by stub-server tests** (T-R15) that call `OpenAiBackend::stream_turn` against a local listener answering 401, 403 and 429 and assert the exact `AiError` variant. `list_models` reads the status directly. Session 401 retry stays Remote-only. `NotConfigured` message: "AI is not configured. Choose a connection in Settings and add its API key or model."

D6. **Model discovery, standalone.** `pub(crate) async fn list_models(base_url, api_key: Option<&str>) -> Result<Vec<String>, AiError>` using reqwest `GET {normalize_base_url(base)}/models`, bearer only when a key is present, non-2xx -> `map_status(..)` (same 401/403/429 classes), ids deduplicated and sorted. Tauri command `ai_list_models(base_url, api_key) -> Result<Vec<String>, String>` (the repo's command convention). **`CompletionBackend::list_models` is removed from the trait and from `GeminiBackend`/`RemoteBackend`** (dead code). Registered in `build.rs` `COMMANDS`, `lib.rs` `generate_handler!`, `permissions/default.toml`. Dependency: `reqwest = { version = "0.13", default-features = false, features = ["rustls", "charset", "json", "stream"] }`: valid names for reqwest 0.13.4 and compatible with rig's own reqwest 0.13 features (feature unification keeps one build).

D7. **Frontend readiness.** `provider_readiness.ts`: pure `isApiKeyMissing`, `isModelMissing`, `needsRemoteLogin`, `needsRemotePermission` using `keyRequirementFor(baseUrl)` ported from D3 with the shared fixtures.

D8. **Settings state, owned by the store.** `chat_store.ts` already exports `setDraft(value: string)` and `session.draft` for the chat composer (`chat_store.ts:139, 595, 790`); those stay untouched. The settings state uses distinct names: `settingsDraft: AiSettingsDraft` (provider, apiKey, openaiApiKey, openaiBaseUrl, openaiModel, serverUrl) with exported `settingsDraftFromConfig(config)`, `setSettingsDraft(patch)`, `isSettingsDraftUnsaved()`, `saveSettingsDraft()`, `switchProviderAndSave(provider)`, `loadModelSuggestions()`. `AiSettings` binds its inputs to `settingsDraft` (no local signals for config fields); `AccessPrompt` calls `switchProviderAndSave("remote")`, which preserves every other field and both secrets. Rows for OpenAI: Base URL, API key (show/hide; required/optional label from `keyRequirementFor`), Model (text + `<datalist>` from `modelSuggestions` + "Load models", the connection test). Quick guide and chat setup prompt render from `settings_copy.ts` (`guideCopyFor`, `setupPromptFor`).

D9. **i18n.** New keys in `keys.ts` with en/ja/ko values; `api_key.label` split per provider; `catalog.test.ts` is structural; translation quality is an explicit unknown for human review.

D10. **Fork release identity and updater.** `tauri.h4.conf.json` merged over `tauri.conf.json`: identifier/productName inherited, `"version": "0.5.8-h4.1"`, `bundle.targets: ["app"]`, `bundle.createUpdaterArtifacts: false`. The updater is disabled at build time and **guarded at the action boundary, not at call sites** (there are two call sites today: `app.tsx:150` and the retry handler in `update_indicator.tsx:33`): moon task `desktop:tauri-build-h4` sets `VITE_KUKU_UPDATER=off`; `stores/updater.ts` defines `UPDATER_BUILD_MARKER` as `import.meta.env.VITE_KUKU_UPDATER === "off" ? "kuku-updater-disabled" : "kuku-updater-enabled"` and `isUpdaterEnabled()` derived from it; `checkForUpdates()` and `downloadAndInstall()` return immediately (state stays `idle`) when the updater is disabled, so no call site can reach the Tauri plugin. **Proof chain (three deterministic links):** (1) `src/stores/__tests__/updater.test.ts`: with `@tauri-apps/plugin-updater` mocked, `checkForUpdates()` and `downloadAndInstall()` under the disabled marker never call the mocked `check()`/`downloadAndInstall()` (call count == 0) and leave `status === "idle"`, and under the enabled marker they do call it (count == 1); (2) `src/stores/__tests__/updater_build_binding.test.ts` reads `apps/desktop/moon.yml` and asserts the `tauri-build-h4` task's env contains `VITE_KUKU_UPDATER: "off"`; (3) the marker is **consumed at runtime** by `components/settings/sections/about_section.tsx`, which renders the version line with the text of key `settings.about.updates_via_homebrew` when the marker is `kuku-updater-disabled` (so Rollup cannot tree-shake it; tested by T-T19), and Vite inlines the env while esbuild constant-folds the comparison, so the production bundle contains exactly one of the two literals (claim C-UPD2, validated by the mentee on the built bundle); `release_h4.sh` greps the built `Kuku.app`'s frontend assets and refuses to publish unless `kuku-updater-disabled` is present and `kuku-updater-enabled` is absent. The About pane screenshot documents the version line.

D11. **Signing and publishing.** Build unsigned on 27-mac-mini; sign/notarize/staple in one `gui/$UID` LaunchAgent (Adapt's script as structural reference; the Kuku copy also signs every Mach-O under `Contents/MacOS` and nested `.framework/.dylib/.bundle/.appex/.xpc/.app`); DMG create/sign/notarize/staple; publish to tag `kuku-v<version>` on `horizonthinking/homebrew-h4`; cask `Casks/kuku.rb` (source of truth in the h4 monorepo, mirrored to the tap clone). `publish_kuku_cask.sh` hashes the DMG itself and refuses a mismatching sha, refuses a dirty or diverged tap clone, syncs `git pull --ff-only`, rewrites `version`/`sha256` in **both** the h4 monorepo source cask and the tap clone, and then **commits and pushes each repository separately with `git add -A`** (the h4 monorepo checkout on the laptop, which is clean, and the tap clone under `~/projects/h4/live/homebrew-h4`), verifying afterwards that both committed files contain the exact version and sha; it has `--dry-run` and a temp-repo test. The final sha cannot exist before Wave 4, so Wave 3 commits the cask with placeholder `version "0.0.0"` / `sha256 "0"*64` and the publisher's post-publication commit is the durable record. **One entry point:** Wave 4 runs `scripts/h4/release_h4.sh 0.5.8-h4.1` and nothing else by hand; the script owns every precondition and step (section 6, Wave 4), including verifying that both `main` checkouts contain the reviewed commits.

D12. **Spend and authorization.** Michael's goal statement (2026-09-11), quoted in full: "please author an exhaustive plan to activate the openai api (to open ai and to other compliant api providers) with full gemini feature parity. Do not plan the codex work. Conduct iterative adversarial review of your plan with codex locally until the plan is agreed. oversee a codex OMSV implementation of the plan. Make sure the plan includes running existing/provided tests before and after development. Extend those tests (do the preplanning for tests during the planning phase and make sure the tests conform to the style of tests currently in the repo and can continue to be used for regression testing going forward. Dod is a test working app running locall yon this mac that is also signed and deployed into the h4 homebrew tap on github and that 27-mac-mini and home-mac-mini have an installed and working version of the app installed via the homebrew tap." This authorizes (a) direct calls to api.openai.com for this feature and (b) installation on 27-mac-mini and home-mac-mini. Bound for (a): model `gpt-5-nano`; the live test suite run once pre-publish by `release_h4.sh` from the laptop (T-L1 one request, T-L2 two requests, T-L3 one `GET /models`) plus one manual Ask turn in Wave 5: at most 4 chat-completion requests and 1 models listing, recorded in the proof.

---

## 4. Feature-parity matrix and proofs

| # | Capability | Gemini today | OpenAI target | Proof |
|---|---|---|---|---|
| P1 | Streaming text | rig `Text` | same | T-L1 exact reconstructed text `pong` |
| P2 | Tool calls, IDs survive turn 2 | three-way mapping | identical (D4) | T-R1..T-R3; T-L2 replay |
| P3 | Multi-round loop | agnostic | unchanged | existing tests; T-L2 round 1 -> result -> round 2 |
| P4 | Approval-gated mutations | agnostic | unchanged | existing tests; Wave 5 screenshot |
| P5 | Ask/Agent/Inline | agnostic | unchanged | existing tests |
| P6 | History compaction | agnostic | unchanged | existing tests |
| P7 | Token usage incl. cached input | mapped | mapped from concrete final response | T-R7 exact synthetic values from a constructed `StreamingCompletionResponse`; T-L1 `usage.is_some()` and `total == input + output` |
| P8 | Exactly one `Finished` | yes | yes | T-R6 |
| P9 | Model selection + discovery before a model exists | static | free text + `ai_list_models` | T-R12, T-R14, T-L3, T-T13 |
| P10 | Secure key storage | `apiKey` | `openaiApiKey` | T-T6, T-T7 |
| P11 | Settings UI, one draft | local signals | store-owned draft | T-T1..T-T4, T-T14, T-T15 |
| P12 | Readiness banners | key | key/model with host policy | T-T8..T-T11 |
| P13 | Error surfacing | `ErrorPayload` | 401/403/429 classified | T-R8 |
| P14 | Reset clears secrets | `apiKey` | both keys | T-T7 |
| P15 | Legacy config loads | n/a | yes | T-R11, T-T3 |
| P16 | Non-OpenAI hosts | n/a | normalization + key policy | T-R4, T-R5, T-R9, fixtures; T-L1..T-L3 on Ollama |
| P17 | Provider-aware guide/setup copy | Gemini-only | provider-aware | T-T16 |
| P18 | No self-update in the H4 build | upstream updater | disabled, proven three ways | T-T17, T-T18, bundle marker gate |

---

## 5. Test pre-plan (binding names; repo styles)

Conventions: Rust inline `#[cfg(test)] mod tests`, plain `#[test]` with a current-thread tokio runtime for async; env-gated live tests; vitest colocated `*.test.ts` (stores under `src/stores/__tests__/`), `vi.mock("@tauri-apps/api/core")`, `vi.resetModules()`; snake_case filenames.

### 5.1 Rust, `crates/kuku-ai` (inline)
- `src/provider/openai.rs::tests`
  - T-R1 `tool_result_uses_original_tool_call_ids`
  - T-R2 `tool_result_without_provider_call_id_still_uses_tool_call_id`
  - T-R3 `assistant_tool_call_round_trips_all_three_ids_without_signature`
  - T-R4 `normalize_base_url_appends_v1_and_strips_trailing_slash`
  - T-R5 `key_requirement_matches_shared_fixtures` (loads `fixtures/host_policy.json`: every case incl. `10.0.0.1`, `172.16.0.1`, `172.31.255.255`, `172.32.0.1` (Required), `192.168.1.5`, `127.255.255.255`, `[::1]`, `mac.local`, `mini.tail211fb5.ts.net`, `evil-local` (Required), `ts.net.example` (Required), malformed URL (Required))
  - T-R6 `adapt_stream_synthesizes_finished_when_stream_ends_early`, `adapt_stream_reports_tool_calls_finish_reason_and_three_ids`
  - T-R7 `usage_from_final_response_maps_cached_input_tokens` (constructs rig's concrete OpenAI `StreamingCompletionResponse` with `prompt_tokens: 120, completion 30, total 150, prompt_tokens_details.cached_tokens: 100`; asserts all four exactly)
  - T-R8 `map_completion_error_classifies_401_403_429`
  - T-R9 `empty_key_is_allowed_only_for_optional_hosts_and_sends_local_placeholder`
  - T-R14 `list_models_against_local_stub_server` (a `std::net::TcpListener` thread answering one canned HTTP response; cases: root URL gets `/v1/models`, trailing slash, existing `/v1` path, bearer header present/absent, non-2xx -> mapped error, unsorted+duplicate ids -> sorted unique)
  - T-R15 `stream_turn_classifies_401_403_429_from_stub_server`: the same listener pattern answering `HTTP/1.1 401`, `403`, `429` with a JSON error body; `OpenAiBackend::stream_turn(..)` (or the first item of its stream) yields exactly `AiError::Unauthorized`, `AiError::Unauthorized`, and `AiError::ProviderError(s)` with `s.starts_with("rate limited: ")` respectively (variant match, not substring on the outcome)
  - Live (env-gated `KUKU_TEST_OPENAI_BASE_URL`, optional `KUKU_TEST_OPENAI_API_KEY`, `KUKU_TEST_OPENAI_MODEL` default `qwen3.5:4b`; print `skipped: KUKU_TEST_OPENAI_BASE_URL unset` and return when unset), all through `OpenAiBackend::stream_turn`:
    - T-L1 `live_streams_text_with_usage_identities`: prompt "Reply with exactly: pong"; count(Finished) == 1, `finish_reason == Stop`, reconstructed text trimmed of whitespace and a trailing period `== "pong"`, `usage.is_some()`, `total == input + output`.
    - T-L2 `live_two_round_tool_call_replays_ids`: round 1 with one `list_files` descriptor and `tool_choice: Required`; count(ToolCalls) == 1, name == `list_files`, `finish_reason == ToolCalls`, `tool_call_id.is_some()`; append Assistant + `ToolResult` `{"files":["alpha.md"]}` with all three IDs replayed; round 2 (no tools, `Auto`) "Reply with exactly the file name from the tool result"; count(Finished) == 1, `Stop`, text (trimmed, trailing period stripped) `== "alpha.md"`. If the local model cannot satisfy the exact text reliably, the mentee reports CONTRADICTS and the text assertion applies only when `KUKU_TEST_OPENAI_STRICT_TEXT=1` (set for the api.openai.com run).
    - T-L3 `live_list_models_contains_the_configured_model_once`.
  - Regression command (AGENTS.md): `KUKU_TEST_OPENAI_BASE_URL=http://127.0.0.1:11434/v1 cargo test -p kuku-ai openai::tests::live_ -- --nocapture`.
- `src/types.rs::tests`: T-R10 `provider_kind_openai_serializes_as_openai`; T-R11 `ai_config_deserializes_without_openai_fields`.
- `src/state.rs::tests`: T-R12 `build_backend_openai_requires_model_and_key_policy`.
- `src/lib.rs::tests`: T-R13 `commands_permissions_and_handler_are_in_three_way_agreement` (parses `include_str!("../build.rs")` COMMANDS, `include_str!("lib.rs")` `generate_handler!` entries, `include_str!("../permissions/default.toml")` allow list; asserts the three sets are equal).

### 5.2 TypeScript, `apps/desktop`
- `config.test.ts` (new): T-T1..T-T4 as before, plus T-T9b `keyRequirementFor matches the shared fixtures` (reads `crates/kuku-ai/fixtures/host_policy.json` via `node:fs`).
- `chat_store.test.ts` (extend): T-T5 load without pinning; T-T6 `saveDraft` persists with `secureKeys: ["apiKey","openaiApiKey"]` and syncs `ai_set_config` with `provider: "openai"`; T-T7 clear both keys; T-T13 `loadModelSuggestions` invokes `plugin:kuku-ai|ai_list_models` with the draft's base URL and key and stores ids, and stores the error message on rejection; T-T14 provider round trip keeps both keys, both models, base URL; T-T15 `switchProviderAndSave("remote")` preserves openai fields and secrets.
- `provider_readiness.test.ts` (new): T-T8, T-T9, T-T10, T-T11.
- `components/model_label.test.ts` (new): T-T12.
- `components/settings_copy.test.ts` (new): T-T16.
- `src/stores/__tests__/updater.test.ts` (new): T-T17 action-level invariant with `@tauri-apps/plugin-updater` mocked: disabled marker -> `checkForUpdates()` and `downloadAndInstall()` never call the plugin (mock call count == 0) and `status` stays `idle`; enabled marker -> `check()` called exactly once.
- `src/stores/__tests__/updater_build_binding.test.ts` (new): T-T18 moon task env binding (`tauri-build-h4` has `VITE_KUKU_UPDATER: "off"`).
- `src/components/settings/sections/__tests__/about_section.test.ts` (new, node environment, pure helper): T-T19 `updateChannelLabelFor(marker)` returns the Homebrew key for `kuku-updater-disabled` and null otherwise; `about_section.tsx` renders from it.
- `chat_store.test.ts` T-T14/T-T15 use `setSettingsDraft` / `saveSettingsDraft` / `switchProviderAndSave` (names per D8; the composer's `setDraft` is untouched and T-T20 `composer setDraft still stores the session draft string` guards that).
- `catalog.test.ts`: unchanged, must stay green.

### 5.3 Shell, `scripts/h4`
- `publish_kuku_cask_test.sh`: temp repos + fake `gh`; non-zero on sha mismatch, non-zero on dirty tap clone, happy path stages everything (`git diff --cached --name-only`).

### 5.4 Gates after every wave
`pnpm moon run kuku-ai:test kuku-ai:lint-check kuku-ai:format-check desktop:test-ts desktop:lint-ts-check desktop:format-ts-check desktop:test-rust desktop:lint-rust-check desktop:format-rust-check web:test`, the live tests against Ollama, and (from Wave 3) `scripts/h4/publish_kuku_cask_test.sh`.

---

## 6. Work breakdown

### Wave 0, baseline hygiene
`crates/kuku-contract/src/lib.rs`: `#![allow(clippy::result_large_err)]` with comment. `oxfmt --write` on `mermaid/runtime_cache.ts`. Acceptance: every existing gate in 5.4 green.

### Wave 1, Rust backend
Files: `crates/kuku-ai/Cargo.toml`, `src/types.rs`, `src/provider/mod.rs` (add `ToolChoice`, remove `list_models` from the trait), `src/provider/gemini.rs` and `src/provider/remote.rs` (drop their `list_models` impls; ignore `tool_choice`), `src/provider/openai.rs` (new), `src/state.rs`, `src/error.rs`, `src/commands.rs`, `src/lib.rs`, `build.rs`, `permissions/default.toml`, `fixtures/host_policy.json` (new), `src/session.rs` (set `tool_choice: Auto` in the request), tests T-R1..T-R14, T-L1..T-L3. Acceptance: unit tests pass; live tests pass against Ollama on the build host; clippy clean; `cargo test -p kuku-app` green.

### Wave 2, frontend
Files: `types.ts`, `config.ts`, `chat_store.ts` (settings draft per D8), `provider_readiness.ts`, `chat_panel.tsx`, `components/ai_settings.tsx`, `components/model_label.ts`, `components/settings_copy.ts`, `index.ts`, `stores/updater.ts` (`UPDATER_BUILD_MARKER`, `isUpdaterEnabled`, action-level guards), `components/settings/sections/about_section.tsx` (consumes the marker, renders the Homebrew line), `env.d.ts`, `apps/desktop/moon.yml` (`tauri-build-h4` task, needed by T-T18; Wave 3 adds the conf file), `i18n/keys.ts` + three locales, tests T-T1..T-T19. Acceptance: `desktop:test-ts`, `desktop:lint-ts-check`, `desktop:format-ts-check`, `desktop:build` green.

### Wave 3, docs, fork build config, packaging (two repositories, two worktrees)
kb-app worktree: `tauri.h4.conf.json`, `apps/desktop/moon.yml` (`tauri-build-h4` with `VITE_KUKU_UPDATER=off`), `scripts/h4/{build_h4.sh, sign_notarize_dmg.sh, release_h4.sh, verify_ai_provider.sh, install_kuku_cask.sh, publish_kuku_cask_test.sh}`, docs per section 8. h4 worktree on 27-mac-mini (`~/projects/h4-worktrees/kuku-cask`, branch `feat/kuku-cask`, passed to Codex as an additional writable root): `deploy/homebrew-tap/Casks/kuku.rb`, `deploy/homebrew-tap/publish_kuku_cask.sh`, README row. Each repository gets its own whole-tree commit (`git add -A`) and push by the overseer after audit. Acceptance: `bash -n` on every script; `release_h4.sh --dry-run`; `publish_kuku_cask_test.sh` green; `pnpm moon run desktop:tauri-build-h4` on the build host yields `Kuku.app` that launches, and the mentee greps its frontend assets for the updater marker (C-UPD2).

### Wave 3b, promotion (overseer, after the Wave 3 audit)
Merge `feat/openai-provider` into kb-app `main` and `feat/kuku-cask` into h4 `main` (fast-forward where possible, otherwise a merge commit), push both, and record the two resulting `main` SHAs in the proof file. Pull both `main` checkouts on the laptop and the build host. No release step runs from a feature branch.

### Wave 4, release (overseer runs exactly one command)
From the laptop: `RELEASE_H4_BUILD_HOST=ts-27-mac-mini scripts/h4/release_h4.sh 0.5.8-h4.1`. The script, fail-closed at every step: (1) clean tree, on `main`, `HEAD == origin/main`, `git merge-base --is-ancestor <reviewed kb-app SHA from the proof> HEAD`, the same ancestry check for the h4 checkout, and the version in `tauri.h4.conf.json` equals the argument; (2) gates in 5.4 on the laptop; (3) the live tests against api.openai.com from the laptop (`KUKU_TEST_OPENAI_BASE_URL=https://api.openai.com/v1`, `KUKU_TEST_OPENAI_MODEL=gpt-5-nano`, key from the login environment, `KUKU_TEST_OPENAI_STRICT_TEXT=1`); (4) over ssh on the build host: `git pull --ff-only`, `verify_ai_provider.sh` against Ollama, `build_h4.sh`, the updater-marker grep on the built assets; (5) the sign/notarize/DMG script inside one `gui/$UID` LaunchAgent, polling `launchctl print` for `last exit code`; (6) `scp` the DMG back, sha256 equality, `spctl -a -t open --context context:primary-signature -vv`; (7) `publish_kuku_cask.sh <version> <sha> <dmg>` (laptop `gh` is logged in as horizonthinking), which uploads the release asset, rewrites and commits the h4 source cask and the tap clone separately, pushes both, and verifies both contain the version and sha; (8) prints the install command for Wave 5. `--dry-run` prints every step.

### Wave 5, install and prove on three Macs
`scripts/h4/install_kuku_cask.sh` on each of laptop-m3, 27-mac-mini, home-mac-mini in a login shell (exports `HOMEBREW_GITHUB_API_TOKEN` from the fleet's rendered `~/.env`; no command substitution; no `op` on the minis):
1. `brew tap-info horizonthinking/h4 --json` -> if absent, `brew tap horizonthinking/h4 git@github.com:horizonthinking/homebrew-h4.git`; assert the resolved remote is `git@github.com:horizonthinking/homebrew-h4.git`; `brew trust horizonthinking/h4` (failure not suppressed).
2. `pkill -x Kuku || true`; if a non-Homebrew `/Applications/Kuku.app` exists, move it to `~/Desktop/Kuku.app.pre-brew-<date>`.
3. `brew list --cask horizonthinking/h4/kuku >/dev/null 2>&1 && brew upgrade --cask horizonthinking/h4/kuku || brew install --cask horizonthinking/h4/kuku`.
4. Verify: `brew list --cask` shows `kuku`; `defaults read /Applications/Kuku.app/Contents/Info.plist CFBundleShortVersionString` `== 0.5.8-h4.1`; `codesign -dvvv` shows `Authority=Developer ID Application`, `TeamIdentifier=8P9788YC9P`, `flags=0x10000(runtime)`; `spctl -a -vv -t exec` accepted, `source=Notarized Developer ID`; `xcrun stapler validate` ok; `open /Applications/Kuku.app` by exact path; after 10 s exactly one `pgrep -x Kuku` pid whose `ps -o comm=` path starts with `/Applications/Kuku.app/Contents/MacOS/`; `lsappinfo info -only bundleid <pid>` shows `mom.kuku.app`.
5. laptop only: configure OpenAI-compatible with Ollama; Agent turn listing vault files (tool round trip); an approval-diff edit; one Ask turn against api.openai.com with `gpt-5-nano` (D12); screenshots of settings (showing the version line with "updates via Homebrew"), the tool turn, the approval diff, and the absence of an updater pill.

---

## 7. Definition-of-Done proof (5 items)
1. Ground truth: proof file section A (committed before implementation).
2. Observed values: proof section B, every 5.4 gate re-run on final `main`, Wave 5 checks verbatim per machine.
3. Expected-vs-observed: proof section C, one row per P1..P18 and per Wave 5 check per Mac.
4. Visual artifacts under `docs/plans/proof/`.
5. Explicit unknowns: proof section D (Windows/Linux; LM Studio, mlx, OpenRouter not gated; Responses deferred; ja/ko pending human review; mentee MISSING-LESSON items).

---

## 8. Doc-cleansing plan

| Artifact | Edit |
|---|---|
| `AGENTS.md` | providers list; live-test command; "Fork release (H4 tap)" section pointing at `scripts/h4/`. |
| `crates/kuku-ai/README.md` | provider adapters and the live-test command. |
| `crates/kuku-ai/src/error.rs` | provider-neutral `NotConfigured`. |
| `ai_chat/index.ts` | description no longer names Gemini. |
| `ai_settings.tsx` Quick guide + `guide.*` keys (en/ja/ko) | provider-aware (`settings_copy.ts`). |
| chat setup prompt keys (`en.ts:612-619` and ja/ko) | provider-neutral. |
| `api_key.label` (en/ja/ko) | split per provider. |
| `docs/development.md` **and `docs/development_ko.md`** | OpenAI-compatible option, Ollama example, live-test env vars; Release Notes section distinguishes upstream metadata from the H4 fork (`tauri.h4.conf.json`, `scripts/h4/`). |
| `~/projects/h4/deploy/homebrew-tap/README.md` | `kuku` cask row, tag namespace `kuku-v<version>`, the tap URL bootstrap line. |
| This plan | superseded content moves to section 14; observations go to the proof file. |

---

## 9. Sustainability and enforcement

| Mechanism | Type | Catches |
|---|---|---|
| Exhaustive `match config.provider` in Rust | compiler, blocking | provider without a code path |
| `assertNever` + `AI_PROVIDERS` single source | tsc (type-aware lint), blocking | same, TS |
| T-R13 three-way command/handler/permission parity | unit, blocking | a command missing from any registry |
| T-R11 / T-T3 legacy-config tests | unit, blocking | field without a default |
| T-T14 / T-T15 round trips through the store's own actions | unit, blocking | a save path dropping inactive fields or secrets |
| T-T17 + T-T18 + bundle marker gate in `release_h4.sh` | unit + script, blocking | an H4 build that could contact the upstream updater |
| Shared host-policy fixtures (Rust + TS) | unit, blocking | Rust/TS policy drift |
| `catalog.test.ts` | vitest, blocking | missing/empty locale keys (structural) |
| Live tests: Ollama on the build host and api.openai.com from the laptop, both inside `release_h4.sh` | script, blocking | provider regression before publishing |
| `release_h4.sh` as the only release path (Wave 4 invokes nothing else) | script, blocking | dirty tree, red gates, version mismatch |
| `publish_kuku_cask.sh` self-hash + dirty/diverged refusal + test | script + test, blocking | wrong artifact, clobbered tap |
| AGENTS.md regression command | prose | (backed by the scripts above) |

---

## 10. OMSV protocol (self-contained)

- **Overseer** (Claude, this session): frames the work, owns this plan, runs every audit, holds the final 5-item proof, drives Waves 3b, 4 and 5 (GUI LaunchAgent on the build host, ssh to the minis, the single release command).
- **Mentor** (Claude): authored this plan and the draft claims in section 11. A claim is unproven until the mentee confirms it at a green point with a compile fact or test output.
- **Mentee** (Codex, launched through `H4_CODEX_RUN_ID=$(uuidgen) bash ~/projects/h4/scripts/codex_exec_guard.sh exec ...` on 27-mac-mini, sandbox `workspace-write` with `-c sandbox_workspace_write.network_access=true` so cargo can fetch): works in the kb-app worktree `~/projects/apps/kb-app-worktrees/openai-provider` (branch `feat/openai-provider`); for Wave 3 additionally receives `--add-dir ~/projects/h4-worktrees/kuku-cask` (branch `feat/kuku-cask`). One wave per dispatch. Returns `WAVE_REPORT.md` at the worktree root with: files touched (`git status --short`), verbatim gate output tails, and a claim table with one row per claim the wave touches, each CONFIRMS / CONTRADICTS / MISSING-LESSON plus evidence, and a list of decisions the plan left open. The mentee may REJECT a claim; a contradicted claim blocks the wave until the plan is amended. The mentee never commits.
- **Audit per wave** (overseer): pull the branch, diff it against the previous wave's commit, re-run the wave's gates independently, check every claim row against its evidence, move `WAVE_REPORT.md` to `docs/plans/reports/wave<N>.md`, commit the whole tree with `git add -A` (co-authored), push, and only then dispatch the next wave. A red gate or an unevidenced claim sends the wave back with the specific gap.
- **Adversarial review loop** (before Wave 1; Wave 0 is exempt as pure hygiene): Codex reviews this document read-only against the repository and the vendored crates and returns `{verdict, previous, blocking, major, minor, confirmed}`; the overseer amends the plan for every blocking and major item, or records a rejection with rationale in section 14, and re-submits; stop at `AGREE` or after four rounds, after which unresolved items are listed in section 12 as accepted risks with rationale.
- **Final audit** (overseer): the 5-item DoD proof (section 7) plus a check that every claim in section 11 and every guidance sentence added to `AGENTS.md`, `crates/kuku-ai/README.md` and `docs/development*.md` traces to a mentee-CONFIRMED fact; anything untraceable is removed from the docs, not left as a guess.

---

## 11. Draft claims (unvalidated until the mentee confirms)
- C-RIG1: `Client::builder().api_key(k).base_url(u).build()?.completions_api().completion_model(id)` compiles against rig-core 0.32.0 and streams with tools.
- C-RIG2: the Chat Completions stream yields `StreamedAssistantContent::{Text, ToolCall, ToolCallDelta, Reasoning, ReasoningDelta, Final}` with `ToolCall { id, call_id, .. }`.
- C-RIG3 (v4): the concrete `Final(StreamingCompletionResponse)` for OpenAI Chat exposes raw `usage` with `prompt_tokens_details.cached_tokens`, and the adapter can read it; the generic `GetTokenUsage` path does not carry it on streaming.
- C-RIG4: both `send` and `send_streaming` reject non-2xx with `InvalidStatusCodeWithMessage(StatusCode, String)`.
- C-RIG5: rig's request builder exposes `tool_choice(..)` and Ollama honours `required`.
- C-RIG6: Chat Completions tool conversion sends `parameters` unchanged with `strict: None`.
- C-RIG7 (v5): rig 0.32's OpenAI Chat streaming adapter re-emits transport errors as `CompletionError::ProviderError(text)` where `text` starts with `Invalid status code <code>`; the textual tier of `map_completion_error` classifies real 401/403/429 responses from a stub server (T-R15).
- C-OLL1: Ollama's streaming Chat Completions assemble into exactly one rig `ToolCall` for a forced single tool call (`tool_choice: required`).
- C-OLL2: Ollama's non-standard `delta.reasoning` field is ignored by rig's chat streaming deserializer (unknown fields tolerated).
- C-CFG1: adding `#[serde(default)]` fields to `AiConfig` keeps every previously saved config loading (T-R11), and `normalizeAiConfig` keeps a pre-change persisted settings object loading on the TS side (T-T3).
- C-SEC1: `plugin_save_settings_with_secrets` / `plugin_get_settings_with_secrets` / the secure-delete path handle two secure keys with no Rust change (`plugin_settings.rs:75-116` iterates the supplied list).
- C-SEC2: the keychain item for `openaiApiKey` resolves to service `mom.kuku.desktop.plugin-secrets` and account `ai-chat:openaiApiKey` for the production identifier (`plugin_secrets.rs` + `variant.rs`); the mentee records the exact `security delete-generic-password -s <service> -a <account>` invocation in the wave report for section 13.
- C-CMD1: adding `ai_list_models` requires `build.rs` `COMMANDS`, `lib.rs` `generate_handler!`, and `permissions/default.toml` (`allow-ai-list-models`); the desktop crate's capability already grants `kuku-ai:default`, so nothing changes there (T-R13 enforces the three-way agreement).
- C-UPD (v5): with `VITE_KUKU_UPDATER=off` baked in by the `tauri-build-h4` task, `checkForUpdates()` and `downloadAndInstall()` return before touching the Tauri plugin from every call site, and the indicator stays `idle` (T-T17, T-T18).
- C-UPD2: the production bundle built by `tauri-build-h4` contains the literal `kuku-updater-disabled` and not `kuku-updater-enabled`, because Vite inlines the env value and esbuild constant-folds the comparison, and because `about_section.tsx` consumes the marker so it is not tree-shaken; validated by grepping the built assets (fallback per R9 if it fails).
- C-BLD1: `tauri build --config src-tauri/tauri.h4.conf.json` with `createUpdaterArtifacts: false` and no `APPLE_SIGNING_IDENTITY` produces a `Kuku.app` (unsigned or ad-hoc, recorded not asserted) that a later deep `codesign --force` re-signs with the hardened runtime and `src-tauri/entitlements.plist` and that then passes notarization and Gatekeeper.
- C-BLD2: 27-mac-mini's Homebrew `cargo 1.98.0` (no rustup) builds the Tauri app for `aarch64-apple-darwin` without a rustup target install.
- C-TAP1: in a login shell on each Mac, `brew tap horizonthinking/h4 git@github.com:horizonthinking/homebrew-h4.git` (when absent) followed by `brew install --cask horizonthinking/h4/kuku` resolves the private release asset through `H4PrivateGitHubReleaseDownloadStrategy` using the exported `HOMEBREW_GITHUB_API_TOKEN`, with no command substitution and no `op` CLI on the minis.

---

## 12. Risks and accepted decisions
R1 spend bounded (D12). R2 tool-only rounds with no text are not errors. R3 local servers without tools answer in prose (banner says so). R4 fork-only files isolated. R5 GUI session required on the build host. R7 Responses API deferred (Action `9055402d`). R8 live-text flakiness mitigated by `tool_choice: Required` and the strict-text switch. R9 (new) esbuild constant folding for C-UPD2 is a claim; if it fails, the fallback is a `define`-injected constant in `vite.config.ts` (`__KUKU_UPDATER__`), which is guaranteed to inline.

## 13. Rollback
Code: revert the merge commit; `normalizeAiConfig` maps `provider: "openai"` back to the default. Credentials: Settings -> AI Chat -> Reset while the new build is installed, or the recorded `security delete-generic-password -s mom.kuku.desktop.plugin-secrets -a ai-chat:openaiApiKey`. Tap: `brew uninstall --cask horizonthinking/h4/kuku`; delete the `kuku-v<version>` release; revert `Casks/kuku.rb` in both places. `~/.kuku` untouched.

---

## 14. Review log

### Round 1 (plan v2) -> REVISE; all 22 items dispositioned in v3 (see v3 text in git history `d84266d..`); round 2 marked B1-B7, B9, M1, M2, M5, M6, M7, M9, m1, m2 RESOLVED.

### Round 2 (plan v3) -> REVISE. Dispositions in v4:
- B8 updater proof: AMENDED (D10 three-link proof chain: helper test, moon/app.tsx binding test T-T18, bundle marker gate in `release_h4.sh`; C-UPD2; R9 fallback).
- B10 tap bootstrap: AMENDED (Wave 5 step 1 uses the SSH URL when absent and asserts the remote).
- m3 proof file: AMENDED (proof file committed with verbatim blocks; section 1 now summarizes and points at A1-A10; inventory moved there).
- M3 live tests: AMENDED (`tool_choice` on `CompletionTurnRequest`, mapped by `OpenAiBackend`; exact text assertions; usage identity; strict-text switch for the OpenAI run).
- M4 draft ownership: AMENDED (D8 store-owned draft; `switchProviderAndSave`; T-T15 bound to it).
- M8 OpenAI gating: AMENDED (release script runs the live suite against api.openai.com from the laptop before publishing; claim now says gated).
- N1 cached tokens: AMENDED (D4 usage from the concrete final response; T-R7 constructs it; C-RIG3 restated).
- N2 discovery contract: AMENDED (`Result<Vec<String>, String>`; shared `normalize_base_url`; T-R14 stub-server cases).
- N3 launch proof: AMENDED (pkill, exact path, `CFBundleShortVersionString`, executable path check).
- N4 release entry point: AMENDED (Wave 4 runs only `release_h4.sh`).
- N5 second repository: AMENDED (h4 worktree `~/projects/h4-worktrees/kuku-cask` on 27-mac-mini, created 2026-09-11; `--add-dir`; separate commits).
- N6 Korean doc: AMENDED (section 8).
- N7 authorization scope: AMENDED (D12 quotes the full goal statement, which names both minis).
- n1 feature wording: AMENDED. n2 trait `list_models`: AMENDED (removed). n3 three-way parity: AMENDED (T-R13). n4 store test location: AMENDED. n5 test filename: AMENDED (`settings_copy.test.ts`). n6 host-policy boundaries: AMENDED (shared fixtures with the listed boundary cases).

### Round 3 (plan v4) -> REVISE; 16 of 19 prior items RESOLVED. Dispositions in v5:
- B8 updater invariant at the action boundary: AMENDED (D10: `checkForUpdates`/`downloadAndInstall` return early when disabled; T-T17 asserts the mocked plugin is never called from either action; T-T18 keeps the moon binding).
- NEW-B1 status erased on the streaming path: AMENDED (D5 two-tier classifier constrained to rig's Display prefix; T-R15 stub-server tests through `stream_turn`; C-RIG7).
- M4 `setDraft` name collision: AMENDED (D8 `settingsDraft` / `setSettingsDraft` / `saveSettingsDraft`; T-T20 guards the composer API).
- NEW-M1 promotion and versioned command: AMENDED (Wave 3b explicit merge of both branches into both `main`s with SHAs recorded in the proof; Wave 4 command shown with the version; ancestry checks in the script).
- NEW-M2 durable cask commit: AMENDED (D11: the publisher commits and pushes the h4 source cask and the tap clone separately with `git add -A` and verifies both; Wave 3 commits a placeholder cask).
- NEW-M3 marker retention and version line: AMENDED (D10: `about_section.tsx` consumes the marker; Wave 2 file list; T-T19).
- NEW-M4 self-containment: AMENDED (sections 10 and 11 restored in full; nothing refers to a prior version for content).
- NEW-m1 proof template: AMENDED (P1..P18).
