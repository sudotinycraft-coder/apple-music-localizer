import SwiftUI

@main
struct AppleMusicLocalizerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 500, minHeight: 400)
        }
    }
}

struct ContentView: View {
    @State private var statusMessage: String = "就緒"

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.list")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
            
            Text("Apple Music 原文還原工具")
                .font(.largeTitle)
                .bold()
            
            Text("點擊下方按鈕以讀取目前播放的歌曲資訊")
                .foregroundColor(.secondary)
            
            Button(action: {
                // TODO: 實作讀取 Music.app 邏輯
                statusMessage = "正在掃描..."
            }) {
                Text("掃描目前歌曲")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            
            Text(statusMessage)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding()
    }
}
