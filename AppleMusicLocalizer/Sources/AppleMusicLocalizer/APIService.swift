import Foundation

struct iTunesSearchResponse: Decodable {
    let resultCount: Int
    let results: [iTunesTrack]
}

struct iTunesTrack: Decodable {
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let collectionId: Int64?
    let discNumber: Int?
    let trackNumber: Int?
    let trackTimeMillis: Int?
}

struct iTunesAlbumMatch {
    let collectionName: String
    let tracks: [iTunesTrack]
    let matchedTrackCount: Int
}

enum APIServiceError: LocalizedError {
    case noSearchResults(album: String)
    case noAlbumMatch(album: String, candidates: [String])

    var errorDescription: String? {
        switch self {
        case let .noSearchResults(album):
            return "iTunes API 搜尋不到專輯「\(album)」的結果"
        case let .noAlbumMatch(album, candidates):
            let examples = candidates.prefix(5).joined(separator: "、")
            return "API 有回傳歌曲，但曲目編號無法確認與「\(album)」相符的專輯。候選專輯：\(examples.isEmpty ? "未提供" : examples)"
        }
    }
}

final class APIService {
    static let shared = APIService()
    private init() {}

    /// 單次 Search API 請求取得專輯歌曲候選，再依本機曲目編號重疊度辨識專輯。
    /// iTunes Search API 的單次結果上限為 200 筆；不對每首歌個別發送請求。
    func searchAlbum(artist: String, album: String, localTracks: [LocalTrack], country: String = "jp") async throws -> iTunesAlbumMatch {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(album)"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "200")
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let result = try JSONDecoder().decode(iTunesSearchResponse.self, from: data).results
        guard !result.isEmpty else { throw APIServiceError.noSearchResults(album: album) }
        let localKeys = Set(localTracks.map { "\($0.discNumber):\($0.trackNumber)" })
        let groups = Dictionary(grouping: result.filter { $0.collectionName != nil }) { track in
            track.collectionId.map { "id:\($0)" } ?? "name:\(Self.normalized(track.collectionName ?? ""))"
        }

        let candidates: [iTunesAlbumMatch] = groups.values.compactMap { group in
            guard let name = group.first?.collectionName else { return nil }
            let keys = Set(group.compactMap { track -> String? in
                guard let number = track.trackNumber else { return nil }
                return "\(track.discNumber ?? 1):\(number)"
            })
            let overlap = keys.intersection(localKeys).count
            guard overlap > 0 else { return nil }

            var seenTrackKeys = Set<String>()
            let orderedTracks = group
                .filter { track in
                    guard let number = track.trackNumber else { return true }
                    return seenTrackKeys.insert("\(track.discNumber ?? 1):\(number)").inserted
                }
                .sorted {
                    let leftDisc = $0.discNumber ?? 1
                    let rightDisc = $1.discNumber ?? 1
                    if leftDisc != rightDisc { return leftDisc < rightDisc }
                    return ($0.trackNumber ?? Int.max) < ($1.trackNumber ?? Int.max)
                }
            return iTunesAlbumMatch(collectionName: name, tracks: orderedTracks, matchedTrackCount: overlap)
        }

        guard let best = candidates.sorted(by: {
            if $0.matchedTrackCount != $1.matchedTrackCount { return $0.matchedTrackCount > $1.matchedTrackCount }
            let leftDistance = abs($0.tracks.count - localTracks.count)
            let rightDistance = abs($1.tracks.count - localTracks.count)
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            return $0.collectionName < $1.collectionName
        }).first,
        best.matchedTrackCount >= min(localTracks.count, max(2, (localTracks.count + 1) / 2)) else {
            let names = Array(Set(candidates.map(\.collectionName))).sorted()
            throw APIServiceError.noAlbumMatch(album: album, candidates: names)
        }
        return best
    }

    static func normalized(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
