import Foundation
import Combine

@MainActor
final class MusicManager: ObservableObject {
    @Published var currentTrackName: String?
    @Published var currentArtistName: String?
    @Published var albumName: String?
    @Published var albumArtistName: String?
    @Published var tracks: [LocalTrack] = []
    @Published var canUndo = false
    @Published var statusMessage = "就緒"
    @Published var isBusy = false

    private var backups: [TrackBackup] = []

    func fetchCurrentAlbum() {
        isBusy = true
        canUndo = false
        backups = []
        tracks = []
        statusMessage = "正在讀取目前歌曲與專輯曲目…"

        let source = #"""
        tell application "Music"
            if it is not running then return "ERROR|||NOT_RUNNING"
            try
                set currentSong to current track
                set currentName to name of currentSong as text
                set currentArtist to artist of currentSong as text
                set currentAlbum to album of currentSong as text
                try
                    set currentAlbumArtist to album artist of currentSong as text
                on error
                    set currentAlbumArtist to ""
                end try
                if currentAlbumArtist is "" then set currentAlbumArtist to currentArtist
                set output to "CURRENT|||" & currentName & "|||" & currentArtist & "|||" & currentAlbum & "|||" & currentAlbumArtist & linefeed
                set matchingTracks to (every track of library playlist 1 whose album is currentAlbum)
                repeat with trackItem in matchingTracks
                    set trackAlbumArtist to ""
                    try
                        set trackAlbumArtist to album artist of trackItem as text
                    end try
                    if trackAlbumArtist is "" then set trackAlbumArtist to artist of trackItem as text
                    if trackAlbumArtist is currentAlbumArtist then
                        set output to output & "TRACK|||" & (disc number of trackItem as text) & "|||" & (track number of trackItem as text) & "|||" & (persistent ID of trackItem as text) & "|||" & (name of trackItem as text) & "|||" & (artist of trackItem as text) & "|||" & (album of trackItem as text) & linefeed
                    end if
                end repeat
                return output
            on error errorMessage number errorNumber
                return "ERROR|||READ|||" & (errorNumber as text) & "|||" & errorMessage
            end try
        end tell
        """#

        Task {
            let output = await Self.runScript(source: source, args: [])
            await handleAlbumOutput(output)
        }
    }

    private func handleAlbumOutput(_ output: String) async {
        if output.contains("ERROR|||NOT_RUNNING") {
            statusMessage = "Apple Music 尚未開啟"
            isBusy = false
            return
        }
        if output.hasPrefix("ERROR|||") {
            let details = output.components(separatedBy: "|||")
            if details.count >= 5, details[1] == "READ" {
                statusMessage = "AppleScript 讀取失敗（錯誤碼 \(details[3])）：\(details[4])"
            } else {
                statusMessage = "AppleScript 讀取失敗：\(output)"
            }
            isBusy = false
            return
        }
        guard !output.isEmpty, !output.contains("execution error") else {
            statusMessage = output.isEmpty ? "AppleScript 沒有回傳資料" : "AppleScript 執行失敗：\(output)"
            isBusy = false
            return
        }

        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let currentLine = lines.first(where: { $0.hasPrefix("CURRENT|||") }) else {
            statusMessage = "讀取失敗：找不到目前播放歌曲的專輯資訊"
            isBusy = false
            return
        }
        let currentFields = currentLine.components(separatedBy: "|||")
        guard currentFields.count >= 5 else {
            statusMessage = "讀取失敗：目前歌曲資料格式不完整"
            isBusy = false
            return
        }
        currentTrackName = currentFields[1]
        currentArtistName = currentFields[2]
        albumName = currentFields[3]
        albumArtistName = currentFields[4]

        var localTracks: [LocalTrack] = []
        for line in lines where line.hasPrefix("TRACK|||") {
            let fields = line.components(separatedBy: "|||")
            guard fields.count >= 7,
                  let discNumber = Int(fields[1]),
                  let trackNumber = Int(fields[2]),
                  !fields[3].isEmpty else { continue }
            localTracks.append(LocalTrack(
                id: fields[3], discNumber: discNumber, trackNumber: trackNumber, name: fields[4],
                artist: fields[5], album: fields[6], durationMs: 0
            ))
        }
        guard !localTracks.isEmpty else {
            statusMessage = "本機資料庫中找不到此專輯的曲目"
            isBusy = false
            return
        }
        tracks = localTracks.sorted {
            $0.discNumber == $1.discNumber ? $0.trackNumber < $1.trackNumber : $0.discNumber < $1.discNumber
        }
        statusMessage = "已讀取 \(tracks.count) 首本機曲目，正在查詢專輯曲目…"

        do {
            let albumMatch = try await APIService.shared.searchAlbum(
                artist: currentFields[4], album: currentFields[3], localTracks: tracks, country: "jp"
            )
            let apiTracks = albumMatch.tracks
            let byNumber = Dictionary(apiTracks.compactMap { track -> (String, iTunesTrack)? in
                guard let number = track.trackNumber else { return nil }
                return ("\(track.discNumber ?? 1):\(number)", track)
            }, uniquingKeysWith: { first, _ in first })

            tracks = tracks.map { local in
                var updated = local
                if let remote = byNumber["\(local.discNumber):\(local.trackNumber)"] {
                    updated.proposedName = remote.trackName
                    updated.proposedArtist = remote.artistName
                }
                return updated
            }
            let mapped = tracks.filter(\.hasProposal).count
            statusMessage = "API 專輯「\(albumMatch.collectionName)」以 \(albumMatch.matchedTrackCount) 個曲目編號配對，\(mapped) 首可套用"
        } catch {
            statusMessage = "專輯曲目查詢失敗：\(error.localizedDescription)"
        }
        isBusy = false
    }

    func setSelected(_ selected: Bool, for trackID: String) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[index].isSelected = selected
    }

    func selectAllAvailable(_ selected: Bool) {
        for index in tracks.indices where tracks[index].hasProposal {
            tracks[index].isSelected = selected
        }
    }

    func applySelectedMetadata() {
        let selectedTracks = tracks.filter { $0.isSelected && $0.hasProposal }
        guard !selectedTracks.isEmpty else {
            statusMessage = "請先勾選至少一首有建議名稱的曲目"
            return
        }

        let args = selectedTracks.flatMap { track in
            [track.id, track.proposedName ?? track.name, track.proposedArtist ?? track.artist]
        }
        backups = selectedTracks.map { TrackBackup(persistentID: $0.id, name: $0.name, artist: $0.artist) }
        isBusy = true
        let source = #"""
        on run argv
            tell application "Music"
                repeat with i from 1 to (count of argv) by 3
                    set targetID to item i of argv
                    set newName to item (i + 1) of argv
                    set newArtist to item (i + 2) of argv
                    try
                        set targetTrack to first track of library playlist 1 whose persistent ID is targetID
                        set name of targetTrack to newName
                        set artist of targetTrack to newArtist
                    on error errorMessage
                        return "ERROR|||" & errorMessage
                    end try
                end repeat
            end tell
            return "OK"
        end run
        """#
        Task {
            let output = await Self.runScript(source: source, args: args)
            if output.hasPrefix("ERROR|||") || output.contains("execution error") {
                // AppleScript 可能已完成前幾首才遇到錯誤，保留完整備份以復原部分寫入。
                canUndo = true
                statusMessage = "批次套用中斷；已保留復原資料：\(output)"
            } else {
                for index in tracks.indices where selectedTracks.contains(where: { $0.id == tracks[index].id }) {
                    tracks[index].name = tracks[index].proposedName ?? tracks[index].name
                    tracks[index].artist = tracks[index].proposedArtist ?? tracks[index].artist
                }
                canUndo = true
                statusMessage = "已套用 \(selectedTracks.count) 首曲目，可復原"
            }
            isBusy = false
        }
    }

    func undoMetadata() {
        guard canUndo, !backups.isEmpty else { return }
        let args = backups.flatMap { [$0.persistentID, $0.name, $0.artist] }
        isBusy = true
        let source = #"""
        on run argv
            tell application "Music"
                repeat with i from 1 to (count of argv) by 3
                    set targetID to item i of argv
                    set oldName to item (i + 1) of argv
                    set oldArtist to item (i + 2) of argv
                    try
                        set targetTrack to first track of library playlist 1 whose persistent ID is targetID
                        set name of targetTrack to oldName
                        set artist of targetTrack to oldArtist
                    on error errorMessage
                        return "ERROR|||" & errorMessage
                    end try
                end repeat
            end tell
            return "OK"
        end run
        """#
        Task {
            let output = await Self.runScript(source: source, args: args)
            if output.hasPrefix("ERROR|||") || output.contains("execution error") {
                statusMessage = "復原失敗：\(output)"
            } else {
                for index in tracks.indices {
                    if let backup = backups.first(where: { $0.persistentID == tracks[index].id }) {
                        tracks[index].name = backup.name
                        tracks[index].artist = backup.artist
                    }
                }
                canUndo = false
                backups = []
                statusMessage = "已還原原始曲目資訊"
            }
            isBusy = false
        }
    }

    nonisolated private static func runScript(source: String, args: [String]) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source] + args
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let error = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: process.terminationStatus == 0 ? output : "execution error: \(error)")
            } catch {
                continuation.resume(returning: "execution error: \(error.localizedDescription)")
            }
        }
    }
}
