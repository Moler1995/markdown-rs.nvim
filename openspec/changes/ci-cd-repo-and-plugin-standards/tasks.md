# Tasks

## 1. Make the test suite complete and portable

- [x] 1.1 Track `engine/tests/fixtures/golden/theme_blocks_width40.json` with `git add` and verify `cargo test -p md-render --test image_layout` passes from a checkout that does not already have the file untracked.
- [x] 1.2 Track `tests/fixtures/diagram_links.md` with `git add` and verify `MDRN_REPO=$PWD nvim --headless -l tests/headless/run.lua` passes section 12.3.
- [x] 1.3 Make `absolute_destinations_are_used_as_given` and its relative sibling in `engine/src/image_art.rs` choose their paths with `cfg!(windows)` (`C:/docs/a.png` on Windows, `/docs/a.png` on Unix) and verify `cargo test -p md-render --lib image_art` passes on Windows; the Linux/macOS run is verified by CI.
- [x] 1.4 Add a stand-in-engine helper to `tests/headless/run.lua` that writes a `.bat` file on Windows and a `#!/bin/sh` script with `vim.fn.setfperm(path, 'rwx------')` on Unix, replace the two `.bat` call sites (sections 10.6 and 11.2), and verify both failure paths plus the garbage-output path pass in the headless suite.
- [x] 1.5 Move the POSIX/drive-letter/UNC absolute-path predicate into `lua/md-render/link.lua` as `M.is_absolute`, use it in both `M.open_image` and `M.follow` in `lua/md-render/init.lua`, and verify the headless suite still passes.
- [x] 1.6 Add headless checks that `link.is_absolute` accepts `/x`, `C:/x`, `C:\x` and `\\server\share` and rejects `docs/x.md`, and that a link with a POSIX absolute target is opened as given rather than joined to the document directory; verify the new checks pass.
- [x] 1.7 Update the "Following links" section of `README.md` to state that absolute destinations (POSIX, drive-letter and UNC) are used as given, and verify the wording matches the behaviour exercised by the checks in 1.6.

## 2. Establish the formatting baseline

- [x] 2.1 Run `cargo fmt -p md-render` and verify `cargo fmt -p md-render -- --check` exits 0.
- [x] 2.2 Verify the reformatted engine still builds and tests: `cargo test --workspace --locked` and `cargo clippy -p md-render --all-targets --locked -- -D warnings` both exit 0.
- [x] 2.3 Commit the formatting change by itself, add its commit hash to a new `.git-blame-ignore-revs`, and verify `git blame --ignore-revs-file=.git-blame-ignore-revs engine/src/main.rs` runs.

## 3. Add the CI workflow

- [x] 3.1 Create `.github/workflows/ci.yml` with `pull_request` and `push` to `main` triggers, `concurrency` cancellation, `permissions: contents: read`, and a three-OS `rust` job running `cargo test --workspace --locked` with `Swatinem/rust-cache@v2`; verify the file parses with `npx --yes js-yaml .github/workflows/ci.yml`.
- [x] 3.2 Add the `lint` job (`cargo fmt -p md-render -- --check`, `cargo clippy -p md-render --all-targets --locked -- -D warnings`) and the `msrv` job (`cargo check --workspace --locked` on Rust 1.92); verify both commands exit 0 locally, including `cargo +1.92 check --workspace --locked`.
- [x] 3.3 Add the `plugin` matrix job for Neovim `v0.10.4` and `stable` that builds the release engine, creates `bin/`, copies the binary, runs both suites with `MDRN_REPO` set, regenerates `doc/tags` and fails on a diff, opens `:help md-render` headlessly, and runs the health probe; verify the YAML parses and both suites plus the three plugin checks pass locally against the built binary.
- [x] 3.4 Add the `openspec` job running `npx --yes @fission-ai/openspec@1.13.2 validate --all --no-interactive`, and verify the same command exits 0 locally.
- [x] 3.5 Add the aggregate `gate` job with `if: always()`, `needs` covering every CI job, and a step that fails unless every needed result is `success`; verify the `needs` list names every job in the file.
- [x] 3.6 Rehearse the complete CI sequence locally in one pass — workspace tests, fmt, clippy, MSRV check, both plugin suites, help/health checks, OpenSpec validation — and verify every command exits 0.
- [x] 3.7 Add `tools/check-readme.sh` and run it from the plugin job: assert the required landing-page sections, resolve every relative link against tracked files, and fail on `g:md_render_binary` or a drive-letter path; verify it fails when a heading is removed or a linked file is missing, and passes on the finished README without making a network request.

## 4. Add the release workflow

- [x] 4.1 Create `.github/workflows/release.yml` with a `v*` tag trigger, a `workflow_dispatch` trigger taking a `tag` input and a `dry_run` input defaulting to true, `permissions: contents: write`, and a preflight check that the tag equals `v` plus the `md-render` version from `cargo metadata`; verify the YAML parses and the tag check passes for `v0.1.0`.
- [ ] 4.2 Add the Linux build job targeting `x86_64-unknown-linux-musl`, install `musl-tools`, smoke-test `md-render --version`, and package the executable with `LICENSE` and `README.md` as `md-render-<tag>-x86_64-unknown-linux-musl.tar.gz`; verify the local musl build and `--version` run.
- [ ] 4.3 Add the Windows build job targeting `x86_64-pc-windows-msvc` with `RUSTFLAGS=-C target-feature=+crt-static`, smoke-test `md-render.exe --version`, and package a zip with the executable, `LICENSE` and `README.md`; verify the build and smoke test locally.
- [x] 4.4 Add the macOS build job building `aarch64-apple-darwin` and `x86_64-apple-darwin`, merging them with `lipo -create`, smoke-testing the universal binary, and packaging a tar.gz; verify the YAML parses and document the fallback to separate runners in the workflow comment.
- [ ] 4.5 Add the release job that depends on all three builds, downloads their artifacts, writes `SHA256SUMS` with `sha256sum`, and runs `gh release create "$TAG" --verify-tag --generate-notes` only when `dry_run` is false; verify the dry-run path uploads artifacts and skips the release.
- [x] 4.6 Verify the packaging and checksum commands by running the Linux package and `sha256sum -c` sequence locally against a built binary.

## 5. Add dependency and vulnerability monitoring

- [x] 5.1 Create `.github/workflows/audit.yml` with a weekly `17 4 * * 1` schedule, `workflow_dispatch`, `contents: read` and `issues: write`, running `rustsec/audit-check@v2`; verify the YAML parses.
- [x] 5.2 Create `.github/dependabot.yml` with weekly `cargo` and `github-actions` updates, grouping patch and minor Cargo updates; verify the YAML parses and names both ecosystems.
- [x] 5.3 Run `cargo install --locked cargo-audit` and `cargo audit` against `Cargo.lock`, and verify the command exits 0 or record the reported advisory in the change.

## 6. Add repository standards and update documentation

- [x] 6.1 Create `.gitattributes` with `* text=auto eol=lf`, CRLF rules for `.bat`/`.ps1`, and `binary` for image and executable fixtures; verify `git check-attr text eol -- tools/make-bench-doc.sh` reports LF and `git check-attr binary -- tests/fixtures/logo.png` reports set.
- [x] 6.2 Run `git add --renormalize .`, inspect the diff, and verify no text file changes its content solely because of line endings.
- [x] 6.3 Create `.editorconfig` with UTF-8, LF, final newline and per-language indentation, and verify it parses as an INI file with Python's `configparser`.
- [x] 6.4 Add `.claude/`, `.idea/`, `.vscode/` and `*.log` to `.gitignore` and verify `git status --porcelain` no longer lists `.claude/`.
- [x] 6.5 Replace `LICENSE` with the canonical MIT text and move the derivation and vendored-crate notices into a new `NOTICE`; verify `grep -c "Permission is hereby granted" LICENSE` is 1 and `NOTICE` contains the `markdown-reader` revision.
- [x] 6.6 Create `CONTRIBUTING.md` covering prerequisites, POSIX and PowerShell build/test/install commands, formatting and clippy scope, snapshot updates, the OpenSpec workflow, regenerating `doc/tags`, and restarting Neovim after editing plugin Lua; verify the PowerShell sequence runs as written and the POSIX sequence is the same one CI runs.
- [x] 6.7 Create `SECURITY.md` and `.github/ISSUE_TEMPLATE/{bug_report.yml,feature_request.yml,config.yml}` plus `.github/pull_request_template.md`; verify the YAML templates parse and the bug template asks for OS, Neovim version, engine version and reproduction steps.
- [x] 6.8 Update the README's installation and engine material: a user-facing release-download path, lazy.nvim/`vim.pack`/`mini.deps` snippets, the data-directory engine location, links to `:help md-render` and `:checkhealth md-render`, POSIX and PowerShell variants for every command, the correct four-step resolution order, and no `g:md_render_binary`; verify `grep -rn "g:md_render_binary" .` returns no matches and the PowerShell commands run.
- [x] 6.9 Rewrite `docs/porting.md` from "the Windows binary" to cross-platform engine distribution, the four-step search order, the wire-version check and staleness; verify its order matches `lua/md-render/engine.lua` and it names `engine`, not the retired key.
- [x] 6.10 Update `CLAUDE.md` with `mkdir -p bin` in the build step, the CI quality gates (fmt/clippy, OpenSpec, help tags, health), the restart needed after editing plugin Lua, and the vendored-crate formatting exemption; verify the documented commands still run.
- [x] 6.11 Track `openspec/` (including the `animation-frame-budget` change as-is) and verify `openspec validate --all --no-interactive` exits 0 and `git ls-files openspec | wc -l` is greater than zero.
- [x] 6.12 Verify no tracked fixture is missing by running `git ls-files --error-unmatch engine/tests/fixtures/golden/theme_blocks_width40.json tests/fixtures/diagram_links.md` and confirming both paths resolve.
- [x] 6.13 Restructure `README.md` into the landing-page order: badges, description, demo, Features, Requirements, Installation, Quick start, Configuration, Commands and keymaps, Troubleshooting, Development, Architecture, Contributing, Security, License and provenance; verify every named section is present and Installation and Quick start precede architecture.
- [x] 6.14 Move the long architecture prose (`The two states`, `Staying in step`, `Following links`, `Images`, `The block preview`, and the vendored-crate detail) into a new `docs/design.md`, leave a short engine/plugin boundary summary and a link in the README, and verify each moved section is present in the design document and no explanation was dropped.
- [x] 6.15 Add the Requirements and compatibility sections (Neovim 0.10+, engine, truecolor for image artwork, Rust only for source builds; supported Neovim versions and published engine targets), the Quick start sequence, and a demo (screenshot/GIF or rendered-output block) before Installation; verify the claims match `plugin/md-render.lua`, the wire version and the release workflow.
- [x] 6.16 Add links to `CONTRIBUTING.md`, `SECURITY.md`, `NOTICE`, `docs/design.md` and GitHub Releases, make the directory tree repository-relative with `md-render[.exe]`, and verify every relative link resolves and no absolute drive path remains.

## 7. Standardize engine discovery and wire compatibility

- [x] 7.1 Add `WIRE_VERSION = 1` to `lua/md-render/engine.lua` and reject a missing or different `doc.version` after JSON decoding, with a diagnostic naming both versions and the rebuild-or-upgrade remedies; verify with a stand-in engine that prints `{"version":2,"lines":[],"styles":[]}`.
- [x] 7.2 Replace the resolution chain with: explicit `engine` (used as given, with an error when it is not executable) → `PATH` → `<plugin-root>/bin` → `stdpath('data')/md-render`; use `vim.fn.executable` for each candidate, and make the not-found error name every searched path plus the build command and the data-directory destination.
- [x] 7.3 Add headless checks for the resolution order: a fake engine in `bin/` beats a data-directory one, a data-directory engine is found when `bin/` is absent, a non-executable file is skipped on Unix, and a configured non-executable path fails without falling back; verify the section passes on Windows and Linux.
- [x] 7.4 Add a headless test that a wire-version mismatch leaves the window in S, reports both versions, and never enters R; verify it passes.
- [x] 7.5 Run the headless suite with only a data-directory engine (no `bin/` and no `md-render` on `PATH`) and verify the engine is resolved and a document renders.
- [x] 7.6 Update the comments in `engine.lua` and the `engine` option in `config.lua` to the new order and the explicit-setting rule; verify no comment still says the search stops at `bin/`.

## 8. Make setup and loading reach the current buffer

- [x] 8.1 Add an attach-current-window helper to `lua/md-render/init.lua` that checks the current buffer's filetype, validates the buffer and window, and calls `M.attach` only when the window is not already attached to that source.
- [x] 8.2 Call the helper from `M.setup()` after `setup_autocmds()` and from `plugin/md-render.lua` after `md.setup_autocmds()`, deferred with `vim.schedule` and re-checking that the window still shows the buffer; verify a normal startup with a markdown file still shows R once.
- [x] 8.3 Add headless checks: `setup{}` with a markdown buffer current attaches it and shows R; sourcing the plugin after `FileType` attaches the triggering buffer; `setup{}` before filetype detection does not attach and the later `FileType` does; two `setup{}` calls leave one autocmd group and one set of buffer maps.
- [x] 8.4 Add a headless check that simulates a lazy.nvim `ft = 'markdown'` load by sourcing the plugin after `FileType` and `BufWinEnter`, and asserts the first buffer shows R without `:e`.
- [x] 8.5 Verify the attach helper does not start a render for a non-managed buffer or for a window showing another buffer, and that it leaves the state of an already attached window unchanged.

## 9. Add `:checkhealth md-render`

- [x] 9.1 Add `lua/md-render/health.lua` with `probe()` returning a table and `check()` rendering it through `vim.health`; `probe()` reports Neovim support, the resolved path and the step that produced it, `--version`, the wire version from an empty-document render, `'termguicolors'`, the resolved image encoding and the configured filetypes.
- [x] 9.2 Bound both engine calls in `probe()` with a timeout, never render the current buffer, and verify `:checkhealth md-render` leaves the current buffer's contents and window state unchanged.
- [x] 9.3 Add headless checks for a healthy engine, a missing engine, a wire mismatch and `'termguicolors'` off; verify the report names the resolution step and includes remediation for each failure.
- [x] 9.4 Add the health check to the plugin CI job and verify it fails with no engine and passes with the built `bin/` engine.
- [x] 9.5 Document `:checkhealth md-render` in the help troubleshooting section and the README, and verify the command opens without an error.

## 10. Add `:help md-render`

- [x] 10.1 Create `doc/md-render.txt` with the main tag, command tags, `md-render.setup`, `md-render-options`, `md-render-commands`, `md-render-keymaps`, and sections for requirements, installation, engine resolution, options, commands, keymaps, links, preview/zoom, images/animation, health and troubleshooting.
- [x] 10.2 Generate `doc/tags` with `nvim --headless -u NONE -c 'helptags doc' -c q`, track it, and verify a second run produces no diff.
- [x] 10.3 Add a headless check that `:help md-render`, each command tag, `md-render.setup`, `md-render-options`, `md-render-commands` and `md-render-keymaps` resolve.
- [x] 10.4 Add a headless check that every command created by `plugin/md-render.lua`, every top-level key in `config.defaults` and every key in `keymaps` appears in `doc/md-render.txt`.
- [x] 10.5 Add a CI step that regenerates the tags and runs `git diff --exit-code doc/tags`; verify it fails when the help file changes without the tags.
- [x] 10.6 Move the detailed option and keymap tables out of `README.md` into the help file, leaving a short summary that links to `:help md-render-options` and `:help md-render-keymaps`; verify the README has no complete duplicated option or keymap table and no `g:md_render_binary`.

## 11. Document installation and troubleshooting

- [x] 11.1 Add lazy.nvim (`event = { 'BufReadPre *.md', 'BufNewFile *.md' }`), `vim.pack` and `mini.deps` snippets to the README and help, including the engine download or build step and the data-directory destination.
- [x] 11.2 Add a cross-platform source-build hook example that runs `cargo build --release -p md-render`, creates `bin/` and copies `md-render[.exe]`; verify the PowerShell and POSIX paths.
- [x] 11.3 Document that editing `lua/md-render/` requires restarting Neovim, and that `:MdRenderReset` clears render and highlight caches only; verify the wording matches the implementation.
- [x] 11.4 Add a troubleshooting section covering engine not found, wire mismatch, no truecolor/ASCII, lazy loading and stale modules; verify each item names the command or setting to check.
- [x] 11.5 Verify the install snippets and troubleshooting steps in a minimal Neovim config containing only the plugin and the built engine.

## 12. Integration verification

- [x] 12.1 Clone the repository into a fresh temporary directory, build the engine into `bin/`, run `cargo test --workspace --locked`, both Neovim suites, and `openspec validate --all --no-interactive`; verify all pass using only tracked files.
- [x] 12.2 On that fresh clone, follow the README's Quick start in a minimal Neovim config, then run `:help md-render`, `:checkhealth md-render`, the lazy-load check and the wire-mismatch check; verify all five pass and every relative link in the README resolves.
- [x] 12.3 Open a draft pull request and verify every CI job appears and the aggregate `gate` job succeeds.
- [ ] 12.4 Run the release workflow with `dry_run=true` for `v0.1.0` and verify three archives plus `SHA256SUMS` are produced and no GitHub Release is created.
- [ ] 12.5 Push the `v0.1.0` tag, verify the GitHub Release contains the three archives and `SHA256SUMS`, run `sha256sum -c` on the downloads, and run each engine with `--version`.
- [ ] 12.6 Apply the repository settings: description, topics (`neovim`, `neovim-plugin`, `markdown`, `rust`, `markdown-renderer`, `terminal`), private vulnerability reporting, Dependabot alerts and security updates, and a `main` ruleset requiring the `gate` check; verify with `gh repo view --json description,repositoryTopics` and `gh api repos/Moler1995/markdown-rs.nvim/rulesets`.
