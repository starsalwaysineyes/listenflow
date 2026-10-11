import SwiftUI
import AppKit
import ImageIO

private enum AttachmentThumbnails {
    static let cache = NSCache<NSString, NSImage>()
    static func image(_ attachment: ImageAttachment, sessionID: UUID) -> NSImage? {
        let url = ImageAttachmentStore.url(for: attachment, sessionID: sessionID)
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 200,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        cache.countLimit = 100
        cache.totalCostLimit = 12 * 1024 * 1024
        cache.setObject(image, forKey: key, cost: thumbnail.width * thumbnail.height * 4)
        return image
    }
}

struct ImageAttachmentPicker: View {
    @ObservedObject var model: AppModel
    let forOrganization: Bool
    @State private var preview: ImageAttachment?
    private var selection: [ImageAttachment] { forOrganization ? model.organizationImages : model.askImages }
    private var busy: Bool { model.isImportingImages || (forOrganization ? model.isOrganizing : model.isAsking) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { model.importImages(forOrganization: forOrganization) } label: {
                    Label(forOrganization ? "添加参考图片" : "添加图片", systemImage: "photo.badge.plus")
                }.buttonStyle(.plain).disabled(busy).help("手动选择图片；先保存在本机，发起请求时才发送")
                if !model.session.imageLibrary.isEmpty {
                    Menu {
                        ForEach(model.session.imageLibrary) { image in
                            Toggle("\(image.label) · \(image.name)", isOn: Binding(
                                get: { (forOrganization ? model.organizationImageIDs : model.askImageIDs).contains(image.id) },
                                set: { model.selectImage(image, forOrganization: forOrganization, selected: $0) }))
                        }
                    } label: { Text("会话图片") }.menuStyle(.borderlessButton).fixedSize().disabled(busy)
                }
                Spacer(minLength: 0)
                if model.isImportingImages { ProgressView().controlSize(.mini) }
                else if !selection.isEmpty { Text("\(selection.count)/6 张").foregroundStyle(.secondary) }
            }.font(.system(size: 11))
            if !selection.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 9) {
                        ForEach(selection) { image in
                            VStack(spacing: 3) {
                                ZStack(alignment: .topTrailing) {
                                    Button { preview = image } label: { AttachmentThumbnail(image: image, sessionID: model.session.id) }
                                        .buttonStyle(.plain).help("预览 \(image.label)：\(image.name)")
                                    Button { model.selectImage(image, forOrganization: forOrganization, selected: false) } label: {
                                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                            .foregroundStyle(Color.secondary, Color.white).font(.system(size: 14))
                                    }.buttonStyle(.plain).disabled(busy).help("取消本次使用；图片仍保存在会话中")
                                }
                                Text(image.label).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.vertical, 2)
                }.frame(height: 78)
                Text(forOrganization ? (model.autoOrganize ? "选中图片将用于本次及后续自动整理" : "选中图片将随本次整理发送") : "选中图片将随本次提问发送")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $preview) { image in AttachmentPreview(image: image, sessionID: model.session.id) }
    }
}

struct ImageReferencesView: View {
    let images: [ImageAttachment]
    let sessionID: UUID
    @State private var preview: ImageAttachment?
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 9) {
                ForEach(images) { image in
                    Button { preview = image } label: {
                        VStack(spacing: 4) {
                            AttachmentThumbnail(image: image, sessionID: sessionID)
                            Text(image.label).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).help("这次提问使用的 \(image.label)：\(image.name)")
                }
            }
        }.frame(height: 78).sheet(item: $preview) { image in AttachmentPreview(image: image, sessionID: sessionID) }
    }
}

private struct AttachmentThumbnail: View {
    let image: ImageAttachment
    let sessionID: UUID
    var body: some View {
        Group {
            if let thumbnail = AttachmentThumbnails.image(image, sessionID: sessionID) {
                Image(nsImage: thumbnail).resizable().scaledToFit()
            } else { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
        }
        .frame(width: 76, height: 56).background(Color.white, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.1)))
        .accessibilityLabel("\(image.label)：\(image.name)")
    }
}

private struct AttachmentPreview: View {
    let image: ImageAttachment
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(image.label) · \(image.name)").font(.headline).lineLimit(1)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let full = NSImage(contentsOf: ImageAttachmentStore.url(for: image, sessionID: sessionID)) {
                Image(nsImage: full).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Text("图片文件暂时不可用，请重新添加。").frame(maxWidth: .infinity, maxHeight: .infinity) }
            Text("\(image.width) × \(image.height) · 保存在本机会话中").font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 760, height: 620)
    }
}
