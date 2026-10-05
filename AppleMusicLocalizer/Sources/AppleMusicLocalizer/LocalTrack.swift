import Foundation

/// 代表本機 Apple Music 資料庫中的單一曲目。
struct LocalTrack: Identifiable {
    let id: String                 // Music.app persistent ID，用於精準寫入及復原
    let discNumber: Int
    let trackNumber: Int
    var name: String
    var artist: String
    let album: String
    let durationMs: Int

    var proposedName: String?
    var proposedArtist: String?
    var isSelected = true

    var hasProposal: Bool {
        guard let proposedName else { return false }
        return proposedName != name || (proposedArtist != nil && proposedArtist != artist)
    }
}

struct TrackBackup {
    let persistentID: String
    let name: String
    let artist: String
}
