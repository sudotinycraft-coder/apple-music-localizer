import Foundation
import Combine

@MainActor
final class MusicManager: ObservableObject {
    @Published var currentTrackName: String?
    @Published var currentArtistName: String?
    @Published var albumName: String?
    @Published var albumArtistName: String?
    @Published var proposedAlbumName: String?
    @Published var updateAlbumName = true
    @Published var tracks: [LocalTrack] = []
    @Published var canUndo = false
    @Published var statusMessage = "就緒"
    @Published var isBusy = false

    private var backups: [TrackBackup] = []
    private var backupAlbumName: String?

    var hasAlbumProposal: Bool {
        guard let proposedAlbumName, let albumName else { return false }
        return !proposedAlbumName.isEmpty && proposedAlbumName != albumName
    }

    func fetchCurrentAlbum() {
        isBusy = true
        canUndo = false
        backups = []
        backupAlbumName = nil
        proposedAlbumName = nil
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
                        set trackDuration to ""
                        try
                            set trackDuration to duration of trackItem as text
                        end try
                        set output to output & "TRACK|||" & (disc number of trackItem as text) & "|||" & (track number of trackItem as text) & "|||" & (persistent ID of trackItem as text) & "|||" & (name of trackItem as text) & "|||" & (artist of trackItem as text) & "|||" & (album of trackItem as text) & "|||" & trackDuration & linefeed
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
            let durationSeconds = fields.count >= 8 ? (Double(fields[7]) ?? 0.0) : 0.0
            localTracks.append(LocalTrack(
                id: fields[3], discNumber: discNumber, trackNumber: trackNumber, name: fields[4],
                artist: fields[5], album: fields[6], durationSeconds: durationSeconds
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

            // 多維度配對演算法 (Smart Matching Pipeline)
            // 優先以「碟片 + 曲目編號 + 播放長度誤差 <= 4 秒」進行第一輪精確配對，避免多單曲/不同版本造成的曲目編號衝突。
            var matchedAPITrackIDs = Set<String>()
            var localToRemote = [String: iTunesTrack]() // local.id -> iTunesTrack

            // 第一輪：碟片、曲目編號吻合，且時長誤差在 4 秒內
            for local in tracks {
                if let candidate = apiTracks.first(where: { remote in
                    guard let rDisc = remote.discNumber, let rTrack = remote.trackNumber, let rMs = remote.trackTimeMillis else { return false }
                    let uniqueKey = "\(rDisc):\(rTrack)"
                    guard !matchedAPITrackIDs.contains(uniqueKey) else { return false }
                    let discMatch = (rDisc == local.discNumber)
                    let trackMatch = (rTrack == local.trackNumber)
                    let durationDiff = abs((Double(rMs) / 1000.0) - local.durationSeconds)
                    return discMatch && trackMatch && durationDiff <= 4.0
                }) {
                    let key = "\(candidate.discNumber ?? 1):\(candidate.trackNumber ?? 0)"
                    matchedAPITrackIDs.insert(key)
                    localToRemote[local.id] = candidate
                }
            }

            // 第二輪：全域最小時長差貪婪配對 (Global Minimal Duration Diff Matching)
            // 當本機曲目編號位移（例如先行單曲的軌號與整張專輯不同）時，將所有未配對的曲目與未認領的 API 曲目計算時長誤差，
            // 依「時長誤差最小」由小到大貪婪配對，徹底解決多首歌曲時長相近時被「唯一候選」條件誤殺的問題。
            let unmatchedLocals = tracks.filter { localToRemote[$0.id] == nil && $0.durationSeconds > 0 }
            let remainingAPITracks = apiTracks.filter { remote in
                guard let rDisc = remote.discNumber, let rTrack = remote.trackNumber else { return false }
                return !matchedAPITrackIDs.contains("\(rDisc):\(rTrack)")
            }

            struct MatchCandidate {
                let localID: String
                let apiTrack: iTunesTrack
                let diffSeconds: Double
            }

            var candidatePairs = [MatchCandidate]()
            for local in unmatchedLocals {
                for remote in remainingAPITracks {
                    guard let rMs = remote.trackTimeMillis else { continue }
                    let diff = abs((Double(rMs) / 1000.0) - local.durationSeconds)
                    if diff <= 4.0 {
                        candidatePairs.append(MatchCandidate(localID: local.id, apiTrack: remote, diffSeconds: diff))
                    }
                }
            }
            // 依時長誤差由小到大排序，優先鎖定最精確的配對
            candidatePairs.sort { $0.diffSeconds < $1.diffSeconds }

            var assignedLocalIDs = Set<String>()
            for pair in candidatePairs {
                let remoteKey = "\(pair.apiTrack.discNumber ?? 1):\(pair.apiTrack.trackNumber ?? 0)"
                if !assignedLocalIDs.contains(pair.localID) && !matchedAPITrackIDs.contains(remoteKey) {
                    assignedLocalIDs.insert(pair.localID)
                    matchedAPITrackIDs.insert(remoteKey)
                    localToRemote[pair.localID] = pair.apiTrack
                }
            }

            // 第三輪：標準備援，僅碟片與曲目編號吻合（針對本機未回報時長或時長被修改的特殊音軌）
            for local in tracks where localToRemote[local.id] == nil {
                if let candidate = apiTracks.first(where: { remote in
                    guard let rDisc = remote.discNumber, let rTrack = remote.trackNumber else { return false }
                    let uniqueKey = "\(rDisc):\(rTrack)"
                    guard !matchedAPITrackIDs.contains(uniqueKey) else { return false }
                    return (rDisc == local.discNumber && rTrack == local.trackNumber)
                }) {
                    let key = "\(candidate.discNumber ?? 1):\(candidate.trackNumber ?? 0)"
                    matchedAPITrackIDs.insert(key)
                    localToRemote[local.id] = candidate
                }
            }

            tracks = tracks.map { local in
                var updated = local
                if let remote = localToRemote[local.id] {
                    updated.proposedName = remote.trackName
                    updated.proposedArtist = remote.artistName
                }
                return updated
            }
            proposedAlbumName = albumMatch.collectionName
            updateAlbumName = (albumMatch.collectionName != albumName)
            let mapped = tracks.filter(\.hasProposal).count
            statusMessage = "API 專輯「\(albumMatch.collectionName)」配對成功，共 \(mapped) 首可套用"
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
        let shouldUpdateAlbum = updateAlbumName && hasAlbumProposal
        guard !selectedTracks.isEmpty || shouldUpdateAlbum else {
            statusMessage = "請先勾選至少一首有建議名稱的曲目，或勾選更新專輯名稱"
            return
        }

        let selectedIDs = Set(selectedTracks.map(\.id))
        let targetAlbum = shouldUpdateAlbum ? (proposedAlbumName ?? albumName ?? "") : ""
        // 若勾選同步更新專輯名稱，需對同專輯所有曲目統一寫入新專輯名，避免專輯在 Apple Music 中被拆散為兩張
        let tracksToUpdate = shouldUpdateAlbum ? tracks : selectedTracks

        let args = tracksToUpdate.flatMap { track -> [String] in
            let isTrackSelected = selectedIDs.contains(track.id)
            let newName = isTrackSelected ? (track.proposedName ?? track.name) : track.name
            let newArtist = isTrackSelected ? (track.proposedArtist ?? track.artist) : track.artist
            let newAlbum = shouldUpdateAlbum && !targetAlbum.isEmpty ? targetAlbum : track.album
            return [track.id, newName, newArtist, newAlbum]
        }

        backups = tracksToUpdate.map {
            TrackBackup(persistentID: $0.id, name: $0.name, artist: $0.artist, album: $0.album)
        }
        backupAlbumName = albumName
        isBusy = true

        let source = #"""
        on run argv
            tell application "Music"
                repeat with i from 1 to (count of argv) by 4
                    set targetID to item i of argv
                    set newName to item (i + 1) of argv
                    set newArtist to item (i + 2) of argv
                    set newAlbum to item (i + 3) of argv
                    try
                        set targetTrack to first track of library playlist 1 whose persistent ID is targetID
                        set name of targetTrack to newName
                        set artist of targetTrack to newArtist
                        set album of targetTrack to newAlbum
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
                for index in tracks.indices {
                    if selectedIDs.contains(tracks[index].id) {
                        tracks[index].name = tracks[index].proposedName ?? tracks[index].name
                        tracks[index].artist = tracks[index].proposedArtist ?? tracks[index].artist
                    }
                    if shouldUpdateAlbum && !targetAlbum.isEmpty {
                        tracks[index].album = targetAlbum
                    }
                }
                if shouldUpdateAlbum && !targetAlbum.isEmpty {
                    albumName = targetAlbum
                }
                canUndo = true
                if shouldUpdateAlbum && !selectedTracks.isEmpty {
                    statusMessage = "已更新專輯為「\(targetAlbum)」並套用 \(selectedTracks.count) 首曲目，可復原"
                } else if shouldUpdateAlbum {
                    statusMessage = "已更新專輯名稱為「\(targetAlbum)」，可復原"
                } else {
                    statusMessage = "已套用 \(selectedTracks.count) 首曲目，可復原"
                }
            }
            isBusy = false
        }
    }

    func undoMetadata() {
        guard canUndo, !backups.isEmpty else { return }
        let args = backups.flatMap { [$0.persistentID, $0.name, $0.artist, $0.album] }
        isBusy = true
        let source = #"""
        on run argv
            tell application "Music"
                repeat with i from 1 to (count of argv) by 4
                    set targetID to item i of argv
                    set oldName to item (i + 1) of argv
                    set oldArtist to item (i + 2) of argv
                    set oldAlbum to item (i + 3) of argv
                    try
                        set targetTrack to first track of library playlist 1 whose persistent ID is targetID
                        set name of targetTrack to oldName
                        set artist of targetTrack to oldArtist
                        set album of targetTrack to oldAlbum
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
                        tracks[index].album = backup.album
                    }
                }
                if let backupAlbumName {
                    albumName = backupAlbumName
                }
                canUndo = false
                backups = []
                backupAlbumName = nil
                statusMessage = "已還原原始專輯與曲目資訊"
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
