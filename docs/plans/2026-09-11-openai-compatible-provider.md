# OpenAI-compatible AI provider for Kuku desktop, with full Gemini parity

Status: DRAFT v9, 2026-09-11. Author: Claude (mentor/overseer). Reviewer: Codex (adversarial, iterative, on 27-mac-mini). Implementer: Codex (OMSV mentee, on 27-mac-mini).
Repo: `horizonthinking/kb-app` (fork of `kuku-mom/kuku`). Implementation base: `main` at `458f34b` (last code commit; later commits on `main` are this plan and its proof file). Branch `feat/openai-provider`. Companion proof file: `docs/plans/2026-09-11-openai-provider-proof.md` (all dated, machine-specific observations live there).

Changelog: v1 initial. v2 author's own source corrections. v3 dispositions for review round 1 (scope narrowed to Chat Completions). v4 dispositions for review round 2 (section 14): production `tool_choice` path, cached-token mapping from the concrete streaming response, updater proof bound to the moon task and the built bundle, tap bootstrap with the SSH URL, single release entry point, h4 worktree for the cask work, shared draft ownership in the store, full goal quotation, proof file committed. v5 dispositions for review round 3: updater guarded at the action boundary, two-tier error classifier proven through a stub server on the real streaming path, `settingsDraft` naming, explicit promotion wave and versioned release command, post-publication cask commit, marker consumed in the About pane, sections 10 and 11 made self-contained. v6 dispositions for review round 4: pre-dispatch branch bootstrap gate, `parse_endpoint` with an https-for-keyed-hosts scheme policy, cask template instead of a placeholder cask on `main`, publisher preconditions and tests for both repositories, static vs live gate split with fail-on-skip, full T-T1..T-T4 definitions, regenerated permission artifacts, exact T-R15 message. v7 dispositions for review round 5: https whenever a key is present, query/fragment rejection, every TS test bound with explicit assertions, incomplete-config discovery pinned (T-R16, T-T21), cask validated by Homebrew before upload, idempotent publisher recovery, authenticated live probe, handoff file per wave, no review-round cap, README depth. v8 dispositions for review round 6: handoff via the installed skill with the root file kept, policy/transport split for discovery tests, precise publisher recovery contract with six failure scenarios, moon inputs for the shared fixture, build-host revision pinning, corrected request bound, mentee commits its own waves. v9 dispositions for review round 7: executable end-of-wave order (commit, push, then the handoff skill last), shared publisher preflight reachable from the release entry point, Wave 3 commit ownership aligned, h4 registry gate in scope, T-R4 aligned with the key policy, stale sentences fixed.

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

D3. **Backend.** `provider/openai.rs`, `OpenAiBackend::new(api_key: Option<&str>, base_url: &str, model: &str)`: `Client::builder().api_key(key).base_url(endpoint.base).build()?.completions_api()`, `completion_model(model)`. **One URL validation for both chat and discovery (v6):** `parse_endpoint(base_url: &str, key_present: bool) -> Result<Endpoint, AiError>` parses with `url::Url` (already a transitive dependency; add as direct), rejects any scheme other than `http`/`https`, rejects URLs carrying userinfo, a query string or a fragment (rig appends paths to the base as text, so `?x=1` would corrupt the request path), classifies the host, trims, strips a trailing `/`, appends `/v1` when the path is empty, and **enforces the scheme policy (v7): `https` is mandatory whenever a non-empty key is supplied, on any host, and for every `Required` host; `http` is permitted only when the host is `Optional` AND the key is empty.** `parse_endpoint` therefore takes `(base_url, key_present: bool)`. **Authentication policy:** `key_requirement(host) -> Required | Optional`; Optional only for loopback (`localhost`, `127.0.0.0/8`, `[::1]`), RFC1918 (`10/8`, `172.16/12`, `192.168/16`), `*.local`, `*.ts.net` (suffix match on a dot boundary, so `evil-local` and `ts.net.example` are Required); when Optional and the key is empty, the literal `local` is sent because rig's builder needs a non-empty key. Public hosts (api.openai.com, openrouter.ai, everything else) require a key and `https`. Host and scheme fixtures are one shared JSON file (`crates/kuku-ai/fixtures/host_policy.json`, entries `{ "url", "key_present": true|false, "requirement": "required"|"optional", "accepted": true|false }`) consumed by both the Rust and TS tests; it includes keyed-local-HTTP rejections such as `http://127.0.0.1:11434` with `key_present: true` -> rejected, and query/fragment rejections such as `https://api.openai.com/v1?x=1` and `https://api.openai.com/v1#f`.

D4. **Stream adapter and request.** `CompletionTurnRequest` gains `tool_choice: ToolChoice` (`Auto | Required | None`, default `Auto`); the session always sends `Auto`; `OpenAiBackend` maps it to rig's `tool_choice(..)` on the request builder; `GeminiBackend` and `RemoteBackend` ignore it (documented). A pure `adapt_stream(...)` (shared by backend and tests) emits: `TextDelta` per text; one `ToolCalls` per complete `ToolCall` with the three-way ID mapping and `signature: None`; ignores `ToolCallDelta`, `Reasoning`, `ReasoningDelta`; exactly one `Finished` with `ToolCalls` if any tool call was seen; **usage from the concrete `Final(StreamingCompletionResponse)`'s raw `usage`, including `prompt_tokens_details.cached_tokens`** (the generic `GetTokenUsage` path loses it, section 2); a synthesized `Finished { usage: None }` if the stream ends without `Final`.

D5. **Errors (v5).** rig's reqwest client raises `http_client::Error::InvalidStatusCodeWithMessage(StatusCode, String)` for any non-2xx (`http_client/mod.rs:143-149, 381-387`), but the OpenAI Chat streaming adapter erases it: every SSE-path error is re-emitted as `CompletionError::ProviderError(error.to_string())` (`providers/openai/completion/streaming.rs:284-290`), whose text begins with rig's fixed Display prefix `Invalid status code <code> <reason> with message: ...` (`http_client/mod.rs:20-21`). `map_completion_error` therefore classifies in two tiers: (a) structured, `HttpError(InvalidStatusCode(s) | InvalidStatusCodeWithMessage(s, _))` by `StatusCode`; (b) textual, constrained to rig's own prefix: a `ProviderError(text)` matching `^Invalid status code (\d{3})\b` is classified by that three-digit code. 401/403 -> `Unauthorized`; 429 -> `ProviderError("rate limited: <text>")`; everything else `ProviderError`. The textual tier depends on rig 0.32's Display format, which is pinned by `Cargo.lock`; **the real streaming path is proven by stub-server tests** (T-R15) that call `OpenAiBackend::stream_turn` against a local listener answering 401, 403 and 429 and assert the exact `AiError` variant. `list_models` reads the status directly. Session 401 retry stays Remote-only. `NotConfigured` message: "AI is not configured. Choose a connection in Settings and add its API key or model."

D6. **Model discovery, standalone, with policy and transport separated (v8).** `pub(crate) async fn list_models(base_url: &str, api_key: Option<&str>) -> Result<Vec<String>, AiError>` = `list_models_at(&reqwest::Client, &parse_endpoint(base_url, key_present)?, api_key)`. The transport function `list_models_at(client, endpoint: &Endpoint, api_key)` does `GET {endpoint.base}/models`, adds `Authorization: Bearer` only when a key is present, maps non-2xx through `map_status(..)`, deduplicates and sorts ids. Tests that need a keyed request against a plaintext local stub construct `Endpoint` directly and call `list_models_at`, so header behaviour is tested without weakening `parse_endpoint`. Tauri command `ai_list_models(base_url, api_key) -> Result<Vec<String>, String>` (the repo's command convention). **`CompletionBackend::list_models` is removed from the trait and from `GeminiBackend`/`RemoteBackend`** (dead code). Registered in `build.rs` `COMMANDS`, `lib.rs` `generate_handler!`, `permissions/default.toml`; the tracked generated artifacts `permissions/autogenerated/commands/ai_list_models.toml`, `permissions/autogenerated/reference.md` and `permissions/schemas/schema.json` are **regenerated by `cargo build`** (tauri-plugin's build step), never hand-edited, and committed. Dependency: `reqwest = { version = "0.13", default-features = false, features = ["rustls", "charset", "json", "stream"] }`: valid names for reqwest 0.13.4 and compatible with rig's own reqwest 0.13 features (feature unification keeps one build).

D7. **Frontend readiness.** `provider_readiness.ts`: pure `isApiKeyMissing`, `isModelMissing`, `needsRemoteLogin`, `needsRemotePermission` using `keyRequirementFor(baseUrl)` ported from D3 with the shared fixtures.

D8. **Settings state, owned by the store.** `chat_store.ts` already exports `setDraft(value: string)` and `session.draft` for the chat composer (`chat_store.ts:139, 595, 790`); those stay untouched. The settings state uses distinct names: `settingsDraft: AiSettingsDraft` (provider, apiKey, openaiApiKey, openaiBaseUrl, openaiModel, serverUrl) with exported `settingsDraftFromConfig(config)`, `setSettingsDraft(patch)`, `isSettingsDraftUnsaved()`, `saveSettingsDraft()`, `switchProviderAndSave(provider)`, `loadModelSuggestions()`. `AiSettings` binds its inputs to `settingsDraft` (no local signals for config fields); `AccessPrompt` calls `switchProviderAndSave("remote")`, which preserves every other field and both secrets. Rows for OpenAI: Base URL, API key (show/hide; required/optional label from `keyRequirementFor`), Model (text + `<datalist>` from `modelSuggestions` + "Load models", the connection test). Quick guide and chat setup prompt render from `settings_copy.ts` (`guideCopyFor`, `setupPromptFor`).

D9. **i18n.** New keys in `keys.ts` with en/ja/ko values; `api_key.label` split per provider; `catalog.test.ts` is structural; translation quality is an explicit unknown for human review.

D10. **Fork release identity and updater.** `tauri.h4.conf.json` merged over `tauri.conf.json`: identifier/productName inherited, `"version": "0.5.8-h4.1"`, `bundle.targets: ["app"]`, `bundle.createUpdaterArtifacts: false`. The updater is disabled at build time and **guarded at the action boundary, not at call sites** (there are two call sites today: `app.tsx:150` and the retry handler in `update_indicator.tsx:33`): moon task `desktop:tauri-build-h4` sets `VITE_KUKU_UPDATER=off`; `stores/updater.ts` defines `UPDATER_BUILD_MARKER` as `import.meta.env.VITE_KUKU_UPDATER === "off" ? "kuku-updater-disabled" : "kuku-updater-enabled"` and `isUpdaterEnabled()` derived from it; `checkForUpdates()` and `downloadAndInstall()` return immediately (state stays `idle`) when the updater is disabled, so no call site can reach the Tauri plugin. **Proof chain (three deterministic links):** (1) `src/stores/__tests__/updater.test.ts`: with `@tauri-apps/plugin-updater` mocked, `checkForUpdates()` and `downloadAndInstall()` under the disabled marker never call the mocked `check()`/`downloadAndInstall()` (call count == 0) and leave `status === "idle"`, and under the enabled marker they do call it (count == 1); (2) `src/stores/__tests__/updater_build_binding.test.ts` reads `apps/desktop/moon.yml` and asserts the `tauri-build-h4` task's env contains `VITE_KUKU_UPDATER: "off"`; (3) the marker is **consumed at runtime** by `components/settings/sections/about_section.tsx`, which renders the version line with the text of key `settings.about.updates_via_homebrew` when the marker is `kuku-updater-disabled` (so Rollup cannot tree-shake it; tested by T-T19), and Vite inlines the env while esbuild constant-folds the comparison, so the production bundle contains exactly one of the two literals (claim C-UPD2, validated by the mentee on the built bundle); `release_h4.sh` greps the built `Kuku.app`'s frontend assets and refuses to publish unless `kuku-updater-disabled` is present and `kuku-updater-enabled` is absent. The About pane screenshot documents the version line.

D11. **Signing and publishing.** Build unsigned on 27-mac-mini; sign/notarize/staple in one `gui/$UID` LaunchAgent (Adapt's script as structural reference; the Kuku copy also signs every Mach-O under `Contents/MacOS` and nested `.framework/.dylib/.bundle/.appex/.xpc/.app`); DMG create/sign/notarize/staple; publish to tag `kuku-v<version>` on `horizonthinking/homebrew-h4`; cask `Casks/kuku.rb` (source of truth in the h4 monorepo, mirrored to the tap clone). `publish_kuku_cask.sh` hashes the DMG itself and refuses a mismatching sha; **before mutating anything it requires BOTH repositories (the h4 monorepo checkout and the tap clone under `~/projects/h4/live/homebrew-h4`) to be clean, on `main`, and with `HEAD == origin/main` after `git fetch`**; it renders `Casks/kuku.rb` from the committed template `deploy/homebrew-tap/templates/kuku.rb.tmpl` (Wave 3 commits only the template, so h4 `main` never carries an uninstallable live cask; a loadable `Casks/kuku.rb` first appears in the publisher's post-publication commit). **Cask validation before publication (v7):** the rendered file is written to a temporary tap layout first and must pass, in order: no `@VERSION@`/`@SHA256@` token left, `ruby -c`, `brew style --cask <file>`, and a load through `brew info --cask <absolute path>` (Homebrew loads a cask from a path); any failure aborts before the release upload. **Idempotent recovery (v8, stated precisely):** the GitHub release is created if absent and the asset uploaded with `--clobber` if present; each repository update is convergent (render, and commit only if the rendered file differs from `HEAD`). The precondition on each repository is: clean tree on `main` and `HEAD == origin/main`, **except** the two states the publisher itself can leave behind, which it reconciles instead of refusing: (i) a dirty tree whose only change is `Casks/kuku.rb` rendering exactly to the target content (it re-renders and continues), and (ii) `HEAD` ahead of `origin/main` by commits that touch only `Casks/kuku.rb` and whose tip content equals the target (it pushes and continues). Any other dirty or diverged state is refused. Re-running after a failure at any of six points (after render, after the local commit, during the push, after the release upload, after the first push, after the second push) therefore converges to one release asset and identical clean remote casks; each is an injected-failure scenario in the test. Then it **commits and pushes each repository separately with `git add -A`** and verifies afterwards that both remote trees contain the exact version and sha and that both worktrees are clean. It has `--dry-run`, a `BREW`/`GH` override for tests, and a test (`publish_kuku_cask_test.sh`) built on two temporary working repositories with bare remotes, a fake `gh` and a fake `brew` that record their arguments (the `ruby -c` check runs for real): dirty and diverged rejection for each repository, sha-mismatch rejection, a leftover-token rejection, a `brew style`/`brew info` failure rejection, six injected-failure reruns (after render, after the local commit, during the push, after upload, after the first push, after the second push) each rerun from the resulting state without manual cleanup and asserting convergence to exactly one asset upload with `--clobber` and identical clean remote casks, and on the happy path exactly one new pushed commit per repository, the exact version and sha in both remote trees, and clean worktrees afterwards. **One entry point:** Wave 4 runs `scripts/h4/release_h4.sh 0.5.8-h4.1` and nothing else by hand; the script owns every precondition and step (section 6, Wave 4), including verifying that both `main` checkouts contain the reviewed commits.

D12. **Spend and authorization.** Michael's goal statement (2026-09-11), quoted in full: "please author an exhaustive plan to activate the openai api (to open ai and to other compliant api providers) with full gemini feature parity. Do not plan the codex work. Conduct iterative adversarial review of your plan with codex locally until the plan is agreed. oversee a codex OMSV implementation of the plan. Make sure the plan includes running existing/provided tests before and after development. Extend those tests (do the preplanning for tests during the planning phase and make sure the tests conform to the style of tests currently in the repo and can continue to be used for regression testing going forward. Dod is a test working app running locall yon this mac that is also signed and deployed into the h4 homebrew tap on github and that 27-mac-mini and home-mac-mini have an installed and working version of the app installed via the homebrew tap." This authorizes (a) direct calls to api.openai.com for this feature and (b) installation on 27-mac-mini and home-mac-mini. Bound for (a): model `gpt-5-nano`; the live gate run once pre-publish by `release_h4.sh` from the laptop (the 5.5 preflight `GET /models`, then T-L1 one chat request, T-L2 two chat requests, T-L3 one `GET /models`) plus one manual Ask turn in Wave 5: at most 4 chat-completion requests and 2 models listings, recorded in the proof with the exact counts.

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
| P9 | Model selection + discovery before a model exists | static | free text + `ai_list_models` | T-R12, T-R14, T-R16, T-L3, T-T13, T-T21 |
| P10 | Secure key storage | `apiKey` | `openaiApiKey` | T-T6, T-T7 |
| P11 | Settings UI, one draft | local signals | store-owned draft | T-T1..T-T4, T-T14, T-T15 |
| P12 | Readiness banners | key | key/model with host policy | T-T8..T-T11 |
| P13 | Error surfacing | `ErrorPayload` | 401/403/429 classified on the real streaming path | T-R8 (synthetic), T-R15 (stub server through `stream_turn`) |
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
  - T-R4 `parse_endpoint_normalizes_path_and_strips_trailing_slash` (`https://api.openai.com` with `key_present = true` -> `/v1`, `https://openrouter.ai/api/v1` with `key_present = true` unchanged, `http://127.0.0.1:11434/` with `key_present = false` -> `/v1`, `http://127.0.0.1:11434/v1/` with `key_present = false` unchanged)
  - T-R5 `endpoint_policy_matches_shared_fixtures` (loads `fixtures/host_policy.json`; every entry asserts both `requirement` and `accepted`: `https://api.openai.com` required/accepted, `http://api.openai.com` required/rejected (plaintext to a key-required host), `https://openrouter.ai/api/v1` required/accepted, `http://10.0.0.1:8080` optional/accepted, `http://172.16.0.1` optional, `http://172.31.255.255` optional, `http://172.32.0.1` required/rejected, `http://192.168.1.5:1234` optional, `http://127.255.255.255` optional, `http://[::1]:8080` optional, `http://mac.local:1234` optional, `http://mini.tail211fb5.ts.net:8080` optional, `http://evil-local` required/rejected, `https://ts.net.example` required/accepted, `ftp://x` rejected, `https://user:pw@api.openai.com` rejected, `not a url` rejected)
  - T-R6 `adapt_stream_synthesizes_finished_when_stream_ends_early`, `adapt_stream_reports_tool_calls_finish_reason_and_three_ids`
  - T-R7 `usage_from_final_response_maps_cached_input_tokens` (constructs rig's concrete OpenAI streaming `Usage` with `prompt_tokens: 120`, `total_tokens: 150`, `prompt_tokens_details: Some({ cached_tokens: 100 })`; rig's streaming `Usage` has no completion field, so output is derived; asserts exactly `input_tokens == 120`, `output_tokens == 30`, `total_tokens == 150`, `cached_input_tokens == 100`)
  - T-R8 `map_completion_error_classifies_401_403_429`
  - T-R9 `empty_key_is_allowed_only_for_optional_hosts_and_sends_local_placeholder`
  - T-R14 `list_models_against_local_stub_server` (a `std::net::TcpListener` thread answering one canned HTTP response and recording the request line and headers; through `list_models` with an empty key: root URL gets `/v1/models`, trailing slash, existing `/v1` path, no `Authorization` header, non-2xx -> mapped error, unsorted+duplicate ids -> sorted unique; through `list_models_at` with a directly constructed `Endpoint` and key `sk-test`: the request carries exactly `Authorization: Bearer sk-test`)
  - T-R15 `stream_turn_classifies_401_403_429_from_stub_server`: the same listener pattern answering `HTTP/1.1 401 Unauthorized`, `403 Forbidden`, `429 Too Many Requests` with the canned body `{"error":{"message":"stub"}}`; `OpenAiBackend::stream_turn(..)` (or the first item of its stream) yields exactly `AiError::Unauthorized`, `AiError::Unauthorized`, and `AiError::ProviderError(String::from("rate limited: Invalid status code 429 Too Many Requests with message: {\"error\":{\"message\":\"stub\"}}"))` respectively (exact equality; if rig's Display differs, the mentee reports the exact string and the test asserts that exact string)
  - Live (env-gated `KUKU_TEST_OPENAI_BASE_URL`, optional `KUKU_TEST_OPENAI_API_KEY`, `KUKU_TEST_OPENAI_MODEL` default `qwen3.5:4b`; print `skipped: KUKU_TEST_OPENAI_BASE_URL unset` and return when unset), all through `OpenAiBackend::stream_turn`:
    - T-L1 `live_streams_text_with_usage_identities`: prompt "Reply with exactly: pong"; count(Finished) == 1, `finish_reason == Stop`, reconstructed text trimmed of whitespace and a trailing period `== "pong"`, `usage.is_some()`, `total == input + output`.
    - T-L2 `live_two_round_tool_call_replays_ids`: round 1 with one `list_files` descriptor and `tool_choice: Required`; count(ToolCalls) == 1, name == `list_files`, `finish_reason == ToolCalls`, `tool_call_id.is_some()`; append Assistant + `ToolResult` `{"files":["alpha.md"]}` with all three IDs replayed; round 2 (no tools, `Auto`) "Reply with exactly the file name from the tool result"; count(Finished) == 1, `Stop`, text (trimmed, trailing period stripped) `== "alpha.md"`. If the local model cannot satisfy the exact text reliably, the mentee reports CONTRADICTS and the text assertion applies only when `KUKU_TEST_OPENAI_STRICT_TEXT=1` (set for the api.openai.com run).
    - T-L3 `live_list_models_contains_the_configured_model_once`.
  - Regression command (AGENTS.md): `KUKU_TEST_OPENAI_BASE_URL=http://127.0.0.1:11434/v1 cargo test -p kuku-ai openai::tests::live_ -- --nocapture`.
- `src/types.rs::tests`: T-R10 `provider_kind_openai_serializes_as_openai`; T-R11 `ai_config_deserializes_without_openai_fields`.
- `src/state.rs::tests`: T-R12 `build_backend_openai_requires_model_and_key_policy` (`Ok(None)` for empty model; `Ok(None)` for a Required host with no key; `Some` for an Optional host with empty key and a model); T-R16 `set_config_stores_incomplete_openai_config_without_backend`, two cases: (a) local discovery: `set_config` with `openai_base_url = http://127.0.0.1:<stub port>`, empty key, no model returns `Ok(())`, `config()` round-trips the fields, `backend()` returns `Err(NotConfigured)`, `openai::list_models(stored base, None)` against the stub succeeds; then `set_config` with a model makes `backend()` return `Ok`; (b) keyed persistence without network: `set_config` with `openai_base_url = https://api.openai.com/v1`, key `sk-test`, no model returns `Ok(())`, `config()` round-trips all three fields, `backend()` returns `Err(NotConfigured)`, no request is made. `AiState::set_config` already stores the config when `build_backend` returns `Ok(None)`; D6/D8 rely on that and T-R16 pins it.
- `src/lib.rs::tests`: T-R13 `commands_permissions_and_handler_are_in_three_way_agreement` (parses `include_str!("../build.rs")` COMMANDS, `include_str!("lib.rs")` `generate_handler!` entries, `include_str!("../permissions/default.toml")` allow list; asserts the three sets are equal).

### 5.2 TypeScript, `apps/desktop`
- `config.test.ts` (new):
  - T-T1 `normalizes openai provider with defaults`: raw `{ provider: "openai", openaiModel: "gpt-5-nano" }` -> `openaiBaseUrl === DEFAULT_OPENAI_BASE_URL`, `openaiApiKey === null`, `model === "gpt-5-nano"`.
  - T-T2 `derives top-level model per provider`: for `openai` the derived `model` equals `openaiModel`; for `gemini` and `remote` it equals `DEFAULT_MODEL` even when `raw.model` differs.
  - T-T3 `keeps legacy configs without openai fields loadable`: raw `{ provider: "gemini", apiKey: "k", model: "gemini-3.1-flash-lite" }` (the pre-change shape) -> `provider === "gemini"`, `apiKey === "k"`, `openaiApiKey === null`, `openaiBaseUrl === DEFAULT_OPENAI_BASE_URL`, `openaiModel === null`.
  - T-T4 `rejects unknown provider values to the default`: raw `{ provider: "codexAppServer" }` -> `provider === DEFAULT_PROVIDER`.
  - T-T9b `endpointPolicyFor matches the shared fixtures` (reads `crates/kuku-ai/fixtures/host_policy.json` via `node:fs`; asserts requirement and acceptance for every entry).
- `chat_store.test.ts` (extend, same `mockInvoke` / `vi.resetModules` style):
  - T-T5 `loads openai settings without pinning the model to the build default`: persisted `{ provider: "openai", openaiModel: "qwen3.5:4b", openaiBaseUrl: "http://127.0.0.1:11434/v1" }` -> `chatState.config.model === "qwen3.5:4b"` and `ai_set_config` receives `model: "qwen3.5:4b"`.
  - T-T6 `saveSettingsDraft persists both secure keys and syncs runtime config`: after `setSettingsDraft({ provider: "openai", openaiApiKey: "sk-test", openaiModel: "gpt-5-nano" })` and `saveSettingsDraft()`, the `plugin_save_settings_with_secrets` call carries `secureKeys: ["apiKey", "openaiApiKey"]` and a settings object with `openaiApiKey: "sk-test"`, and `ai_set_config` receives `provider: "openai"`, `model: "gpt-5-nano"`.
  - T-T7 `clearPersistedConfig clears both secure keys`: the secure-aware clear command is invoked with both key names.
  - T-T13 `loadModelSuggestions lists models for the current draft`: `plugin:kuku-ai|ai_list_models` is invoked with `{ baseUrl: <draft base>, apiKey: <draft key> }`, `modelSuggestions` equals the returned ids; on rejection `modelsError` equals the error message and `modelSuggestions` is `[]`.
  - T-T14 `provider round trip keeps every provider's fields`: openai (key A, model M1, base B) -> gemini (key G) -> openai; after each save the persisted object still contains `apiKey: G` or null as saved, `openaiApiKey: A`, `openaiModel: M1`, `openaiBaseUrl: B`.
  - T-T15 `switchProviderAndSave keeps openai fields when moving to remote`: same assertions with `provider: "remote"`.
  - T-T20 `composer setDraft still stores the session draft string`: `setDraft("hello")` -> `session.draft === "hello"`, unchanged behaviour.
  - T-T21 `first-run discovery works before a model is chosen`: `setSettingsDraft({ provider: "openai", openaiBaseUrl: "http://127.0.0.1:11434/v1" })`, `saveSettingsDraft()` succeeds (mocked `ai_set_config` resolves), `loadModelSuggestions()` invokes `ai_list_models` and stores ids, `setSettingsDraft({ openaiModel: ids[0] })`, `saveSettingsDraft()` sends `ai_set_config` with that model.
- `provider_readiness.test.ts` (new), each a pure call on a config object:
  - T-T8 `gemini reports a missing key`: `{ provider: "gemini", apiKey: null }` -> `isApiKeyMissing === true`; with a key -> `false`.
  - T-T9 `openai requires a key only for key-required hosts`: base `https://api.openai.com/v1` without key -> `true`; `http://127.0.0.1:11434/v1` without key -> `false`; `https://openrouter.ai/api/v1` without key -> `true`.
  - T-T10 `openai reports a missing model`: `openaiModel: ""` -> `isModelMissing === true`; `"gpt-5-nano"` -> `false`; gemini/remote -> `false`.
  - T-T11 `remote login and permission predicates are unchanged`: `needsRemoteLogin` true only for `remote` + unauthenticated; `needsRemotePermission` true only for `remote` + authenticated + not authorized.
- `components/model_label.test.ts` (new): T-T12 `shortModelLabel keeps gemini labels and passes other ids through`: `"gemini-3.1-flash-lite"` -> `"Gemini 3.1 Flash Lite"`, `"gpt-5-nano"` -> `"gpt-5-nano"`, `"qwen3.5:4b"` -> `"qwen3.5:4b"`, `""` -> `"—"`.
- `components/settings_copy.test.ts` (new): T-T16 `guide and setup copy are provider-specific`: `guideCopyFor("gemini")` returns the AI-Studio guide keys, `guideCopyFor("openai")` returns the OpenAI/Ollama guide keys, `guideCopyFor("remote")` returns the sign-in guide keys; `setupPromptFor(p)` returns a distinct key per provider; all returned keys exist in `MESSAGE_KEYS`.
- `src/stores/__tests__/updater.test.ts` (new): T-T17 action-level invariant with `@tauri-apps/plugin-updater` mocked: disabled marker -> `checkForUpdates()` and `downloadAndInstall()` never call the plugin (mock call count == 0) and `status` stays `idle`; enabled marker -> `checkForUpdates()` calls the mocked `check()` exactly once, and with `check()` resolving a mocked `Update` whose `downloadAndInstall` records its calls, `downloadAndInstall()` invokes it exactly once and ends in `status === "ready"`.
- `src/stores/__tests__/updater_build_binding.test.ts` (new): T-T18 moon task env binding (`tauri-build-h4` has `VITE_KUKU_UPDATER: "off"`).
- `src/components/settings/sections/__tests__/about_section.test.ts` (new, node environment, pure helper): T-T19 `updateChannelLabelFor(marker)` returns the Homebrew key for `kuku-updater-disabled` and null otherwise; `about_section.tsx` renders from it.
- `chat_store.test.ts` T-T14/T-T15 use `setSettingsDraft` / `saveSettingsDraft` / `switchProviderAndSave` (names per D8; the composer's `setDraft` is untouched and T-T20 `composer setDraft still stores the session draft string` guards that).
- `catalog.test.ts`: unchanged, must stay green.

### 5.3 Shell, `scripts/h4`
- `publish_kuku_cask_test.sh`: two temporary working repositories (monorepo, tap) each with a bare remote, plus a fake `gh` and a fake `brew` on PATH recording their arguments (`ruby -c` runs for real); asserts non-zero exit on sha mismatch, on a dirty monorepo, on a dirty tap clone, on a diverged monorepo, on a diverged tap clone, on a leftover template token, on a `brew style` failure and on a `brew info --cask` load failure; runs six injected-failure scenarios (abort after render, after the local commit, during the push with the bare remote made unwritable and then restored, after the release upload, after the first push, after the second push) and re-runs **the release entry point's real preflight plus the publisher** (`publisher_preflight.sh` then `publish_kuku_cask.sh`, the same two units `release_h4.sh` executes) from each resulting state without manual cleanup, asserting convergence to one asset upload with `--clobber` and identical clean remote casks, and that a dirty tree with any other change is still refused by the preflight; and on the happy path exactly one new commit pushed to each bare remote, the exact version and sha present in both remote trees' `Casks/kuku.rb`, and both worktrees clean afterwards.
- `verify_ai_provider_test.sh`: a local listener asserts the probe sends `Authorization: Bearer` when `KUKU_TEST_OPENAI_API_KEY` is set and omits it otherwise, and that a simulated skip line makes the script exit non-zero.

### 5.4 Static gates after every wave
`pnpm moon run kuku-ai:test kuku-ai:lint-check kuku-ai:format-check desktop:test-ts desktop:lint-ts-check desktop:format-ts-check desktop:test-rust desktop:lint-rust-check desktop:format-rust-check web:test`, and (from Wave 3) `scripts/h4/publish_kuku_cask_test.sh`. These never need a network.

### 5.5 Live provider gates (separate, never skippable when invoked)
`scripts/h4/verify_ai_provider.sh` requires `KUKU_TEST_OPENAI_BASE_URL` and `KUKU_TEST_OPENAI_MODEL` to be set, probes `GET <base>/models` first (sending `Authorization: Bearer $KUKU_TEST_OPENAI_API_KEY` when that variable is non-empty, never printing it; a shell test against a local listener asserts the header is present with a key and absent without), runs `cargo test -p kuku-ai openai::tests::live_ -- --nocapture`, and **fails if the output contains the skip line or fewer than 3 live tests ran**. Wave 1 and Wave 3 run it against Ollama on the build host; Wave 4 runs it against Ollama on the build host and against api.openai.com from the laptop.

---

## 6. Work breakdown

### Pre-dispatch bootstrap gate (before every mentee dispatch, overseer)
`git fetch origin` in the mentee worktree; merge `origin/main` into `feat/openai-provider` (fast-forward when possible, otherwise a merge commit; never a force-push); push; assert the worktree HEAD contains the commit of the reviewed plan version, that `docs/plans/2026-09-11-openai-compatible-provider.md` in the worktree has the current `Status:` line, and that the proof file's `git hash-object` equals the one on `main`. The h4 worktree (`feat/kuku-cask`) is created from its then-current `origin/main` under the same gate before Wave 3. Wave 0 was dispatched on the v4 base before this gate existed; its two-file diff is independent of the plan text and it was audited against the v4 gates, so it stands.

### Wave 0, baseline hygiene (done, commit `1db5f0a`)
`crates/kuku-contract/src/lib.rs`: `#![allow(clippy::result_large_err)]` with comment. `oxfmt --write` on `mermaid/runtime_cache.ts`. Acceptance: every existing static gate in 5.4 green (observed; report in `docs/plans/reports/wave0.md`).

### Wave 1, Rust backend
Files: `crates/kuku-ai/Cargo.toml` (+`reqwest`, +`url`), `crates/kuku-ai/moon.yml` (add `fixtures/**/*.json` to the `test` task inputs), `src/types.rs`, `src/provider/mod.rs` (add `ToolChoice`, remove `list_models` from the trait), `src/provider/gemini.rs` and `src/provider/remote.rs` (drop their `list_models` impls; ignore `tool_choice`), `src/provider/openai.rs` (new), `src/state.rs`, `src/error.rs`, `src/commands.rs`, `src/lib.rs`, `build.rs`, `permissions/default.toml`, the regenerated `permissions/autogenerated/**` and `permissions/schemas/schema.json`, `fixtures/host_policy.json` (new), `src/session.rs` (set `tool_choice: Auto` in the request), tests T-R1..T-R16, T-L1..T-L3. Acceptance: static gates in 5.4 green; 5.5 against Ollama on the build host green; `cargo test -p kuku-app` green.

### Wave 2, frontend
Files: `types.ts`, `config.ts`, `chat_store.ts` (settings draft per D8), `provider_readiness.ts`, `chat_panel.tsx`, `components/ai_settings.tsx`, `components/model_label.ts`, `components/settings_copy.ts`, `index.ts`, `stores/updater.ts` (`UPDATER_BUILD_MARKER`, `isUpdaterEnabled`, action-level guards), `components/settings/sections/about_section.tsx` (consumes the marker, renders the Homebrew line), `env.d.ts`, `apps/desktop/moon.yml` (`tauri-build-h4` task, needed by T-T18; Wave 3 adds the conf file; add `/crates/kuku-ai/fixtures/**/*.json` to the `test-ts` task inputs and prove cache invalidation by editing the fixture and observing `desktop:test-ts` and `kuku-ai:test` re-execute), `i18n/keys.ts` + three locales, tests T-T1..T-T21. Acceptance: `desktop:test-ts`, `desktop:lint-ts-check`, `desktop:format-ts-check`, `desktop:build` green.

### Wave 3, docs, fork build config, packaging (two repositories, two worktrees)
kb-app worktree: `tauri.h4.conf.json`, `apps/desktop/moon.yml` (`tauri-build-h4` with `VITE_KUKU_UPDATER=off`), `scripts/h4/{build_h4.sh, check_updater_marker.sh, sign_notarize_dmg.sh, release_h4.sh, lib/publisher_preflight.sh, verify_ai_provider.sh, verify_ai_provider_test.sh, install_kuku_cask.sh, publish_kuku_cask_test.sh}`, docs per section 8. h4 worktree on 27-mac-mini (`~/projects/h4-worktrees/kuku-cask`, branch `feat/kuku-cask`, passed to Codex as an additional writable root): `deploy/homebrew-tap/templates/kuku.rb.tmpl` (the cask with `@VERSION@`/`@SHA256@` placeholders; **no `Casks/kuku.rb` is committed before publication**), `deploy/homebrew-tap/publish_kuku_cask.sh`, README row. The mentee makes a whole-tree commit (`git add -A`) and push in each worktree (`feat/openai-provider`, `feat/kuku-cask`) per section 10; the overseer audits both pushed commits and adds only corrective commits. The h4 commit must pass the h4 pre-commit registry gate: `deploy/homebrew-tap/registry-homebrew-tap.yaml` (subtree depth 0, enumerates immediate children) gains entries for `templates` and `publish_kuku_cask.sh`, every new script carries the `# ---` YAML header the gate requires, and `uv run scripts/registry.py check deploy/homebrew-tap` is a Wave 3 gate. Acceptance: `bash -n` on every script; `release_h4.sh --dry-run`; `publish_kuku_cask_test.sh` green; `pnpm moon run desktop:tauri-build-h4` on the build host yields `Kuku.app` that launches, and the mentee greps its frontend assets for the updater marker (C-UPD2).

### Wave 3b, promotion (overseer, after the Wave 3 audit)
Merge `feat/openai-provider` into kb-app `main` and `feat/kuku-cask` into h4 `main` (fast-forward where possible, otherwise a merge commit), push both, and record the two resulting `main` SHAs in the proof file. Pull both `main` checkouts on the laptop and the build host. No release step runs from a feature branch.

### Wave 4, release (overseer runs exactly one command)
From the laptop: `RELEASE_H4_BUILD_HOST=ts-27-mac-mini scripts/h4/release_h4.sh 0.5.8-h4.1`. The script, fail-closed at every step: (1) clean tree, on `main`, `HEAD == origin/main`, `git merge-base --is-ancestor <reviewed kb-app SHA from the proof> HEAD`, the same ancestry check for the h4 checkout, and the version in `tauri.h4.conf.json` equals the argument; the h4 monorepo checkout and the tap clone are validated by **the publisher's own preflight** (`scripts/h4/lib/publisher_preflight.sh`, sourced by both `release_h4.sh` and `publish_kuku_cask.sh`), which accepts exactly the two recoverable states of D11 and refuses everything else, so a rerun of `release_h4.sh` after a partial publication reaches the publisher's recovery instead of being refused upstream of it; (2) static gates in 5.4 on the laptop; (3) the live gate 5.5 against api.openai.com from the laptop (`KUKU_TEST_OPENAI_BASE_URL=https://api.openai.com/v1`, `KUKU_TEST_OPENAI_MODEL=gpt-5-nano`, key from the login environment, `KUKU_TEST_OPENAI_STRICT_TEXT=1`); (4) over ssh on the build host, in the `main` checkout `~/projects/apps/kb-app` (never a feature worktree): require a clean tree on `main`, `git fetch origin`, `HEAD == origin/main` after `git pull --ff-only`, `git merge-base --is-ancestor <reviewed SHA> HEAD`, and record the exact remote HEAD in the proof; then `verify_ai_provider.sh` against Ollama, `build_h4.sh`, the updater-marker grep on the built assets; (5) the sign/notarize/DMG script inside one `gui/$UID` LaunchAgent, polling `launchctl print` for `last exit code`; (6) `scp` the DMG back, sha256 equality, `spctl -a -t open --context context:primary-signature -vv`; (7) `publish_kuku_cask.sh <version> <sha> <dmg>` (laptop `gh` is logged in as horizonthinking), which uploads the release asset, rewrites and commits the h4 source cask and the tap clone separately, pushes both, and verifies both contain the version and sha; (8) prints the install command for Wave 5. `--dry-run` prints every step.

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
| `~/projects/h4/deploy/homebrew-tap/registry-homebrew-tap.yaml` | Register `templates` and `publish_kuku_cask.sh` (the h4 pre-commit registry gate enumerates immediate children). |
| `~/projects/h4/deploy/homebrew-tap/README.md` | A "Kuku" section matching the depth of the existing per-cask sections: source artifact (kb-app `scripts/h4/release_h4.sh` as the single release owner), the template `templates/kuku.rb.tmpl` and the publisher `publish_kuku_cask.sh`, tag namespace `kuku-v<version>`, the tap URL bootstrap line, authentication (`HOMEBREW_GITHUB_API_TOKEN` from the login environment), upgrade (`brew upgrade --cask horizonthinking/h4/kuku`; the app never self-updates), uninstall (keeps `~/.kuku`), and rollback (previous release tag). |
| This plan | superseded content moves to section 14; observations go to the proof file. |

---

## 9. Sustainability and enforcement

| Mechanism | Type | Catches |
|---|---|---|
| Exhaustive `match config.provider` in Rust | compiler, blocking | provider without a code path |
| `assertNever` + `AI_PROVIDERS` single source | tsc (type-aware lint), blocking | same, TS |
| T-R13 three-way command/handler/permission parity | unit, blocking | a command missing from any registry |
| T-R11 / T-T3 legacy-config tests | unit, blocking | field without a default |
| T-T17 + T-T18 + bundle marker gate in `release_h4.sh` | unit + script, blocking | an H4 build that could contact the upstream updater |
| T-T14 / T-T15 round trips through the store's own actions | unit, blocking | a save path dropping inactive fields or secrets |
| moon inputs: `fixtures/**/*.json` on `kuku-ai:test`, `/crates/kuku-ai/fixtures/**/*.json` on `desktop:test-ts` (both `moon.yml` files in Wave 1/2 scope) | build cache, blocking | a fixture-only policy change served from moon's cache without re-running either consumer; proven in Wave 2 by editing the fixture and observing both tasks re-execute (not "cached") |
| Shared host-policy fixtures (Rust + TS) | unit, blocking | Rust/TS policy drift |
| `catalog.test.ts` | vitest, blocking | missing/empty locale keys (structural) |
| T-R15 stub-server status classification through the real streaming path | unit, blocking | a rig upgrade changing the error text and silently breaking 401/429 handling |
| Live gate 5.5 (`verify_ai_provider.sh`, fails on skip): Ollama on the build host and api.openai.com from the laptop, both inside `release_h4.sh` | script, blocking | provider regression before publishing |
| Shared endpoint fixtures with scheme cases | unit, blocking | a key sent over plaintext HTTP, Rust/TS policy drift |
| `release_h4.sh` as the only release path (Wave 4 invokes nothing else) | script, blocking | dirty tree, red gates, version mismatch |
| `publish_kuku_cask.sh` self-hash + dirty/diverged refusal + test | script + test, blocking | wrong artifact, clobbered tap |
| AGENTS.md regression command | prose | (backed by the scripts above) |

---

## 10. OMSV protocol (self-contained)

- **Overseer** (Claude, this session): frames the work, owns this plan, runs every audit, holds the final 5-item proof, drives Waves 3b, 4 and 5 (GUI LaunchAgent on the build host, ssh to the minis, the single release command).
- **Mentor** (Claude): authored this plan and the draft claims in section 11. A claim is unproven until the mentee confirms it at a green point with a compile fact or test output.
- **Mentee** (Codex, launched through `H4_CODEX_RUN_ID=$(uuidgen) bash ~/projects/h4/scripts/codex_exec_guard.sh exec ...` on 27-mac-mini, sandbox `workspace-write` with `-c sandbox_workspace_write.network_access=true` so cargo can fetch): works in the kb-app worktree `~/projects/apps/kb-app-worktrees/openai-provider` (branch `feat/openai-provider`); for Wave 3 additionally receives `--add-dir ~/projects/h4-worktrees/kuku-cask` (branch `feat/kuku-cask`). One wave per dispatch. Writes its report to `docs/plans/reports/wave<N>.md` with: files touched (`git status --short`), verbatim gate output tails, and a claim table with one row per claim the wave touches, each CONFIRMS / CONTRADICTS / MISSING-LESSON plus evidence, and a list of decisions the plan left open. The mentee may REJECT a claim; a contradicted claim blocks the wave until the plan is amended. **Executable end-of-wave sequence (v9), in this order:** (1) gates; (2) the wave report at `docs/plans/reports/wave<N>.md`; (3) **commit the whole worktree** with `git add -A` (message `feat(openai-provider): wave <N> ...`, co-authored) and push `feat/openai-provider` (and, for Wave 3, commit and push `feat/kuku-cask` in the h4 worktree the same way); (4) **last of all, invoke the installed handoff skill** (`~/.agents/skills/source-command-handoff/SKILL.md`, which Codex loads as a skill) in the kb-app worktree root, exactly as the skill prescribes: it overwrites `HANDOFF.md`, attempts the iMessage step, prints its completion line and stops. The iMessage step cannot succeed on this fleet (the outbound iMessage channel was retired 2026-08-24; the mentee has no iMessage tool), so the skill's attempt fails or is unavailable and the mentee stops there, which is the skill's own contract. Because the skill ends the session, `HANDOFF.md` is left uncommitted by design; the **overseer** verifies it (exists, newest file in the wave, conforms to the template and its 60-line cap), archives a copy as `docs/plans/reports/wave<N>-handoff.md`, and commits both in its audit commit. That is the single, explicit exception to "the mentee commits everything": the mentee's commit carries all implementation and the report; the overseer's audit commit carries the handoff file and any corrections. The root `HANDOFF.md` stays in place for the next dispatch's SessionStart injection. The overseer audits the pushed wave commit, adds corrective commits if needed, and only then accepts the wave.
- **Audit per wave** (overseer): pull the branch, diff the mentee's wave commit against the previous wave's commit, re-run the wave's gates independently, check every claim row against its evidence, verify the handoff file, add corrective commits with `git add -A` if needed, push, and only then dispatch the next wave. A red gate or an unevidenced claim sends the wave back with the specific gap.
- **Adversarial review loop** (before Wave 1; Wave 0 is exempt as pure hygiene): Codex reviews this document read-only against the repository and the vendored crates and returns `{verdict, previous, blocking, major, minor, confirmed}`; the overseer amends the plan for every blocking and major item, or records a rejection with rationale in section 14, and re-submits; the loop continues until `AGREE`. There is no numeric cap; if the overseer ever stops the loop before `AGREE`, every unresolved item is listed in section 12 as an accepted risk with a written rationale, and that decision is itself recorded in section 14.
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

### Round 4 (plan v5, run locally) -> REVISE; 7 of 8 prior items RESOLVED. Dispositions in v6:
- R4-B1 branch behind the reviewed plan: AMENDED (pre-dispatch bootstrap gate in section 6; the branch is merged with `main` and pushed before Wave 1, and the assertion is repeated before every dispatch).
- NEW-M4 (carried) T-T1..T-T4 "as before": AMENDED (full definitions in 5.2).
- R4-M1 test bindings: AMENDED (P13 cites T-R15; Wave 1 T-R1..T-R15; Wave 2 T-T1..T-T20; section 9 row; T-R15 asserts the exact message).
- R4-M2 publisher preconditions and test: AMENDED (D11 both repositories clean/on-main/equal-to-origin; 5.3 test with bare remotes and per-repo assertions).
- R4-M3 placeholder cask on main: AMENDED (Wave 3 commits `templates/kuku.rb.tmpl`; the live cask is rendered at publication).
- R4-M4 plaintext HTTP with a key: AMENDED (D3 `parse_endpoint` with the scheme policy shared by chat and discovery; fixtures gain scheme and userinfo cases; T-R4/T-R5/T-T9b).
- R4-m1 generated permission artifacts: AMENDED (D6, Wave 1 file list; regenerate, never hand-edit).
- R4-m2 enabled `downloadAndInstall` case: AMENDED (T-T17).
- R4-m3 live gates conflated with static gates: AMENDED (5.4 static, 5.5 live with fail-on-skip).

### Round 5 (plan v6, run locally) -> REVISE; 8 of 9 prior items RESOLVED. Dispositions in v7:
- R5-B1 handoff discipline: AMENDED (section 10: every wave ends by writing `HANDOFF.md` in the `/handoff` shape; the overseer verifies freshness and conformance; the mentee is Codex, which cannot run the Claude skill, so it writes the file directly).
- R4-M4 (carried) keyed plaintext HTTP: AMENDED (D3: `https` mandatory whenever a key is present; `http` only for Optional hosts with an empty key; `parse_endpoint(base, key_present)`; fixtures gain `key_present` and keyed-local rejections).
- R5-M1 test bindings: AMENDED (every T-T test has a unique description and explicit assertions; T-T6 uses `saveSettingsDraft`; P12/P17 bound).
- R5-M2 discovery through the real incomplete-config path: AMENDED (T-R16 pins `set_config` storing an incomplete OpenAI config without a backend; T-T21 exercises the store flow end to end; P9 updated).
- R5-M3 cask validation: AMENDED (D11: token check, `ruby -c`, `brew style --cask`, `brew info --cask <path>` before upload; test coverage).
- R5-M4 idempotent recovery: AMENDED (D11: create-or-clobber upload, convergent per-repo commits, three injected-failure reruns in the test).
- R5-m1 query/fragment: AMENDED (D3, fixtures). R5-m2 authenticated probe: AMENDED (5.5, `verify_ai_provider_test.sh`). R5-m3 round cap: AMENDED (section 10). R5-m4 T-R7 construction: AMENDED. R5-m5 README depth: AMENDED (section 8).

### Round 6 (plan v7, run locally) -> REVISE; 8 of 11 prior items RESOLVED. Dispositions in v8:
- R5-B1 (carried) handoff: AMENDED (section 10: the mentee runs the installed `source-command-handoff` skill; the retired iMessage step is skipped explicitly; the root `HANDOFF.md` stays for injection and a copy is archived).
- R5-M2 (carried) keyed stub tests vs the HTTPS rule: AMENDED (D6 splits `parse_endpoint` policy from `list_models_at` transport; T-R14 keyed case constructs `Endpoint` directly; T-R16 split into local-empty-key discovery and keyed-HTTPS persistence without network).
- R5-M4 (carried) publisher recovery: AMENDED (D11 states the two self-inflicted states it reconciles and refuses everything else; six injected-failure scenarios in 5.3).
- NEW-M1 moon cache and the shared fixture: AMENDED (both `moon.yml` inputs in Wave 1/2 scope; section 9 row; invalidation proof in Wave 2).
- NEW-M2 build host revision: AMENDED (Wave 4 step 4: clean `main` checkout, fetch, `HEAD == origin/main`, ancestry, remote HEAD recorded).
- NEW-M3 request bound: AMENDED (D12: at most 4 chat requests and 2 models listings).
- NEW-M4 mentee commits: AMENDED (section 10: the mentee commits and pushes each wave with `git add -A`; the overseer audits the pushed commit).
- NEW-m1 signature consistency: AMENDED (D3, D6, T-R4). NEW-m2 duplicate row: AMENDED.

### Round 7 (plan v8, run locally) -> REVISE; 5 of 9 prior items RESOLVED. Dispositions in v9:
- R5-B1 (carried) handoff sequence impossible as written: AMENDED (section 10: commit and push first, invoke the skill last exactly as it prescribes and stop; the overseer commits the handoff file in its audit commit as the one explicit exception).
- R5-M4 (carried) recovery unreachable through the entry point: AMENDED (shared `lib/publisher_preflight.sh` used by both `release_h4.sh` and the publisher; the test reruns preflight + publisher from all six states).
- NEW-M4 (carried) commit ownership: AMENDED (Wave 3 now matches section 10).
- R7-M1 h4 registry gate: AMENDED (registry entries, YAML headers, `registry.py check` as a Wave 3 gate; section 8 row).
- NEW-m1 (carried) T-R4 vs policy: AMENDED (public hosts tested with `key_present = true`). R7-m1 stale three-scenario sentence: AMENDED. R7-m2 missing round-trip row: AMENDED (restored).
