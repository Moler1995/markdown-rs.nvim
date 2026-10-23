# Spec Delta

## Purpose

How the plugin finds the `md-render` executable, verifies that the wire format it receives is one it understands, and reports the result through `:checkhealth md-render` instead of failing somewhere inside a render.

## ADDED Requirements

### Requirement: Engine resolution order

When the `engine` option is a non-empty path, the plugin SHALL use that path. If it does not name an executable file, the plugin SHALL report that the configured engine cannot be executed and SHALL NOT fall back to another location.

When the `engine` option is empty, the plugin SHALL resolve the engine from the first of these locations that names an executable file:

1. an executable named `md-render` on `PATH`;
2. `<plugin-root>/bin/md-render` or `<plugin-root>/bin/md-render.exe`;
3. `stdpath('data')/md-render/md-render` or `stdpath('data')/md-render/md-render.exe`.

The plugin root SHALL be derived from the path of the loaded plugin module, not from the current working directory. A candidate that exists but is not executable SHALL be skipped rather than attempted. When no candidate resolves, the plugin SHALL report a diagnostic that names every location it searched and at least one way to obtain an engine.

The repository's `bin/` SHALL be searched before the user data directory, so a locally built engine is not shadowed by an older downloaded one.

#### Scenario: The configured path wins

- **WHEN** the `engine` option names an executable and a different `md-render` is on `PATH`
- **THEN** the configured path is used

#### Scenario: The configured path is wrong

- **WHEN** the `engine` option names a path that is missing or not executable
- **THEN** the render fails with a diagnostic naming that path
- **AND** the plugin does not fall back to `PATH`, `bin/` or the data directory

#### Scenario: The engine is on PATH

- **WHEN** the `engine` option is empty and `md-render` is executable on `PATH`
- **THEN** the `PATH` executable is used

#### Scenario: A development build in the repository

- **WHEN** the engine is not on `PATH`, `<plugin-root>/bin/md-render` is executable, and a downloaded engine also exists in the data directory
- **THEN** the repository's `bin/` executable is used

#### Scenario: An installed plugin with no repository binary

- **WHEN** the plugin was installed by a package manager, its `bin/` is absent, and `stdpath('data')/md-render/md-render` is executable
- **THEN** the data-directory executable is used

#### Scenario: A file that cannot be executed

- **WHEN** an automatically searched candidate path exists but is not executable
- **THEN** the plugin skips it and continues to the next location

#### Scenario: No engine is found

- **WHEN** the `engine` option is empty and none of the searched locations resolves
- **THEN** the render fails
- **AND** the diagnostic names every searched location
- **AND** the diagnostic says how to build or download the engine

### Requirement: Wire format compatibility

The engine's JSON document SHALL carry an integer `version`. The plugin SHALL accept only the wire version it was built for, which is version 1. When `version` is missing or is a different value, the plugin SHALL refuse the document and SHALL NOT enter the rendered state.

The diagnostic SHALL name the version the engine produced, the version the plugin expects, and the two remedies: rebuild the engine from the plugin's checkout, or upgrade the plugin and engine together.

#### Scenario: A matching wire version

- **WHEN** the engine returns a document whose `version` is 1
- **THEN** the plugin accepts the document and renders it

#### Scenario: A newer wire version

- **WHEN** the engine returns `{"version":2,...}` or any other value greater than 1
- **THEN** the window remains in the source state
- **AND** the plugin reports that the engine's wire format is not the one it expects
- **AND** the report names both versions

#### Scenario: A missing wire version

- **WHEN** the engine returns a document with no `version` field
- **THEN** the window remains in the source state
- **AND** the plugin reports that the engine did not state a wire version

#### Scenario: The engine is older than the plugin

- **WHEN** the engine emits a wire version lower than the plugin expects
- **THEN** the plugin refuses the document
- **AND** the diagnostic offers the same rebuild-or-upgrade remedies

### Requirement: Health check reports the engine contract

`:checkhealth md-render` SHALL report:

- whether the running Neovim satisfies the plugin's minimum version;
- the resolved engine path, or that no engine was found;
- which resolution step produced that path, being the configured path, `PATH`, the repository's `bin/`, or the data directory;
- the engine's `--version` output, or that the engine could not be run;
- the wire version the engine emits and whether it matches the plugin's expected version;
- whether `'termguicolors'` is enabled and which image encoding `image_mode = 'auto'` therefore selects;
- the configured filetypes.

When a value is wrong or missing, the report SHALL include a remediation line. For a missing engine the remediation SHALL name the build command and the data-directory destination. For a mismatched wire version it SHALL say to rebuild or upgrade the engine.

The health check SHALL NOT render the document in the current buffer and SHALL NOT modify any buffer.

#### Scenario: A healthy installation

- **WHEN** the user runs `:checkhealth md-render` with a working engine
- **THEN** the report lists the resolved path, its resolution step, the engine version and the matching wire version
- **AND** every check is reported as healthy

#### Scenario: No engine

- **WHEN** the user runs `:checkhealth md-render` with no engine in any searched location
- **THEN** the report says no engine was found
- **AND** it lists the searched locations
- **AND** it gives the build command and the data-directory destination

#### Scenario: A wire mismatch

- **WHEN** the engine emits a wire version other than the expected one
- **THEN** the report names both versions
- **AND** it says to rebuild or upgrade the engine

#### Scenario: A terminal without truecolor

- **WHEN** `'termguicolors'` is disabled and `image_mode` is `auto`
- **THEN** the report says the ASCII encoding will be used
- **AND** it does not report that as an error

#### Scenario: The current buffer is untouched

- **WHEN** `:checkhealth md-render` runs while a markdown buffer is shown
- **THEN** that buffer's contents and window state are unchanged
- **AND** no render of that document is started
