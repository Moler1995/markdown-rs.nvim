# Spec Delta

## ADDED Requirements

### Requirement: Following a link

The plugin SHALL expose a follow key, configurable and defaulting to `gf`, available in both R and S. With the cursor on a link, the key SHALL open its destination: a URL SHALL be handed to the operating system's URL handler, an anchor SHALL jump to the heading it names, and a local file SHALL open in the window.

A relative destination SHALL resolve against the directory of the document holding the reference. An absolute destination SHALL be used as given, whether it is written as a POSIX path beginning with `/`, a drive-letter path such as `C:/docs/a.md` or `C:\docs\a.md`, or a UNC path beginning with `\\`. A local destination that does not exist SHALL be reported, and no buffer SHALL be opened. With no link under the cursor, the key SHALL perform its ordinary editor action.

#### Scenario: A relative link

- **WHEN** the link target is `docs/guide.md` and the document is `/work/readme.md`
- **THEN** `/work/docs/guide.md` is opened

#### Scenario: An absolute POSIX path

- **WHEN** the link target is `/work/guide.md`
- **THEN** `/work/guide.md` is opened
- **AND** the document's directory is not prepended

#### Scenario: An absolute Windows drive path

- **WHEN** the link target is `C:/work/guide.md` or `C:\work\guide.md`
- **THEN** `C:/work/guide.md` is opened
- **AND** the document's directory is not prepended

#### Scenario: An absolute UNC path

- **WHEN** the link target is `\\server\share\guide.md`
- **THEN** that share path is opened
- **AND** the document's directory is not prepended

#### Scenario: A URL

- **WHEN** the link target is an `http` or `https` URL
- **THEN** the URL is handed to the operating system's URL handler
- **AND** no local path is resolved

#### Scenario: An anchor

- **WHEN** the link target is `#installation`
- **THEN** the cursor moves to the heading whose slug is `installation`

#### Scenario: A missing local file

- **WHEN** the resolved local path does not exist
- **THEN** no buffer is opened
- **AND** the plugin reports that the file does not exist

#### Scenario: No link under the cursor

- **WHEN** the cursor is on text that is not a link
- **THEN** the key performs its ordinary editor action

### Requirement: Setup and loading reach the buffer already on screen

The plugin SHALL work when sourced from `runtimepath` without calling `setup()`. `setup(opts)` SHALL apply the options and SHALL be idempotent: repeated calls SHALL NOT create duplicate autocmds, commands or keymaps.

When the plugin is sourced, or when `setup()` runs, while the current window shows a managed buffer, that buffer SHALL be attached without the user reopening the file, and the window SHALL enter R as the "State on open" requirement describes. When the plugin is loaded lazily after the `FileType` event, the buffer that triggered the load SHALL be attached the same way.

Attaching SHALL use the same checks as the `FileType` path: the buffer and window SHALL still be valid, the window SHALL still show that buffer, and a window already attached to that source SHALL not be attached a second time.

#### Scenario: The plugin is sourced with a markdown buffer on screen

- **WHEN** the plugin is added to `runtimepath` and sourced while the current window shows a markdown buffer
- **THEN** that buffer is attached without reopening the file
- **AND** the window shows R once rendering completes

#### Scenario: Setup runs with a markdown buffer on screen

- **WHEN** `require('md-render').setup{}` runs while the current window shows a markdown buffer
- **THEN** that buffer is attached
- **AND** the window shows R once rendering completes

#### Scenario: A plugin manager loads the plugin on FileType

- **WHEN** the plugin is loaded after the `FileType` event for a markdown buffer
- **THEN** the buffer that triggered the load is attached
- **AND** the first markdown file shows R without being reopened

#### Scenario: Setup is called twice

- **WHEN** `setup{}` is called twice with different options
- **THEN** no autocmd, command or buffer-local keymap is duplicated
- **AND** subsequent renders use the second set of options

#### Scenario: Setup runs before filetype detection

- **WHEN** `setup{}` runs while the current buffer has no managed filetype
- **THEN** no buffer is attached at that moment
- **AND** the later `FileType` event attaches the buffer normally
