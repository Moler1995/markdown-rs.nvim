# Design

## Context

See `proposal.md` for motivation. The relevant current state:

- The workspace has three members: `engine` (the `md-render` binary and library), and the vendored `crates/mermaid-text` and `crates/ascii-dag`. `Cargo.lock` is tracked; the release profile already strips symbols and uses `panic = "abort"`.
- `engine/tests/image_layout.rs` uses `include_str!` on an untracked golden file, and `tests/headless/run.lua` opens an untracked fixture. A clean checkout therefore fails before any CI can be useful.
- The headless suite writes Windows `.bat` stand-in engines; the engine has a unit test that assumes `C:/...` is absolute on every platform; the plugin's follow-link path joins absolute targets to the document directory while its image-open path already handles them.
- The plugin resolves the engine as configured `engine` → `md-render` on `PATH` → `<repo>/bin/md-render[.exe]`. Part of the documentation still describes the retired `g:md_render_binary` key.
- There is no `doc/` and no `health.lua`. `engine.lua` never reads the wire `version` field, although `docs/porting.md` says a mismatch is a hard error. `setup()` does not attach the buffer already on screen, and `plugin/md-render.lua` only installs autocmds.
- There is no `.github/`, no `.gitattributes`, no `.editorconfig`, and `openspec/` is untracked.
- The engine's source is not rustfmt-clean; the vendored crates are intentionally not formatted.

## Goals / Non-Goals

**Goals:**

- One required CI gate that a pull request can be blocked on, backed by per-platform jobs.
- A release that a user can download and run without a Rust toolchain, with an artifact per supported target.
- A fresh clone that builds and tests identically on Windows, Linux and macOS.
- Repository files that make contribution, licensing and security reporting obvious.
- A plugin a user can install with a standard manager, read with `:help md-render`, and diagnose with `:checkhealth md-render`.
- An engine contract that refuses a binary whose wire format the plugin does not understand, instead of rendering with it.

**Non-Goals:**

- Publishing the Neovim plugin to a package registry; the release ships the engine only.
- Publishing the `md-render` crate to crates.io.
- Downloading the engine automatically at startup. The release artifacts are placed by the user or by a build hook, so no plugin code fetches and executes a URL.
- Reproducible (bit-identical) builds or signed/notarized macOS binaries.
- Formatting or linting the vendored crates.
- Adding Lua formatters or linters; the selected gates are Rust-only.
- Changing engine output, the wire format, or plugin rendering behaviour beyond the link-path and setup-attach fixes. The wire version stays 1.
- Giving the plugin a separate version number. The repository tag is the plugin version; the engine reports its own version.

## Decisions

### Workflow layout

Four workflow files under `.github/workflows/`:

| File | Trigger | Jobs |
| --- | --- | --- |
| `ci.yml` | `pull_request`, `push` to `main` | Rust matrix, lint, MSRV, plugin matrix, OpenSpec, aggregate gate |
| `release.yml` | tag `v*`, `workflow_dispatch` (dry run) | Linux, Windows, macOS builds; release assembly |
| `audit.yml` | weekly schedule, `workflow_dispatch` | `cargo audit` |
| Dependabot | weekly schedule (configuration, not a workflow) | Cargo and GitHub Actions PRs |

`ci.yml` uses `concurrency` keyed on the workflow and ref with `cancel-in-progress: true`, so a new push cancels the previous run. `release.yml` uses `cancel-in-progress: false`: a half-cancelled release is worse than a slow one.

The CI jobs expose one aggregate `gate` job with `if: always()` and `needs` on every other job. Branch protection requires only `gate`, so adding or renaming a matrix leg later does not require a repository-setting change. The gate fails when any dependency is not `success`.

**Alternative considered:** requiring each matrix leg individually. Rejected because every matrix expansion would require editing branch protection, and a skipped job can read as success.

### Rust matrix and quality gates

- `rust`: `ubuntu-latest`, `windows-latest`, `macos-latest`; stable toolchain; `cargo test --workspace --locked`. All three members are tested, including the vendored crates, because they are part of the shipped engine.
- `lint`: Ubuntu only; `cargo fmt -p md-render -- --check` and `cargo clippy -p md-render --all-targets --locked -- -D warnings`. Formatting is scoped with `-p` so the vendored crates never enter the gate. Clippy is likewise engine-only.
- `msrv`: Ubuntu; `dtolnay/rust-toolchain@1.92`; `cargo check --workspace --locked`. This verifies the declared `rust-version` rather than trusting it.
- Caching: `Swatinem/rust-cache@v2` on every Rust job, keyed by job and target.

**Alternative considered:** `cargo fmt --all --check`. Rejected: it fails on the vendored crates, whose formatting is deliberately left as published. Formatting them would make future re-vendoring a large diff.

### Plugin matrix

The plugin job runs on Ubuntu with Neovim `v0.10.4` and `stable`, in a matrix. Each leg:

1. Builds the release engine with `cargo build --release -p md-render --locked`.
2. Creates `bin/` and copies the binary to `bin/md-render`, the repository fallback the suite expects.
3. Installs Neovim with `rhysd/action-setup-vim@v1`.
4. Runs `MDRN_REPO=$GITHUB_WORKSPACE nvim --headless -l tests/headless/run.lua`.
5. Runs `nvim -l tests/interactive/run.lua`.
6. Regenerates `doc/tags` and fails if `git diff --exit-code doc/tags` sees a change.
7. Opens `:help md-render` headlessly and fails if the tag does not resolve.
8. Runs `:checkhealth md-render` headlessly against the built engine and fails if `probe()` reports an error.
9. Runs the wire-mismatch check from the headless suite, which uses a stand-in engine printing `version: 2`.
10. Runs `tools/check-readme.sh`, which asserts the required landing-page sections, resolves relative links against tracked files and rejects the retired `g:md_render_binary` key and drive-letter paths. It does not fetch external URLs, so a network failure cannot fail the gate.

Both suites are retained because they test different things: the headless suite has the bulk of the checks, and the interactive suite is the only one that exercises the main input loop, `nvim_feedkeys` and `TextChanged`.

**Alternative considered:** installing Neovim by downloading a release tarball. Kept as a fallback if the setup action cannot resolve a pinned 0.10 release; the action is preferred because it also handles the stable channel.

### OpenSpec validation

`npx --yes @fission-ai/openspec@1.13.2 validate --all --no-interactive`, with Node from `actions/setup-node@v4`. The version is pinned because the CLI's validation rules change between releases; Dependabot cannot update a version embedded in a workflow, so it lives in one workflow-level `env` for a deliberate bump.

`openspec/` becomes tracked. The active `animation-frame-budget` change is committed as planning work, not archived or deleted; it belongs to the repository's planning history.

### Release targets and packaging

| Target | Runner | Build | Archive |
| --- | --- | --- | --- |
| `x86_64-unknown-linux-musl` | `ubuntu-latest` | `cargo build --release --locked --target ...` | `md-render-<tag>-x86_64-unknown-linux-musl.tar.gz` |
| `x86_64-pc-windows-msvc` | `windows-latest` | same, with `RUSTFLAGS=-C target-feature=+crt-static` | `md-render-<tag>-x86_64-pc-windows-msvc.zip` |
| `universal-apple-darwin` | `macos-latest` | build `aarch64-apple-darwin` and `x86_64-apple-darwin`, then `lipo -create` | `md-render-<tag>-universal-apple-darwin.tar.gz` |

- musl makes the Linux binary independent of the runner's glibc; `musl-tools` is installed first.
- `+crt-static` embeds the MSVC runtime, so the Windows archive runs without a Visual C++ redistributable.
- The macOS archive is one `lipo`-merged executable, not two binaries, so a user does not have to choose an architecture.
- Each archive is flat: the executable, `LICENSE` and `README.md`.
- Each build job smoke-tests `--version` before uploading.
- The release job downloads all three archives, writes `SHA256SUMS`, and calls `gh release create "$TAG" --verify-tag --generate-notes`. It only runs when every build job succeeds, so a failed target cannot leave a partial release.
- The release job also checks that the tag equals `v` plus the `md-render` package version from `cargo metadata`; a mismatched tag fails before publication.
- A `workflow_dispatch` trigger with a `tag` input and a `dry_run` flag (default on) builds and checksums the same three archives but skips `gh release create`. This lets the release pipeline be exercised on a branch without publishing a version, and a real tag push runs the same code with `dry_run` off.

**Alternative considered:** separate macOS runners for arm64 and x86_64 plus a merge job. Rejected as the primary approach because a single `macos-latest` (arm64) runner can cross-build and `lipo` both targets. If the cross-link fails on the first run, the fallback is `macos-13` (x86_64) plus a merge job.

**Verification record.** The development host has neither a musl sysroot nor an MSVC linker, and only the `x86_64-pc-windows-gnu` and `x86_64-pc-windows-gnullvm` targets installed, so the Linux and Windows release builds could not be produced or smoke-tested locally. The release workflow supplied that verification instead: the dry run (39925461403) built all three archives and wrote `SHA256SUMS`, the published run for `v0.1.0` (39927596622) did the same and created the release, and the downloaded Windows archive was run on this host with `--version`. The macOS build has no local counterpart at all and is verified only by these runs.

### Dependency and vulnerability monitoring

- `.github/dependabot.yml` with two ecosystems: `cargo` and `github-actions`, both weekly. Patch and minor Cargo updates are grouped into one PR; major updates stay individual.
- `audit.yml` runs `rustsec/audit-check@v2` on a weekly schedule and on `workflow_dispatch`, with `contents: read` and `issues: write` so it can record a finding. The schedule is `17 4 * * 1`, deliberately off the hour.
- Dependabot cannot update the vendored crates. `crates/*/VENDORED.md` remains the record of their patch level; a re-vendor stays a deliberate manual operation.

### Platform fixes

**Engine path test.** `absolute_destinations_are_used_as_given` and its relative sibling choose their absolute path with `cfg!(windows)`: `C:/docs/a.png` on Windows, `/docs/a.png` on Unix. This tests the platform's own notion of absolute instead of asserting Windows semantics everywhere.

**Headless stand-in engines.** A helper writes either a `.bat` file on Windows or a `#!/bin/sh` script with `vim.fn.setfperm(path, 'rwx------')` on Unix. The two call sites (section 10.6 and section 11.2) use the helper and receive a path, so the `.bat` suffix disappears from the tests' logic.

**Absolute link destinations.** The predicate that `M.open_image` already uses —

```lua
local function is_absolute(path)
  return path:match('^[/\\]') ~= nil or path:match('^%a:[/\\]') ~= nil
end
```

— moves to `lua/md-render/link.lua` as `M.is_absolute` and is used by both `init.lua` functions. `M.follow` then becomes:

```lua
local path = found.target
if not link.is_absolute(path) then
  path = base .. '/' .. path
end
path = vim.fn.fnamemodify(path, ':p')
```

Placing it in `link.lua` lets the headless suite test the predicate directly on Linux for POSIX, drive-letter and UNC forms, since the plugin suite does not run on Windows.

### Plugin user-facing surface

The plugin is already structurally standard: `plugin/md-render.lua` guards loading, `lua/md-render/` holds the modules, and the commands are created at startup. What is missing is the surface a user reaches before reading the source.

#### Help

`doc/md-render.txt` becomes the reference for the plugin. It covers:

- requirements (Neovim 0.10+, an engine);
- installation, including the three package-manager snippets and the engine location;
- `require('md-render').setup()`, every top-level option and every key in `keymaps`, with defaults and `false` semantics;
- the four commands, the configurable keymaps and the fixed insert-entry keys;
- links, preview and zoom, images and animation;
- engine resolution, `:checkhealth md-render`, and troubleshooting.

`doc/tags` is generated with `nvim --headless -u NONE -c 'helptags doc' -c q` and committed, because `vim.pack` and a plain `runtimepath` entry do not generate tags. The CI plugin job regenerates the tags and fails on a diff. A headless check also asserts that every command created by `plugin/md-render.lua` has a tag, and that every top-level option and every `keymaps` key appears in the help file; this is the part that keeps the reference from drifting when an option is added.

The README keeps the landing-page role: badges, a short install section, and links into `:help md-render`. Detailed option and keymap tables move to help rather than being maintained twice.

#### Health

`lua/md-render/health.lua` exposes two functions:

- `probe()` returns a table: whether Neovim is supported, the resolved engine path, which resolution step produced it, the engine's `--version` output, the wire version from a minimal render, `'termguicolors'`, the resulting image encoding, and the configured filetypes.
- `check()` renders that table through `vim.health` and adds remediation lines when a value is wrong.

`probe()` runs the engine twice at most: `--version`, and one minimal render of an empty document to read `version`. It uses `vim.system` with a short timeout and never renders the current buffer, so `:checkhealth` cannot change what the user is looking at. A headless test calls `probe()` directly instead of parsing the `:checkhealth` buffer.

#### Wire version

`engine.lua` gains `WIRE_VERSION = 1`, and the decoded document is rejected when `doc.version` is missing or different. The message names the engine's value, the expected value, and both remedies: rebuild the engine from the checkout, or upgrade the plugin/engine pair. A headless test uses a stand-in engine that prints `{"version":2,...}` and asserts the window stays in S with that diagnostic. This is the check `docs/porting.md` already promised.

#### Engine discovery

The resolution order becomes:

```text
0. the `engine` option, when non-empty: use it or fail
1. `md-render` on PATH
2. <plugin-root>/bin/md-render[.exe]          -- development build
3. stdpath('data')/md-render/md-render[.exe]  -- installed release
```

The `engine` option is authoritative: when it names a path that is missing or not executable, the plugin reports that path and does not fall through to the other locations. Falling back would hide a configuration mistake behind a different engine.

When `engine` is empty, the remaining locations are tried in order. The repository's `bin/` stays ahead of the data directory so a fresh local build is not shadowed by an older downloaded binary. An installed plugin has no repository `bin/`, so it falls through to the data directory. The plugin root is derived from the loaded module's own path, as today.

Each automatic candidate is checked with `vim.fn.executable()` rather than `uv.fs_stat()`, so a file that exists but cannot be run is skipped instead of producing an `EACCES` later. When nothing resolves, the error names every location searched and gives the build and release-download options. `:checkhealth` reports which step won, which is what makes a `PATH` shadow visible.

**Alternative considered:** putting the data directory before the repository's `bin/`. Rejected because a developer who builds locally would silently keep running an older downloaded engine.

**Alternative considered:** downloading the release automatically into the data directory. Rejected for now: it adds a network fetch and an execute path to a plugin that does not need either, and the manual download plus `:checkhealth` is enough.

#### Loading and setup

`setup()` currently changes the config and re-runs `setup_autocmds()`, which is idempotent, but it does not attach the buffer already in the window. A lazy.nvim `ft = 'markdown'` load can therefore happen after `FileType` and `BufWinEnter` have fired, leaving the first buffer in S until it is reopened.

Both entry points attach the current buffer when it is managed:

- `plugin/md-render.lua`, after `md.setup_autocmds()`, so a plugin sourced during `FileType` still catches the file that triggered it;
- `M.setup(opts)`, after applying the new options, so a user who calls setup after loading a file gets R immediately.

The attach is deferred with `vim.schedule` and re-checks that the buffer is still in the window, reusing the guard `FileType` already uses. Repeated `setup()` calls remain free of duplicate autocmds and keymaps.

The documented lazy.nvim snippet uses `event = { 'BufReadPre *.md', 'BufNewFile *.md' }`, which loads the plugin before the file is read and avoids relying on the attach fallback. `ft` is documented as supported because of the attach, not as the recommended event.

### README structure

The README becomes a landing page rather than the project's full design document. Its order:

1. Badges: CI status, latest release, license.
2. A one-paragraph description and a demo of the reading view, either a screenshot/GIF or a short rendered-output block when no recording is maintained.
3. Features.
4. Requirements: Neovim 0.10+, an engine, and a truecolor terminal for image artwork; Rust only for a source build. A compatibility table names the supported Neovim versions and the published engine targets.
5. Installation: the prebuilt-engine download, then lazy.nvim, `vim.pack` and `mini.deps` snippets; the engine destination and the source-build alternative are stated here.
6. Quick start: install, place the engine, open a markdown file, press the toggle key.
7. Configuration, commands and keymaps: a short summary that links to `:help md-render-options` and `:help md-render-keymaps`; no second complete table.
8. Troubleshooting: engine not found, wire mismatch, no truecolor, lazy loading, stale modules; each points at `:checkhealth md-render` or the setting to check.
9. Development: both shells, the test suites, OpenSpec, help tags, and the restart after editing plugin Lua.
10. Architecture: a short engine/plugin boundary summary and a link to `docs/design.md`.
11. Contributing, security, license and provenance: links to `CONTRIBUTING.md`, `SECURITY.md`, `NOTICE` and GitHub Releases.

The deep explanations currently inline — "The two states", "Staying in step", "Following links", "Images", "The block preview", and the vendored-crate detail — move to `docs/design.md`, linked from the architecture section. They are moved, not deleted: the README keeps the summary a new user needs, and the design document keeps the reasoning a contributor needs.

The directory tree uses repository-relative paths and `md-render[.exe]`, never a path from a contributor's machine. Build, test, install and copy commands are given in POSIX and PowerShell forms wherever the README instructs a reader to run them.

**Alternative considered:** keeping the architecture prose in the README and adding a table of contents. Rejected because the install path would still sit below several screens of internals, and the same prose would compete with `:help` as a second reference.

### Repository standards

- `.gitattributes`: `* text=auto eol=lf`, `*.bat text eol=crlf`, `*.ps1 text eol=crlf`, and explicit `binary` for image fixtures and executables. This is what keeps `tools/make-bench-doc.sh` LF when checked out on Windows.
- `.editorconfig`: UTF-8, LF, final newline, trim trailing whitespace; 4 spaces for Rust, 2 for Lua/Markdown/YAML/JSON, 2 for TOML.
- `LICENSE`: the canonical MIT text with only the copyright line, so GitHub recognizes it. The derivation paragraph and vendored-crate notices move to `NOTICE`.
- `.gitignore`: add `.claude/`, `.idea/`, `.vscode/` and `*.log`. `target/`, `bin/` and `issues/` stay ignored.
- New files: `CONTRIBUTING.md`, `SECURITY.md`, `.github/ISSUE_TEMPLATE/bug_report.yml`, `.github/ISSUE_TEMPLATE/feature_request.yml`, `.github/ISSUE_TEMPLATE/config.yml`, `.github/pull_request_template.md`, `doc/md-render.txt`, `doc/tags`, `docs/design.md`.
- README: the landing-page structure above; CI, license and latest-release badges; a user-facing install section that points at the release archives; lazy.nvim, `vim.pack` and `mini.deps` snippets; POSIX and PowerShell variants for building, creating `bin/`, running tests, and installing the engine; the correct resolution order including the data directory; links to `:help md-render`, `:checkhealth md-render`, `CONTRIBUTING.md`, `SECURITY.md`, `NOTICE`, Releases and `docs/design.md`; no duplicate option or keymap table.
- `docs/porting.md`: reframed from "the Windows binary" to the engine's cross-platform distribution, the four-step search order, the wire-version check and staleness.
- `CLAUDE.md`: add `mkdir -p bin` to the build step, note the CI gates (fmt/clippy on the engine, OpenSpec validation, help tags, health) and the restart needed after editing plugin Lua; keep the vendored-crate exemption explicit.

**Alternative considered:** committing `.claude/commands/opsx`. Rejected for now: it is local agent tooling, not a project artifact, and adding it to `.gitignore` keeps `git status` clean. It can be committed later if the agents' commands become contributor-facing.

### Formatting baseline

`cargo fmt -p md-render` runs once as its own commit, before the formatting gate is enabled. The commit is recorded in `.git-blame-ignore-revs` so `git blame` skips it. The vendored crates are untouched.

### Repository settings (manual, one-time)

These are not workflow files and cannot be tested by CI:

- Repository description and topics (`neovim`, `neovim-plugin`, `markdown`, `rust`, `markdown-renderer`, `terminal`).
- Enable private vulnerability reporting, so `SECURITY.md` can point at it.
- Enable Dependabot alerts and security updates.
- A ruleset on `main` requiring the `gate` check and blocking force-pushes.
- Optionally, `v0.1.0` as the first release tag after the workflows land.

## Risks / Trade-offs

- **macOS cross-build of x86_64 on an arm64 runner fails to link** → the first release run is the test; the fallback is separate `macos-13` and `macos-latest` builds with a `lipo` merge job, which costs one more runner.
- **`rhysd/action-setup-vim` cannot resolve the pinned 0.10 release** → fall back to downloading the official Neovim tarball for that version; the matrix value is the only place to change.
- **OpenSpec CLI drift** → the version is pinned in one `env`; a bump is a deliberate commit. A new CLI release cannot silently change the gate.
- **The formatting baseline creates a large diff** → it is a separate commit and listed in `.git-blame-ignore-revs`; review it once as a mechanical change, never as part of a behaviour change.
- **`* text=auto eol=lf` renormalizes existing files** → run `git add --renormalize .` and review; the index is already LF, so the expected diff is small or empty.
- **Committing `openspec/` publishes the in-progress `animation-frame-budget` change** → it is planning, not code; if it is abandoned, archive or remove it in a separate change rather than hiding the whole directory.
- **Release tags can be deleted or moved** → `--verify-tag` ensures the tag exists; the release workflow is re-runnable from the Actions tab. A deleted release is not a rollback of the code.
- **The plugin suite runs only on Linux** → Windows-specific link-path branches are covered by the shared predicate's unit checks in the headless suite, not by an end-to-end Windows run. This is a deliberate matrix-size trade-off.
- **`doc/tags` drifts from the help file** → CI regenerates it and fails on a diff; the option and command coverage check fails when a new one is added without a help entry.
- **A stale data-directory binary is hard to notice** → the repository's `bin/` stays ahead of it, and `:checkhealth` names the step that won, so a `PATH` or data-directory shadow is visible.
- **`:checkhealth` runs the engine** → `probe()` uses one `--version` call and one minimal empty render, both with a timeout, and never renders the current buffer.
- **Attaching the current buffer on setup could double-attach** → the attach path reuses the `FileType` guard (valid buffer and window, state matching the source) and is deferred; a repeated `setup()` does not install a second autocmd set.
- **A lazy.nvim `ft` load still misses a buffer that is not current** → the documented snippet uses `BufReadPre` instead; `ft` is supported for the current buffer, which is the one the event is about.
- **Moving README prose to `docs/design.md` loses detail** → the sections are moved rather than rewritten; the README keeps a summary and links to the design document, and a heading comparison plus link check catches an omission.
- **The README demo goes stale** → it shows only the toggle and, optionally, preview; a committed rendered-output block is the fallback when no recording is maintained.
- **CI minutes** → public repositories get free hosted minutes, so the cost is wall-clock time; `concurrency` cancellation and Rust caching keep it bounded.

## Migration Plan

1. Land the platform fixes, the two fixtures and the link predicate with no workflow changes, and verify both plugin suites locally.
2. Land the engine contract: wire-version check, four-step discovery, setup attach, and the headless checks for each. Verify a mismatched stand-in engine leaves the window in S.
3. Land `health.lua`, `doc/md-render.txt` and generated `doc/tags`; verify `:help md-render` and `:checkhealth md-render` by hand.
4. Land the formatting baseline as a separate commit.
5. Restructure the README as a landing page and move the architecture prose to `docs/design.md`, then land `.github/` workflows, repository metadata and the remaining documentation, including the help-tag, help-open, health and wire-mismatch CI steps.
6. Push a branch and open a pull request; confirm all CI jobs and the gate pass on a clean checkout.
7. Enable branch protection for `gate`, then tag `v0.1.0` and confirm the three release archives and `SHA256SUMS` appear.
8. Rollback is by deleting a bad tag/release and reverting the workflow commit; no runtime state is involved.
