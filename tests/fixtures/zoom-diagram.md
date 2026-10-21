# Zoom diagram

One diagram, wider than the preview popup's own inner width at a narrow
terminal, and narrow enough that the engine can lay it out whole inside that
width by wrapping its labels.

It is the other half of the pair with `wide-diagram.md`. That fixture's diagram
is also wider than the popup, but it cannot be laid out whole any narrower than
108 columns, so zooming it out lands on that floor rather than on the popup. This
one compacts to 69 at a 70-column budget (36 rows, against 40 for the narrower
64-column arrangement the old search stopped at), so zooming it out lands on the
popup itself and the diagram is reachable without scrolling sideways.

```mermaid
sequenceDiagram
  participant U as Client Application
  participant API as Gateway Router Service
  participant DB as Response Assembler
  U->>API: a long enough request label to need wrapping
  API->>DB: and a long enough response to need it too
  DB-->>API: rows
  API-->>U: 200 OK
```
