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
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: scriptSource) {
            let output = scriptObject.executeAndReturnError(&error)
            
            if error != nil {
                DispatchQueue.main.async {
                    self.statusMessage = "讀取失敗：AppleScript 執行錯誤"
                    self.currentTrackName = nil
                    self.currentArtistName = nil
                }
                return
            }
            
            if let resultString = output.stringValue {
                DispatchQueue.main.async {
                    if resultString == "ERROR_NOT_RUNNING" {
                        self.statusMessage = "Apple Music 尚未開啟"
                        self.currentTrackName = nil
                        self.currentArtistName = nil
                    } else if resultString == "ERROR_NO_TRACK" {
                        self.statusMessage = "目前沒有正在播放的歌曲"
                        self.currentTrackName = nil
                        self.currentArtistName = nil
                    } else {
                        let components = resultString.components(separatedBy: "|||")
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
        }
    }
}
