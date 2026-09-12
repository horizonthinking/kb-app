# kuku-ai

Desktop AI runtime crate for Kuku.

This crate owns the Tauri AI plugin boundary, chat session runtime, provider adapters, tool execution flow, and mutation approval types used by the desktop app. Its adapters cover the Kuku remote backend, Gemini, and OpenAI Chat Completions compatible endpoints. OpenAI-compatible endpoints may omit a key only when the endpoint policy classifies the host as local.

The Tauri plugin command namespace, Rust package name, and crate name use the Kuku-prefixed `kuku-ai` / `kuku_ai` naming convention.

Run the reusable live regression through its verifier, never with a substring cargo filter:

```bash
KUKU_TEST_OPENAI_BASE_URL=http://127.0.0.1:11434/v1 \
KUKU_TEST_OPENAI_MODEL=qwen3.5:4b \
KUKU_LIVE_REQUEST_LOG=/private/tmp/kuku-live-provider.log \
scripts/h4/verify_ai_provider.sh
```

The verifier fingerprints the configuration, runs the exact live inventory, enforces three chat attempts and two model-list attempts including its probe, and refuses a pre-existing nonempty log.
