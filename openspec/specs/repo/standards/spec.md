# repo/standards Specification

## Purpose
Defines the repository files and conventions that keep a fresh clone buildable on every supported platform and make contribution, licensing and support information easy to find.

## Requirements

### Requirement: A fresh clone contains every test asset

Every file that a build script or test reads SHALL be tracked. In particular, `engine/tests/fixtures/golden/theme_blocks_width40.json` and `tests/fixtures/diagram_links.md` SHALL be tracked, because a test includes or opens each of them.

#### Scenario: A fresh clone builds the engine tests

- **WHEN** the repository is cloned into an empty directory and `cargo test --workspace` runs
- **THEN** the test targets compile
- **AND** the workspace tests pass without generating any missing fixture

#### Scenario: A fresh clone runs the plugin suites

- **WHEN** the engine is built into `bin/` on a fresh clone and the headless suite runs
- **THEN** the checks that read `tests/fixtures/diagram_links.md` pass

#### Scenario: A referenced fixture is missing

- **WHEN** a test references a fixture that is not tracked
- **THEN** CI fails on a clean checkout rather than passing on a machine that happens to have the file

### Requirement: Repository text conventions are explicit

The repository SHALL contain a `.gitattributes` file that normalizes text files to LF in the repository and the working tree on every platform, declares any Windows batch files as CRLF, and marks binary files as binary. It SHALL contain an `.editorconfig` that declares UTF-8, LF line endings, a final newline and the project's indentation for Rust, Lua, Markdown and YAML.

#### Scenario: A shell script on Windows

- **WHEN** the repository is checked out on Windows
- **THEN** `tools/make-bench-doc.sh` keeps LF line endings
- **AND** its `#!/bin/sh` line remains executable by a POSIX shell

#### Scenario: A batch file

- **WHEN** a `.bat` file is present in the repository
- **THEN** it is checked out with CRLF line endings

#### Scenario: An editor opens a project file

- **WHEN** an editor that reads `.editorconfig` opens a Rust or Lua file
- **THEN** it uses the indentation and line-ending settings declared for that file type

### Requirement: Test helpers run on every supported platform

The headless suite SHALL create stand-in engine executables that the host platform can execute: a POSIX shell script with the executable bit set on Unix, and a batch file on Windows. Engine path-resolution tests SHALL use an absolute path that is absolute on the host platform.

#### Scenario: A failing stand-in engine on Linux or macOS

- **WHEN** the headless suite exercises its failing-engine path on Linux or macOS
- **THEN** the stand-in is an executable shell script
- **AND** the suite observes the stand-in's non-zero exit and diagnostic

#### Scenario: A failing stand-in engine on Windows

- **WHEN** the headless suite exercises its failing-engine path on Windows
- **THEN** the stand-in is a batch file
- **AND** the suite observes the stand-in's non-zero exit and diagnostic

#### Scenario: An absolute destination in an engine unit test

- **WHEN** the engine's image path-resolution tests run on Unix
- **THEN** the test supplies a POSIX absolute path
- **AND** when they run on Windows, the test supplies a drive-letter absolute path

### Requirement: Contributor instructions work in both shells

The README and `CONTRIBUTING.md` SHALL give both POSIX-shell and PowerShell commands for building the workspace, creating `bin/`, installing the engine there, and running both Neovim suites.

#### Scenario: A PowerShell contributor follows the instructions

- **WHEN** a contributor on Windows runs the documented PowerShell sequence from a fresh clone
- **THEN** the engine is built and copied into `bin/`
- **AND** the headless suite runs with `MDRN_REPO` set

#### Scenario: A POSIX-shell contributor follows the instructions

- **WHEN** a contributor on Linux or macOS runs the documented shell sequence from a fresh clone
- **THEN** the engine is built and copied into `bin/`
- **AND** the headless suite runs with `MDRN_REPO` set

### Requirement: Engine resolution is documented as implemented

The documentation SHALL state the plugin's engine resolution order: the configured `engine` path, then `md-render` on `PATH`, then `<repository>/bin/md-render` or `bin/md-render.exe`, then `stdpath('data')/md-render/md-render` or `md-render.exe`. It SHALL state that a configured `engine` path is used as given and that the later locations are searched only when it is empty. It SHALL state that `:checkhealth md-render` reports which step resolved the engine and which wire version it speaks. Documentation SHALL NOT name a configuration key that the plugin does not read.

#### Scenario: A reader installs the engine from the documentation

- **WHEN** a reader follows the installation instructions
- **THEN** the documented destination is one the plugin actually searches
- **AND** the documented option name is the one the plugin exposes

#### Scenario: A reader installs a downloaded release

- **WHEN** a reader follows the release-download instructions
- **THEN** the documented destination is the per-user data directory the plugin searches
- **AND** `:checkhealth md-render` confirms that the downloaded engine was found

#### Scenario: A stale option name is searched for

- **WHEN** the documentation is searched for `g:md_render_binary`
- **THEN** no match is found

### Requirement: Plugin installation is documented for standard managers

The README SHALL give install snippets for lazy.nvim, `vim.pack` and `mini.deps`. The lazy.nvim snippet SHALL load the plugin on `BufReadPre` and `BufNewFile` for markdown files rather than only on `FileType`. The README SHALL state where the engine goes for an installed plugin, and SHALL give a cross-platform source-build hook or the equivalent build-and-copy commands.

The documentation SHALL state that editing the plugin's Lua while Neovim is running requires a restart, because Neovim caches loaded modules; `:MdRenderReset` SHALL be described as clearing render and highlight caches, not as reloading code.

#### Scenario: A lazy.nvim user installs the plugin

- **WHEN** a user follows the lazy.nvim snippet
- **THEN** the plugin is loaded before the first markdown file is read
- **AND** that file shows R without being reopened

#### Scenario: A vim.pack or mini.deps user installs the plugin

- **WHEN** a user follows the `vim.pack` or `mini.deps` snippet
- **THEN** the snippet names the repository and any required setup call
- **AND** the engine location is stated

#### Scenario: A source install builds the engine

- **WHEN** a user follows the source-build hook on Windows, Linux or macOS
- **THEN** the engine is built and copied into a location the plugin searches
- **AND** the snippet does not assume a POSIX-only shell

#### Scenario: A contributor edits plugin Lua

- **WHEN** a contributor changes a file under `lua/md-render/` while Neovim is running
- **THEN** the documentation says to restart Neovim before testing the change
- **AND** it does not claim `:MdRenderReset` reloads the module

### Requirement: The README is a landing page

The README SHALL open with badges, a one-paragraph description of the project and a demo of the reading view. It SHALL contain sections for Features, Requirements, Installation, Quick start, Configuration, Commands and keymaps, Troubleshooting, Development, Architecture, Contributing and License. Installation and Quick start SHALL appear before the architecture section.

The Requirements section SHALL state the minimum Neovim version, the engine requirement, the terminal requirement for image artwork, and that Rust is required only for a source build. It SHALL include a compatibility table naming the supported Neovim versions and the published engine targets.

The Quick start SHALL give the shortest path from a fresh install to a rendered buffer: install the plugin, place the engine, open a markdown file and press the toggle key.

The demo SHALL be a screenshot, an animated recording or a short rendered-output block, and SHALL appear before Installation.

#### Scenario: A first-time reader opens the README

- **WHEN** a reader opens the README without prior knowledge of the project
- **THEN** the description, requirements, installation and quick start appear before the architecture section
- **AND** the reader does not need to read engine internals to install the plugin

#### Scenario: The requirements are checked before installing

- **WHEN** a reader has Neovim older than 0.10 or no engine
- **THEN** the Requirements section states the minimum version and the engine requirement
- **AND** it states that a source build needs Rust

#### Scenario: The compatibility table is read

- **WHEN** a reader looks for the supported platforms
- **THEN** the table names the supported Neovim versions
- **AND** it names the published engine targets

#### Scenario: The demo is viewed

- **WHEN** the README is rendered on GitHub
- **THEN** a demo of the reading view appears before the Installation section

### Requirement: The README links the reference, community and release surfaces

The README SHALL link to `:help md-render`, `:checkhealth md-render`, `docs/design.md`, `CONTRIBUTING.md`, `SECURITY.md`, `NOTICE` and the GitHub Releases page. It SHALL show a CI status badge, a latest-release badge and a license badge, each linking to the workflow, the releases page and the license respectively.

The README SHALL give only a short configuration, command and keymap summary and SHALL link to `:help md-render-options` and `:help md-render-keymaps` for the complete reference. It SHALL NOT maintain a second complete option or keymap table.

#### Scenario: A reader needs the full option reference

- **WHEN** a reader wants the meaning of every option or keymap
- **THEN** the README points to the corresponding help tag
- **AND** the complete reference exists once, in the help file

#### Scenario: A reader wants to contribute

- **WHEN** a reader looks for contribution or security instructions
- **THEN** the README links to `CONTRIBUTING.md` and `SECURITY.md`

#### Scenario: A reader wants the release history

- **WHEN** the README is rendered on GitHub
- **THEN** the latest-release badge links to the Releases page

#### Scenario: The README is checked for a retired key

- **WHEN** the README is searched for `g:md_render_binary`
- **THEN** no match is found

### Requirement: Deep design prose lives in docs/design.md

The architecture explanations that a user does not need in order to install or operate the plugin SHALL live in `docs/design.md`. The README SHALL keep a short summary of the engine/plugin boundary and link to that file. The README SHALL NOT duplicate the two-state buffer model, the render-cache rules, link resolution, image artwork or preview/zoom implementation.

Moving the prose SHALL preserve it; `docs/design.md` SHALL contain the sections that the README linked to before the move.

#### Scenario: A reader wants the design rationale

- **WHEN** a reader follows the architecture link in the README
- **THEN** `docs/design.md` opens
- **AND** it contains the engine/plugin boundary, the buffer states, the render cache and the preview/zoom design

#### Scenario: A design behaviour changes

- **WHEN** the render cache or preview/zoom design changes
- **THEN** the explanation is updated in `docs/design.md`
- **AND** the README has no duplicate paragraph to update

#### Scenario: The move is reviewed

- **WHEN** the README's former architecture sections are compared with `docs/design.md`
- **THEN** each section is present in the design document
- **AND** no explanation was dropped rather than moved

### Requirement: README paths and commands are portable

The README's directory tree SHALL use repository-relative paths and `md-render[.exe]`. It SHALL NOT contain an absolute path from a contributor's machine. Build, test, install and copy commands SHALL be given in POSIX-shell and PowerShell forms wherever the README instructs a reader to run them.

#### Scenario: A reader clones on Linux or macOS

- **WHEN** a reader runs the documented installation and build commands in a POSIX shell
- **THEN** they work as written

#### Scenario: A reader clones on Windows

- **WHEN** a reader runs the documented installation and build commands in PowerShell
- **THEN** they work as written
- **AND** the engine is referred to as `md-render.exe` where the extension matters

#### Scenario: The directory tree is read

- **WHEN** the README's directory tree is inspected
- **THEN** it starts from the repository root
- **AND** it contains no drive-letter or user-home absolute path

### Requirement: Repository metadata is complete

The repository SHALL have a canonical MIT `LICENSE` that GitHub recognizes, with the derivation notice kept in `NOTICE`. It SHALL have `CONTRIBUTING.md`, `SECURITY.md`, bug-report and feature-request issue templates, and a pull-request template.

#### Scenario: GitHub identifies the license

- **WHEN** the repository's license is read by GitHub
- **THEN** it is identified as MIT

#### Scenario: A contributor reports a bug

- **WHEN** a contributor opens a new issue
- **THEN** the bug template asks for the operating system, Neovim version, engine version and reproduction steps

#### Scenario: A vulnerability is reported

- **WHEN** someone needs to report a security problem
- **THEN** `SECURITY.md` explains how to report it privately rather than in a public issue

### Requirement: Local tool state stays out of the repository

The `openspec/` directory SHALL be tracked, because CI validates it. Local editor and agent state, including `.claude/`, SHALL be ignored, as build output (`target/`, `bin/`) and diagnostic notes (`issues/`) already are.

#### Scenario: OpenSpec validation finds the project

- **WHEN** the OpenSpec workflow runs on a clean checkout
- **THEN** `openspec/` is present
- **AND** `openspec validate --all` finds the project's specs and changes

#### Scenario: A contributor uses a local agent tool

- **WHEN** Claude Code or another tool writes files under `.claude/`
- **THEN** those files do not appear as changes to commit

#### Scenario: A local build is produced

- **WHEN** the engine is built into `target/` and copied into `bin/`
- **THEN** neither directory appears as a change to commit
