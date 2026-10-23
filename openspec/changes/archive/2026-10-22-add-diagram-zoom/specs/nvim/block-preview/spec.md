# Spec Delta

## MODIFIED Requirements

### Requirement: The popup lays the block out against a budget of its own

The popup SHALL lay the block out against a column budget of its own, chosen per kind, and the
budget SHALL be no smaller than the window's, so that the popup never holds less of the block than
the window did.

For a diagram the budget SHALL begin at the largest the engine accepts, because the engine may
discard the columns of a diagram that do not fit, and discarded columns cannot be recovered by
scrolling. The budget SHALL remain at that value until the reader zooms it down, as the zoom
requirement describes.
For a table the budget SHALL be the popup's own inner width, floored at the window's, because the
engine wraps a cell that does not fit rather than discarding it. A table's budget SHALL NOT be
changed by zooming.

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

## ADDED Requirements

### Requirement: Zooming a diagram

While a diagram's popup is open, the zoom keys SHALL re-lay the diagram out at a different column
budget. Zooming out SHALL ask for the popup's own inner width, so that the whole diagram is on
screen at once; zooming in SHALL ask for the engine's largest budget, restoring the layout the
popup opened with. Both keys SHALL be configurable and SHALL default to `+` and `-`.

A reader SHALL never be shown a diagram with columns discarded. Zooming out SHALL lay the diagram
out whole: at the popup's inner width where the engine can, and otherwise at the narrowest budget
at which the engine lays it out whole, so that a diagram whose narrowest whole layout is still
wider than the popup is nonetheless shown narrower than it opened. Where the diagram is already
laid out at its narrowest whole budget, or already fits the popup's inner width, zooming out SHALL
leave it as it was.

Zooming SHALL apply to diagrams only. In a table's popup the zoom keys SHALL be bound and SHALL do
nothing. Zooming SHALL change the popup's content and SHALL NOT change the popup's window.

The popup SHALL make its zoom state visible, so that a diagram laid out at a reduced budget is
distinguishable from one that is simply that wide.

#### Scenario: Zooming out a diagram too wide for the popup

- **WHEN** the popup shows a diagram wider than its inner width, the engine can lay that diagram out
  whole within the popup's inner width, and the user zooms out
- **THEN** the diagram is laid out within the popup's inner width
- **AND** the whole diagram is reachable without scrolling sideways
- **AND** no participant, node, label or note that the previous layout held is missing

#### Scenario: Zooming out a diagram whose narrowest whole layout exceeds the popup

- **WHEN** the engine cannot lay the diagram out whole within the popup's inner width, but can lay
  it out whole at a budget narrower than the one in force, and the user zooms out
- **THEN** the diagram is laid out at that narrowest whole budget
- **AND** no column of the diagram is lost
- **AND** the diagram is narrower than it was before the zoom

#### Scenario: Zooming out a diagram already at its narrowest

- **WHEN** the diagram is already laid out at the narrowest budget at which the engine lays it out
  whole and the user zooms out
- **THEN** the popup's content is unchanged
- **AND** no column of the diagram is lost

#### Scenario: Zooming out a diagram that already fits the popup

- **WHEN** the popup shows a diagram no wider than its inner width and the user zooms out
- **THEN** the popup's content is unchanged

#### Scenario: Zooming back in

- **WHEN** the user zooms out and then zooms in
- **THEN** the diagram is laid out at the engine's largest budget again
- **AND** its content is what the popup showed when it opened

#### Scenario: The window does not move

- **WHEN** the user zooms a diagram
- **THEN** the popup's window keeps its size and position
- **AND** only its content changes

#### Scenario: A table's popup

- **WHEN** the popup shows a table and the user presses either zoom key
- **THEN** the table's content is unchanged
- **AND** the popup stays open

#### Scenario: Configured zoom keys

- **WHEN** the user sets the zoom keys to other mappings and presses them in a diagram's popup
- **THEN** the diagram is re-laid out, and the default keys no longer zoom

#### Scenario: The zoom state is visible

- **WHEN** a diagram is laid out at a reduced budget
- **THEN** the popup identifies itself as zoomed
- **AND** a reader can tell the diagram's current width from its width when unzoomed

### Requirement: Scrolling the popup sideways

The popup SHALL bind one key that scrolls its content left and one that scrolls it right, each moving
the view by a fixed number of display columns per press, so that either key can be held down to
scroll continuously. Both keys SHALL be configurable and SHALL default to `<C-h>` and `<C-l>`.

The step SHALL be the horizontal step of the reader's `'mousescroll'` option, so that the keys and a
horizontal wheel move the view by the same amount.

The keys SHALL be bound in every popup, for a table as well as a diagram: a table is laid out at a
budget floored at the window's, so it can be wider than the popup too, and its columns past the edge
are reached the same way.

Scrolling SHALL move the view, SHALL NOT change the popup's content, and SHALL NOT reach the engine.

#### Scenario: Scrolling a block wider than the popup

- **WHEN** the popup holds a block wider than its own inner width and the user presses the
  scroll-right key
- **THEN** the view moves right by the horizontal step of `'mousescroll'`
- **AND** the popup's content is unchanged
- **AND** no engine is spawned

#### Scenario: Repeated presses

- **WHEN** the user presses the scroll-right key twice
- **THEN** the view has moved twice the step

#### Scenario: The left edge

- **WHEN** the view is at the left edge and the user presses the scroll-left key
- **THEN** the view stays at the left edge

#### Scenario: A table's popup

- **WHEN** the popup shows a table wider than the popup's inner width and the user presses a scroll
  key
- **THEN** the view moves

#### Scenario: Configured scroll keys

- **WHEN** the user sets the scroll keys to other mappings and presses them
- **THEN** those keys scroll the popup
- **AND** the default keys no longer scroll it
