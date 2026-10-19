A fenced Rust block:

```rust
/// Doubles its argument.
fn double(x: u32) -> u32 {
    x * 2
}

fn main() {
    println!("{}", double(21));
}
```

A fenced Python block:

```python
def double(x: int) -> int:
    return x * 2

print(double(21))
```

A fenced shell block:

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "$(date) hello"
```

A block in a language the highlighter does not know:

```not-a-real-language
this line has no highlighting at all
but it must still be framed and padded
```

An indented block:

    indented code, no fence
    second line

An untagged fence:

```
plain text with no language
```
