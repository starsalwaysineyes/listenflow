import Foundation
let input = """
## Title

**Bold** and *italic* `code` [link](https://example.com).

1. First
   - Nested
2. Second

> Quote

| Name | Value |
| :--- | ---: |
| A | **10** |

```swift
let a = 1
print(a)
```

---
"""
let value = try AttributedString(markdown: input, options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
for run in value.runs {
 print(String(value[run.range].characters).debugDescription)
 print(String(describing: run.presentationIntent))
 print(String(describing: run.inlinePresentationIntent))
}
