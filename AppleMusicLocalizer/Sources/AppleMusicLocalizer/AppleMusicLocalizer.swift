import SwiftUI

@main
struct AppleMusicLocalizerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 500, minHeight: 500)
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
                
                VStack(alignment: .leading, spacing: 15) {
                    // 目前的名稱區塊
                    VStack(alignment: .leading, spacing: 5) {
                        Text("📍 目前歌曲資訊")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("歌名：\(trackName)")
                            .font(.title3)
                            .bold()
                        Text("歌手：\(artistName)")
                            .foregroundColor(.secondary)
                    }
                    
                    // 若有搜尋到原文，顯示建議區塊與套用按鈕
                    if let propTrack = musicManager.proposedTrackName,
                       let propArtist = musicManager.proposedArtistName,
                       !musicManager.canUndo {  // 當還沒套用修改時，才顯示建議
                        
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("✨ 建議替換的原文")
                                .font(.headline)
                                .foregroundColor(.green)
                            Text("歌名：\(propTrack)")
                                .font(.title3)
                                .bold()
                            Text("歌手：\(propArtist)")
                                .foregroundColor(.secondary)
                            
                            Button(action: {
                                musicManager.applyProposedMetadata()
                            }) {
                                Text("套用修改")
                                    .fontWeight(.bold)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        }
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(10)
                
            } else {
                Text("尚未讀取或目前無播放歌曲")
                    .foregroundColor(.secondary)
                    .padding()
            }
            
            HStack(spacing: 15) {
                Button(action: {
                    musicManager.fetchCurrentTrack()
                }) {
                    Text(musicManager.canUndo ? "掃描下一首" : "掃描目前歌曲")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                
                // 復原按鈕 (只有在套用修改後才會出現)
                if musicManager.canUndo {
                    Button(action: {
                        musicManager.undoMetadata()
                    }) {
                        Text("復原修改 (Undo)")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                }
            }
            
            Text(musicManager.statusMessage)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(30)
    }
}
