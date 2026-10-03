import Foundation
import Combine

class MusicManager: ObservableObject {
    @Published var currentTrackName: String?
    @Published var currentArtistName: String?
    @Published var statusMessage: String = "就緒"

    func fetchCurrentTrack() {
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
        
        // 改用 Process 呼叫系統原生 osascript，以繼承終端機權限並觸發 TCC 授權提示
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
                self.currentTrackName = components[0]
                self.currentArtistName = components[1]
                self.statusMessage = "成功讀取歌曲資訊"
            } else {
                self.statusMessage = "讀取失敗：資料解析錯誤"
            }
        }
    }
}
