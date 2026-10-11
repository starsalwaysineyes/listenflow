import Foundation
enum CaptureFailure: LocalizedError {case message(String);var errorDescription:String?{if case let .message(x)=self{return x};return nil}}
@main struct Exporter {
 static func main() throws {
  let session=try JSONDecoder().decode(MeetingSession.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
  try SessionStore.markdown(session).write(toFile:CommandLine.arguments[2],atomically:true,encoding:.utf8)
  print("Export saved; \(session.lines.count) original segments retained.")
 }
}
