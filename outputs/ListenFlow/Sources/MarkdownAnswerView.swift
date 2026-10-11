import SwiftUI
import AppKit

private let markdownAccent = Color(red: 0.05, green: 0.48, blue: 0.43)

struct MarkdownAnswerView: View, Equatable {
    let text: String
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(MarkdownDocument.parse(text)) { block in
                HStack(alignment: .top, spacing: 9) {
                    if block.quoteDepth > 0 {
                        RoundedRectangle(cornerRadius: 2).fill(markdownAccent.opacity(0.35)).frame(width: 3)
                    }
                    if let marker = block.listMarker {
                        Text(marker).font(.system(size: 13, weight: .medium)).foregroundStyle(markdownAccent)
                            .frame(minWidth: 16, alignment: .trailing).padding(.top, 1)
                    }
                    blockBody(block)
                }
                .padding(.leading, CGFloat(min(block.indentation, 8)) * 16)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            MarkdownDocument.allowedLink(url) ? .systemAction : .discarded
        })
    }

    @ViewBuilder private func blockBody(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            inline(block.content).font(.system(size: 13)).lineSpacing(4)
        case let .heading(level):
            inline(block.content).font(.system(size: level == 1 ? 20 : level == 2 ? 17 : 14, weight: .semibold))
                .padding(.top, 4).accessibilityAddTraits(.isHeader)
        case let .code(language):
            codeBlock(String(block.content.characters), language: language)
        case .rule:
            Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1)
                .frame(maxWidth: .infinity).padding(.vertical, 3)
        case .table:
            table(block)
        }
    }

    private func inline(_ input: AttributedString) -> some View {
        var value = input
        for run in Array(value.runs) {
            if run.inlinePresentationIntent?.contains(.code) == true {
                value[run.range].font = .system(size: 12, design: .monospaced)
                value[run.range].backgroundColor = Color.black.opacity(0.055)
            }
            if run.link != nil { value[run.range].foregroundColor = markdownAccent }
        }
        return Text(value).textSelection(.enabled)
    }

    private func codeBlock(_ source: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language! : "代码").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source, forType: .string)
                } label: { Label("复制代码", systemImage: "doc.on.doc").font(.system(size: 10)) }
                    .buttonStyle(.plain).help("复制代码，不包含 Markdown 围栏")
            }.padding(.horizontal, 11).padding(.vertical, 8)
            Divider()
            ScrollView(.horizontal) {
                Text(source.hasSuffix("\n") ? String(source.dropLast()) : source)
                    .font(.system(size: 12, design: .monospaced)).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true).padding(11)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.08)))
    }

    private func table(_ block: MarkdownBlock) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(block.tableRows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(block.columns.indices, id: \.self) { column in
                            inline(block.tableRows[row][column])
                                .font(.system(size: 12, weight: row == 0 ? .semibold : .regular))
                                .lineSpacing(3)
                                .frame(minWidth: 90, maxWidth: 230, alignment: alignment(block.columns[column].alignment))
                                .padding(.horizontal, 10).padding(.vertical, 9)
                                .frame(maxHeight: .infinity, alignment: .topLeading)
                                .background(row == 0 ? markdownAccent.opacity(0.08) : Color.white.opacity(0.7))
                                .overlay(Rectangle().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func alignment(_ value: PresentationIntent.TableColumn.Alignment) -> Alignment {
        switch value {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        @unknown default: return .leading
        }
    }
}
