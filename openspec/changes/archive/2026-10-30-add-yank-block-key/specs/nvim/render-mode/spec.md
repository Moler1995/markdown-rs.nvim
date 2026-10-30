# Spec Delta

## ADDED Requirements

### Requirement: Copying a block's content

The plugin SHALL expose a copy key, configurable and defaulting to `gy`, available in both R and S. With the cursor in a copyable block, the key SHALL put that block's content in the unnamed register and in register `0`, SHALL leave the cursor where it is, and SHALL NOT spawn an engine process.

A fenced code block of any language, mermaid included, SHALL contribute the lines between its fences, without the opening and closing fence lines. A GFM table SHALL contribute its own source lines. An image reference SHALL contribute the `![...](...)` text as it is written in the source, characterwise. A linewise block SHALL be put in the registers linewise and an image reference characterwise, so that the register's type matches what was copied.

A paragraph, a heading, a list item, an indented code block and a fence indented past three spaces SHALL NOT be copyable blocks. With the cursor in none of the copyable blocks, the key SHALL perform its ordinary editor action and SHALL leave both registers unchanged.

#### Scenario: A code fence in R

- **WHEN** the cursor is on any display row of a ```rust fence and the key is pressed in R
- **THEN** register `0` holds the fence's body lines, without the ```rust line and the closing ``` line
- **AND** the unnamed register holds the same text
- **AND** the cursor has not moved

#### Scenario: A code fence in S

- **WHEN** the cursor is on any source row of the same fence and the key is pressed in S
- **THEN** register `0` holds the same body lines

#### Scenario: A mermaid fence

- **WHEN** the cursor is on a ```mermaid fence
- **THEN** register `0` holds the diagram's definition, without its fences

#### Scenario: A table

- **WHEN** the cursor is on any row of a GFM table
- **THEN** register `0` holds the table's source lines, pipes included

#### Scenario: An image reference

- **WHEN** the cursor is on an image's artwork or alt text in R, or on the reference itself in S
- **THEN** register `0` holds the `![...](...)` source text
- **AND** the register is characterwise

#### Scenario: A block that is not copyable

- **WHEN** the cursor is in a paragraph, a heading or a list item
- **THEN** both registers are unchanged
- **AND** the key performs its ordinary editor action

#### Scenario: Copying costs no render

- **WHEN** the key is pressed on a copyable block
- **THEN** no engine process is started

#### Scenario: The key is not bound

- **WHEN** `keymaps.yank_block` is `false`
- **THEN** neither R nor S maps `gy`
