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
        var firstAppearanceRank: [String: Int] = [:]
        var groupedTracks: [String: [iTunesTrack]] = [:]
        for (index, track) in result.enumerated() {
            guard let colName = track.collectionName else { continue }
            let key = track.collectionId.map { "id:\($0)" } ?? "name:\(Self.normalized(colName))"
            if firstAppearanceRank[key] == nil {
                firstAppearanceRank[key] = index
            }
            groupedTracks[key, default: []].append(track)
        }

        struct CandidateGroup {
            let match: iTunesAlbumMatch
            let searchRank: Int
        }

        let candidates: [CandidateGroup] = groupedTracks.compactMap { key, group in
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
            let match = iTunesAlbumMatch(collectionName: name, tracks: orderedTracks, matchedTrackCount: overlap)
            return CandidateGroup(match: match, searchRank: firstAppearanceRank[key] ?? Int.max)
        }

        struct CandidateScore {
            let match: iTunesAlbumMatch
            let isDurationPlausible: Bool
            let artistScore: Int       // 3: 完全吻合, 2: 長字串包含關係, 0: 無關或跨語系別名
            let overlapCount: Int
            let avgDurationDiff: Double
            let searchRank: Int        // iTunes Search API 原生相關性排名 (越小越相關)
            let countDistance: Int
        }

        let localNormArtists = Set(([artist] + localTracks.map(\.artist)).map(Self.normalized).filter { !$0.isEmpty })

        let scoredCandidates: [CandidateScore] = candidates.map { item in
            let candidate = item.match
            let candidateArtist = candidate.tracks.first?.artistName ?? ""
            let remoteNormArtist = Self.normalized(candidateArtist)

            var artistScore = 0
            if !remoteNormArtist.isEmpty {
                if localNormArtists.contains(remoteNormArtist) {
                    artistScore = 3
                } else if remoteNormArtist.count >= 4,
                          localNormArtists.contains(where: { $0.count >= 4 && ($0.contains(remoteNormArtist) || remoteNormArtist.contains($0)) }) {
                    // 限制至少 4 個字元才允許子字串包含比對，防止如 "RU" 誤匹配 "yoRUshika"
                    artistScore = 2
                }
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
            let isDurationPlausible = matchedDurationCount == 0 || avgDiff <= 4.0

            return CandidateScore(
                match: candidate,
                isDurationPlausible: isDurationPlausible,
                artistScore: artistScore,
                overlapCount: candidate.matchedTrackCount,
                avgDurationDiff: avgDiff,
                searchRank: item.searchRank,
                countDistance: abs(candidate.tracks.count - localTracks.count)
            )
        }

        // 排序優先級：
        // 1. 時長合理性 (isDurationPlausible：平均時長誤差 <= 4 秒者優先)
        // 2. 歌手相符度 (artistScore)
        // 3. 軌數重疊最多 (overlapCount)
        // 4. 平均時長誤差最小 (精確至 0.1 秒，原曲母帶通常誤差接近 0.0 秒，能區分翻唱版)
        // 5. iTunes API 原生搜尋相關性順位 (searchRank，Apple 後端具備跨語系藝人/曲名映射能力，原曲通常排第 1)
        // 6. 曲目總數最接近 (countDistance)
        let sorted = scoredCandidates.sorted {
            if $0.isDurationPlausible != $1.isDurationPlausible { return $0.isDurationPlausible && !$1.isDurationPlausible }
            if $0.artistScore != $1.artistScore { return $0.artistScore > $1.artistScore }
            if $0.overlapCount != $1.overlapCount { return $0.overlapCount > $1.overlapCount }
            if abs($0.avgDurationDiff - $1.avgDurationDiff) > 0.1 { return $0.avgDurationDiff < $1.avgDurationDiff }
            if $0.searchRank != $1.searchRank { return $0.searchRank < $1.searchRank }
            return $0.countDistance < $1.countDistance
        }

        guard let bestScore = sorted.first,
              bestScore.overlapCount >= min(localTracks.count, max(1, (localTracks.count + 1) / 2)) else {
            let names = Array(Set(candidates.map(\.match.collectionName))).sorted()
            throw APIServiceError.noAlbumMatch(album: album, candidates: names)
        }
        return bestScore.match
    }

    static func normalized(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
