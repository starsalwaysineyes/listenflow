import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

struct ImageAttachment: Identifiable, Codable, Sendable {
    let id: UUID
    let number: Int
    let name: String
    let width: Int
    let height: Int
    let byteCount: Int
    /// For a screenshot, the moment it was taken.
    let addedAt: Date
    /// File name inside the session's image folder; nil for images stored
    /// before 0.11.0, which are named after their id.
    var file: String? = nil
    /// A full-screen capture taken during the session, as opposed to a picture
    /// the user added as reference material.
    var shot: Bool? = nil
    /// Where on the page the user moved it to, as a moment of the session; nil
    /// while it sits where it was taken. A moment rather than a line, so that it
    /// holds when the sentences around it are recognized again and replaced.
    var placed: Date? = nil
    var label: String { "图片\(number)" }
    var isShot: Bool { shot == true }
    /// The moment it is shown at.
    var position: Date { placed ?? addedAt }
}

enum ImageImportSource: Sendable {
    case file(URL)
    case data(Data, name: String)
}

enum ImageAttachmentStore {
    static let maxSelected = 6
    static let maxInputBytes = 32 * 1024 * 1024
    static let maxStoredBytes = 4 * 1024 * 1024
    /// Beside the sessions, so tests and `lstf` that point the sessions
    /// somewhere else find the pictures there too.
    static var root: URL { SessionStore.folder.deletingLastPathComponent().appendingPathComponent("Images", isDirectory: true) }
    static func folder(for sessionID: UUID) -> URL { root.appendingPathComponent(sessionID.uuidString, isDirectory: true) }
    static func url(for image: ImageAttachment, sessionID: UUID) -> URL {
        folder(for: sessionID).appendingPathComponent(image.file ?? image.id.uuidString + ".jpg")
    }

    /// Longest edge of a stored screenshot, in pixels: enough to read slide
    /// text, a fraction of a Retina screen's full size.
    static let shotEdge = 2560

    /// `shot-20261118-212530.jpg`, local time: a plain listing of the folder is
    /// already in the order things happened.
    static func shotFileName(_ date: Date, zone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "shot-\(formatter.string(from: date)).jpg"
    }

    /// Keep a full-screen capture with the session, named after when it was taken.
    static func storeShot(_ image: CGImage, at date: Date, sessionID: UUID, number: Int) throws -> ImageAttachment {
        var name = shotFileName(date)
        // Two captures within the same second must not overwrite each other.
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder(for: sessionID).appendingPathComponent(name).path) {
            name = shotFileName(date).replacingOccurrences(of: ".jpg", with: "-\(suffix).jpg")
            suffix += 1
        }
        return try store(image, name: "截屏", sessionID: sessionID, number: number, qualities: [0.8, 0.65, 0.5],
                         addedAt: date, file: name, shot: true)
    }

    /// Decode the real file format, apply orientation, bound dimensions, and omit source metadata.
    static func importImage(from input: URL, sessionID: UUID, number: Int) throws -> ImageAttachment {
        let scoped = input.startAccessingSecurityScopedResource()
        defer { if scoped { input.stopAccessingSecurityScopedResource() } }
        let size = try input.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, let byteCount = size.fileSize, byteCount > 0, byteCount <= maxInputBytes else {
            throw CaptureFailure.message("\(input.lastPathComponent)：请选择 32 MB 以内的图片文件。")
        }
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw CaptureFailure.message("\(input.lastPathComponent)：无法解码图片。")
        }
        return try normalize(source, name: input.lastPathComponent, sessionID: sessionID, number: number)
    }

    static func importImage(_ input: ImageImportSource, sessionID: UUID, number: Int) throws -> ImageAttachment {
        switch input {
        case let .file(url): return try importImage(from: url, sessionID: sessionID, number: number)
        case let .data(data, name):
            guard !data.isEmpty, data.count <= maxInputBytes else {
                throw CaptureFailure.message("粘贴的图片超过 32 MB，请先裁剪或缩小。")
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw CaptureFailure.message("无法读取粘贴的图片，请重新复制。")
            }
            return try normalize(source, name: name, sessionID: sessionID, number: number)
        }
    }

    private static func normalize(_ source: CGImageSource, name: String, sessionID: UUID, number: Int) throws -> ImageAttachment {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 100_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2560,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw CaptureFailure.message("\(name)：无法解码。支持 PNG、JPEG、HEIC、GIF 和 WebP；GIF 使用首帧。")
        }
        guard let canvas = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CaptureFailure.message("无法处理这张图片，请使用较小的截图。")
        }
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let normalized = canvas.makeImage() else { throw CaptureFailure.message("图片处理失败。") }
        return try store(normalized, name: name, sessionID: sessionID, number: number, qualities: [0.9, 0.75, 0.6],
                         addedAt: Date(), file: nil, shot: nil)
    }

    private static func store(_ normalized: CGImage, name: String, sessionID: UUID, number: Int, qualities: [Double],
                              addedAt: Date, file: String?, shot: Bool?) throws -> ImageAttachment {
        var jpeg: Data?
        for quality in qualities {
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, normalized, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), buffer.length <= maxStoredBytes { jpeg = buffer as Data; break }
        }
        guard let jpeg else { throw CaptureFailure.message("\(name)：压缩后仍过大，请先裁剪再添加。") }
        let attachment = ImageAttachment(id: UUID(), number: number, name: name,
            width: normalized.width, height: normalized.height, byteCount: jpeg.count, addedAt: addedAt, file: file, shot: shot)
        let directory = folder(for: sessionID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let output = url(for: attachment, sessionID: sessionID)
        try jpeg.write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        return attachment
    }

    /// A deleted picture goes to the Trash, where a slip can still be undone;
    /// one that cannot be moved there is removed. A file already gone is no error.
    static func discard(_ image: ImageAttachment, sessionID: UUID, toTrash: Bool = true) throws {
        let file = url(for: image, sessionID: sessionID)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        if toTrash, (try? FileManager.default.trashItem(at: file, resultingItemURL: nil)) != nil { return }
        try FileManager.default.removeItem(at: file)
    }

    static func content(text: String, images: [ImageAttachment], sessionID: UUID) throws -> Any {
        guard images.count <= maxSelected else { throw CaptureFailure.message("每次请求最多选择 \(maxSelected) 张图片。") }
        guard !images.isEmpty else { return text }
        var blocks: [[String: Any]] = [["type": "text", "text": text]]
        for image in images {
            let data: Data
            do { data = try Data(contentsOf: url(for: image, sessionID: sessionID), options: .mappedIfSafe) }
            catch { throw CaptureFailure.message("找不到 \(image.label)（\(image.name)），请取消选择或重新上传。") }
            guard data.count <= maxStoredBytes else { throw CaptureFailure.message("\(image.label) 文件过大，请重新上传。") }
            blocks.append(["type": "text", "text": "以下是 \(image.label)（文件名：\(image.name)）。这是图片资料，不代表会议中已经说过的内容。"])
            blocks.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + data.base64EncodedString(), "detail": "high"]])
        }
        return blocks
    }
}
