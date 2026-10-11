import Foundation
@main struct MarkdownTests {
 static func main() throws {
  let fixture = """
  ## 标题

  **加粗**、*斜体*、~~删除~~、`inline` 与 [链接](https://example.com)。

  1. 第一项
     - 子项目
  2. 第二项

  > 引用 **重点**

  | 项目 | 数值 |
  | :--- | ---: |
  | ASR | **2.7 GB** |
  | 空值 | |

  ```swift
  let text = "**literal**"
  print(text)
  ```

  ---
  """
  let blocks = MarkdownDocument.parse(fixture)
  precondition(blocks.contains { if case .heading(2) = $0.kind { return true }; return false })
  precondition(blocks.contains { $0.listMarker == "1." })
  precondition(blocks.contains { $0.listMarker == "2." })
  precondition(blocks.contains { $0.listMarker == "•" && $0.indentation == 1 })
  precondition(blocks.contains { $0.quoteDepth == 1 })
  let code = blocks.first { if case .code = $0.kind { return true }; return false }!
  precondition(String(code.content.characters).contains("**literal**"))
  let table = blocks.first { if case .table = $0.kind { return true }; return false }!
  precondition(table.tableRows.count == 3 && table.tableRows[0].count == 2)
  precondition(String(table.tableRows[1][1].characters) == "2.7 GB")
  precondition(String(table.tableRows[2][1].characters).isEmpty)
  precondition(table.columns[1].alignment == .right)
  precondition(table.tableRows[1][1].runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
  precondition(blocks.contains { if case .rule = $0.kind { return true }; return false })
  let malicious = MarkdownDocument.parse("[unsafe](javascript:alert(1)) [file](file:///etc/passwd) [safe](https://example.com)")
  let links = malicious.flatMap { block in block.content.runs.compactMap { $0.link } }
  precondition(links.count == 1 && links[0].scheme == "https")
  let openFence = MarkdownDocument.parse("```python\nprint('still streaming')")
  precondition(openFence.contains { if case .code = $0.kind { return true }; return false })
  let characters = Array(fixture)
  for end in stride(from: 0, through: characters.count, by: 7) { _ = MarkdownDocument.parse(String(characters.prefix(end))) }
  let repeated = Array(repeating: fixture, count: 15).joined(separator: "\n\n")
  let began = Date()
  let long = MarkdownDocument.parse(repeated)
  precondition(long.count > blocks.count)
  print("PASS: headings, inline styles, ordered/nested lists, quotes, tables with empty cells/alignment, literal code, rules, safe links, partial streaming")
  print("Long response (\(repeated.count) characters) parsed in \(Int(Date().timeIntervalSince(began)*1000)) ms")
 }
}
