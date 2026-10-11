import SwiftUI
import AVFoundation
@main struct PlayerApp: App {
 @State private var player: AVAudioPlayer?
 var body: some Scene {
  WindowGroup("听流音频测试") {
   VStack(spacing:20) {
    Text("本地中文测试音频").font(.title)
    Text("27 秒合成语音，仅用于验证 App 音频采集。")
    Button("播放测试音频") {
     player = try? AVAudioPlayer(contentsOf: Bundle.main.url(forResource:"sample",withExtension:"wav")!)
     player?.numberOfLoops = -1
     player?.play()
    }
    Button("停止") { player?.stop() }
   }.padding(40).frame(width:420,height:180)
  }
 }
}
