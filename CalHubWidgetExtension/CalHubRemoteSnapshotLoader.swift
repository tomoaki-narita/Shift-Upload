import Foundation
import Security

enum CalHubRemoteSnapshotLoader {
    private static let keychainService = "net.unwraps.Shift-Upload"
    private static let accessGroup = "DU562ND7L2.net.unwraps.Shift-Hub.shared"

    static func refresh(_ snapshot: CalHubWidgetSnapshot) async -> CalHubWidgetSnapshot? {
        guard let configuration = snapshot.remoteConfiguration else { return nil }
        do {
            let events: [CalHubWidgetEvent]
            switch snapshot.sourceKind {
            case "google":
                events = try await googleEvents(configuration: configuration, snapshot: snapshot)
            case "notion":
                events = try await notionEvents(configuration: configuration, snapshot: snapshot)
            default:
                return nil
            }
            return CalHubWidgetSnapshot(
                configurationKey: snapshot.configurationKey,
                localeIdentifier: snapshot.localeIdentifier,
                updatedAt: .now,
                events: events,
                sourceKind: snapshot.sourceKind,
                appleCalendarIdentifier: snapshot.appleCalendarIdentifier,
                remoteConfiguration: configuration
            )
        } catch {
            return nil
        }
    }

    private static func googleEvents(
        configuration: CalHubWidgetRemoteConfiguration,
        snapshot: CalHubWidgetSnapshot
    ) async throws -> [CalHubWidgetEvent] {
        guard var tokens = googleTokens(),
              let clientID = keychainString(account: "google-oauth-client-id") else {
            throw URLError(.userAuthenticationRequired)
        }
        if tokens.expiresAt.timeIntervalSinceNow < 5 * 60 {
            tokens = try await refreshGoogleTokens(tokens, clientID: clientID)
        }
        let calendarIDs = configuration.googleShowJapaneseHolidays
            ? [configuration.googleCalendarID, "ja.japanese#holiday@group.v.calendar.google.com"]
            : [configuration.googleCalendarID]
        let range = dateRange()
        var events: [CalHubWidgetEvent] = []
        for calendarID in calendarIDs where !calendarID.isEmpty {
            var components = URLComponents(
                string: "https://www.googleapis.com/calendar/v3/calendars/\(calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID)/events"
            )
            components?.queryItems = [
                URLQueryItem(name: "timeMin", value: iso8601(range.start)),
                URLQueryItem(name: "timeMax", value: iso8601(range.end)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: "2500")
            ]
            guard let url = components?.url else { continue }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            let data = try await responseData(for: request)
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let items = payload?["items"] as? [[String: Any]] ?? []
            events.append(contentsOf: items.compactMap { googleEvent($0, snapshot: snapshot) })
        }
        return deduplicated(events)
    }

    private static func notionEvents(
        configuration: CalHubWidgetRemoteConfiguration,
        snapshot: CalHubWidgetSnapshot
    ) async throws -> [CalHubWidgetEvent] {
        guard let token = keychainString(account: "notion-access-token"),
              !configuration.notionDataSourceID.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        let range = dateRange()
        guard let url = URL(string: "https://api.notion.com/v1/databases/\(configuration.notionDataSourceID)/query") else {
            throw URLError(.badURL)
        }
        let dateFilter: [String: Any] = [
            "property": configuration.notionDateProperty,
            "date": [
                "on_or_after": dayString(range.start),
                "before": dayString(range.end)
            ]
        ]
        let configuredTagValues = notionTagValues(from: configuration.notionTagValue)
        let filter: [String: Any]
        if !configuration.notionTagProperty.isEmpty, !configuredTagValues.isEmpty {
            let tagFilters = configuredTagValues.map { value in
                [
                    "property": configuration.notionTagProperty,
                    "multi_select": ["contains": value]
                ]
            }
            let tagFilter: [String: Any] = tagFilters.count == 1
                ? tagFilters[0]
                : ["or": tagFilters]
            filter = [
                "and": [
                    dateFilter,
                    tagFilter
                ]
            ]
        } else {
            filter = dateFilter
        }

        var cursor: String?
        var events: [CalHubWidgetEvent] = []
        var requestedCursors = Set<String>()
        var pageCount = 0
        repeat {
            if let cursor, !requestedCursors.insert(cursor).inserted { break }
            pageCount += 1
            guard pageCount <= 100 else { break }

            var body: [String: Any] = [
                "page_size": 100,
                "filter": filter
            ]
            if let cursor {
                body["start_cursor"] = cursor
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let data = try await responseData(for: request)
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pages = payload["results"] as? [[String: Any]] else {
                throw URLError(.cannotParseResponse)
            }
            events.append(contentsOf: pages.compactMap {
                notionEvent($0, configuration: configuration, snapshot: snapshot)
            })
            cursor = payload["has_more"] as? Bool == true
                ? payload["next_cursor"] as? String
                : nil
        } while cursor != nil
        return deduplicated(events)
    }

    private static func notionTagValues(from encodedValue: String) -> [String] {
        guard let data = encodedValue.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return encodedValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func googleEvent(
        _ item: [String: Any],
        snapshot: CalHubWidgetSnapshot
    ) -> CalHubWidgetEvent? {
        guard let id = item["id"] as? String,
              let startObject = item["start"] as? [String: Any] else { return nil }
        let endObject = item["end"] as? [String: Any]
        let isAllDay = startObject["date"] != nil
        guard let start = parsedDate(startObject["dateTime"] as? String ?? startObject["date"] as? String) else {
            return nil
        }
        let end = parsedDate(endObject?["dateTime"] as? String ?? endObject?["date"] as? String)
        let title = (item["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        let accent = snapshot.events.first.map { ($0.red, $0.green, $0.blue) }
        return CalHubWidgetEvent(
            id: id, title: title, detail: isAllDay ? "All day" : "",
            date: Calendar.current.startOfDay(for: start), startDate: start,
            endDate: isAllDay ? nil : end, isAllDay: isAllDay,
            isRestEvent: isRest(title), red: accent?.0, green: accent?.1, blue: accent?.2
        )
    }

    private static func notionEvent(
        _ page: [String: Any],
        configuration: CalHubWidgetRemoteConfiguration,
        snapshot: CalHubWidgetSnapshot
    ) -> CalHubWidgetEvent? {
        guard let id = page["id"] as? String,
              let properties = page["properties"] as? [String: Any],
              let dateProperty = properties[configuration.notionDateProperty] as? [String: Any],
              let dateObject = dateProperty["date"] as? [String: Any],
              let startText = dateObject["start"] as? String,
              let start = parsedDate(startText) else { return nil }
        let end = parsedDate(dateObject["end"] as? String)
        let titleProperty = properties[configuration.notionTitleProperty] as? [String: Any]
        let titleParts = titleProperty?["title"] as? [[String: Any]] ?? []
        let title = titleParts.compactMap { ($0["plain_text"] as? String) }.joined()
        let resolvedTitle = title.isEmpty ? "Untitled" : title
        let isAllDay = !startText.contains("T")
        let accent = snapshot.events.first.map { ($0.red, $0.green, $0.blue) }
        return CalHubWidgetEvent(
            id: id, title: resolvedTitle, detail: isAllDay ? "All day" : "",
            date: Calendar.current.startOfDay(for: start), startDate: start,
            endDate: isAllDay ? nil : end, isAllDay: isAllDay,
            isRestEvent: isRest(resolvedTitle), red: accent?.0, green: accent?.1, blue: accent?.2
        )
    }

    private struct GoogleTokens: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    private static func googleTokens() -> GoogleTokens? {
        guard let value = keychainString(account: "google-calendar-oauth-tokens"),
              let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GoogleTokens.self, from: data)
    }

    private static func refreshGoogleTokens(
        _ tokens: GoogleTokens,
        clientID: String
    ) async throws -> GoogleTokens {
        var components = URLComponents()
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "refresh_token", value: tokens.refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        if let secret = keychainString(account: "google-oauth-client-secret"), !secret.isEmpty {
            items.append(URLQueryItem(name: "client_secret", value: secret))
        }
        components.queryItems = items
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let data = try await responseData(for: request)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = payload["access_token"] as? String,
              let expiresIn = payload["expires_in"] as? Double else {
            throw URLError(.cannotParseResponse)
        }
        let refreshed = GoogleTokens(
            accessToken: accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: .now.addingTimeInterval(expiresIn)
        )
        if let data = try? JSONEncoder().encode(refreshed),
           let value = String(data: data, encoding: .utf8) {
            setKeychainString(value, account: "google-calendar-oauth-tokens")
        }
        return refreshed
    }

    private static func responseData(for request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func dateRange() -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let monthStart = calendar.dateInterval(of: .month, for: start)?.start ?? start
        let end = calendar.date(byAdding: .month, value: 2, to: monthStart) ?? start.addingTimeInterval(60 * 24 * 60 * 60)
        return (start, end)
    }

    private static func parsedDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if value.contains("T") {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }
            return ISO8601DateFormatter().date(from: value)
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func isRest(_ title: String) -> Bool {
        let value = title.folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        return ["休", "休み", "休日", "off"].contains(value)
    }

    private static func deduplicated(_ events: [CalHubWidgetEvent]) -> [CalHubWidgetEvent] {
        var ids = Set<String>()
        return events.filter { ids.insert($0.id).inserted }
    }

    private static func keychainString(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func setKeychainString(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let attributes = [kSecValueData as String: Data(value.utf8)]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
