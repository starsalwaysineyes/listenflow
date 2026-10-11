import AppKit
import UniformTypeIdentifiers

enum ClipboardImages {
    private static let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier]
    ]

    /// Read only when the user pastes. Prefer original files to Finder's icon representation.
    @MainActor static func sources(from pasteboard: NSPasteboard) throws -> [ImageImportSource] {
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL], !files.isEmpty {
            guard files.count <= ImageAttachmentStore.maxSelected else { throw CaptureFailure.message("每次最多选择 6 张图片，请减少选择。") }
            return files.map(ImageImportSource.file)
        }
        var result: [ImageImportSource] = []
        for item in pasteboard.pasteboardItems ?? [] {
            // A clipboard item often provides PNG and TIFF for the same picture: use it once.
            let candidates = ([NSPasteboard.PasteboardType.png, .tiff] + item.types).filter { type in
                item.types.contains(type) && UTType(type.rawValue)?.conforms(to: .image) == true
            }
            guard let data = candidates.lazy.compactMap({ item.data(forType: $0) }).first else { continue }
            guard result.count < ImageAttachmentStore.maxSelected else { throw CaptureFailure.message("每次最多选择 6 张图片，请减少选择。") }
            guard !data.isEmpty, data.count <= ImageAttachmentStore.maxInputBytes else {
                throw CaptureFailure.message("粘贴的图片超过 32 MB，请先裁剪或缩小。")
            }
            result.append(.data(data, name: "粘贴图片"))
        }
        return result
    }

    @MainActor static func containsImage(in pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: fileOptions) ||
            (pasteboard.types ?? []).contains { UTType($0.rawValue)?.conforms(to: .image) == true }
    }
}
