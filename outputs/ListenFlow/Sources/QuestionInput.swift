import SwiftUI
import AppKit

/// Native text input lets both the Edit menu and Command-V follow the responder chain.
struct QuestionInput: NSViewRepresentable {
    @Binding var text: String
    var onPaste: (NSPasteboard) -> Bool
    var onSubmit: () -> Void
    /// Incremented by the ⌘K menu command; each new value pulls focus here.
    var focusToken: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let input = ImagePasteTextView(frame: .zero)
        input.isRichText = false
        input.importsGraphics = false
        input.allowsUndo = true
        input.drawsBackground = false
        input.font = .systemFont(ofSize: 13)
        input.textColor = .labelColor
        input.insertionPointColor = .systemTeal
        input.textContainerInset = NSSize(width: 0, height: 3)
        input.textContainer?.lineFragmentPadding = 0
        input.isHorizontallyResizable = false
        input.isVerticallyResizable = true
        input.autoresizingMask = [.width]
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.textContainer?.widthTracksTextView = true
        input.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        input.setAccessibilityLabel("针对已有内容或图片提问")
        input.delegate = context.coordinator
        input.imagePaste = onPaste
        input.string = text
        scroll.documentView = input
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let input = scroll.documentView as? ImagePasteTextView else { return }
        input.imagePaste = onPaste
        // Preserve selection and Chinese input composition during unrelated model updates.
        if input.string != text, !input.hasMarkedText() {
            input.string = text
            input.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            input.undoManager?.removeAllActions()
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            // The window may still be ordering front, so defer one runloop turn.
            DispatchQueue.main.async {
                input.window?.makeFirstResponder(input)
            }
        }
        input.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let size = ((text.isEmpty ? " " : text + " ") as NSString).boundingRect(
            with: NSSize(width: max(1, width - 16), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 13)])
        return CGSize(width: width, height: min(96, max(38, ceil(size.height) + 8)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: QuestionInput
        var lastFocusToken = 0
        init(_ parent: QuestionInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let input = notification.object as? NSTextView else { return }
            parent.text = input.string
            input.needsDisplay = true
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText(),
                  !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) else { return false }
            parent.onSubmit()
            return true
        }
    }
}

final class ImagePasteTextView: NSTextView {
    var imagePaste: ((NSPasteboard) -> Bool)?

    override func paste(_ sender: Any?) {
        if imagePaste?(NSPasteboard.general) == true { return }
        super.pasteAsPlainText(sender)
    }
    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if [#selector(paste(_:)), #selector(pasteAsPlainText(_:)), #selector(pasteAsRichText(_:))].contains(item.action),
           isEditable, ClipboardImages.containsImage(in: .general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            ("提问，或 ⌘V 粘贴图片…" as NSString).draw(at: NSPoint(x: 0, y: 3), withAttributes: [
                .font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor
            ])
        }
    }
}
