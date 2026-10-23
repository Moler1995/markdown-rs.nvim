# nvim/help Specification

## Purpose
The plugin's built-in documentation: a `:help md-render` entry that covers the commands, keymaps, options, engine setup and troubleshooting, with tags that are present on a fresh checkout and checks that keep the reference in step with the code.

## Requirements

### Requirement: The help entry opens from a fresh checkout

The repository SHALL contain `doc/md-render.txt` and a committed `doc/tags`. `:help md-render` SHALL open the help file. The tags SHALL make `:help md-render`, `:help :MdRenderToggle`, `:help :MdRenderShow`, `:help :MdRenderSource`, `:help :MdRenderReset`, `:help md-render.setup`, `:help md-render-options`, `:help md-render-commands` and `:help md-render-keymaps` resolve.

Regenerating the tags with `nvim --headless -u NONE -c 'helptags doc' -c q` SHALL leave `doc/tags` unchanged.

#### Scenario: The main help tag

- **WHEN** the user runs `:help md-render`
- **THEN** the plugin's help file opens

#### Scenario: A command tag

- **WHEN** the user runs `:help :MdRenderToggle`
- **THEN** the help entry for that command opens

#### Scenario: The option tag

- **WHEN** the user runs `:help md-render-options`
- **THEN** the option reference opens

#### Scenario: Tags are regenerated

- **WHEN** `helptags doc` runs on a fresh checkout
- **THEN** `doc/tags` is byte-identical to the tracked file

### Requirement: The help covers the public surface

The help file SHALL document:

- the supported Neovim version and the engine requirement;
- installation, including package-manager snippets and the engine resolution order with the data-directory location;
- `require('md-render').setup()` and every top-level option in `config.defaults`, with its type, default and meaning;
- every key in `keymaps`, its default, the state it applies to, and the meaning of `false`;
- the fixed insert-entry keys;
- every user command created by `plugin/md-render.lua`;
- links, block preview and zoom, images and animation;
- `:checkhealth md-render` and the diagnostics it reports;
- troubleshooting for a missing engine, a wire-version mismatch, a terminal without truecolor, and editing plugin Lua while Neovim is running.

The help SHALL NOT name a configuration key that the plugin does not read.

#### Scenario: Every command is documented

- **WHEN** the help file is searched for each command created by `plugin/md-render.lua`
- **THEN** every command has a help tag and a description

#### Scenario: Every option is documented

- **WHEN** the help file is searched for each top-level key in `config.defaults` and each key in `keymaps`
- **THEN** every key appears in the option or keymap section

#### Scenario: A retired key is not documented

- **WHEN** the help and README are searched for `g:md_render_binary`
- **THEN** no match is found

#### Scenario: A new option is added

- **WHEN** a top-level option is added to `config.defaults` without a help entry
- **THEN** the documentation check fails

### Requirement: The help stays in step with the code

The repository's plugin checks SHALL fail when a command created by `plugin/md-render.lua` has no help tag, when a top-level option or a `keymaps` key is absent from the help file, or when regenerating `doc/tags` changes the tracked file.

#### Scenario: A command without a tag

- **WHEN** a user command is added to `plugin/md-render.lua` and the help is not updated
- **THEN** the plugin checks fail

#### Scenario: Stale tags

- **WHEN** `doc/md-render.txt` changes and `doc/tags` is not regenerated
- **THEN** the plugin checks fail

#### Scenario: A new keymap

- **WHEN** a key is added to `config.defaults.keymaps` and the help is not updated
- **THEN** the plugin checks fail

### Requirement: The README is a landing page, not a second reference

The README SHALL give the short install path, the engine download or build step, a quick start, and links to `:help md-render`, `:checkhealth md-render` and `docs/design.md`. It SHALL NOT maintain a second complete option or keymap table that can disagree with the help file.

#### Scenario: A reader needs an option

- **WHEN** a reader wants the meaning of an option
- **THEN** the README points to `:help md-render-options`
- **AND** the option is documented there once

#### Scenario: A reader installs the plugin

- **WHEN** a reader follows the README's install section
- **THEN** it names a package-manager snippet or the runtimepath layout
- **AND** it names where the engine goes

#### Scenario: A reader wants the design

- **WHEN** a reader follows the README's architecture link
- **THEN** `docs/design.md` opens
- **AND** the README does not repeat the design explanation
