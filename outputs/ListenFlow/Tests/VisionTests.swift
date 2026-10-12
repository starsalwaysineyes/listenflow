import Foundation
import AppKit
import ImageIO

enum CaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

@main struct VisionTests {
    @MainActor static func fixture(at url: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3200, pixelsHigh: 1800,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 3200, height: 1800)).fill()
        let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 110, weight: .semibold), .foregroundColor: NSColor.black]
        ("VISION TEST - CHECK CODE: 7426" as NSString).draw(at: NSPoint(x: 150, y: 1510), withAttributes: style)
        ("REVENUE: 180" as NSString).draw(at: NSPoint(x: 150, y: 1230), withAttributes: style)
        NSColor.systemTeal.setFill(); NSBezierPath(rect: NSRect(x: 150, y: 1000, width: 1800, height: 140)).fill()
        ("COST: 120" as NSString).draw(at: NSPoint(x: 150, y: 730), withAttributes: style)
        NSColor.systemOrange.setFill(); NSBezierPath(rect: NSRect(x: 150, y: 500, width: 1200, height: 140)).fill()
        ("NEXT REVIEW: FRIDAY" as NSString).draw(at: NSPoint(x: 150, y: 200), withAttributes: style)
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    @MainActor static func main() async throws {
        let input = URL(fileURLWithPath: "work/vision-test.png")
        try fixture(at: input)
        var session = MeetingSession(title: "图片功能测试（虚构资料）")
        let directory = ImageAttachmentStore.folder(for: session.id)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try ImageAttachmentStore.importImage(from: input, sessionID: session.id, number: 1)
        session.images = [image]
        precondition(image.width == 2560 && image.height == 1440)
        precondition(image.byteCount <= ImageAttachmentStore.maxStoredBytes)
        let imageURL = ImageAttachmentStore.url(for: image, sessionID: session.id)
        let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil)!
        precondition(CGImageSourceGetType(source)! as String == "public.jpeg")
        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(MeetingSession.self, from: encoded)
        precondition(decoded.imageLibrary[0].id == image.id)

        let messages = try LLMClient.requestMessages(session: session, question: "图中的校验码是什么？", images: [image])
        let content = messages.last!["content"] as! [[String: Any]]
        let imageBlock = content.first { $0["type"] as? String == "image_url" }!
        let imageDataURL = (imageBlock["image_url"] as! [String: String])["url"]!
        precondition(imageDataURL.hasPrefix("data:image/jpeg;base64,"))
        precondition(messages.dropLast().allSatisfy { $0["content"] is String })
        session.chat = [ChatMessage(role: "user", text: "先前问题", imageIDs: [image.id])]
        let noImages = try LLMClient.requestMessages(session: session, question: "只看文字", images: [])
        precondition(noImages.allSatisfy { $0["content"] is String }, "Historical images must not be silently resent")
        let organize = try LLMClient.organizationRequestMessages(session: session, lines: [], images: [image])
        precondition(organize[1]["content"] is [[String: Any]])
        do { _ = try ImageAttachmentStore.content(text: "test", images: Array(repeating: image, count: 7), sessionID: session.id); fatalError("Limit not enforced") } catch {}
        let invalid = URL(fileURLWithPath: "work/invalid-image.png")
        try Data("not an image".utf8).write(to: invalid)
        do { _ = try ImageAttachmentStore.importImage(from: invalid, sessionID: session.id, number: 2); fatalError("Invalid image accepted") } catch {}
        try FileManager.default.removeItem(at: invalid)
        session.organized = OrganizedTranscript(text: "参考 [图片1]", generatedAt: Date(), sourceLineIDs: [], through: session.created, imageIDs: [image.id])
        let export = URL(fileURLWithPath: "work/vision-export/record.md")
        try FileManager.default.createDirectory(at: export.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SessionStore.export(session, to: export)
        let markdown = try String(contentsOf: export, encoding: .utf8)
        precondition(markdown.contains("![图片1]") && markdown.contains("参考图片：图片1"))
        print("PASS: image decode/resize/JPEG conversion, image-only session persistence, multimodal user payload, explicit selection, image limits, bad-file rejection, export assets")

        if CommandLine.arguments.contains("--live-image-only") {
            let key = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
            session.chat = []; session.lines = []
            let result = try await LLMClient.organize(preferences: Preferences(), key: key, session: session,
                                                      lines: session.lines, images: [image]) { _ in }
                .map(\.text).joined(separator: "\n\n")
            precondition(result.contains("7426") && result.contains("图片"))
            precondition(result.range(of: #"\[\d+:\d\d\]"#, options: .regularExpression) == nil)
            try result.write(toFile: "work/vision-image-only-result.txt", atomically: true, encoding: .utf8)
            print("PASS: live image-only organization without invented recording timestamps\n\(result)")
        }
        if CommandLine.arguments.contains("--live") {
            let key = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
            session.chat = []
            let answer = try await LLMClient.ask(preferences: Preferences(), key: key, session: session,
                question: "请读出图片中的校验码、收入、成本，以及下次复盘的星期。说明信息来自图片。", images: [image]) { _ in }
            print("LIVE IMAGE ANSWER:\n\(answer)")
            precondition(answer.contains("7426") && answer.contains("180") && answer.contains("120"))
            session.lines = [TranscriptLine(start: session.created, end: session.created.addingTimeInterval(4), source: "测试 App",
                text: "今天讨论产品计划，收入与成本数据请参考图片。", latency: 4)]
            let organized = try await LLMClient.organize(preferences: Preferences(), key: key, session: session,
                                                         lines: session.lines, images: [image]) { _ in }
                .map(\.text).joined(separator: "\n\n")
            print("LIVE IMAGE + TRANSCRIPT ORGANIZATION:\n\(organized)")
            precondition(organized.contains("180") && organized.contains("120") && organized.contains("图片"))
            try JSONSerialization.data(withJSONObject: ["answer": answer, "organized": organized], options: [.prettyPrinted]).write(to: URL(fileURLWithPath: "work/vision-live-results.json"))
            print("PASS: actual DeepSeek Flash vision QA and image-assisted organization")
        }
    }
}
