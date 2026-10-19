| Name | Type | Default | Description |
|------|:----:|--------:|-------------|
| `width` | integer | 80 | The column width to lay the document out for. |
| `theme` | string | `default` | The colour theme to render with. |
| `path` | string | — | The markdown file to read; standard input when omitted. |

A table whose columns cannot all fit at their natural width:

| Identifier | Summary |
|---|---|
| alpha | A description that is comfortably longer than the column can hold at the corpus width, so the cell has to wrap. |
| beta | Short. |

A minimal table:

| a | b |
|---|---|
| 1 | 2 |
