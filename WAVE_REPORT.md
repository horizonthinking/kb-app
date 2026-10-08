# Wave 0 report

## Files touched

Verbatim `git status --short`:

```text
 M apps/desktop/src/plugins/builtin/mermaid/runtime_cache.ts
 M crates/kuku-contract/src/lib.rs
?? WAVE_REPORT.md
```

## Gate output tails

### `pnpm moon run kuku-ai:lint-check`

Exit status: 0

```text
   Compiling kuku-ai v0.1.0 (/Users/michasmi/projects/apps/kb-app-worktrees/openai-provider/crates/kuku-ai)
   Compiling tauri-macros v2.6.2
    Checking blake3 v1.8.5
▮▮▮▮ kuku-ai:lint-check (running for 30s)
   Compiling aws-lc-rs v1.17.0
   Compiling rustls v0.23.40
    Checking rustls-webpki v0.103.13
    Checking tokio-rustls v0.26.4
    Checking rustls-platform-verifier v0.7.0
    Checking hyper-rustls v0.27.9
    Checking connectrpc v0.3.3
    Checking reqwest v0.13.4
    Checking rig-core v0.32.0
    Checking kuku-contract v0.1.0 (/Users/michasmi/projects/apps/kb-app-worktrees/openai-provider/crates/kuku-contract)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 40.92s
▮▮▮▮ kuku-ai:lint-check (41s 2ms, 24bebe99)

Tasks: 1 completed
 Time: 41s 93ms
```

### `pnpm moon run desktop:lint-rust-check`

Exit status: 0

```text
    Checking window-vibrancy v0.6.0
    Checking objc2-osa-kit v0.3.2
    Checking osakit v0.3.1
    Checking rusqlite v0.32.1
    Checking zstd v0.13.3
    Checking rustls-webpki v0.103.13
    Checking tokio-rustls v0.26.4
    Checking rustls-platform-verifier v0.7.0
    Checking hyper-rustls v0.27.9
    Checking reqwest v0.13.4
    Checking connectrpc v0.3.3
    Checking rig-core v0.32.0
    Checking kuku-contract v0.1.0 (/Users/michasmi/projects/apps/kb-app-worktrees/openai-provider/crates/kuku-contract)
▮▮▮▮ desktop:lint-rust-check (running for 60s)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 1m 14s
▮▮▮▮ desktop:lint-rust-check (1m 14s 562ms, a3050647)

Tasks: 1 completed
 Time: 1m 14s 621ms
```

### `pnpm moon run desktop:format-ts-check`

Exit status: 0

```text
▮▮▮▮ desktop:format-ts-check (f79a21cf)
Checking formatting...

All matched files use the correct format.
Finished in 405ms on 369 files using 10 threads.
▮▮▮▮ desktop:format-ts-check (496ms, f79a21cf)

Tasks: 1 completed
 Time: 657ms
```

### `pnpm moon run kuku-ai:test`

Exit status: 0

```text
     Running unittests src/lib.rs (/Users/michasmi/projects/apps/kb-app-worktrees/openai-provider/target/debug/deps/kuku_ai-0da14c7fd775f838)
▮▮▮▮ kuku-ai:test (running for 60s)

running 22 tests
test provider::remote::tests::finish_reason_defaults_to_stop ... ok
test prompts::tests::inline_prompt_mentions_active_file_edit_limit ... ok
test provider::gemini::tests::tool_result_without_provider_call_id_still_uses_tool_call_id ... ok
test provider::remote::tests::missing_finished_event_is_rejected ... ok
test provider::gemini::tests::tool_result_uses_original_tool_call_ids ... ok
test provider::remote::tests::proto_messages_preserve_event_order_until_finished ... ok
test session::tests::compact_history_keeps_all_messages_when_within_budget ... ok
test provider::gemini::tests::assistant_tool_call_preserves_signature ... ok
test session::tests::cancel_during_apply_cancels_the_running_token ... ok
test session::tests::content_with_mode_notice_describes_mode_changes ... ok
test session::tests::compact_history_places_summary_into_synthetic_history_messages ... ok
test session::tests::content_with_mode_notice_keeps_content_when_mode_is_same ... ok
test session::tests::content_with_turn_context_includes_active_file_and_open_tabs ... ok
test session::tests::content_with_turn_context_includes_embedded_files ... ok
test session::tests::embedded_files_register_session_snapshots ... ok
test session::tests::content_with_turn_context_includes_selected_text ... ok
test session::tests::summarize_output_keeps_short_strings ... ok
test session::tests::tool_not_allowed_message_mentions_current_mode ... ok
test tools::descriptor::tests::ask_mode_allows_only_read_only_tools ... ok
test session::tests::summarize_output_truncates_on_char_boundary ... ok
test tools::descriptor::tests::inline_mode_allows_read_only_tools_and_edit_file_only ... ok
test session::tests::compact_history_summarizes_older_turns_but_keeps_recent_raw_history ... ok

test result: ok. 22 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s

   Doc-tests kuku_ai

running 0 tests

test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

▮▮▮▮ kuku-ai:test (1m 482ms, 6ccc9f42)

Tasks: 1 completed
 Time: 1m 562ms
```

### `pnpm moon run desktop:test-ts`

Exit status: 0

```text
▮▮▮▮ desktop:test-ts (257080de)

 RUN  v4.1.5 /Users/michasmi/projects/apps/kb-app-worktrees/openai-provider/apps/desktop

(node:92180) ExperimentalWarning: localStorage is not available because --localstorage-file was not provided.
(Use `node --trace-warnings ...` to show where the warning was created)
(node:92222) ExperimentalWarning: localStorage is not available because --localstorage-file was not provided.
(Use `node --trace-warnings ...` to show where the warning was created)
(node:92220) ExperimentalWarning: localStorage is not available because --localstorage-file was not provided.
(Use `node --trace-warnings ...` to show where the warning was created)
(node:92215) ExperimentalWarning: localStorage is not available because --localstorage-file was not provided.
(Use `node --trace-warnings ...` to show where the warning was created)
(node:92273) ExperimentalWarning: localStorage is not available because --localstorage-file was not provided.
(Use `node --trace-warnings ...` to show where the warning was created)

 Test Files  80 passed (80)
      Tests  451 passed (451)
   Start at  05:29:38
   Duration  2.77s (transform 3.36s, setup 0ms, import 5.93s, tests 2.18s, environment 6.47s)

▮▮▮▮ desktop:test-ts (3s 688ms, 257080de)

Tasks: 1 completed
 Time: 3s 845ms
```

### `cargo fmt -p kuku-ai -p kuku-app -- --check`

Exit status: 0. Verbatim output tail is empty.

```text
```

## Claims

| Claim | Result | Evidence |
|---|---|---|
| Wave 0 makes every gate in plan section 5.3 green (except the not-yet-existing live test) | CONFIRMS | All six required Wave 0 commands exited 0. The Rust lint tails show both Clippy tasks finishing, the TS formatter checked 369 files, the Rust tests report exactly 22 passed and 0 failed, the TS tests report exactly 80 files and 451 tests passed, and Cargo fmt produced no output with exit status 0. |
