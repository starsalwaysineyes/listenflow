import Foundation

struct MarkdownBlock: Identifiable {
    enum Kind { case paragraph, heading(Int), code(String?), rule, table }
    let id: Int
    var kind: Kind = .paragraph
    var content = AttributedString()
    var listMarker: String?
    var indentation = 0
    var quoteDepth = 0
    var columns: [PresentationIntent.TableColumn] = []
    var tableRows: [[AttributedString]] = []
}

/// Foundation's Markdown parser supplies the full block tree and inline styles.
/// Parsing is local: HTML is never executed and remote media is never loaded.
enum MarkdownDocument {
    private final class Cached: NSObject {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }
    private static let cache: NSCache<NSString, Cached> = {
        let value = NSCache<NSString, Cached>()
        value.countLimit = 24
        value.totalCostLimit = 2_000_000
        return value
    }()
    private struct Leaf {
        let id: Int
        let components: [PresentationIntent.IntentType]
        var content: AttributedString
    }

    static func allowedLink(_ url: URL) -> Bool {
        ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let key = markdown as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let parsed = (try? AttributedString(markdown: markdown, options: .init(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(markdown)
        var leaves: [Leaf] = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let id = components.first?.identity ?? 0
            var fragment = AttributedString(parsed[run.range])
            fragment.presentationIntent = nil
            if let link = fragment.link, !allowedLink(link) { fragment.link = nil }
            if leaves.last?.id == id { leaves[leaves.count - 1].content.append(fragment) }
            else { leaves.append(Leaf(id: id, components: components, content: fragment)) }
        }
        var result: [MarkdownBlock] = []
        var seenListItems: Set<Int> = []
        var tablePositions: [Int: Int] = [:]
        for leaf in leaves {
            if let table = leaf.components.first(where: { if case .table = $0.kind { return true }; return false }),
               case let .table(columns) = table.kind {
                let position: Int
                if let existing = tablePositions[table.identity] { position = existing }
                else {
                    position = result.count
                    tablePositions[table.identity] = position
                    var block = MarkdownBlock(id: table.identity, kind: .table)
                    block.columns = columns
                    result.append(block)
                }
                var rowIndex = 0, columnIndex = 0
                for component in leaf.components {
                    if case let .tableRow(row) = component.kind { rowIndex = row }
                    if case let .tableCell(column) = component.kind { columnIndex = column }
                }
                guard columnIndex < columns.count, rowIndex < 10_000 else { continue }
                while result[position].tableRows.count <= rowIndex {
                    result[position].tableRows.append(Array(repeating: AttributedString(), count: columns.count))
                }
                result[position].tableRows[rowIndex][columnIndex].append(leaf.content)
                continue
            }
            var block = MarkdownBlock(id: leaf.id, content: leaf.content)
            for component in leaf.components {
                switch component.kind {
                case let .header(level): block.kind = .heading(level)
                case let .codeBlock(language): block.kind = .code(language)
                case .thematicBreak: block.kind = .rule
                case .blockQuote: block.quoteDepth += 1
                default: break
                }
            }
            let items = leaf.components.filter { if case .listItem = $0.kind { return true }; return false }
            block.indentation = max(0, items.count - 1)
            if let item = items.first, case let .listItem(ordinal) = item.kind {
                let nearestList = leaf.components.first { component in
                    if case .orderedList = component.kind { return true }
                    if case .unorderedList = component.kind { return true }
                    return false
                }
                if seenListItems.insert(item.identity).inserted {
                    if case .orderedList = nearestList?.kind { block.listMarker = "\(ordinal)." }
                    else { block.listMarker = "•" }
                } else { block.listMarker = "" } // Continuation paragraph aligned with its item.
            }
            result.append(block)
        }
        cache.setObject(Cached(result), forKey: key, cost: max(1, markdown.utf8.count * 4))
        return result
    }
}
