# Spec Delta

## Purpose

Lets a reader see a block whole. A diagram or a table is laid out against the window's column
budget and clipped to it, so a block wider than the window cannot be read however far it is
scrolled; the preview re-renders that one block against a larger budget and shows it in a popup.

## ADDED Requirements

### Requirement: Opening the preview

While R is showing, the preview key SHALL open a popup for the block under the cursor when that
block is a `mermaid` fence or a table. The key SHALL be configurable and SHALL default to `<CR>`.

#### Scenario: Cursor on a diagram

- **WHEN** the cursor is anywhere within a `mermaid` fence's rendered artwork and the user presses the preview key
- **THEN** a popup opens showing that diagram

#### Scenario: Cursor on a table

- **WHEN** the cursor is on any row of a table and the user presses the preview key
- **THEN** a popup opens showing that table

#### Scenario: Cursor on a table border

- **WHEN** the cursor is on a table's border row, which carries no source line of its own
- **THEN** a popup opens showing the table that drew that border

#### Scenario: Configured key

- **WHEN** the user sets the preview key to another mapping and presses that mapping in R
- **THEN** the popup opens, and the default key no longer opens it

### Requirement: The preview key is not stolen

Where no preview is available the preview key SHALL perform its ordinary editor action rather than
doing nothing.

#### Scenario: Cursor on prose

- **WHEN** the cursor is on prose and the user presses the preview key
- **THEN** no popup opens
- **AND** the cursor moves to the first non-blank of the next line, as that key does in any buffer

#### Scenario: Cursor on a non-diagram code fence

- **WHEN** the cursor is on a fenced block that is not a diagram and the user presses the preview key
- **THEN** no popup opens
- **AND** the key's ordinary editor action is performed

### Requirement: Availability

The preview key SHALL be available in R only. It SHALL NOT be bound in S, where the block's source
is already on screen and editable.

#### Scenario: Pressed in S

- **WHEN** the window is showing S and the user presses the preview key
- **THEN** nothing preview-related happens

#### Scenario: Not a markdown buffer

- **WHEN** the buffer is not one the plugin manages
- **THEN** the preview key is not bound and the key behaves normally

### Requirement: The popup lays the block out against a budget of its own

The popup SHALL lay the block out against a column budget of its own, chosen per kind, and the
budget SHALL be no smaller than the window's, so that the popup never holds less of the block than
the window did.

For a diagram the budget SHALL be the largest the engine accepts, because the engine discards the
columns of a diagram that do not fit, and discarded columns cannot be recovered by scrolling.
For a table the budget SHALL be the popup's own inner width, floored at the window's, because the
engine wraps a cell that does not fit rather than discarding it.

Where the popup's budget is larger than the window's, the popup SHALL hold columns that the window's
rendering clipped.

#### Scenario: A window narrower than the cap

- **WHEN** the window is narrower than the preview cap and the block is wider than the window's budget
- **THEN** the popup lays the block out against a budget larger than the window's
- **AND** columns that the window's rendering clipped are present

#### Scenario: A diagram wider than the popup

- **WHEN** a diagram is wider than the popup's own inner width and the popup opens for it
- **THEN** the popup's content is laid out at the engine's largest budget
- **AND** the popup holds the diagram's columns beyond its own inner width, reachable by scrolling

#### Scenario: A window as wide as the cap

- **WHEN** the window is as wide as the preview cap, so a table's budget cannot exceed the window's
- **THEN** the popup's content holds no less of the block than the window showed
- **AND** the part of the block wider than the popup is reachable by scrolling within it

#### Scenario: A table wider than the window

- **WHEN** a table is wider than the window's column budget and the popup opens for it
- **THEN** the popup shows the table's rows and columns laid out against the popup's inner width

#### Scenario: A block that fits the window

- **WHEN** the block is no wider than the window's column budget and the popup opens for it
- **THEN** the popup shows the block whole

### Requirement: A preview is repeatable

Previewing the same unchanged block twice SHALL show the same arrangement. Where the popup differs
from the window, the difference SHALL be attributable to the popup's width budget and not to the
render being a separate run.

#### Scenario: The same block previewed twice

- **WHEN** the user opens the preview for a block, closes it, and opens it again with the block unchanged
- **THEN** the popup shows the same content both times

#### Scenario: A diagram with subgraphs

- **WHEN** the block is a diagram containing subgraphs, including a composite state in a state diagram
- **THEN** the popup's arrangement is stable across runs
- **AND** any difference from the window's rendering is explained by the popup's width, not by the run

### Requirement: The popup is a reading surface

The popup's content SHALL be ordinary buffer content, so that the editor's own scrolling, searching
and yanking operate on it. Modification SHALL be refused, and the popup SHALL NOT be a listed
buffer.

#### Scenario: Scrolling a block larger than the popup

- **WHEN** the block is taller or wider than the popup
- **THEN** the popup's content can be scrolled to reach the rest of it
- **AND** no line is soft-wrapped, so a row of artwork stays on one row

#### Scenario: Modification is refused

- **WHEN** an editing command is issued while the popup has focus
- **THEN** the block's content is unchanged
- **AND** the source buffer is unchanged

### Requirement: The popup is not adopted as a window of R

A floating window SHALL NOT be treated as a split of R. The plugin's rule that a window appearing
with R's rendered buffer is a split of R and is given a rendered buffer of its own SHALL exclude
floating windows, because `nvim_open_win` fires `WinEnter` for a new float before swapping its own
buffer in, so at that moment the float still holds the buffer it was opened over. The rule is
general rather than preview-specific: any float opened over R is excluded.

#### Scenario: The preview's popup over R

- **WHEN** the preview key opens the popup while R is showing
- **THEN** the popup shows the block's rendering
- **AND** the plugin holds no window state for the popup
- **AND** closing the popup leaves the window underneath in R

#### Scenario: A float opened over R by anything else

- **WHEN** a floating window is opened over R showing a buffer of its own
- **THEN** the float still shows that buffer
- **AND** the plugin holds no window state for it
- **AND** the window showing R is unchanged

### Requirement: Popup geometry

The popup SHALL be centred and SHALL be sized to fit its content, capped at a configurable fraction
of the editor's columns and lines. The cap SHALL default to 90% in each dimension.

#### Scenario: A small block

- **WHEN** the block is smaller than the cap
- **THEN** the popup is no larger than the block needs
- **AND** it is centred in the editor

#### Scenario: A block larger than the cap

- **WHEN** the block is larger than the cap in either dimension
- **THEN** the popup is capped in that dimension
- **AND** the rest of the block is reachable by scrolling

### Requirement: Closing the preview

The preview key, `q` and `Esc` SHALL close the popup. Closing SHALL leave the window underneath
exactly as it was — same buffer, same cursor position, same scroll position — so that opening and
closing a preview is not observable in the document view.

#### Scenario: The same key closes it

- **WHEN** the popup is open and the user presses the preview key
- **THEN** the popup closes

#### Scenario: `q` or `Esc` closes it

- **WHEN** the popup is open and the user presses `q` or `Esc`
- **THEN** the popup closes

#### Scenario: The view underneath is untouched

- **WHEN** the user opens a preview and then closes it
- **THEN** the window shows the same buffer it showed before
- **AND** the cursor is on the same line
- **AND** the window is scrolled to the same position
- **AND** the window is still in R

#### Scenario: The popup does not outlive its window

- **WHEN** the popup is closed, by any route
- **THEN** its buffer is discarded rather than left in the buffer list

### Requirement: Preview failure

When the block cannot be rendered, the popup SHALL NOT open empty or partial, and the failure SHALL
be reported.

#### Scenario: The engine cannot be executed

- **WHEN** the preview key is pressed and the render engine cannot be executed
- **THEN** no popup is opened
- **AND** a diagnostic is reported

#### Scenario: A diagram that the engine cannot draw

- **WHEN** the popup is opened for a `mermaid` fence whose source the engine cannot render as a diagram
- **THEN** the popup shows what the engine produced for that block, as R shows it inline
