#!/bin/sh
# Generate the large markdown document the engine's timing numbers are taken
# against.
#
# The document is not committed: it is 342 KB of repeated prose, it would
# dominate the repository, and it carries no information the generator does
# not. What matters is that the *measurement* is reproducible, so the recipe
# lives here and the artifact is a build output.
#
# The shape is deliberate. A document of nothing but paragraphs would flatter
# the engine — prose is one parse and one wrap per line. The chapter below
# carries the constructs that actually cost something: a table (column fitting
# plus per-cell wrapping), a fenced block in a language syntect knows (a full
# highlight pass), a mermaid fence (a layout algorithm), and display math. One
# chapter is roughly 1.5 KB, so the default 225 chapters land near 340 KB.
#
# Usage: make-bench-doc.sh [chapters] > bench.md
set -eu

chapters=${1:-225}
i=1
while [ "$i" -le "$chapters" ]; do
	cat <<EOF
## Chapter $i — rendering cost

A paragraph of ordinary prose, long enough that the wrapper has to find its
own break points rather than taking a line as it comes. The engine measures
this text in display columns, not bytes, so a paragraph containing multi-byte
characters is measured the same way as one that is not.

### A table

| Column | Type | Default | Notes |
|--------|------|---------|-------|
| \`width\` | integer | 80 | The column budget the document is laid out against |
| \`theme\` | string | \`default\` | The colour theme to render with |
| \`path\` | string | — | The file to read; standard input when omitted |

### A code block

\`\`\`rust
/// Doubles its argument.
///
/// The doc comment is here so the highlighter has more than one token kind
/// to classify, which is the work being measured.
pub fn double(x: u32) -> u32 {
    let doubled = x * 2;
    debug_assert!(doubled >= x, "no overflow for the inputs we accept");
    doubled
}
\`\`\`

### A diagram

\`\`\`mermaid
graph LR
    A[Start] --> B{Choice}
    B -->|yes| C[Do the thing]
    B -->|no| D[Do the other thing]
    C --> E[Done]
    D --> E
\`\`\`

### A formula

The mass-energy relation is \$E = mc^2\$, and the divergence of the electric
field is given by

\$\$\nabla \cdot \vec{E} = \frac{\rho}{\epsilon_0}\$\$

A list follows, because list handling accumulates a counter per depth:

- the first item
- the second item
  - a nested item
  - another nested item
- the third item

> A block quote, which the renderer prefixes line by line.

EOF
	i=$((i + 1))
done
