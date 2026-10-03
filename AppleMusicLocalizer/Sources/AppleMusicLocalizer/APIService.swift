import Foundation

struct iTunesSearchResponse: Codable {
    let resultCount: Int
    let results: [iTunesTrack]
}

struct iTunesTrack: Codable {
    let trackName: String?
    let artistName: String?
    let collectionName: String?
}

class APIService {
    static let shared = APIService()
    
    func searchTrack(artist: String, track: String, country: String = "jp") async throws -> iTunesTrack? {
        // 建構搜尋關鍵字
        let searchTerm = "\(artist) \(track)"
        
        // 將字串進行 URL Encode
        guard let encodedTerm = searchTerm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encodedTerm)&country=\(country)&entity=song&limit=1") else {
            throw URLError(.badURL)
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoder = JSONDecoder()
        let response = try decoder.decode(iTunesSearchResponse.self, from: data)
        
        return response.results.first
    }
}
