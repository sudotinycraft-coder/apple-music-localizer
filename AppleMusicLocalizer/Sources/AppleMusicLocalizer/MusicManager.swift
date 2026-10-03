import Foundation
import Combine

@MainActor
class MusicManager: ObservableObject {
    @Published var currentTrackName: String?
    @Published var currentArtistName: String?
    
    @Published var proposedTrackName: String?
    @Published var proposedArtistName: String?
    
    // 用於 Undo (復原) 機制的備份變數
    @Published var originalTrackName: String?
    @Published var originalArtistName: String?
    @Published var canUndo: Bool = false
    
    @Published var statusMessage: String = "就緒"

    // MARK: - 1. 讀取目前歌曲
    func fetchCurrentTrack() {
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
        
        // 透過 Task 非同步執行，避免阻塞主執行緒 (Main Thread)
        Task {
            let output = await runScript(source: scriptSource, args: [])
            handleScriptOutput(output)
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
                
                // 重置 Undo 狀態 (針對不同歌曲)
                self.canUndo = false
                self.originalTrackName = track
                self.originalArtistName = artist
                
                self.statusMessage = "成功讀取，正在搜尋原文..."
                searchOriginalName(artist: artist, track: track)
                
            } else {
                self.statusMessage = "讀取失敗：資料解析錯誤"
            }
        }
    }
    
    // MARK: - 2. 搜尋原文 (API)
    private func searchOriginalName(artist: String, track: String) {
        Task {
            do {
                if let result = try await APIService.shared.searchTrack(artist: artist, track: track, country: "jp") {
                    self.proposedTrackName = result.trackName
                    self.proposedArtistName = result.artistName
                    self.statusMessage = "搜尋完成！"
                } else {
                    self.statusMessage = "找不到對應的原文歌曲"
                }
            } catch {
                self.statusMessage = "API 搜尋發生錯誤"
            }
        }
    }
    
    // MARK: - 3. 套用修改 (寫入 Apple Music)
    func applyProposedMetadata() {
        guard let newTrack = proposedTrackName, let newArtist = proposedArtistName else { return }
        
        let scriptSource = """
        on run argv
            set newName to item 1 of argv
            set newArtist to item 2 of argv
            tell application "Music"
                if it is running then
                    try
                        set name of current track to newName
                        set artist of current track to newArtist
                    end try
                end if
            end tell
        end run
        """
        
        Task {
            let output = await runScript(source: scriptSource, args: [newTrack, newArtist])
            if output.contains("execution error") {
                self.statusMessage = "修改失敗"
            } else {
                self.currentTrackName = newTrack
                self.currentArtistName = newArtist
                self.canUndo = true
                self.statusMessage = "修改成功！"
            }
        }
    }
    
    // MARK: - 4. 復原修改 (Undo)
    func undoMetadata() {
        guard let oldTrack = originalTrackName, let oldArtist = originalArtistName, canUndo else { return }
        
        let scriptSource = """
        on run argv
            set oldName to item 1 of argv
            set oldArtist to item 2 of argv
            tell application "Music"
                if it is running then
                    try
                        set name of current track to oldName
                        set artist of current track to oldArtist
                    end try
                end if
            end tell
        end run
        """
        
        Task {
            let output = await runScript(source: scriptSource, args: [oldTrack, oldArtist])
            if output.contains("execution error") {
                self.statusMessage = "復原失敗"
            } else {
                self.currentTrackName = oldTrack
                self.currentArtistName = oldArtist
                self.canUndo = false
                self.statusMessage = "已復原為原先名稱。"
            }
        }
    }
    
    // MARK: - Helper: 背景執行 AppleScript (隔離於主執行緒)
    nonisolated private func runScript(source: String, args: [String]) async -> String {
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source] + args
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: output)
            } catch {
                continuation.resume(returning: "execution error")
            }
        }
    }
}
