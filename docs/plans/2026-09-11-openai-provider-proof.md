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

`b3sum` (2026-09-11, `command -v b3sum` in a login shell): absent on the laptop, absent on 27-mac-mini, absent on home-mac-mini at baseline; installed by the overseer with `brew install b3sum` on 2026-09-11 after Wave 3 (the mentee's sandbox cannot write `/opt/homebrew`), now `/opt/homebrew/bin/b3sum` on all three; `brew info b3sum` on the laptop shows `b3sum: stable 1.8.7 (bottled)`. Phase A step 1b and the installer preflight install it.

Laptop application state changed during the day (observed 2026-09-11 16:10 local): `/Applications/Kuku.app` now exists, modified `Sep 10 22:35:37 2026`, `CFBundleShortVersionString 0.5.8`, `CFBundleVersion 0.5.8`, `CFBundleIdentifier mom.kuku.app`, signed `Developer ID Application: askitmore Co, Ltd (G5Y49VU39W)` (upstream's identity, not H4's), neither H4 updater marker present in `Contents/Resources` (`0/0`), no `Kuku` process; Homebrew still lists only the upstream receipt `kuku-mom/kuku/kuku 0.5.4` and the h4 tap has no `kuku` cask. Consequence for Wave 5 on the laptop: the pre-install state is a foreign receipt plus a non-Homebrew app, so the receipt is removed by hand first (step 2a) and the installer moves the bundle aside as `app_bundle` backup (step 2b).

Existing Homebrew `kuku` cask receipts (2026-09-11, `brew info --cask --json=v2 kuku`, name-only): laptop `full_token=kuku-mom/kuku/kuku tap=kuku-mom/kuku installed=0.5.4 version=0.5.4` with `/Applications/Kuku.app` absent; 27-mac-mini and home-mac-mini: `brew info --cask --json=v2 kuku` reports no `kuku` cask known to that Homebrew (the h4 tap carries none yet and upstream's tap is not tapped there), `/Applications/Kuku.app` absent on both.

Homebrew cask-load probes on the laptop (2026-09-11, Homebrew 6.0.22-306): `brew info --cask /Users/michasmi/projects/h4/deploy/homebrew-tap/Casks/adapt.rb --json=v2` exits 1 with `Homebrew requires casks to be in a tap` (reported by Codex review round 32). `brew tap h4-validate/probe-<pid> file:///tmp/<repo>` (a temporary git repository holding `Casks/adapt.rb` and `lib/`) fails with `Cannot tap ...: invalid syntax in tap!` preceded by `Refusing to load cask ... from untrusted tap`, and `brew trust` before the tap does not change that. `brew tap-new h4-validate/probe-tn<pid>`, then copying `Casks/` and `lib/` into `$(brew --repo ...)` and committing, then `brew trust h4-validate/probe-tn<pid>`, then `brew info --cask --json=v2 h4-validate/probe-tn<pid>/adapt` printed `version 0.2.0`, the expected sha256 and `tap h4-validate/probe-tn<pid>`; `brew style --cask h4-validate/probe-tn<pid>/adapt` ran (3 offenses on the existing Adapt cask). `brew untap h4-validate/probe-tn<pid>` refused with `Would untap ... after uninstalling the following casks: h4-validate/probe-tn<pid>/adapt` even though no `adapt` cask is installed on the laptop (`brew list --cask` and `brew info --cask --json=v2 --installed` list none, `/Applications/Adapt.app` absent; Homebrew's untap check matched a stale bare-token Caskroom directory); `brew untap --force` removed the tap (`Untapped 1 cask (46 files)`), leaving no `h4-validate` tap directory. Consequence for the plan: the validation tap must be created with `brew tap-new`, trusted with `brew trust`, loaded by tap-qualified token, and removed with `brew untap --force` in the trap. Afterwards `brew trust --json=v1` still listed the three probe taps (`h4-validate/probe-7715`, `h4-validate/probe-9763`, `h4-validate/probe-tn11474`) under `taps`, so `brew untap` does not remove trust; each was removed with `brew untrust --tap <tap>` (`Untrusted tap: ...`) and the list then contained no `h4-validate` entry.

Ollama on 27-mac-mini: brew service `sh.brew.ollama` started 2026-09-11; `ollama list` shows `qwen3.5:4b 3.4 GB`; a chat completion returned `"content":"pong"`.

GitHub access from 27-mac-mini (2026-09-11, before the Wave 3 dispatch): `gh auth status` reports the stored token for `horizonthinking` is invalid, so HTTPS pushes through the `gh` credential helper fail (`could not read Username for 'https://github.com': Device not configured`); `ssh -T git@github.com` authenticates as `horizonthinking`. The kb-app checkout's `origin` on the mini was switched to `git@github.com:horizonthinking/kb-app.git` (the h4 checkout already used SSH). The release plan never uses `gh` on the minis (Wave 4 runs `gh` on the laptop only), so no token repair is needed there for the release.

Codex: 27-mac-mini `codex-cli 0.153.1`, home-mac-mini `codex-cli 0.151.0`, both answered `ALIVE` through the guard; laptop `codex-cli 0.154.0` initially could not refresh its ChatGPT token ("refresh token was already used"); Michael re-ran `codex login` on 2026-09-11 and the laptop then answered `ALIVE` through the guard, so review rounds 4 onward ran locally while the mentee stays on 27-mac-mini.

Release repository (2026-09-11, laptop, `gh` as `horizonthinking`, a User account): `gh repo create horizonthinking/kuku-releases --private` -> `https://github.com/horizonthinking/kuku-releases`; `gh api -X GET repos/horizonthinking/kuku-releases/immutable-releases` -> `{"enabled":false,"enforced_by_owner":false}`; `gh api -X PUT repos/horizonthinking/kuku-releases/immutable-releases` -> (empty body); `GET` again -> `{"enabled":true,"enforced_by_owner":false}`. For comparison `gh api repos/horizonthinking/homebrew-h4/releases` shows the Adapt release with `"draft":false,"immutable":false` and `assets[0].digest = sha256:0731768060b755a907d8ea20833d12547f9381f0a9d3c4989f9ba39f69a65a5c`, confirming the REST `immutable` and `assets[].digest` fields.

Repository initialization and consumer access precheck (2026-09-11, laptop): `gh api -X PUT repos/horizonthinking/kuku-releases/contents/README.md` (artifact-only README) -> `{"commit":"dbf0feb07e16551b34c4bdcc43c683c47b42f81c","path":"README.md"}`; `gh api repos/horizonthinking/kuku-releases` -> `{"default_branch":"main","private":true,"visibility":"private"}`; branches -> `main` at `dbf0feb07e16551b34c4bdcc43c683c47b42f81c`. From a login shell on each Mac, `curl -s -o /dev/null -w "%{http_code}"` with `Authorization: Bearer $HOMEBREW_GITHUB_API_TOKEN` (inside the shell, never printed) against `https://api.github.com/repos/horizonthinking/kuku-releases` returned `200` on the laptop, `200` on 27-mac-mini and `200` on home-mac-mini.

## B. Post-change observations

### B1. Wave 3 audit (2026-09-11, overseer, 27-mac-mini worktree at `2b613c0`, h4 `9598ce437`)
Independent gate re-run (`audit_wave3.sh`): `cargo test -p kuku-ai` `62 passed; 0 failed` (10 `gate_and_apply_preserves_approval_semantics_*` cases, `adapt_stream_does_not_emit_finished_after_error`, `fingerprint_matches_shared_vectors`, `refuses_send_on_missing_or_mismatched_fingerprint` listed); clippy `Finished`; `cargo fmt --check` exit 0; `desktop:test-ts` `88 files, 476 tests passed` (T-T24/T-T25 present); lint `0 errors`; format `All matched files use the correct format`; Ollama verifier `LIVE_GATE_RECEIPT chat=3 models=2` with a fingerprinted `receipt config=7bc419a6...` line; `desktop:tauri-build-h4` `Finished 1 bundle`; `UPDATER_MARKERS disabled=1 enabled=0`; built `Info.plist` `CFBundleShortVersionString 0.5.8`, `CFBundleVersion 5.8.1`, `CFBundleExecutable kuku-app`; `open -n <bundle>` from an ssh session launched pid `74312 .../Kuku.app/Contents/MacOS/kuku-app` (the mentee's `kLSNoExecutableErr` was the Codex sandbox). `pgrep -x Kuku` matches nothing; `pgrep -x kuku-app` matches the process (plan v58 correction). Shell suites: `release_h4_test.sh` `PASS cases=91`, `publish_kuku_cask_test.sh` `PASS cases=58`, `install_kuku_cask_test.sh` `PASS cases=34`, `publish_kuku_cask_realbrew_test.sh` `PASS`, but most cases print inspection-only or lease-only labels without exercising behaviour, as the mentee's own report rejects; `smoke_kuku_app_test.sh`, `update_repo_file_test.sh`, `verify_ai_provider_test.sh` `PASS`; `registry.py check` clean; no `h4-validate` tap or trust entry left behind. Wave 3 not accepted; Wave 3c dispatched for behavioural tests and the process-name fix.

## C. Expected vs observed (P1..P18 and per-machine install checks)
(filled in at DoD time; a missing row is a failure)

## D. Explicit unknowns
(filled in at DoD time)
