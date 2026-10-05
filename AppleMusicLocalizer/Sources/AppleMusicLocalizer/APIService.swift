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

        struct CandidateScore {
            let match: iTunesAlbumMatch
            let artistScore: Int       // 3: 完全吻合, 2: 包含關係, 0: 無關
            let overlapCount: Int
            let countDistance: Int
            let avgDurationDiff: Double
        }

        let localNormArtist = Self.normalized(artist)

        let scoredCandidates: [CandidateScore] = candidates.map { candidate in
            let candidateArtist = candidate.tracks.first?.artistName ?? ""
            let remoteNormArtist = Self.normalized(candidateArtist)

            let artistScore: Int
            if !localNormArtist.isEmpty && localNormArtist == remoteNormArtist {
                artistScore = 3
            } else if !localNormArtist.isEmpty && (localNormArtist.contains(remoteNormArtist) || remoteNormArtist.contains(localNormArtist)) {
                artistScore = 2
            } else {
                artistScore = 0
            }

            // 計算與本機曲目的平均時長誤差
            var totalDiff = 0.0
            var matchedDurationCount = 0
            for local in localTracks where local.durationSeconds > 0 {
                if let remote = candidate.tracks.first(where: {
                    ($0.discNumber ?? 1) == local.discNumber && ($0.trackNumber ?? 0) == local.trackNumber
                }), let rMs = remote.trackTimeMillis {
                    totalDiff += abs((Double(rMs) / 1000.0) - local.durationSeconds)
                    matchedDurationCount += 1
                }
            }
            let avgDiff = matchedDurationCount > 0 ? (totalDiff / Double(matchedDurationCount)) : 999.0

            return CandidateScore(
                match: candidate,
                artistScore: artistScore,
                overlapCount: candidate.matchedTrackCount,
                countDistance: abs(candidate.tracks.count - localTracks.count),
                avgDurationDiff: avgDiff
            )
        }

        // 排序優先級：
        // 1. 歌手相符度最高 (artistScore)
        // 2. 軌數重疊最多 (overlapCount)
        // 3. 平均時長誤差最小 (avgDurationDiff)
        // 4. 曲目總數最接近 (countDistance)
        let sorted = scoredCandidates.sorted {
            if $0.artistScore != $1.artistScore { return $0.artistScore > $1.artistScore }
            if $0.overlapCount != $1.overlapCount { return $0.overlapCount > $1.overlapCount }
            if abs($0.avgDurationDiff - $1.avgDurationDiff) > 0.5 { return $0.avgDurationDiff < $1.avgDurationDiff }
            return $0.countDistance < $1.countDistance
        }

        guard let bestScore = sorted.first,
              bestScore.overlapCount >= min(localTracks.count, max(1, (localTracks.count + 1) / 2)) else {
            let names = Array(Set(candidates.map(\.collectionName))).sorted()
            throw APIServiceError.noAlbumMatch(album: album, candidates: names)
        }
        return bestScore.match
    }

    static func normalized(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
