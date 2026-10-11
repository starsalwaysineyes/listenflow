import Foundation
enum CaptureFailure: LocalizedError {
 case message(String)
 var errorDescription: String? { if case let .message(x)=self{return x};return nil }
}
@main struct Organizer {
 static func main() async throws {
  let session=try JSONDecoder().decode(MeetingSession.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
  let key=String(data:FileHandle.standardInput.readDataToEndOfFile(),encoding:.utf8)!.trimmingCharacters(in:.whitespacesAndNewlines)
  let start=Date()
  let output=try await LLMClient.organize(preferences:Preferences(),key:key,session:session){_ in}
  var updated=session
  updated.organized=OrganizedTranscript(text:output,generatedAt:Date(),sourceLineIDs:session.lines.map(\.id),through:session.lines.map(\.end).max()!)
  try JSONEncoder().encode(updated).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
  let paragraphs=output.components(separatedBy:"\n\n").filter{!$0.isEmpty}
  print("Completed in \(Date().timeIntervalSince(start)) seconds; \(paragraphs.count) paragraphs; longest \(paragraphs.map(\.count).max() ?? 0) characters")
  print(output)
 }
}
