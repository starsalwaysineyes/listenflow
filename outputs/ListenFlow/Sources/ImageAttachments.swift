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
    let addedAt: Date
    var label: String { "图片\(number)" }
}

enum ImageImportSource: Sendable {
    case file(URL)
    case data(Data, name: String)
}

enum ImageAttachmentStore {
    static let maxSelected = 6
    static let maxInputBytes = 32 * 1024 * 1024
    static let maxStoredBytes = 4 * 1024 * 1024
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ListenFlow/Images", isDirectory: true)
    }
    static func folder(for sessionID: UUID) -> URL { root.appendingPathComponent(sessionID.uuidString, isDirectory: true) }
    static func url(for image: ImageAttachment, sessionID: UUID) -> URL {
        folder(for: sessionID).appendingPathComponent(image.id.uuidString + ".jpg")
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
        var jpeg: Data?
        for quality in [0.9, 0.75, 0.6] {
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, normalized, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), buffer.length <= maxStoredBytes { jpeg = buffer as Data; break }
        }
        guard let jpeg else { throw CaptureFailure.message("\(name)：压缩后仍过大，请先裁剪再添加。") }
        let attachment = ImageAttachment(id: UUID(), number: number, name: name,
            width: image.width, height: image.height, byteCount: jpeg.count, addedAt: Date())
        let directory = folder(for: sessionID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let output = url(for: attachment, sessionID: sessionID)
        try jpeg.write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        return attachment
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
