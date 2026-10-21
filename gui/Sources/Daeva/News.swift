import Foundation

struct NewsItem: Identifiable, Decodable {
    let gid: String
    let title: String
    let url: String
    let date: TimeInterval
    let feedname: String

    var id: String { gid }
    var published: Date { Date(timeIntervalSince1970: date) }

    /// "[Notice] Patch Notes | ..." -> ("Notice", "Patch Notes | ...")
    var parts: (tag: String?, title: String) {
        guard title.hasPrefix("["), let end = title.firstIndex(of: "]") else { return (nil, title) }
        let tag = String(title[title.index(after: title.startIndex)..<end])
        return (tag, title[title.index(after: end)...].trimmingCharacters(in: .whitespaces))
    }
}

enum News {
    private struct Response: Decodable {
        struct Inner: Decodable { let newsitems: [NewsItem] }
        let appnews: Inner
    }

    static func fetch(appID: String, count: Int = 12) async -> [NewsItem] {
        var c = URLComponents(string: "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/")!
        c.queryItems = [.init(name: "appid", value: appID), .init(name: "count", value: "\(count)"),
                        .init(name: "maxlength", value: "1"), .init(name: "format", value: "json")]
        guard let (data, _) = try? await URLSession.shared.data(from: c.url!),
              let r = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return r.appnews.newsitems.filter { $0.feedname == "steam_community_announcements" }
    }
}
