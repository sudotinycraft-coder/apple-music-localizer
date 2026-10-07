import Foundation

/// 代表本機 Apple Music 資料庫中的單一曲目。
struct LocalTrack: Identifiable {
    let id: String                 // Music.app persistent ID，用於精準寫入及復原
    let discNumber: Int
    let trackNumber: Int
    var name: String
    var artist: String
    var albumArtist: String
    var sortArtist: String
    var album: String
    var sortAlbum: String
    let durationSeconds: Double

    var proposedName: String?
    var proposedArtist: String?
    var proposedAlbumArtist: String?
    var proposedAlbum: String?
    var isSelected = true

    var hasProposal: Bool {
        guard let proposedName else { return false }
        if !proposedName.utf8.elementsEqual(name.utf8) { return true }
        if let proposedArtist, !proposedArtist.utf8.elementsEqual(artist.utf8) { return true }
        if let proposedAlbumArtist, !proposedAlbumArtist.utf8.elementsEqual(albumArtist.utf8) { return true }
        if let proposedArtist, !sortArtist.isEmpty, !sortArtist.utf8.elementsEqual(proposedArtist.utf8) { return true }
        if let proposedAlbum, !sortAlbum.isEmpty, !sortAlbum.utf8.elementsEqual(proposedAlbum.utf8) { return true }
        return false
    }
}

struct TrackBackup {
    let persistentID: String
    let name: String
    let artist: String
    let albumArtist: String
    let sortArtist: String
    let album: String
    let sortAlbum: String
}
