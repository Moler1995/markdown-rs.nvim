# Wide

A table whose natural width is wider than a narrow window's column budget, so
that the engine has to lay it out to fit and the preview has something to
recover.

| the first column | the second column | the third column | the fourth column |
| ---------------- | ----------------- | ---------------- | ----------------- |
| alpha            | bravo             | charlie          | delta             |

A diagram wider than the same window, for the same reason.

```mermaid
graph LR
  A[alpha] --> B[bravo]
  B --> C[charlie]
  C --> D[delta]
  D --> E[echo]
```

## Tail

The tail is here so that the document is taller than a window, and so that the
preview's "the view underneath is untouched" check has somewhere to scroll to.

- tail item 1
- tail item 2
- tail item 3
- tail item 4
- tail item 5
- tail item 6
- tail item 7
- tail item 8
- tail item 9
- tail item 10

Another paragraph, long enough to push the document past the height of a short
window, and saying nothing in particular.
