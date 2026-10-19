A flowchart:

```mermaid
graph LR
    A[Start] --> B{Choice}
    B -->|yes| C[Do the thing]
    B -->|no| D[Do the other thing]
    C --> E[Done]
    D --> E
```

A sequence diagram:

```mermaid
sequenceDiagram
    participant C as Client
    participant S as Server
    C->>S: request
    S-->>C: response
```

A state diagram:

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Running: start
    Running --> Idle: stop
    Running --> [*]: crash
```

A diagram whose natural layout is wider than the corpus width. The layout
backend treats the width as a hint, not a clamp, so this one comes back 119
columns wide at any budget and must fall back to its source rather than being
word-wrapped into confetti:

```mermaid
graph LR
    A_Very_Long_Node_Identifier --> B_Another_Long_Node_Identifier --> C_And_A_Third_One --> D_And_A_Fourth
```

A fence that is not a diagram at all, which must fall back to its source:

```mermaid
this is not a diagram
```
