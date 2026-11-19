import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The pictures a paste would bring: image files copied in Finder, or image
/// data copied from a screenshot, a browser, a chat.
enum PastedPictures {
    static let name = "粘贴的图片"
    static func sources(on board: NSPasteboard) -> [ImageImportSource] {
        // Copied files come with their icon as image data, so the files decide:
        // a copied PDF must not paste its icon.
        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            return files.filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true }
                .map(ImageImportSource.file)
        }
        // The compressed forms first: the same picture as TIFF is several times the size.
        let types = board.types ?? []
        let preferred = [UTType.png, .jpeg, .heic, .webP, .gif, .tiff].map { NSPasteboard.PasteboardType($0.identifier) }
        let others = types.filter { UTType($0.rawValue)?.conforms(to: .image) == true }
        for type in preferred.filter(types.contains) + others {
            if let data = board.data(forType: type), !data.isEmpty { return [.data(data, name: name)] }
        }
        return []
    }
}

enum AttachmentThumbnails {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    /// Decoded at the size it is shown, never the full picture: a session can
    /// hold dozens of screenshots of a few megapixels each.
    static func image(_ attachment: ImageAttachment, sessionID: UUID, edge: Int = 200) -> NSImage? {
        let url = ImageAttachmentStore.url(for: attachment, sessionID: sessionID)
        let key = "\(url.path)#\(edge)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        cache.setObject(image, forKey: key, cost: thumbnail.width * thumbnail.height * 4)
        return image
    }
}

/// Pictures sent along when the organized draft is written: files the user
/// adds, or any picture already in the session, screenshots included.
struct ImageAttachmentPicker: View {
    @ObservedObject var model: AppModel
    @State private var preview: ImageAttachment?
    private var busy: Bool { model.isImportingImages || model.isOrganizing }
    var body: some View {
        let selection = model.organizationImages
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { model.importImages() } label: {
                    Label("添加参考图片", systemImage: "photo.badge.plus")
                }.buttonStyle(.plain).disabled(busy).help("选择图片文件；先保存在本机，整理时才发送")
                if !model.session.imageLibrary.isEmpty {
                    Menu {
                        ForEach(model.session.imageLibrary) { image in
                            Toggle(title(image), isOn: Binding(
                                get: { model.organizationImageIDs.contains(image.id) },
                                set: { model.selectImage(image, selected: $0) }))
                        }
                    } label: { Text("从这场会话的图片里选") }.menuStyle(.borderlessButton).fixedSize().disabled(busy)
                }
                Spacer(minLength: 0)
                if model.isImportingImages { ProgressView().controlSize(.mini) }
                else if !selection.isEmpty { Text("已选 \(selection.count)/\(ImageAttachmentStore.maxSelected) 张").foregroundStyle(.secondary) }
            }.font(.system(size: 11))
            if !selection.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 9) {
                        ForEach(selection) { image in
                            VStack(spacing: 3) {
                                ZStack(alignment: .topTrailing) {
                                    Button { preview = image } label: { AttachmentThumbnail(image: image, sessionID: model.session.id) }
                                        .buttonStyle(.plain).help("预览 \(title(image))")
                                    Button { model.selectImage(image, selected: false) } label: {
                                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                            .foregroundStyle(Palette.muted, Palette.page).font(.system(size: 14))
                                    }.buttonStyle(.plain).disabled(busy).help("这次整理不用这张；图片仍保存在会话中")
                                }
                                Text(image.label).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.vertical, 2)
                }.frame(height: 78)
                Text(model.autoOrganize ? "选中的图片会随这次和之后的自动整理发送" : "选中的图片会随这次整理发送")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $preview) { image in
            AttachmentPreview(image: image, sessionID: model.session.id, created: model.session.created, late: model.session.addedLater(image))
        }
    }

    private func title(_ image: ImageAttachment) -> String {
        guard image.isShot else { return "\(image.label)，\(image.name)" }
        return model.session.addedLater(image) ? "\(image.label)，后加的截屏"
            : "\(image.label)，\(SessionStore.timestamp(image.addedAt, relativeTo: model.session.created)) 的截屏"
    }
}

struct AttachmentThumbnail: View {
    let image: ImageAttachment
    let sessionID: UUID
    var body: some View {
        Group {
            if let thumbnail = AttachmentThumbnails.image(image, sessionID: sessionID) {
                Image(nsImage: thumbnail).resizable().scaledToFit()
            } else { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
        }
        .frame(width: 76, height: 56).background(Palette.rail, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.hairline))
        .accessibilityLabel("\(image.label)：\(image.name)")
    }
}

struct AttachmentPreview: View {
    let image: ImageAttachment
    let sessionID: UUID
    let created: Date
    /// Put in after the session was over: no moment of the session to name it by.
    var late = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let url = ImageAttachmentStore.url(for: image, sessionID: sessionID)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(!image.isShot ? image.name : late ? "后加的截屏" : "\(SessionStore.timestamp(image.addedAt, relativeTo: created)) 的截屏")
                    .font(.headline).lineLimit(1)
                Spacer()
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let full = NSImage(contentsOf: url) {
                Image(nsImage: full).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Text("图片文件不在了：\(url.path)").frame(maxWidth: .infinity, maxHeight: .infinity) }
            Text("\(image.label)，\(image.width) × \(image.height)，保存在本机").font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 860, height: 640)
    }
}
