# Spec Delta

## Purpose

Gives a markdown buffer two stable states — a rendered reading view and the raw editable source —
with explicit, reversible movement between them, so that reading and editing each get the editor
behaviour they need instead of compromising on one.

## ADDED Requirements

### Requirement: State on open

Opening a markdown file SHALL show the rendered state (R). Files that are not markdown SHALL be
unaffected: no rendered state exists for them and no rendering is attempted.

#### Scenario: Opening a markdown file

- **WHEN** the user opens a `.md` file
- **THEN** the window shows rendered content rather than raw markdown

#### Scenario: Opening a non-markdown file

- **WHEN** the user opens a file whose type is not markdown
- **THEN** the window shows the file normally
- **AND** no rendering process is started

#### Scenario: Rendered content is not yet available

- **WHEN** a markdown file is opened and rendering has not completed
- **THEN** the window continues to show the source
- **AND** the window shows the rendered content once rendering completes

### Requirement: Rendered state

R SHALL display the engine's output in a read-only buffer shown in the same window. The displayed
content SHALL be ordinary buffer content, so scrolling, searching and yanking operate on it with
the editor's normal mechanisms. Modification SHALL be refused.

#### Scenario: Scroll and search

- **WHEN** the user scrolls or searches while in R
- **THEN** the movement and the search operate on the displayed rendered content
- **AND** line-addressed motions such as `gg` and `G` resolve within the rendered content

#### Scenario: Modification is refused

- **WHEN** an editing command is issued while in R
- **THEN** the document is not modified
- **AND** the buffer contents are unchanged

#### Scenario: Rendered state does not outlive its window

- **WHEN** the window stops showing the rendered content
- **THEN** the rendered buffer is discarded rather than left in the buffer list

### Requirement: Source state

S SHALL display the document's source buffer in the same window, unmodified and fully editable,
with the editor's complete normal-mode vocabulary available — including undo, operators,
substitutions, and whatever language tooling attaches to the buffer.

#### Scenario: Editing in S

- **WHEN** the user edits while in S
- **THEN** the source buffer is modified as usual
- **AND** undo, operators and substitutions behave as they do for any other buffer

#### Scenario: Returning to a position

- **WHEN** the user leaves S for R and later returns to S
- **THEN** the window's cursor and scroll position in the source are restored

### Requirement: Crossing from R into S

The insert-entry keys `i`, `a`, `I`, `A`, `o` and `O` SHALL switch from R to S, place the cursor at
the source line corresponding to the display line the cursor was on, and enter the corresponding
insert mode. A toggle mapping SHALL also switch from R to S while remaining in normal mode, so that
normal-mode editing commands can be reached without passing through insert mode.

#### Scenario: Insert from a rendered paragraph

- **WHEN** the user presses `i` with the cursor on a display line derived from source line N
- **THEN** the window shows the source
- **AND** the cursor is on source line N
- **AND** the editor is in insert mode

#### Scenario: Open a new line

- **WHEN** the user presses `o` with the cursor on a display line derived from source line N
- **THEN** the window shows the source with the cursor on source line N
- **AND** a new line is opened below it in insert mode, as `o` does in any buffer

#### Scenario: Reach normal mode directly

- **WHEN** the user presses the toggle mapping while in R
- **THEN** the window shows the source
- **AND** the editor remains in normal mode

#### Scenario: Cursor on a synthetic display line

- **WHEN** the cursor is on a display line marked synthetic — a table border or diagram artwork
- **THEN** the cursor is placed on the source line of the construct that produced it

### Requirement: Returning to R

The toggle mapping SHALL switch from S to R. Leaving insert mode SHALL NOT change state: after
`Esc`, the editor SHALL remain in S until the user asks for R.

#### Scenario: Toggle back

- **WHEN** the user presses the toggle mapping while in S
- **THEN** the window shows the rendered content

#### Scenario: Leaving insert mode does not toggle

- **WHEN** the user presses `Esc` in insert mode while in S
- **THEN** the editor is in normal mode
- **AND** the window still shows the source
- **AND** normal-mode editing commands still apply to the source buffer

### Requirement: Writing while rendered

A write issued while in R SHALL write the source buffer. Rendered content SHALL never be written to
the document's file.

#### Scenario: Write with no pending edits

- **WHEN** the user issues a write while in R and the source has not been modified
- **THEN** the file on disk is unchanged

#### Scenario: Write after editing in S

- **WHEN** the user edits in S and then issues a write while in R
- **THEN** the edit is written to the document's file
- **AND** the rendered content is not written to the file

### Requirement: Freshness

R SHALL reflect the source buffer's current contents rather than the file on disk, so unsaved edits
are rendered. R SHALL be refreshed when the window's width changes or when the source buffer
changes. Re-entering R when neither has happened SHALL reuse the previous rendering rather than
rendering again.

#### Scenario: Unsaved edits

- **WHEN** the user edits in S without writing and then returns to R
- **THEN** the rendered content reflects the edit

#### Scenario: Window width changes

- **WHEN** the window is resized while in R
- **THEN** the rendered content is produced again at the new width

#### Scenario: Toggling without an edit

- **WHEN** the user toggles from R to S and back without editing
- **THEN** the previously rendered content is shown without a new rendering pass

### Requirement: Rendering failure

When rendering cannot be performed — the engine is unavailable, exits non-zero, or returns
unusable output — the editor SHALL remain in S and SHALL report the failure, rather than showing an
empty or partial rendered state.

#### Scenario: Engine unavailable

- **WHEN** the user opens a markdown file and the render engine cannot be executed
- **THEN** the window shows the source
- **AND** a diagnostic is reported

#### Scenario: Engine returns an error

- **WHEN** the engine exits non-zero for a document
- **THEN** the editor does not enter R for that document
- **AND** the diagnostic the engine produced is reported

### Requirement: State is per window

Each window SHALL carry its own state independently, so two windows on the same document may show
different states without interfering.

#### Scenario: Same document in two windows

- **WHEN** the same document is open in two windows and one is switched to S
- **THEN** the other window's state is unchanged
