# repo/ci-cd Specification

## Purpose
Keeps the Rust workspace, the Neovim plugin and the OpenSpec specs verified on every change, and publishes prebuilt engine binaries when a version tag is pushed.

## Requirements

### Requirement: README structure and links are checked

The CI workflow SHALL check the README for the sections a landing page requires: Features, Requirements, Installation, Quick start, Configuration, Commands and keymaps, Troubleshooting, Development, Architecture, Contributing and License. It SHALL fail when a required section is missing.

The check SHALL resolve every relative link in the README against tracked files, including `CONTRIBUTING.md`, `SECURITY.md`, `NOTICE` and `docs/design.md`, and SHALL fail when a link names a missing file. It SHALL fail when the README contains `g:md_render_binary` or a drive-letter absolute path in its directory tree. It SHALL NOT fetch external URLs, so a network failure cannot fail the gate.

#### Scenario: A required section is removed

- **WHEN** the README no longer contains one of the required sections
- **THEN** the README check fails

#### Scenario: A relative link is broken

- **WHEN** the README links to a local file that is not tracked
- **THEN** the README check fails

#### Scenario: A retired key remains

- **WHEN** the README contains `g:md_render_binary`
- **THEN** the README check fails

#### Scenario: The README is valid

- **WHEN** every required section is present and every relative link resolves
- **THEN** the README check passes
- **AND** no external request is made

### Requirement: Changes are verified on every push and pull request

The repository SHALL run a CI workflow for every pull request and for every push to the default branch. The workflow SHALL report a failure when any required job fails, and that result SHALL be visible on the pull request.

#### Scenario: A pull request is opened or updated

- **WHEN** a pull request is opened, reopened or receives a new commit
- **THEN** the Rust, engine-quality, plugin and OpenSpec jobs run
- **AND** their results are attached to the pull request

#### Scenario: A commit lands on the default branch

- **WHEN** a commit is pushed to the default branch
- **THEN** the same required jobs run against that commit

### Requirement: The Rust workspace is tested on three operating systems

The CI workflow SHALL run `cargo test --workspace` on Ubuntu, Windows and macOS with the stable Rust toolchain. Every workspace member SHALL be tested, including the vendored crates.

#### Scenario: The three-platform matrix

- **WHEN** CI runs for a commit
- **THEN** the workspace tests run once on Ubuntu, once on Windows and once on macOS

#### Scenario: A test fails on one platform

- **WHEN** a workspace test fails on any of the three platforms
- **THEN** that platform's job fails
- **AND** the overall workflow reports a failure

### Requirement: The engine passes formatting and lint gates

The CI workflow SHALL check the `md-render` package with `cargo fmt --check` and with `cargo clippy --all-targets -- -D warnings`. The vendored crates SHALL NOT be subject to the formatting gate.

#### Scenario: Formatting drift

- **WHEN** a file in the `md-render` package is not rustfmt-clean
- **THEN** the engine-quality job fails

#### Scenario: A clippy warning

- **WHEN** clippy reports a warning for the `md-render` package
- **THEN** the engine-quality job fails

#### Scenario: A change confined to a vendored crate

- **WHEN** only `crates/mermaid-text` or `crates/ascii-dag` changes
- **THEN** the formatting gate does not fail merely because those crates are not rustfmt-clean

### Requirement: The declared minimum Rust version is verified

The CI workflow SHALL build the workspace with the `rust-version` declared in `Cargo.toml`, so the declaration cannot drift away from the code.

#### Scenario: The MSRV job runs

- **WHEN** CI runs for a commit
- **THEN** the workspace is checked with Rust 1.92

#### Scenario: The code needs a newer compiler

- **WHEN** a change uses a language or standard-library feature newer than the declared MSRV
- **THEN** the MSRV job fails

### Requirement: The plugin suites run against two Neovim versions

On Linux, the CI workflow SHALL build the release engine, place it in `bin/`, and run both `tests/headless/run.lua` and `tests/interactive/run.lua` with Neovim 0.10.x and with the current stable Neovim release. The headless run SHALL include the setup-attach and repeated-setup checks, the help-tag and option-coverage checks, the health probe against the built engine, and the wire-mismatch check.

#### Scenario: The headless suite

- **WHEN** the plugin job runs with either Neovim version
- **THEN** the headless suite runs with `MDRN_REPO` set to the checkout
- **AND** the job fails if any check fails

#### Scenario: The interactive suite

- **WHEN** the plugin job runs with either Neovim version
- **THEN** the interactive suite starts a real Neovim and completes
- **AND** the job fails if any check fails

#### Scenario: A plugin test fails on one Neovim version

- **WHEN** a suite fails under Neovim 0.10.x but passes under stable, or the reverse
- **THEN** the plugin job for that version reports a failure

### Requirement: OpenSpec artifacts are validated in CI

The CI workflow SHALL install a pinned OpenSpec CLI and run `openspec validate --all --no-interactive` from the repository root. The `openspec/` directory SHALL be tracked so the gate has the project's specs and changes to read.

#### Scenario: The specs and changes validate

- **WHEN** the OpenSpec job runs
- **THEN** every spec and every change validates
- **AND** the job succeeds

#### Scenario: An invalid change is proposed

- **WHEN** a change is missing a required artifact or contains an invalid requirement
- **THEN** `openspec validate` exits non-zero
- **AND** the OpenSpec job fails

### Requirement: A version tag publishes engine binaries

Pushing a tag matching `v*` SHALL build and publish the engine for three targets: Linux x86_64 with the musl runtime, Windows x86_64 with the MSVC toolchain and a static C runtime, and a macOS universal binary containing arm64 and x86_64. Each archive SHALL contain the executable, `LICENSE` and `README.md`, and SHALL be named for the tag and the target. The release SHALL include a SHA-256 checksum file covering every archive. The GitHub Release SHALL be named for the tag and use generated release notes.

#### Scenario: A release tag is pushed

- **WHEN** a tag such as `v0.2.0` is pushed
- **THEN** all three target builds run
- **AND** a GitHub Release is created for the tag with the three archives and the checksum file
- **AND** generated release notes describe the changes since the previous tag

#### Scenario: One target fails to build

- **WHEN** any target build fails
- **THEN** no GitHub Release is published for the tag
- **AND** the failed job is visible in the workflow run

#### Scenario: The checksums match

- **WHEN** the checksum file is compared with the published archives
- **THEN** every SHA-256 digest matches its archive

#### Scenario: The engines start

- **WHEN** each built executable is run with `--version` on its build platform
- **THEN** it prints the `md-render` version and exits successfully before it is uploaded

### Requirement: Dependencies and vulnerabilities are monitored

Dependabot SHALL check Cargo dependencies and GitHub Actions weekly. A scheduled and manually dispatchable workflow SHALL run `cargo audit` against the committed `Cargo.lock`, and SHALL fail when the advisory database reports a vulnerability affecting the dependency graph.

#### Scenario: The weekly audit

- **WHEN** the audit workflow's weekly schedule fires
- **THEN** `cargo audit` runs against `Cargo.lock`
- **AND** a reported vulnerability makes the workflow fail

#### Scenario: A dependency update is available

- **WHEN** Dependabot finds a newer Cargo dependency or GitHub Action
- **THEN** it opens a pull request
- **AND** the normal CI workflow runs against that pull request

#### Scenario: A manual audit

- **WHEN** a maintainer dispatches the audit workflow by hand
- **THEN** the audit runs without waiting for the schedule

### Requirement: Plugin documentation and diagnostics are gated

The plugin CI job SHALL regenerate `doc/tags` with `nvim --headless -u NONE -c 'helptags doc' -c q` and SHALL fail when the regenerated file differs from the tracked one. It SHALL run `:help md-render` headlessly and fail when the tag does not resolve. It SHALL run the health probe headlessly against the built engine and fail when the probe reports a missing engine or a wire-version mismatch.

The headless suite SHALL fail when a command created by `plugin/md-render.lua` has no help tag, or when a top-level option or a `keymaps` key is absent from `doc/md-render.txt`.

#### Scenario: The tags are current

- **WHEN** the plugin job regenerates `doc/tags` on a branch where the help file and tags agree
- **THEN** `git diff --exit-code doc/tags` succeeds
- **AND** the job continues

#### Scenario: The tags are stale

- **WHEN** `doc/md-render.txt` changed without regenerating `doc/tags`
- **THEN** the diff is non-empty
- **AND** the plugin job fails

#### Scenario: The help entry does not resolve

- **WHEN** `:help md-render` cannot open the help file
- **THEN** the plugin job fails

#### Scenario: A command or option is undocumented

- **WHEN** a command, top-level option or `keymaps` key is added without a help entry
- **THEN** the headless suite fails

#### Scenario: The health probe finds a working engine

- **WHEN** the plugin job runs the health probe with the built engine in `bin/`
- **THEN** the probe reports the engine path, its resolution step, its version and a matching wire version
- **AND** the job succeeds

#### Scenario: A wire mismatch is refused

- **WHEN** the headless suite renders through a stand-in engine that emits a wire version other than the expected one
- **THEN** the plugin refuses the document
- **AND** the suite sees the diagnostic naming both versions
