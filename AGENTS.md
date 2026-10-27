# Repository Guidelines

## Project Structure & Module Organization

- Core Rust sources live in `src/`. `main.rs`, `cli.rs`, and `config.rs` define the primary CLI surface and configuration handling.
- Language- and tool-specific helpers live in `src/developers/`, `src/tools/`, `src/utils/`, and OS integration in `src/os/`.
- The development-only binary `src/bin/qbit-dev.rs` is for local tooling and experiments.
- `assets/` holds CLI assets (for example `assets/icon.svg`). `dev-sandbox/` contains a lightweight Node/JS sandbox driven by `qbit.yml` for trying workflows.
- GitHub Actions workflows are under `.github/workflows/`, and helper scripts (if any) belong in `scripts/`.

## Build, Test, and Development Commands

- Build debug: `cargo build`
- Build release binary: `cargo build --release`
- Run CLI locally: `cargo run -- --help` or `cargo run -- <subcommand> ...`
- Run dev binary: `cargo run --bin qbit-dev -- --help`
- Run tests (unit and integration): `cargo test`

## Coding Style & Naming Conventions

- Use Rust 4-space indentation and standard `rustfmt` formatting: `cargo fmt` before committing.
- Prefer `snake_case` for modules, functions, and local variables; `PascalCase` for types and enums; `SCREAMING_SNAKE_CASE` for constants.
- Keep module files focused (for example, CLI parsing in `cli.rs`, config loading in `config.rs`) and avoid cross-layer coupling.
- Add documentation comments (`///`) for public functions and types that are part of the CLI behavior.

## Testing Guidelines

- Place unit tests in the same file under `#[cfg(test)] mod tests` near the code they cover.
- Use descriptive test names (for example, `parses_basic_qbit_yaml`, `adds_python_dependency_to_requirements`).
- New features should include tests for both the happy path and primary error cases; run `cargo test` before opening a PR.

## User Documentation

- `qbit-ai-toolkit/website` is the canonical Qbit documentation template. Clone its structure, shared CSS, homepage layout, Docusaurus/React/Bun/search stack, RTL/LTR behavior, tests, and deployment conventions; override only CLI content, CLI routes/assets, locale-default routing, base paths, and repository-specific links. Pin the consumed template revision in `user-docs/template.source.json`.
- Public end-user documentation lives under `user-docs/` and is deployed from this repository to GitHub Pages.
- Persian is the default locale and English lives under `user-docs/i18n/en/docusaurus-plugin-content-docs/current/`; keep sidebar and page coverage in parity.
- Ground command behavior in the current stable CLI source and tests. Keep download asset names aligned with `.github/workflows/release.yml` and `src/os/upgrade.rs`.
- Documentation code/config changes require Unit, Integration, and Playwright E2E coverage under `user-docs/tests/`.
- Docusaurus build output and local documentation dependencies are generated artifacts and must not be committed.

## Commit & Pull Request Guidelines

- Use short, imperative commit messages (for example, `Add python init workflow`, `Refine os install error handling`).
- Each PR should have a clear description, mention affected commands (for example, `qbit py init`), and link related issues.
- Include notes on testing performed (`cargo test`, manual CLI scenarios) and, when relevant, example commands in the PR body.


<!-- qbit-toolkit:ai-context:start -->
## AI context lifecycle

- Before the first substantive repository analysis, planning, or implementation in a Codex session, automatically start AI context with the repository-owned launcher. On **Windows**, use the verified, fail-closed entrypoint `powershell -NoProfile -ExecutionPolicy Bypass -File .ai/context/context-sync-gate.ps1 -MemberPath . -Mode Start`; this calls `context.ps1 start` and requires current verified central remote/Cache identity. On Linux/macOS use `bash .ai/context/context.sh start` and confirm status/freshness (the strict Windows verification gate is not cross-platform yet). If Start fails or the gate reports `CONTEXT_UNSYNCED`, do not claim synchronized Context. Do not ask the developer and do not wait for a context-loading instruction.
- Read `.ai-bridge/context-runtime.md` before substantive planning or implementation. Treat its active workstream, execution cursor, unresolved work items, dependencies, acceptance criteria, and validation freshness as the continuity resume contract. Do not replace that structured state with a shorter free-form summary.
- Do not rerun `start` repeatedly in the same session unless the context cache may have changed materially. If runtime validation evidence is stale for the current worktree, do not rely on it as current validation; rerun the required gate before claiming validation.
- Central AI context is coordination evidence, never implementation authority. Current source, tests, schemas/migrations, explicit contracts, and committed canonical decisions outrank stored context according to their claim type.
- Preserve pre-existing uncommitted user changes; do not stage, format, rewrite, reset, clean, or otherwise disturb unrelated work.
- After a substantive validated milestone that materially changes durable continuity state, and before the final handoff, write the complete v2 `.ai-bridge/context-checkpoint.json` with active workstream continuity. On **Windows**, run `powershell -NoProfile -ExecutionPolicy Bypass -File .ai/context/context-sync-gate.ps1 -MemberPath . -Mode Checkpoint` and REQUIRE success: new central Context commit, remote publication and per-repository record. On Linux/macOS run `bash .ai/context/context.sh checkpoint` and verify remote publication separately. If blocked (offline, permission, divergence, invalid checkpoint), mark `CONTEXT_UNSYNCED` with a durable replay plan and do not mark the feature fully closed. No developer reminder is required.
- Do not create checkpoints for ordinary read-only questions, every chat message, or work that produced no durable continuity change.
- New substantive checkpoints must use `schemaVersion: 2`, repository `qbit-cli`, and include `scope`, controlled `status`, `objective`, `confirmedFindings[]`, `decisions[]`, `rejectedApproaches[]`, `validation[]`, `openQuestions[]`, `nextAction`, plus `continuity.mode`, `continuity.workstream`, and `continuity.validationLedger[]`. `schemaVersion: 1` is legacy-read compatibility only.
- Use `continuity.mode: tracked` whenever work remains active, pending, blocked, or otherwise resumable. Carry every existing work item forward by stable ID, preserve dependencies/blockers/acceptance criteria/validation requirements, and set the execution cursor to the exact current item and exact next action. Never silently drop an unresolved item or switch workstream IDs to make a checkpoint pass.
- Use `continuity.mode: snapshot` only when there is no unresolved tracked workstream. Terminal workstreams must explicitly close/cancel/supersede every work item and clear `cursor.currentItemId`; the lifecycle will archive the workstream rather than discard it.
- Add structured validation ledger entries only for validation actually executed for this repository/worktree. Validation IDs are immutable; use a new stable ID for each new validation event.
- Use `export`, `import`, and `reconnect` only for deliberate offline or cross-machine continuity transfer. After an imported offline session advances context locally, use `reconnect` when the configured remote is reachable; never bypass a reconnect divergence by reset, rebase, merge, or force-push.
- Promote durable technical decisions into their canonical owning repository/ADR/contract; the context checkpoint records continuity, not technical authority.
- Never store secrets, credentials, cookies, tokens, private keys, `.env` values, customer secrets, or raw chat transcripts in AI context.
- If context start/checkpoint fails because of missing context source, authentication, dirty/diverged context state, continuity loss prevention, invalid transition, or a concurrent conflict, do not perform destructive recovery; report `CONTEXT_UNSYNCED`, preserve the checkpoint and provide an exact recovery action. Updating only a local ignored cache is **not** proof of durable remote publication.
- `.ai-bridge/` and `.ai/context/cache/` are transient/ignored runtime locations. Semantic indexes and graph outputs remain derived evidence tools, not project memory.
<!-- qbit-toolkit:ai-context:end -->
