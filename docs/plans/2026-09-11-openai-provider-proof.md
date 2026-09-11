# Proof file: OpenAI-compatible provider (dated observations)

Companion to `2026-09-11-openai-compatible-provider.md`. Everything here is a dated, machine-specific observation. The plan holds durable design; this file holds what was actually seen, verbatim, before and after the change.

## A. Pre-change ground truth

Implementation base: `main` at `458f34b`. Captured on the laptop (ComputerName `agent-mini`, tailnet name `laptop-m3`) starting 2026-09-11T05:03Z after `pnpm install --frozen-lockfile` exited 0. Toolchain inventory captured 2026-09-11T06:28:03Z:

```
macOS 27.0
Xcode 27.0
cargo 1.98.0 (797e8a9bc 2026-08-05) (Homebrew)
rustc 1.98.0 (88d9e12ae 2026-08-18) (Homebrew)
node v26.8.1
pnpm 11.1.1
go version go1.27.0 darwin/arm64
```

### A1. `cargo test -p kuku-ai` (tail)
```
test tools::descriptor::tests::inline_mode_allows_read_only_tools_and_edit_file_only ... ok
test tools::descriptor::tests::ask_mode_allows_only_read_only_tools ... ok

test result: ok. 22 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s

   Doc-tests kuku_ai

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

### A2. `cargo test -p kuku-app` (tail)
```
test knowledge::apply::tests::stale_staged_journal_without_created_paths_is_cleaned_before_apply ... ok

test result: ok. 334 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.40s

     Running unittests src/main.rs (target/debug/deps/kuku_app-5dbea528577a91f9)

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

   Doc-tests app_lib

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

### A3. `cargo clippy -p kuku-ai -p kuku-app --all-targets -- -D warnings` (tail) and `pnpm moon run kuku-ai:lint-check`
```
     = help: try reducing the size of `connectrpc::ConnectError`, for example by boxing large elements or replacing it with `Box<connectrpc::ConnectError>`
     = help: for further information visit https://rust-lang.github.io/rust-clippy/rust-1.98.0/index.html#result_large_err

error: could not compile `kuku-contract` (lib) due to 80 previous errors
warning: build failed, waiting for other jobs to finish...
```
Error class count from `cargo clippy -p kuku-ai --all-targets -- -D warnings 2>&1 | grep -E "^error" | sort | uniq -c`:
```
  80 error: the `Err`-variant returned from this function is very large
   1 error: could not compile `kuku-contract` (lib) due to 80 previous errors
```
Files (from `--> ` lines): `crates/kuku-contract/src/generated/connect/kuku.sync.v1.sync.rs` (46), `kuku.auth.v1.auth.rs` (26), `kuku.dashboard.v1.dashboard.rs` (6), `kuku.ai.v1.ai.rs` (2).

### A4. `cargo fmt -p kuku-ai -p kuku-app -- --check`
No output, exit 0.

### A5. `pnpm moon run desktop:test-ts`
```
### git HEAD 458f34b 2026-09-11T05:03:18Z
 Test Files  80 passed (80)
      Tests  451 passed (451)
   Start at  01:03:38
   Duration  3.05s (transform 9.37s, setup 0ms, import 14.06s, tests 3.73s, environment 7.76s)

▮▮▮▮ desktop:test-ts (3s 918ms, 34575b35)

Tasks: 1 completed
 Time: 15s 736ms
```

### A6. `pnpm moon run web:test`
```
   Start at  01:03:47
   Duration  167ms (transform 70ms, setup 0ms, import 91ms, tests 22ms, environment 0ms)

▮▮▮▮ web:test (512ms, 66bedc23)

Tasks: 1 completed
 Time: 4s 537ms
```

### A7. `pnpm moon run desktop:lint-ts-check`
```
Finished in 6.4s on 343 files with 263 rules using 14 threads.
▮▮▮▮ desktop:lint-ts-check (6s 731ms, 5c10096b)

Tasks: 1 completed
 Time: 6s 879ms
```

### A8. `pnpm moon run desktop:format-ts-check` and `cd apps/desktop && pnpm exec oxfmt --check .`
```
  × Task desktop:format-ts-check failed to run.
  ╰─▶ Process oxfmt failed: exit code 1
```
```
Checking formatting...
src/plugins/builtin/mermaid/runtime_cache.ts (1ms)
Format issues found in above 1 files. Run without `--check` to fix.
Finished in 382ms on 369 files using 14 threads.
```

### A9. Live provider observations (2026-09-11, laptop)
`curl` non-streaming `POST http://127.0.0.1:11434/v1/chat/completions` with model `qwen3.5:4b` and one `list_files` tool:
```
finish: tool_calls
tool_calls: [{"id": "call_cjumc699", "index": 0, "type": "function", "function": {"name": "list_files", "arguments": "{\"path\":\"/\"}"}}]
content:
usage: {'prompt_tokens': 292, 'prompt_tokens_details': {'cached_tokens': 0}, 'completion_tokens': 67, 'total_tokens': 359}
```
Streaming first chunk (non-standard `reasoning` field):
```
data: {"id":"chatcmpl-801","object":"chat.completion.chunk","created":1789103128,"model":"qwen3.5:4b","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":"","reasoning":"The"},"finish_reason":null}]}
```
`GET https://api.openai.com/v1/models` (key from the session environment, used only inside the request): `138 models`, list includes `gpt-5-nano`, `gpt-5-mini`, `gpt-5`.

### A10. Machine state relevant to Waves 4 and 5 (2026-09-11, name-only, no values)
| Machine | Developer ID identity | ASC key | cargo | node/pnpm | Xcode | tap `horizonthinking/h4` (login shell) | `HOMEBREW_GITHUB_API_TOKEN` exported (login shell) | `/Applications/Kuku.app` | `op` CLI |
|---|---|---|---|---|---|---|---|---|---|
| laptop (agent-mini / laptop-m3) | no (Apple Development only) | n/a | 1.98.0 | v26.8.1 / 11.1.1 | 27.0 | present | set, 40 chars | absent | present |
| 27-mac-mini | yes | `AuthKey_CABZCFW333.p8` | 1.98.0 (Homebrew, no rustup) | v26.8.1 / 11.25.0 | 27.0 | present | set, 40 chars | absent | absent |
| home-mac-mini | yes | `AuthKey_CABZCFW333.p8` | absent | v26.8.1 / 11.24.0 | 27.0 | present | set, 40 chars | absent | absent |

Ollama on 27-mac-mini: brew service `sh.brew.ollama` started 2026-09-11; `ollama list` shows `qwen3.5:4b 3.4 GB`; a chat completion returned `"content":"pong"`.

Codex: 27-mac-mini `codex-cli 0.153.1`, home-mac-mini `codex-cli 0.151.0`, both answered `ALIVE` through the guard; laptop `codex-cli 0.154.0` cannot refresh its ChatGPT token ("refresh token was already used"), so all Codex work runs on 27-mac-mini.

## B. Post-change observations
(filled in by the overseer after each wave and at release; empty until then)

## C. Expected vs observed (P1..P17 and per-machine install checks)
(filled in at DoD time; a missing row is a failure)

## D. Explicit unknowns
(filled in at DoD time)
