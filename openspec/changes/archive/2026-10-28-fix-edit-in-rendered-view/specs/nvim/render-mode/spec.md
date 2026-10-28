# Spec Delta

## ADDED Requirements

### Requirement: Reloading the document from R

An `:edit` issued while a window is in R SHALL reload the document's source from disk, the way
`:edit` reloads the file of any other buffer, and SHALL show the reloaded document in R. The window
SHALL remain in R with the same window, state and rendered buffer it had; reloading SHALL NOT close
a window, discard a rendered buffer that is still on screen, or leave the source buffer unloaded.

With unsaved changes in the source, `:edit` without a bang SHALL refuse with `E37` and leave both
views as they were; `:edit!` SHALL discard the unsaved changes and reload. A reload that fails —
the file cannot be read — SHALL report the failure and leave R showing what it showed rather than
an emptied buffer.

#### Scenario: Picking up a change made outside the editor

- **WHEN** the file is changed on disk while the window is in R and the user issues `:edit`
- **THEN** the source buffer holds the file's new contents
- **AND** R shows the new contents, still in R, in the same window

#### Scenario: Unsaved source changes

- **WHEN** the source has unsaved changes and the user issues `:edit` in R
- **THEN** the reload is refused with `E37`
- **AND** the source keeps its unsaved changes
- **AND** R still shows the document it showed

#### Scenario: Reloading over unsaved changes

- **WHEN** the source has unsaved changes and the user issues `:edit!` in R
- **THEN** the source holds the file's contents
- **AND** R shows them

#### Scenario: Reloading in a split

- **WHEN** R is shown in one of two windows and the user issues `:edit` in it
- **THEN** the window still exists and still shows R
- **AND** the other window is untouched
- **AND** no rendered buffer is attached as a document

### Requirement: A rendered buffer is not a document

The buffer shown in R SHALL never be treated as a document, whatever its filetype or name says. A
filetype event raised for a rendered buffer SHALL NOT attach a window to it, start a rendering pass
for it, or change any window's state.

#### Scenario: Filetype event on the rendered buffer

- **WHEN** a filetype event is raised for a rendered buffer, as a read of that buffer does when its
  name ends in a markdown extension
- **THEN** no window is attached to it
- **AND** no rendering pass is started for it
- **AND** the window showing it stays in R
