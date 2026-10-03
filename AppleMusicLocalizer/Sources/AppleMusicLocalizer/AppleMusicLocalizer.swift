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
    @StateObject private var musicManager = MusicManager()

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.list")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
            
            Text("Apple Music 原文還原工具")
                .font(.largeTitle)
                .bold()
            
            if let trackName = musicManager.currentTrackName,
               let artistName = musicManager.currentArtistName {
                VStack(spacing: 5) {
                    Text("目前歌曲：\(trackName)")
                        .font(.title3)
                        .bold()
                    Text("歌手：\(artistName)")
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(10)
            } else {
                Text("尚未讀取或目前無播放歌曲")
                    .foregroundColor(.secondary)
                    .padding()
            }
            
            Button(action: {
                musicManager.statusMessage = "正在掃描..."
                musicManager.fetchCurrentTrack()
            }) {
                Text("掃描目前歌曲")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            
            Text(musicManager.statusMessage)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding()
    }
}
