import Foundation
import Combine

class MusicManager: ObservableObject {
    @Published var currentTrackName: String?
    @Published var currentArtistName: String?
    
    // 新增：建議替換的原文資訊
    @Published var proposedTrackName: String?
    @Published var proposedArtistName: String?
    
    @Published var statusMessage: String = "就緒"

    func fetchCurrentTrack() {
        // 重置狀態
        self.proposedTrackName = nil
        self.proposedArtistName = nil
        self.statusMessage = "正在讀取..."
        
        let scriptSource = """
        tell application "Music"
            if it is running then
                try
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    return trackName & "|||" & trackArtist
                on error
                    return "ERROR_NO_TRACK"
                end try
            else
                return "ERROR_NOT_RUNNING"
            end if
        end tell
        """
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", scriptSource]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                DispatchQueue.main.async {
                    self.handleScriptOutput(output)
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.statusMessage = "執行指令失敗：\\(error.localizedDescription)"
                self.currentTrackName = nil
                self.currentArtistName = nil
            }
        }
    }
    
    private func handleScriptOutput(_ output: String) {
        if output.contains("ERROR_NOT_RUNNING") {
            self.statusMessage = "Apple Music 尚未開啟"
            self.currentTrackName = nil
            self.currentArtistName = nil
        } else if output.contains("ERROR_NO_TRACK") {
            self.statusMessage = "目前沒有正在播放的歌曲"
            self.currentTrackName = nil
            self.currentArtistName = nil
        } else if output.isEmpty || output.contains("execution error") || output.contains("Not authorized") {
            self.statusMessage = "權限遭阻擋 (請在系統設定中允許終端機控制Music)"
            self.currentTrackName = nil
            self.currentArtistName = nil
        } else {
            let components = output.components(separatedBy: "|||")
            if components.count == 2 {
                let track = components[0]
                let artist = components[1]
                
                self.currentTrackName = track
                self.currentArtistName = artist
                self.statusMessage = "成功讀取，正在搜尋原文..."
                
                // 啟動 API 搜尋
                searchOriginalName(artist: artist, track: track)
                
            } else {
                self.statusMessage = "讀取失敗：資料解析錯誤"
            }
        }
    }
    
    private func searchOriginalName(artist: String, track: String) {
        Task {
            do {
                // 預設先使用 jp (日本)，後續可做成 UI 選擇
                if let result = try await APIService.shared.searchTrack(artist: artist, track: track, country: "jp") {
                    DispatchQueue.main.async {
                        self.proposedTrackName = result.trackName
                        self.proposedArtistName = result.artistName
                        self.statusMessage = "搜尋完成！"
                    }
                } else {
                    DispatchQueue.main.async {
                        self.statusMessage = "找不到對應的原文歌曲"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "API 搜尋發生錯誤"
                }
            }
        }
    }
}
