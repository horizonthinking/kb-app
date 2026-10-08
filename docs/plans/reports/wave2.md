# Wave 2 OMSV mentee report

Date: 2026-09-11
Branch: `feat/openai-provider`
Role: OMSV mentee
Binding plan: `docs/plans/2026-09-11-openai-compatible-provider.md`, v26

## Outcome

Wave 2 adds the OpenAI-compatible desktop configuration, store-owned settings draft, provider readiness gate, provider-aware setup and guide copy, secure two-key persistence, model discovery, H4 updater action guards, and the H4 About label. The two Wave 1 audit corrections were applied first: T-R21 now covers a dropped SSE body with one terminal attempt, and live tests print exactly one attempt-tagged `LIVE_REQUESTS` line.

C-UPD2 initially contradicted the assumed esbuild folding. The required R9 fallback was implemented with the Vite-injected `__KUKU_UPDATER__` constant. The final disabled and enabled bundles contain exactly one respective marker.

## Files touched

Verbatim `git status --short` immediately before writing this report, plus this report's own untracked line:

```text
 M apps/desktop/moon.yml
 M apps/desktop/src/components/settings/sections/about_section.tsx
 M apps/desktop/src/env.d.ts
 M apps/desktop/src/i18n/keys.ts
 M apps/desktop/src/i18n/locales/en.ts
 M apps/desktop/src/i18n/locales/ja.ts
 M apps/desktop/src/i18n/locales/ko.ts
 M apps/desktop/src/plugins/builtin/ai_chat/chat_panel.tsx
 M apps/desktop/src/plugins/builtin/ai_chat/chat_store.test.ts
 M apps/desktop/src/plugins/builtin/ai_chat/chat_store.ts
 M apps/desktop/src/plugins/builtin/ai_chat/components/ai_settings.tsx
 M apps/desktop/src/plugins/builtin/ai_chat/config.ts
 M apps/desktop/src/plugins/builtin/ai_chat/index.ts
 M apps/desktop/src/plugins/builtin/ai_chat/types.ts
 M apps/desktop/src/stores/updater.ts
 M apps/desktop/vite.config.ts
 M crates/kuku-ai/src/provider/openai.rs
 M scripts/h4/verify_ai_provider.sh
 M scripts/h4/verify_ai_provider_test.sh
?? apps/desktop/src/components/settings/sections/__tests__/
?? apps/desktop/src/components/settings/sections/update_channel_label.ts
?? apps/desktop/src/plugins/builtin/ai_chat/components/model_label.test.ts
?? apps/desktop/src/plugins/builtin/ai_chat/components/model_label.ts
?? apps/desktop/src/plugins/builtin/ai_chat/components/settings_copy.test.ts
?? apps/desktop/src/plugins/builtin/ai_chat/components/settings_copy.ts
?? apps/desktop/src/plugins/builtin/ai_chat/components/setup_gate.test.tsx
?? apps/desktop/src/plugins/builtin/ai_chat/components/setup_gate.tsx
?? apps/desktop/src/plugins/builtin/ai_chat/config.test.ts
?? apps/desktop/src/plugins/builtin/ai_chat/provider_readiness.test.ts
?? apps/desktop/src/plugins/builtin/ai_chat/provider_readiness.ts
?? apps/desktop/src/stores/__tests__/updater.test.ts
?? apps/desktop/src/stores/__tests__/updater_build_binding.test.ts
?? docs/plans/reports/wave2.md
```

The generated `.pnpm-store/` cache was removed before this status capture. `git diff --check` produced no output.

## Ground truth and expected versus observed

The binding user brief stated that the disabled bundle counts must be `1` and `0`, the default bundle counts must be `0` and `1`, the fixture-only edit must re-execute both moon consumers, and the live verifier must emit one attempt-tagged line per named test with aggregate `chat=3 models=2`.

| Assertion | Expected | Observed |
|---|---:|---:|
| TypeScript tests | 88 files, 474 tests | 88 files, 474 tests |
| Type-aware lint | 0 errors | 0 errors, 11 pre-existing out-of-scope warnings |
| TypeScript formatting | all matched | all matched |
| Desktop production build | exit 0 | exit 0 |
| Desktop Rust tests | 334 pass, 0 fail | 334 pass, 0 fail |
| `kuku-ai` tests | 57 pass, 0 fail | 57 pass, 0 fail |
| Fixture unchanged second run | both cached | both cached |
| Fixture-only whitespace edit | both execute | both executed with new hashes |
| Disabled bundle markers | disabled 1, enabled 0 | disabled 1, enabled 0 |
| Default bundle markers | disabled 0, enabled 1 | disabled 0, enabled 1 |
| Ollama live verifier | chat 3, models 2 | chat 3, models 2 |
| Legacy live-request line | 0 | 0 |

## Moon fixture cache proof

Unchanged second run tail:

```text
▮▮▮▮ kuku-ai:test (cached, ecf9775e)
desktop:test-ts | RUN  v4.1.5 /Users/michasmi/projects/apps/kb-app-worktrees/openai-provider/apps/desktop
desktop:test-ts |
desktop:test-ts |
desktop:test-ts |  Test Files  88 passed (88)
desktop:test-ts |       Tests  474 passed (474)
desktop:test-ts |    Start at  10:37:28
desktop:test-ts |    Duration  3.41s (transform 5.04s, setup 0ms, import 8.20s, tests 2.85s, environment 7.31s)
▮▮▮▮ desktop:test-ts (cached, 293ce08c)

Tasks: 2 completed (2 cached)
 Time: 152ms ❯❯❯❯ to the moon
```

After adding one blank line to `crates/kuku-ai/fixtures/host_policy.json`, both tasks received new hashes and executed:

```text
▮▮▮▮ kuku-ai:test (6fd65f5d)
▮▮▮▮ desktop:test-ts (94d03608)

desktop:test-ts |  Test Files  88 passed (88)
desktop:test-ts |       Tests  474 passed (474)
desktop:test-ts |    Duration  3.43s (transform 5.59s, setup 0ms, import 8.82s, tests 2.90s, environment 6.48s)
▮▮▮▮ desktop:test-ts (3s 771ms, 94d03608)

   kuku-ai:test | test result: ok. 57 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.14s
▮▮▮▮ kuku-ai:test (4s 137ms, 6fd65f5d)

Tasks: 2 completed
 Time: 4s 223ms
```

The blank line was then reverted. `git diff -- crates/kuku-ai/fixtures/host_policy.json` produced no output.

## Gate output tails

### `pnpm moon run desktop:test-ts`

```text
 Test Files  88 passed (88)
      Tests  474 passed (474)
   Start at  10:44:41
   Duration  3.25s (transform 5.56s, setup 0ms, import 8.77s, tests 2.32s, environment 6.15s)

(node:21862) ExperimentalWarning: localStorage is not available because --localstorage-file was not provided.
(Use `node --trace-warnings ...` to show where the warning was created)
▮▮▮▮ desktop:test-ts (3s 666ms, 9a6c1ab4)

Tasks: 1 completed
 Time: 3s 825ms
```

### `pnpm moon run desktop:lint-ts-check`

```text
Found 11 warnings and 0 errors.
Finished in 5.9s on 356 files with 263 rules using 10 threads.
▮▮▮▮ desktop:lint-ts-check (6s 15ms, 945585bd)

Tasks: 1 completed
 Time: 6s 169ms
```

All 11 warnings are in pre-existing voxel-graph and Mermaid files outside Wave 2.

### `pnpm moon run desktop:format-ts-check`

```text
▮▮▮▮ desktop:format-ts-check (95bb7e8a)
Checking formatting...

All matched files use the correct format.
Finished in 344ms on 382 files using 10 threads.
▮▮▮▮ desktop:format-ts-check (415ms, 95bb7e8a)

Tasks: 1 completed
 Time: 564ms
```

### `pnpm moon run desktop:build`

```text
dist/assets/chunk-graph_canvas_3d-MqBbnk4P.js                 755.25 kB │ gzip: 217.08 kB
dist/assets/entry-index-DWobXVeV.js                         2,220.37 kB │ gzip: 701.74 kB

✓ built in 1.59s
[plugin builtin:vite-reporter]
(!) Some chunks are larger than 500 kB after minification. Consider:
- Using dynamic import() to code-split the application
- Use build.rolldownOptions.output.codeSplitting to improve chunking: https://rolldown.rs/reference/OutputOptions.codeSplitting
- Adjust chunk size limit for this warning via build.chunkSizeWarningLimit.
▮▮▮▮ desktop:build (2s 280ms, 4979a5b9)

Tasks: 1 completed
 Time: 2s 716ms
```

### `TMPDIR=/private/tmp pnpm moon run desktop:test-rust`

```text
test result: ok. 334 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.82s

     Running unittests src/main.rs (/Users/michasmi/projects/apps/kb-app-worktrees/openai-provider/target/debug/deps/kuku_app-85e7edf62fbe7ca4)

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

   Doc-tests app_lib

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

▮▮▮▮ desktop:test-rust (13s 547ms, b06046c8)

Tasks: 1 completed
 Time: 13s 657ms
```

## Wave 1 correction gates

### `TMPDIR=/private/tmp cargo test -p kuku-ai`

```text
test provider::openai::tests::stream_turn_classifies_401_403_429_from_stub_server ... ok
test provider::openai::tests::request_body_omits_tool_choice_without_tools ... ok
test provider::openai::tests::list_models_against_local_stub_server ... ok
test provider::openai::tests::counted_http_client_logs_before_send_and_refuses_on_log_failure ... ok

test result: ok. 57 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.23s

   Doc-tests kuku_ai

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

### `TMPDIR=/private/tmp scripts/h4/verify_ai_provider_test.sh`

```text
verify_ai_provider_test: all rejection, clean-run, header, and renewal cases passed
```

### Ollama verifier

Command:

```text
TMPDIR=/private/tmp KUKU_TEST_OPENAI_BASE_URL=http://127.0.0.1:11434/v1 KUKU_TEST_OPENAI_MODEL=qwen3.5:4b KUKU_LIVE_REQUEST_LOG=/private/tmp/kuku-wave2-live.log scripts/h4/verify_ai_provider.sh
```

Verbatim relevant output tail:

```text
running 1 test
LIVE_REQUESTS attempt=dbeebcab-e0c2-425a-9d0e-358a9ec2ef51 test=live_streams_text_with_usage_identities chat=1 models=0
test provider::openai::tests::live_streams_text_with_usage_identities ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 56 filtered out; finished in 8.53s
    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.57s
     Running unittests src/lib.rs (target/debug/deps/kuku_ai-da9d7abd182928e2)

running 1 test
LIVE_REQUESTS attempt=17eb9d1e-70b6-4884-8d7a-ef4d6488aa92 test=live_list_models_contains_the_configured_model_once chat=0 models=1
test provider::openai::tests::live_list_models_contains_the_configured_model_once ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 56 filtered out; finished in 0.03s
    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.18s
     Running unittests src/lib.rs (target/debug/deps/kuku_ai-da9d7abd182928e2)

running 1 test
LIVE_REQUESTS attempt=a246eaa7-0e38-4640-8528-e26e99a7d476 test=live_two_round_tool_call_replays_ids chat=2 models=0
test provider::openai::tests::live_two_round_tool_call_replays_ids ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 56 filtered out; finished in 8.54s
LIVE_GATE_RECEIPT chat=3 models=2 attempts=06b899fe-a845-4db6-be85-ad1c61999be0,dbeebcab-e0c2-425a-9d0e-358a9ec2ef51,17eb9d1e-70b6-4884-8d7a-ef4d6488aa92,a246eaa7-0e38-4640-8528-e26e99a7d476
```

There is no second `LIVE_REQUESTS test=...` line without an attempt id.

## C-UPD2 bundle proof

Before R9, the exact grep pair observed `1` disabled file and `1` enabled file. After the `define` fallback, the final runs were:

### Disabled build

```text
$ VITE_KUKU_UPDATER=off pnpm moon run desktop:build
✓ built in 1.58s
▮▮▮▮ desktop:build (2s 167ms, da0fe460)

Tasks: 1 completed
 Time: 2s 595ms

$ grep -rl "kuku-updater-disabled" dist/assets | wc -l
       1
$ grep -rl "kuku-updater-enabled" dist/assets | wc -l
       0
```

### Default enabled build

```text
$ pnpm moon run desktop:build
✓ built in 1.59s
▮▮▮▮ desktop:build (2s 280ms, 4979a5b9)

Tasks: 1 completed
 Time: 2s 716ms

$ grep -rl "kuku-updater-disabled" dist/assets | wc -l
       0
$ grep -rl "kuku-updater-enabled" dist/assets | wc -l
       1
```

## Claim validation

| Claim | Disposition | Evidence |
|---|---|---|
| C-SEC1 | CONFIRMS | `plugin_settings.rs:75-116` iterates each supplied secure key for read, save, and deletion. T-T6 observes `secureKeys: ["apiKey", "openaiApiKey"]` with normalized values at persistence and runtime sync; T-T7 observes the same two-key list on clear. |
| C-CFG1 (TS) | CONFIRMS | T-T3 loads the exact pre-change Gemini object and observes provider/key preservation plus default/null OpenAI fields. The full 474-test run includes it. |
| C-UPD | CONFIRMS | T-T17 observes zero updater-plugin calls and `idle` in a disabled build, then exactly one `check()` and one `downloadAndInstall()` with final `ready` when enabled. T-T18 reads `moon.yml` and observes `VITE_KUKU_UPDATER: "off"` in `tauri-build-h4`. Both actions guard internally. |
| C-UPD2 | CONFIRMS | The original expression contradicted at `1/1`; the plan's R9 fallback was applied. Final exact bundle counts are disabled `1/0` and default `0/1`. `$VITE_KUKU_UPDATER` is a moon build input, producing distinct hashes and preventing cross-env cache restoration. |
| C-REQ1 | CONFIRMS | T-R21 drives a valid SSE prefix followed by a mid-body close through the concrete OpenAI adapter. It observes one counted/logged streaming attempt, a terminal backend error, and no second `send_streaming`; all 57 `kuku-ai` tests pass. |
| D8 secret-input extraction | MISSING-LESSON | D8 requires two show/hide secret rows but did not name their shared UI unit. A local `ApiKeyInput` component inside `ai_settings.tsx` was needed to keep Gemini and OpenAI behavior identical without duplicated markup. |

No claim remains contradicted after the required R9 fallback.

## Decisions made

- Applied R9 because production output disproved the original constant-folding claim. The test mode retains `import.meta.env` so `vi.stubEnv` can exercise both branches; production mode uses `__KUKU_UPDATER__`.
- Added `$VITE_KUKU_UPDATER` to the `desktop:build` moon inputs after observing that the first env-specific command restored a cached default bundle.
- Kept `ApiKeyInput` local to `ai_settings.tsx`; it is implementation detail rather than another public component surface.
- Used a suffix comparison in `updateChannelLabelFor` and the injected boolean in `isUpdaterEnabled`, ensuring the opposite full marker literal cannot survive the production bundle.

The plan left no Wave 2 product decision requiring owner input.

## Explicit unknowns

- Japanese and Korean strings are complete, non-placeholder translations, but native-speaker quality review remains outstanding as anticipated by D9.
- Wave 2 does not add `src-tauri/tauri.h4.conf.json`; therefore `tauri-build-h4` is structurally bound by T-T18 but is not runnable until Wave 3 adds that config.
- No interactive packaged-app screenshot was produced in this frontend-only wave. T-T23 is render-level SSR coverage for every provider/readiness pair; packaged UI proof belongs to the later build/install waves.
- The repository still emits 11 pre-existing lint warnings in voxel-graph and Mermaid code and a production chunk-size warning. Neither is introduced by this wave.
