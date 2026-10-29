import Foundation

/// Steam's public store answers, read into the games list's facts. The games-list builder calls these for
/// every Steam game it knows; the app calls them for a game someone searches for that the list lacks.
public enum SteamStore {
    // Steam's category ids (stable across languages)
    static let singlePlayer = 2, fullController = 28, partialController = 18
    static let controllerWorksToken = "#SteamDeckVerified_TestResult_DefaultControllerConfigFullyFunctional"
    static let passed = 4   // a Deck test result's display_type when it passed

    public static func appdetailsURL(_ appID: Int) -> URL {
        URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&cc=us&l=en")!
    }

    public static func deckReportURL(_ appID: Int) -> URL {
        URL(string: "https://store.steampowered.com/saleaction/ajaxgetdeckappcompatibilityreport?nAppID=\(appID)&l=english")!
    }

    /// The store's list of a game's art files (GetItems, no key): newer games keep theirs at hashed paths.
    public static func itemsURL(_ appID: Int) -> URL {
        let request = #"{"ids":[{"appid":\#(appID)}],"context":{"language":"english","country_code":"US"},"data_request":{"include_assets":true}}"#
        var parts = URLComponents(string: "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/")!
        parts.queryItems = [URLQueryItem(name: "input_json", value: request)]
        return parts.url!
    }

    /// A game's art files by Steam's name for each ("library_capsule", "library_hero"), as paths under the CDN's
    /// store_item_assets/; empty when Steam has none for the game; nil when the body isn't a GetItems answer.
    public static func assets(_ data: Data, appID: Int) -> [String: String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (root["response"] as? [String: Any])?["store_items"] as? [[String: Any]] else { return nil }
        guard let assets = items.first(where: { $0["id"] as? Int == appID })?["assets"] as? [String: Any],
              let format = assets["asset_url_format"] as? String else { return [:] }
        var out: [String: String] = [:]
        for case let (name, file as String) in assets where name != "asset_url_format" {
            out[name] = format.replacingOccurrences(of: "${FILENAME}", with: file)
        }
        return out
    }

    /// The search term: Steam's search finds nothing when the name holds a spaced dash ("Castlevania - Belmont's Curse",
    /// how folder names write a colon), so colons and spaced dashes become spaces. Matching stays exact (exactMatch).
    public static func searchURL(_ term: String) -> URL {
        let words = term.replacingOccurrences(of: #"\s*:\s*|\s+[-\u2013\u2014]+\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        var parts = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        parts.queryItems = [URLQueryItem(name: "term", value: words), URLQueryItem(name: "cc", value: "us"), URLQueryItem(name: "l", value: "en")]
        return parts.url!
    }

    /// The games a store search found, in Steam's order; nil when the body isn't a search answer.
    public static func searchResults(_ data: Data) -> [(id: Int, name: String)]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            return (id, name)
        }
    }

    /// The one search result whose name is `name` (GameName.normalized, editions kept, so a "Definitive Edition"
    /// remake never stands in for the original); nil when none or several fit.
    public static func exactMatch(_ results: [(id: Int, name: String)], for name: String) -> Int? {
        let key = GameName.normalized(name, dropEdition: false)
        let same = Set(results.filter { GameName.normalized($0.name, dropEdition: false) == key }.map(\.id))
        return same.count == 1 ? same.first : nil
    }

    /// Nil when Steam has no data for the game ("success": false), the app isn't a game, or the body isn't its appdetails.
    public static func storeFacts(appdetails: Data, appID: Int, checked: String) -> (name: String, facts: StoreFacts)? {
        guard let root = try? JSONSerialization.jsonObject(with: appdetails) as? [String: Any],
              let app = root[String(appID)] as? [String: Any], app["success"] as? Bool == true,
              let data = app["data"] as? [String: Any], let name = data["name"] as? String,
              data["type"] as? String == "game" else { return nil }   // not a delisted game's "advertising" page
        let categories = Set((data["categories"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int })
        let controller: ControllerCategory? = categories.contains(fullController) ? .full
            : categories.contains(partialController) ? .partial : nil
        let mac = (data["platforms"] as? [String: Any])?["mac"] as? Bool ?? false
        return (name, StoreFacts(macVersion: mac, singlePlayer: categories.contains(singlePlayer),
                                 controller: controller, checked: checked))
    }

    public static func deckFacts(report: Data, checked: String) -> DeckFacts? {
        guard let root = try? JSONSerialization.jsonObject(with: report) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let raw = results["resolved_category"] as? Int else { return nil }
        let items = results["resolved_items"] as? [[String: Any]] ?? []
        let controllerWorks = items.contains {
            $0["loc_token"] as? String == controllerWorksToken && $0["display_type"] as? Int == passed
        }
        return DeckFacts(category: DeckCategory(rawValue: raw) ?? .unknown, controllerWorks: controllerWorks, checked: checked)
    }
}
