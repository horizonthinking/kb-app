# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Kuku, a local-first Markdown knowledge workspace (upstream `kuku-mom/kuku`; this checkout is the `horizonthinking/kb-app` fork). One monorepo holds the macOS desktop app, the marketing/auth/dashboard website, the Go API server, the protobuf contract, and the Rust crates. Not an H4 Swift app: the Certainty/CK/CDK Swift rules do not apply here.

Human-facing docs: `README.md`, `docs/development.md`. There is no other agent guidance in the tree.

## Toolchain and commands

pnpm + **moon** drive everything. moon is a workspace devDependency, not a global install, so run `pnpm install` first; `pnpm <script>` and `pnpm moon run ...` both work after that. Host toolchains (Go, cargo, buf) are used as-is (`.moon/toolchains.yml` pins nothing).

Every project (`apps/*`, `packages/*`, `crates/*`) has a `moon.yml` with the same task vocabulary: `format`, `format-check`, `lint`, `lint-check`, `test`, `build`, `check`. `check` never mutates files; `format`/`lint` do.

```sh
pnpm install
pnpm check            # moon run :check  (format-check + lint-check [+ tests where wired])
pnpm test             # moon run :test
pnpm build            # moon run :build
pnpm format / pnpm lint   # auto-fix across the workspace
pnpm contract:generate    # regenerate TS/Go/Rust from packages/contract/proto

pnpm moon run desktop:check          # one project
pnpm moon run desktop:lint-rust      # one sub-task (desktop splits -ts / -rust)
```

Per-project entry points:

```sh
# desktop (Tauri 2 + SolidJS); uses tauri.development.conf.json → KukuDev, ~/.kuku.dev
pnpm --filter @kuku/desktop tauri:dev
pnpm moon run desktop:tauri-dev-preview     # preview bundle id + preview API

# web (Astro, static)
pnpm --filter @kuku/web dev

# server (Go, Connect-RPC, Postgres); air watcher reads ENV_PATH=.env.dev (copy from .env.example)
pnpm moon run server:dev
pnpm moon run server:db-migrate             # go run ./cmd/server migrate
pnpm moon run server:sqlc-generate          # after editing sql/queries/**/*.sql (output is committed)
pnpm --filter @kuku/server deps:up          # postgres :5555 + mailpit + rustfs for integration tests
```

Single tests:

```sh
# desktop TS (vitest, environment: node, colocated *.test.ts or __tests__/)
cd apps/desktop && pnpm vitest run src/plugins/builtin/ai_chat/chat_store.test.ts -t "name"
# Rust (inline #[cfg(test)] modules; -p scopes to one crate from repo root)
cargo test -p kuku-app variant::
cargo test -p kuku-indexer
# Go (stdlib testing; *_integration_test.go t.Skip unless KUKU_TEST_DATABASE_URL is set)
cd apps/server && go test ./internal/sync -run TestName -count=1
# web
cd apps/web && pnpm vitest run src/config/__tests__/prod_release.test.ts
```

Full stacks: `infra/docker/local` (web :8081, api :8080, mailpit :8025; copy `env.example` to `env`) for ordinary dev; `pnpm local-test:up|down|reset|logs` uses `infra/docker/local-test` (adds RustFS S3 and binds all interfaces) for two-device encrypted-sync testing.

## Lint and format conventions (enforced, will fail `check`)

- oxlint + oxfmt, not eslint/prettier. Root `.oxlintrc.json`; desktop extends it with type-aware rules on (`no-floating-promises`, `no-misused-promises`, `await-thenable` are errors).
- **snake_case filenames** everywhere (`unicorn/filename-case`).
- Desktop Tailwind: no arbitrary `px` values (use rem); unknown classes error unless they match the `kuku-*` allowlist in `apps/desktop/.oxlintrc.json`.
- Web: no `../` imports under `src/` (`scripts/check_parent_imports.mjs`), use the `@/` alias. `.astro` files are formatted by prettier, everything else by oxfmt.
- Go: golangci-lint v2 standard set, goimports local prefix `github.com/kuku-mom/kuku`. Dev tools are `go tool -modfile=tools/<x>.mod` (air, sqlc, golangci-lint), never added to the app `go.mod`.
- Rust: clippy with `-D warnings` on every crate. `kuku-contract` is generated and is only ever `cargo build`-checked; never edit `crates/kuku-contract/src/generated/`.
- Generated code (`packages/contract/gen/`, `crates/kuku-contract/src/generated/`, `apps/server/internal/database/sqlc/`) is committed and excluded from lint/format. Regenerate, don't hand-edit.
- `.moon/workspace.yml` sets `defaultBranch: develop` while this fork works on `main`; moon "affected" detection uses that base, so prefer explicit `moon run <project>:<task>` over `--affected`.

## Architecture

### Contract is the spine
`packages/contract/proto/kuku/{auth,user,dashboard,ai,sync,error}/v1/*.proto` (edition 2023, protovalidate) is the single source for all client/server types. `buf.gen.yaml` fans out to TS (`gen/es`, consumed by web and desktop), Go (`gen/go`, consumed by the server through a `replace` directive in `apps/server/go.mod`), and Rust (`crates/kuku-contract/src/generated/{buffa,connect}`, consumed by `kuku-ai` and the desktop crate). Rust codegen plugins are cargo-installed into `packages/contract/.cargo-tools` by the package's `postinstall`. After a proto change: `pnpm contract:generate`, `pnpm moon run contract:build`, then update server handlers and the `publicPaths` allowlist in `apps/server/internal/middleware/auth.go` if procedures changed.

### Desktop (`apps/desktop`)
**The frontend is a plugin system; `src/plugins/` is the architecture, `src/components/` is just widgets.**
- `src/plugins/bootstrap.ts` registers the ~16 builtins under `src/plugins/builtin/` (core_editor, core_commands, core_auth, core_sync, core_indexer, core_tool_registry, ai_chat, knowledge, graph_view, voxel_graph, search, wikilink, mermaid, diff_view, theme_default, typography), topologically sorts by declared deps, and activates them. The editor must not mount until `pluginsReady()` is true because ProseKit needs every schema contribution at `createEditor()` time.
- `src/plugins/types.ts` is the `KukuPlugin` contract; `context.ts` is the `PluginContext` given to `activate()` (sandboxed fs, vault, editor, tabs, layout, commands, typed events, cross-plugin `services`); `slots.tsx` is the Slot/Fill UI extension mechanism (title bar, center tab, side/bottom panels, settings sections).
- State is module-level SolidJS stores/signals in `src/stores/` (vault, files/tabs, layout, settings, theme, editor, updater). No Context providers, no router: `src/app.tsx` renders `PanelLayout`, and navigation is the tab model in `src/stores/files.ts` (`editor | diff | graph | voxel-graph | search | settings`).
- Rust bridge is hand-written typed `invoke` wrappers: `src/lib/vault_fs.ts` for `vault_*`, per-plugin `service.ts` files for sync/indexer/knowledge/auth, and `invoke("plugin:kuku-ai|ai_*")` for the AI plugin. Rust→UI events arrive via `listen` (`vault:file-changed`, `ai:*` in `builtin/ai_chat/event_bridge.ts`).
- Editor: ProseKit/ProseMirror (`src/components/editor/system/editor_engine.ts`); CodeMirror only inside code-block node views. Markdown ↔ ProseMirror round-trip is remark/mdast through a plugin-extensible `ConversionRegistry` in `src/lib/markdown/`.
- Graphs: 2D pixi.js and 3D three.js/3d-force-graph in `builtin/graph_view`; `builtin/voxel_graph` is a separate three.js "agent world" with `.glb` assets.
- `~` alias = `src`. i18n keys are typed (`src/i18n/keys.ts` + `locales/{en,ko,ja}.ts`), so new UI strings need all three.

**Rust side (`apps/desktop/src-tauri`, crate `kuku-app`)**: `src/lib.rs` is the single registration point (state, plugins, AI host and native tools, deep-link handling, one `generate_handler![]` grouped auth / plugin_fs / plugin_settings / app_settings / vault / knowledge / search / sync). Modules: `vault/` (path-strict FS, checksum-guarded writes, `notify` watcher with an expected-mutation ledger so the app's own writes don't echo back), `search/` (the actual SQLite FTS5 index via rusqlite, incremental by mtime+checksum, wikilink resolution and backlink graph), `sync/` (E2E-encrypted vault sync: scanner → planner → packer → transfer → applier/merge/checkpoint; argon2, chacha20poly1305, ed25519, BIP-39 recovery), `knowledge/` (proposals and decision documents stored as frontmatter + fenced `kuku` blocks in vault Markdown), `ai_host/desktop_host.rs` (implements `kuku_ai::AiHostBindings`, applies AI mutation plans to the vault), `ai_tools/` (native tools handed to kuku-ai), `contract_client.rs`, `secure_storage.rs` (keychain).

**`variant.rs` is load-bearing**: the bundle identifier selects `~/.kuku` vs `~/.kuku.dev` vs `~/.kuku.preview` and the keychain service suffix, so dev, preview, and prod never share data or tokens. The three configs: `tauri.conf.json` (prod, `mom.kuku.app`, the real release version), `tauri.development.conf.json` (KukuDev), `tauri.preview.conf.json` (KukuPreview, own updater key, built with `--features devtools`). API URLs are injected per moon task, not read from a file.

### Rust crates (`crates/`)
- `kuku-ai` is a Tauri plugin (namespace `kuku-ai`; `build.rs` generates the command ACL, so the `COMMANDS` list, `generate_handler!`, and `src/commands.rs` must stay in sync). `src/session.rs` holds the agent loop: bounded rounds, streaming deltas, tool execution, history compaction at a byte budget, three `ChatMode`s (ask / agent / inline) that gate tools and prompts. Providers: `provider/remote.rs` (Kuku backend over Connect + JSON streaming, the default) and `provider/gemini.rs` (user's own key via rig-core). **Tools never write**: a mutating tool returns a `MutationPlan` with expected checksums, the session emits a pending-approval event and blocks on an approval channel, and only then does the host apply it, reporting Applied / PartiallyApplied / Conflict. Depends on `kuku-contract` only; search reaches it as native tools registered by the desktop crate.
- `kuku-indexer` is pure, engine-free Markdown extraction (pulldown-cmark): sections, chunks with overlap, CJK normalization, wikilinks, query routing and FTS query building, snippets. The database lives in the desktop crate, not here.
- `kuku-contract` is a ten-line re-export over generated code.

### Server (`apps/server`)
Single binary `cmd/server/main.go`; positional subcommands `migrate` and `healthcheck`, otherwise it serves. Dependency direction is strict: `cmd` → `internal/server` (all wiring, middleware order RequestID → Recover → ClientIP → Logging → CORS → RateLimit → Auth) → feature packages `internal/{auth,dashboard,sync,ai}` → `internal/database/sqlc` + `internal/config`. Connect handlers are mounted from the generated `*connect.New*Handler` constructors. Auth is HttpOnly cookie JWT with silent refresh in `internal/middleware/auth.go`; anything not in its `publicPaths` list 401s before reaching a handler; handlers read identity with `auth.FromContext`. Desktop clients use a separate token exchange/refresh RPC pair. Errors leave through `internal/rpcerr` so internals never hit the wire.

Sync is deliberately server-blind: account root key and key envelopes, workspaces, ed25519 device keys, signed commits with expected-head compare-and-swap, and content-addressed encrypted objects moved through presigned S3/R2/RustFS URLs. The server only ever sees object IDs, ciphertext hashes, sizes, and opaque envelopes, and `internal/sync/no_plaintext_test.go` guards that. The dev direct-bytes upload path is rejected by config validation in production.

Migrations are plain SQL under `sql/migrations`, applied in filename order by `internal/database/migrations.go` (also at boot when `AUTO_MIGRATION` is set). Config is env-only (`internal/config/config.go`, `ENV_PATH` picks a dotenv); `.env.example` is the template and `.env*` is gitignored.

### Web (`apps/web`)
Static Astro 6. Marketing pages plus `auth/*` and a Solid dashboard SPA at `dashboard/[...path].astro`. All API calls go through one Connect transport in `src/lib/api/client.ts` (credentials included, 401 → sign-in redirect); `PUBLIC_KUKU_API_MOCKING=1` swaps in `src/mocks/transport.ts`. `src/config/prod_release.ts` is the release manifest: it drives download links and is served verbatim as the Tauri updater feed by `src/pages/release.json.ts`.

## Release flow

`scripts/release.sh` is the prod path: bumps `version` in `apps/desktop/src-tauri/tauri.conf.json` (the source of truth; the GitHub tag must match it), runs `desktop:tauri-build-prod`, writes the minisign signature into `prod_release.ts` via `apps/web/scripts/update_prod_release_config.mjs write`, builds the web bundle, notarizes and staples the DMG, and prints the manual `gh release create`, Homebrew sha256, and Pages deploy steps. Needs Apple signing/notarization env plus `TAURI_SIGNING_PRIVATE_KEY`. `release-preview.sh` is the same shape without notarization against the preview config; `release-prod-web.sh` builds only the site. Commit `tauri.conf.json` and `prod_release.ts` together after a release.
