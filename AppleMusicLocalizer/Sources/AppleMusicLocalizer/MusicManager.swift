import Foundation
import Combine

@MainActor
final class MusicManager: ObservableObject {
    @Published var currentTrackName: String?
    @Published var currentArtistName: String?
    @Published var albumName: String?
    @Published var albumArtistName: String?
    @Published var proposedAlbumName: String?
    @Published var proposedAlbumArtistName: String?
    @Published var updateAlbumName = true
    @Published var tracks: [LocalTrack] = []
    @Published var canUndo = false
    @Published var statusMessage = "就緒"
    @Published var isBusy = false

    private var backups: [TrackBackup] = []
    private var backupAlbumName: String?
    private var backupAlbumArtistName: String?

    var hasAlbumProposal: Bool {
        guard let proposedAlbumName, let albumName else { return false }
        return !proposedAlbumName.isEmpty && !proposedAlbumName.utf8.elementsEqual(albumName.utf8)
    }

    var hasAlbumArtistProposal: Bool {
        guard let proposedAlbumArtistName, let albumArtistName else { return false }
        return !proposedAlbumArtistName.isEmpty && !proposedAlbumArtistName.utf8.elementsEqual(albumArtistName.utf8)
    }

    func fetchCurrentAlbum() {
        isBusy = true
        canUndo = false
        backups = []
        backupAlbumName = nil
        backupAlbumArtistName = nil
        proposedAlbumName = nil
        proposedAlbumArtistName = nil
        tracks = []
        statusMessage = "正在讀取目前歌曲與專輯曲目…"

        let source = #"""
        use framework "Foundation"
        use scripting additions

        on toNFC(str)
            if str is "" then return ""
            return ((current application's NSString's stringWithString:str)'s precomposedStringWithCanonicalMapping()) as text
        end toNFC

        on toNFD(str)
            if str is "" then return ""
            return ((current application's NSString's stringWithString:str)'s decomposedStringWithCanonicalMapping()) as text
        end toNFD

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
                set currentAlbumNFC to my toNFC(currentAlbum)
                set currentAlbumNFD to my toNFD(currentAlbum)
                set matchingTracks to (every track of library playlist 1 whose album is currentAlbumNFC or album is currentAlbumNFD)
                repeat with trackItem in matchingTracks
                    set trackArtist to artist of trackItem as text
                    set trackAlbumArtist to ""
                    try
                        set trackAlbumArtist to album artist of trackItem as text
                    end try
                    if trackAlbumArtist is "" then set trackAlbumArtist to trackArtist
                    if trackAlbumArtist is currentAlbumArtist or trackAlbumArtist is currentArtist or trackArtist is currentArtist or trackArtist is currentAlbumArtist then
                        set trackDuration to ""
                        try
                            set trackDuration to duration of trackItem as text
                        end try
                        set trackSortArtist to ""
                        try
                            set trackSortArtist to sort artist of trackItem as text
                        end try
                        set trackSortAlbum to ""
                        try
                            set trackSortAlbum to sort album of trackItem as text
                        end try
                        set output to output & "TRACK|||" & (disc number of trackItem as text) & "|||" & (track number of trackItem as text) & "|||" & (persistent ID of trackItem as text) & "|||" & (name of trackItem as text) & "|||" & trackArtist & "|||" & (album of trackItem as text) & "|||" & trackDuration & "|||" & trackAlbumArtist & "|||" & trackSortArtist & "|||" & trackSortAlbum & linefeed
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
            let trackAlbumArtist = fields.count >= 9 && !fields[8].isEmpty ? fields[8] : fields[5]
            let trackSortArtist = fields.count >= 10 ? fields[9] : ""
            let trackSortAlbum = fields.count >= 11 ? fields[10] : ""
            localTracks.append(LocalTrack(
                id: fields[3], discNumber: discNumber, trackNumber: trackNumber, name: fields[4],
                artist: fields[5], albumArtist: trackAlbumArtist, sortArtist: trackSortArtist,
                album: fields[6], sortAlbum: trackSortAlbum, durationSeconds: durationSeconds
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

            // 解決 iTunes API 針對同專輯回傳不一致的歌手名稱，並統一正規化為 Unicode NFC
            let matchedAPIArtists = localToRemote.values.compactMap { $0.artistName?.precomposedStringWithCanonicalMapping }
            let mostFrequentAPIArtist = matchedAPIArtists.reduce(into: [:]) { $0[$1, default: 0] += 1 }
                .max(by: { $0.value < $1.value })?.key
            
            let localArtists = tracks.map(\.artist)
            let mostFrequentLocalArtist = localArtists.reduce(into: [:]) { $0[$1, default: 0] += 1 }
                .max(by: { $0.value < $1.value })?.key

            let proposedAlbumNFC = albumMatch.collectionName.precomposedStringWithCanonicalMapping
            proposedAlbumArtistName = mostFrequentAPIArtist

            tracks = tracks.map { local in
                var updated = local
                if let remote = localToRemote[local.id] {
                    updated.proposedName = remote.trackName?.precomposedStringWithCanonicalMapping
                    let remoteArtistNFC = remote.artistName?.precomposedStringWithCanonicalMapping
                    // 若這首本地曲目的歌手是該專輯的主要歌手，則強制統一為 API 上的主要歌手，避免名稱分歧
                    if local.artist == mostFrequentLocalArtist, let unifiedArtist = mostFrequentAPIArtist {
                        updated.proposedArtist = unifiedArtist
                    } else {
                        updated.proposedArtist = remoteArtistNFC
                    }
                    updated.proposedAlbumArtist = mostFrequentAPIArtist ?? updated.proposedArtist
                    updated.proposedAlbum = proposedAlbumNFC
                }
                return updated
            }
            proposedAlbumName = proposedAlbumNFC
            updateAlbumName = !proposedAlbumNFC.utf8.elementsEqual((albumName ?? "").utf8)
            let mapped = tracks.filter(\.hasProposal).count
            if mapped == 0 && !hasAlbumProposal && !hasAlbumArtistProposal {
                statusMessage = "API 專輯「\(proposedAlbumNFC)」配對成功，目前專輯與曲目皆已為原文名稱（可點選右側強制合併同名分類）"
            } else {
                statusMessage = "API 專輯「\(proposedAlbumNFC)」配對成功，共 \(mapped) 首可套用"
            }
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

    /// 批次套用已勾選曲目，或強制合併 Apple Music 中重複的同名歌手與同名專輯分類
    func applySelectedMetadata(forceMergeAll: Bool = false) {
        guard !tracks.isEmpty else { return }
        let selectedTracks = forceMergeAll ? tracks : tracks.filter { $0.isSelected && $0.hasProposal }
        let shouldUpdateAlbum = forceMergeAll || (updateAlbumName && hasAlbumProposal)
        guard forceMergeAll || !selectedTracks.isEmpty || shouldUpdateAlbum else {
            statusMessage = "請先勾選至少一首有建議名稱的曲目，或勾選更新專輯名稱"
            return
        }

        let selectedIDs = Set(selectedTracks.map(\.id))
        let targetAlbum = (shouldUpdateAlbum ? (proposedAlbumName ?? albumName ?? "") : (albumName ?? "")).precomposedStringWithCanonicalMapping
        let targetAlbumArtist = (proposedAlbumArtistName ?? selectedTracks.first?.proposedAlbumArtist ?? selectedTracks.first?.proposedArtist ?? albumArtistName ?? "").precomposedStringWithCanonicalMapping
        // 始終對同專輯所有曲目統一寫入專輯名稱、專輯演出者與排序欄位，徹底防止同張專輯在 Apple Music 中被拆散為兩個分類
        let tracksToUpdate = tracks

        let args = [targetAlbumArtist] + tracksToUpdate.flatMap { track -> [String] in
            let isTrackSelected = selectedIDs.contains(track.id)
            let newName = (isTrackSelected ? (track.proposedName ?? track.name) : track.name).precomposedStringWithCanonicalMapping
            let newArtist = (isTrackSelected ? (track.proposedArtist ?? track.artist) : (track.proposedArtist ?? track.artist)).precomposedStringWithCanonicalMapping
            let newAlbumArtist = (track.proposedAlbumArtist ?? (!targetAlbumArtist.isEmpty ? targetAlbumArtist : newArtist)).precomposedStringWithCanonicalMapping
            let newAlbum = (!targetAlbum.isEmpty ? targetAlbum : track.album).precomposedStringWithCanonicalMapping
            return [track.id, newName, newArtist, newAlbumArtist, newAlbum]
        }

        backups = tracksToUpdate.map {
            TrackBackup(
                persistentID: $0.id, name: $0.name, artist: $0.artist,
                albumArtist: $0.albumArtist, sortArtist: $0.sortArtist,
                album: $0.album, sortAlbum: $0.sortAlbum
            )
        }
        backupAlbumName = albumName
        backupAlbumArtistName = albumArtistName
        isBusy = true
        statusMessage = "正在寫入原文資訊並合併 Apple Music 同名歌手與專輯分類…"

        let source = #"""
        use framework "Foundation"
        use scripting additions

        on toNFC(str)
            if str is "" then return ""
            return ((current application's NSString's stringWithString:str)'s precomposedStringWithCanonicalMapping()) as text
        end toNFC

        on toNFD(str)
            if str is "" then return ""
            return ((current application's NSString's stringWithString:str)'s decomposedStringWithCanonicalMapping()) as text
        end toNFD

        on run argv
            set targetArtistNFC to my toNFC(item 1 of argv)
            set targetArtistNFD to my toNFD(targetArtistNFC)
            set tempArtist to targetArtistNFC & "_merge"

            tell application "Music"
                -- 第一階段：更新目前專輯所有曲目，並先將 album 設為暫存名以強制 Music.app 重建專輯索引（消除兩個同名專輯）
                repeat with i from 2 to (count of argv) by 5
                    set targetID to item i of argv
                    set newName to my toNFC(item (i + 1) of argv)
                    set newArtist to my toNFC(item (i + 2) of argv)
                    set newAlbumArtist to my toNFC(item (i + 3) of argv)
                    set newAlbum to my toNFC(item (i + 4) of argv)
                    try
                        set targetTrack to first track of library playlist 1 whose persistent ID is targetID
                        set name of targetTrack to newName
                        try
                            if (sort name of targetTrack as text) is not "" then
                                set sort name of targetTrack to newName
                            end if
                        end try
                        set sort artist of targetTrack to newArtist
                        set sort album artist of targetTrack to newAlbumArtist
                        set sort album of targetTrack to newAlbum
                        set artist of targetTrack to newArtist
                        set album artist of targetTrack to newAlbumArtist
                        set album of targetTrack to (newAlbum & "_merge")
                    on error errorMessage
                        return "ERROR|||" & errorMessage
                    end try
                end repeat

                -- 第二階段：將目前專輯所有曲目的 album 統一寫回正式 NFC 名稱，使所有曲目歸戶至單一專輯
                repeat with i from 2 to (count of argv) by 5
                    set targetID to item i of argv
                    set newAlbum to my toNFC(item (i + 4) of argv)
                    try
                        set targetTrack to first track of library playlist 1 whose persistent ID is targetID
                        set album of targetTrack to newAlbum
                    on error errorMessage
                        return "ERROR|||" & errorMessage
                    end try
                end repeat

                -- 第三階段：掃描本機資料庫中所有已為該原文歌手（含 NFC/NFD）的曲目，統一其 sort artist / album artist 並強制合併同名歌手分類
                if targetArtistNFC is not "" then
                    set sameArtistTracks to (every track of library playlist 1 whose artist is targetArtistNFC or artist is targetArtistNFD or album artist is targetArtistNFC or album artist is targetArtistNFD)
                    repeat with t in sameArtistTracks
                        try
                            set tNameNFC to my toNFC(name of t as text)
                            set tAlbumNFC to my toNFC(album of t as text)
                            if (name of t as text) is not tNameNFC then set name of t to tNameNFC
                            set sort artist of t to targetArtistNFC
                            set sort album artist of t to targetArtistNFC
                            set sort album of t to tAlbumNFC
                            if (album of t as text) is not tAlbumNFC then
                                set album of t to (tAlbumNFC & "_merge")
                                set album of t to tAlbumNFC
                            end if
                            set artist of t to tempArtist
                            set album artist of t to tempArtist
                        end try
                    end repeat
                    repeat with t in sameArtistTracks
                        try
                            set artist of t to targetArtistNFC
                            set album artist of t to targetArtistNFC
                        end try
                    end repeat
                end if
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
                    let isTrackSelected = selectedIDs.contains(tracks[index].id)
                    let appliedName = (isTrackSelected ? (tracks[index].proposedName ?? tracks[index].name) : tracks[index].name).precomposedStringWithCanonicalMapping
                    let appliedArtist = (tracks[index].proposedArtist ?? tracks[index].artist).precomposedStringWithCanonicalMapping
                    let appliedAlbumArtist = (tracks[index].proposedAlbumArtist ?? (!targetAlbumArtist.isEmpty ? targetAlbumArtist : appliedArtist)).precomposedStringWithCanonicalMapping
                    let appliedAlbum = (!targetAlbum.isEmpty ? targetAlbum : tracks[index].album).precomposedStringWithCanonicalMapping
                    tracks[index].name = appliedName
                    tracks[index].artist = appliedArtist
                    tracks[index].albumArtist = appliedAlbumArtist
                    tracks[index].sortArtist = appliedArtist
                    tracks[index].album = appliedAlbum
                    tracks[index].sortAlbum = appliedAlbum
                }
                if !targetAlbumArtist.isEmpty {
                    albumArtistName = targetAlbumArtist
                    currentArtistName = targetAlbumArtist
                }
                if !targetAlbum.isEmpty {
                    albumName = targetAlbum
                }
                canUndo = true
                if forceMergeAll {
                    statusMessage = "已強制統一並合併「\(targetAlbumArtist)」與「\(targetAlbum)」的所有同名分類，可復原"
                } else if shouldUpdateAlbum && !selectedTracks.isEmpty {
                    statusMessage = "已更新專輯為「\(targetAlbum)」並套用 \(selectedTracks.count) 首曲目（含同名分類合併），可復原"
                } else if shouldUpdateAlbum {
                    statusMessage = "已更新專輯名稱為「\(targetAlbum)」（含同名分類合併），可復原"
                } else {
                    statusMessage = "已套用 \(selectedTracks.count) 首曲目並合併同名歌手／專輯分類，可復原"
                }
            }
            isBusy = false
        }
    }

    func undoMetadata() {
        guard canUndo, !backups.isEmpty else { return }
        let args = backups.flatMap {
            [$0.persistentID, $0.name, $0.artist, $0.albumArtist, $0.sortArtist, $0.album, $0.sortAlbum]
        }
        isBusy = true
        let source = #"""
        use framework "Foundation"
        use scripting additions

        on toNFC(str)
            if str is "" then return ""
            return ((current application's NSString's stringWithString:str)'s precomposedStringWithCanonicalMapping()) as text
        end toNFC

        on run argv
            tell application "Music"
                repeat with i from 1 to (count of argv) by 7
                    set targetID to item i of argv
                    set oldName to my toNFC(item (i + 1) of argv)
                    set oldArtist to my toNFC(item (i + 2) of argv)
                    set oldAlbumArtist to my toNFC(item (i + 3) of argv)
                    set oldSortArtist to my toNFC(item (i + 4) of argv)
                    set oldAlbum to my toNFC(item (i + 5) of argv)
                    set oldSortAlbum to my toNFC(item (i + 6) of argv)
                    try
                        set targetTrack to first track of library playlist 1 whose persistent ID is targetID
                        set name of targetTrack to oldName
                        set artist of targetTrack to oldArtist
                        set album artist of targetTrack to oldAlbumArtist
                        if oldSortArtist is not "" then
                            set sort artist of targetTrack to oldSortArtist
                        end if
                        if oldSortAlbum is not "" then
                            set sort album of targetTrack to oldSortAlbum
                        end if
                        set album of targetTrack to (oldAlbum & "_merge")
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
                        tracks[index].albumArtist = backup.albumArtist
                        tracks[index].sortArtist = backup.sortArtist
                        tracks[index].album = backup.album
                        tracks[index].sortAlbum = backup.sortAlbum
                    }
                }
                if let backupAlbumArtistName {
                    albumArtistName = backupAlbumArtistName
                }
                if let backupAlbumName {
                    albumName = backupAlbumName
                }
                canUndo = false
                backups = []
                backupAlbumName = nil
                backupAlbumArtistName = nil
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
