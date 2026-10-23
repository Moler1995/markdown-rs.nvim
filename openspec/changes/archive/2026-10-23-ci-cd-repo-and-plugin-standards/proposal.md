# Proposal

## Why

The repository is public but nothing verifies it on a clean machine: there is no CI, no release, and a fresh clone cannot even compile the engine tests because two fixtures are untracked. Several tests and developer instructions are also platform-specific in ways that make the first Linux/macOS run fail, and users must build the engine themselves because no prebuilt binary is published. Automating verification and publishing release binaries makes contributions safe and the plugin usable without a Rust toolchain.

The plugin is also not yet a standard Neovim plugin from a user's point of view. It has no `:help`, no `:checkhealth`, ignores the wire-format version the engine sends even though the documentation calls a mismatch a hard error, and only looks for the engine on `PATH` or in the repository's untracked `bin/`. A plugin manager that loads it on `FileType` can miss the first buffer because `setup()` does not attach the buffer already on screen. These gaps turn every installation problem into a source-reading exercise.

The README is thorough but reads as a design document. It opens with a Windows-specific directory tree, has no requirements or quick start, duplicates the option and keymap reference, and still names the retired `g:md_render_binary` key. A first-time user has to reconstruct the install path from architecture prose, and the document that should answer "what is this and how do I run it" instead explains how the render cache works.

## What Changes

- Add a GitHub Actions CI workflow that runs the Rust workspace on Ubuntu, Windows and macOS, checks the engine with rustfmt and clippy, verifies the declared MSRV, runs both Neovim plugin suites on Linux against Neovim 0.10.x and stable, and validates the OpenSpec specs.
- Add a tag-driven release workflow that publishes `md-render` for Linux x86_64 (musl), Windows x86_64 (static CRT) and macOS universal, with SHA-256 checksums and generated release notes.
- Add weekly `cargo audit` and Dependabot updates for Cargo dependencies and GitHub Actions.
- Track the two fixtures that tests already reference: `engine/tests/fixtures/golden/theme_blocks_width40.json` and `tests/fixtures/diagram_links.md`.
- Make the test suites platform-neutral: the headless suite's stand-in engines are written as `.bat` only today, and one engine unit test assumes Windows path semantics.
- Make follow-link path resolution leave absolute destinations (POSIX, drive-letter and UNC) as given, matching the existing image-open behaviour.
- Standardize the repository: `.gitattributes`, `.editorconfig`, issue and pull-request templates, `CONTRIBUTING.md`, `SECURITY.md`, a canonical MIT `LICENSE` with the derivation notice moved to `NOTICE`, README status badges and cross-platform install/test instructions, and corrected engine-resolution documentation.
- Restructure `README.md` as a landing page: badges, features, requirements, installation, quick start, compatibility matrix, troubleshooting and links to `:help`, `:checkhealth`, `CONTRIBUTING.md`, `SECURITY.md`, `NOTICE` and Releases; move the long architecture prose into `docs/design.md`.
- Add `doc/md-render.txt` with tags and track `doc/tags`, so `:help md-render` documents the commands, keymaps, options, engine resolution and troubleshooting.
- Add `lua/md-render/health.lua`, so `:checkhealth md-render` reports the resolved engine, its version, the wire version and the terminal's image capability.
- Validate the engine's wire-format `version` and refuse a missing or mismatched value instead of rendering with it.
- Add `stdpath('data')/md-render/` as the installed-engine location, after the configured path, `PATH` and the repository's `bin/`.
- Attach the buffer already on screen when the plugin is sourced or `setup()` runs, so lazy loading on `FileType` renders the first markdown file rather than waiting for a reopen.
- Document lazy.nvim, `vim.pack` and `mini.deps` installation, a cross-platform source-build hook, and the Neovim module cache that makes a restart necessary after editing plugin Lua.
- Commit `openspec/` so the validation gate has content, and ignore the local `.claude/` directory.
- Format the engine once with `cargo fmt -p md-render` as a separate baseline commit; vendored crates stay untouched.

## Capabilities

### New Capabilities

- `repo/ci-cd`: automated verification of the Rust workspace, the Neovim plugin and the OpenSpec specs, plus tag-driven engine releases, dependency updates and vulnerability auditing.
- `repo/standards`: repository conventions that keep a fresh clone buildable and the project portable — tracked test assets, cross-platform scripts and contributor instructions, line-ending and editor settings, community files and canonical licensing metadata.
- `nvim/engine-discovery`: how the plugin finds the `md-render` executable, including the per-user data directory, verifies that its wire format is understood, and reports the result through `:checkhealth`.
- `nvim/help`: the plugin's built-in `:help` documentation, its tags, and the checks that keep the documented commands and options in step with the code.

### Modified Capabilities

- `nvim/render-mode`: following a markdown link resolves absolute destinations as given instead of joining them to the document's directory; and setup attaches the buffer already on screen, so lazy loading renders the first markdown file.

## Impact

- New `.github/` workflows and metadata; new root-level contributor and licensing files.
- New `doc/md-render.txt` and `doc/tags`; new `lua/md-render/health.lua`.
- `tests/headless/run.lua` and `engine/src/image_art.rs` become platform-neutral.
- `lua/md-render/engine.lua` gains the data-directory resolution step and the wire-version check.
- `lua/md-render/init.lua` shares one absolute-path predicate between image opening and link following, and attaches the buffer already on screen when setup or plugin loading reaches a managed filetype.
- `plugin/md-render.lua` attaches the current buffer after installing its autocmds, and gains no new user commands.
- `README.md` is restructured as a landing page with requirements, a compatibility matrix, a quick start, a demo and links to the reference, community and release surfaces; its long architecture prose moves to a new `docs/design.md`.
- `docs/porting.md` and `CLAUDE.md` gain cross-platform commands, plugin-manager install snippets, the data-directory engine location and the `:help`/`:checkhealth` entry points, and lose the stale `g:md_render_binary` references.
- The CI plugin job gains help-tag, `:help`, `:checkhealth` and wire-mismatch checks.
- `openspec/` and the two test fixtures become tracked; `.claude/` becomes ignored.
- Release tags gain a contract: `v*` tags publish three artifacts and their checksums. No runtime dependency, wire-format or engine-output change; the wire version stays 1.
