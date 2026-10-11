import Foundation
import AppKit
import ImageIO

enum CaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

@main struct ClipboardTests {
    @MainActor static func main() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let input = URL(fileURLWithPath: "work/vision-test.png")
        let png = try Data(contentsOf: input)
        let tiff = NSImage(contentsOf: input)!.tiffRepresentation!
        let sessionID = UUID()
        defer { try? FileManager.default.removeItem(at: ImageAttachmentStore.folder(for: sessionID)) }

        board.setString("普通文字\n第二行", forType: .string)
        precondition(!ClipboardImages.containsImage(in: board))
        let textSources = try ClipboardImages.sources(from: board)
        precondition(textSources.isEmpty)

        board.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        item.setString("图片附带的文字", forType: .string)
        board.writeObjects([item])
        precondition(ClipboardImages.containsImage(in: board))
        let sources = try ClipboardImages.sources(from: board)
        precondition(sources.count == 1, "One picture with multiple representations must be imported once")
        let image = try ImageAttachmentStore.importImage(sources[0], sessionID: sessionID, number: 1)
        precondition(image.name == "粘贴图片" && image.width == 2560 && image.height == 1440)
        let normalized = CGImageSourceCreateWithURL(ImageAttachmentStore.url(for: image, sessionID: sessionID) as CFURL, nil)!
        precondition(CGImageSourceGetType(normalized)! as String == "public.jpeg")

        board.clearContents()
        board.setData(tiff, forType: .tiff)
        let tiffSources = try ClipboardImages.sources(from: board)
        precondition(tiffSources.count == 1)
        let second = try ImageAttachmentStore.importImage(tiffSources[0], sessionID: sessionID, number: 2)
        precondition(second.width == image.width && second.height == image.height)

        board.clearContents()
        let fileItem = NSPasteboardItem()
        fileItem.setString(input.absoluteString, forType: .fileURL)
        fileItem.setData(png, forType: .png) // Finder may advertise an icon too.
        board.writeObjects([fileItem])
        let files = try ClipboardImages.sources(from: board)
        precondition(files.count == 1)
        guard case let .file(url) = files[0] else { fatalError("Must prefer original file to clipboard icon") }
        precondition(url.standardizedFileURL.path == input.standardizedFileURL.path)

        board.clearContents()
        board.writeObjects((0..<7).map { _ in let value = NSPasteboardItem(); value.setData(png, forType: .png); return value })
        do { _ = try ClipboardImages.sources(from: board); fatalError("Too many images accepted") } catch {}

        board.clearContents()
        board.setData(Data("bad image".utf8), forType: .png)
        let invalid = try ClipboardImages.sources(from: board)
        do { _ = try ImageAttachmentStore.importImage(invalid[0], sessionID: sessionID, number: 3); fatalError("Invalid image accepted") } catch {}
        print("PASS: text fallback, PNG/TIFF paste, one import per clipboard item, file preference, size normalization, image count cap, corrupt image rejection")
    }
}
