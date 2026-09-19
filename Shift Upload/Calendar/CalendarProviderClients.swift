import Combine
import CryptoKit
import EventKit
import Foundation
import AuthenticationServices
import Network

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// Apple, Google, and Notion calendar clients and registration writers.
private struct NotionRegistrationResult {
    let savedCount: Int
    let skippedTitles: [String]
}

private struct NotionPropertyOption: Identifiable, Hashable {
    let name: String
    let type: String
    let options: [String]

    var id: String { "\(name)|\(type)" }

    var displayName: String {
        "\(name)（\(type)）"
    }

    func displayName(for locale: Locale) -> String {
        ShiftHubLocalization.isEnglish(locale) ? "\(name) (\(type))" : displayName
    }
}

private struct NotionDatabaseSchema {
    let title: String
    let properties: [NotionPropertyOption]
}

private struct NotionSchemaClient {
    func fetchSchema(
        token: String,
        databaseID: String,
        localeIdentifier: String
    ) async throws -> NotionDatabaseSchema {
        guard let url = URL(string: "https://api.notion.com/v1/databases/\(databaseID)") else {
            throw NotionAPIError.invalidSettings
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NotionAPIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = responseObject?["message"] as? String ?? "不明なエラー"
            throw NotionAPIError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        guard let responseObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = responseObject["properties"] as? [String: Any] else {
            throw NotionAPIError.invalidResponse
        }

        let title = (responseObject["title"] as? [[String: Any]] ?? [])
            .compactMap { richText in
                if let plainText = richText["plain_text"] as? String {
                    return plainText
                }

                let text = richText["text"] as? [String: Any]
                return text?["content"] as? String
            }
            .joined()

        let propertyOptions: [NotionPropertyOption] = properties.compactMap { name, value in
            guard let property = value as? [String: Any],
                  let type = property["type"] as? String else {
                return nil
            }

            let options: [String]
            if type == "multi_select",
               let configuration = property["multi_select"] as? [String: Any],
               let rawOptions = configuration["options"] as? [[String: Any]] {
                options = rawOptions.compactMap { $0["name"] as? String }
            } else {
                options = []
            }

            return NotionPropertyOption(name: name, type: type, options: options)
        }
        .sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return NotionDatabaseSchema(
            title: title.isEmpty
                ? (ShiftHubLocalization.isEnglish(Locale(identifier: localeIdentifier))
                    ? "Untitled Notion database"
                    : "名称未設定のNotion DB")
                : title,
            properties: propertyOptions
        )
    }
}

private enum NotionAPIError: LocalizedError {
    case invalidSettings
    case invalidDate(String)
    case requestFailed(statusCode: Int, message: String)
    case invalidResponse

    var statusCode: Int? {
        if case .requestFailed(let statusCode, _) = self {
            return statusCode
        }

        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            return "Notionの設定を確認してください。"
        case .invalidDate(let day):
            return "日付を作成できませんでした: \(day)"
        case .requestFailed(let statusCode, let message):
            return "Notion APIエラー（\(statusCode)）: \(message)"
        case .invalidResponse:
            return "Notionから無効な応答が返されました。"
        }
    }
}

@MainActor
private final class NotionPageWriter {
    private let endpoint = URL(string: "https://api.notion.com/v1/pages")!

    func register(
        cells: [ExtractedShiftCell],
        yearMonth: YearMonth?,
        definitions: [ShiftDefinition],
        token: String,
        dataSourceID: String,
        titleProperty: String,
        dateProperty: String,
        tagProperty: String,
        tagValue: String,
        restTitle: String,
        includeRest: Bool
    ) async throws -> NotionRegistrationResult {
        guard let yearMonth,
              !dataSourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !titleProperty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !dateProperty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !tagProperty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !tagValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotionAPIError.invalidSettings
        }

        let definitionByTitle = Dictionary(
            uniqueKeysWithValues: definitions.map { (normalizedTitle($0.title), $0) }
        )
        let registeredRestTitle = restTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "休"
            : restTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var skippedTitles: [String] = []
        var savedCount = 0

        for cell in cells {
            guard let day = Int(cell.dateText), (1...yearMonth.numberOfDays).contains(day) else {
                continue
            }

            let title = normalizedTitle(cell.valueText)
            guard !title.isEmpty else { continue }

            if title == "休" {
                guard includeRest else { continue }
                try await createPage(
                    title: registeredRestTitle,
                    yearMonth: yearMonth,
                    dayText: cell.dateText,
                    startMinutes: 0,
                    endMinutes: 1439,
                    token: token,
                    dataSourceID: dataSourceID,
                    titleProperty: titleProperty,
                    dateProperty: dateProperty,
                    tagProperty: tagProperty,
                    tagValue: tagValue
                )
                savedCount += 1
                continue
            }

            guard let definition = definitionByTitle[title] else {
                if !skippedTitles.contains(title) {
                    skippedTitles.append(title)
                }
                continue
            }

            try await createPage(
                title: title,
                yearMonth: yearMonth,
                dayText: cell.dateText,
                startMinutes: definition.startMinutes,
                endMinutes: definition.endMinutes,
                token: token,
                dataSourceID: dataSourceID,
                titleProperty: titleProperty,
                dateProperty: dateProperty,
                tagProperty: tagProperty,
                tagValue: tagValue
            )
            savedCount += 1
        }

        return NotionRegistrationResult(savedCount: savedCount, skippedTitles: skippedTitles)
    }

    private func createPage(
        title: String,
        yearMonth: YearMonth,
        dayText: String,

        startMinutes: Int?,
        endMinutes: Int?,
        token: String,
        dataSourceID: String,
        titleProperty: String,
        dateProperty: String,
        tagProperty: String,
        tagValue: String
    ) async throws {
        guard let day = Int(dayText), (1...yearMonth.numberOfDays).contains(day) else {
            throw NotionAPIError.invalidDate(dayText)
        }

        var dateValue: [String: Any] = [:]
        if let startMinutes, let endMinutes,
           let startDate = date(yearMonth: yearMonth, day: day, minutes: startMinutes),
           let endDate = date(yearMonth: yearMonth, day: day, minutes: endMinutes) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            formatter.timeZone = TimeZone.current
            dateValue["start"] = formatter.string(from: startDate)
            dateValue["end"] = formatter.string(from: endDate)
        } else if startMinutes == nil && endMinutes == nil {
            dateValue["start"] = String(format: "%04d-%02d-%02d", yearMonth.year, yearMonth.month, day)
        } else {
            throw NotionAPIError.invalidDate(dayText)
        }

        let properties: [String: Any] = [
            titleProperty: [
                "title": [[
                    "type": "text",
                    "text": ["content": title]
                ]]
            ],
            dateProperty: ["date": dateValue],
            tagProperty: [
                "multi_select": [["name": tagValue]]
            ]
        ]

        _ = try await sendCreatePageRequest(
            parent: ["database_id": dataSourceID],
            properties: properties,
            token: token
        )
    }

    func registerDateTimeEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        token: String,
        dataSourceID: String,
        titleProperty: String,
        dateProperty: String,
        tagProperty: String,
        tagValue: String
    ) async throws -> String {
        guard !dataSourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !titleProperty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !dateProperty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !tagProperty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !tagValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotionAPIError.invalidSettings
        }

        var dateValue: [String: Any]
        if isAllDay {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"

            let calendar = Calendar.current
            let normalizedStartDate = calendar.startOfDay(for: startDate)
            let normalizedEndDate = calendar.startOfDay(for: endDate)
            dateValue = ["start": formatter.string(from: normalizedStartDate)]
            if normalizedEndDate > normalizedStartDate {
                dateValue["end"] = formatter.string(from: normalizedEndDate)
            }
        } else {
            guard endDate >= startDate else {
                throw NotionAPIError.invalidDate("終了日時")
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            formatter.timeZone = .current
            dateValue = [
                "start": formatter.string(from: startDate),
                "end": formatter.string(from: endDate)
            ]
        }

        let properties: [String: Any] = [
            titleProperty: [
                "title": [[
                    "type": "text",
                    "text": ["content": title]
                ]]
            ],
            dateProperty: ["date": dateValue],
            tagProperty: [
                "multi_select": [["name": tagValue]]
            ]
        ]

        return try await sendCreatePageRequest(
            parent: ["database_id": dataSourceID],
            properties: properties,
            token: token
        )
    }

    private func sendCreatePageRequest(
        parent: [String: Any],
        properties: [String: Any],
        token: String
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "parent": parent,
            "properties": properties
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NotionAPIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = responseObject?["message"] as? String ?? "不明なエラー"
            throw NotionAPIError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        guard let responseObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identifier = responseObject["id"] as? String else {
            throw NotionAPIError.invalidResponse
        }

        return identifier
    }

    private func date(yearMonth: YearMonth, day: Int, minutes: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: yearMonth.year,
                month: yearMonth.month,
                day: day,
                hour: minutes / 60,
                minute: minutes % 60
            )
        )
    }

    private func normalizedTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "／", with: "/")
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CalendarEventManagementError: LocalizedError {
    case invalidSettings(String)
    case accessDenied
    case calendarNotFound
    case invalidResponse
    case requestFailed(String)
    case invalidDate

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidSettings(let message):
            return message
        case .accessDenied:
            return "カレンダーへのアクセスが許可されていません。"
        case .calendarNotFound:
            return "登録先カレンダーが見つかりません。"
        case .invalidResponse:
            return "カレンダーから無効な応答が返されました。"
        case .requestFailed(let message):
            return message
        case .invalidDate:
            return "イベントの日付を作成できませんでした。"
        }
    }
}

nonisolated final class AppleCalendarEventClient {
    private let eventStore = EKEventStore()
    private let calendarIdentifier: String

    init(calendarIdentifier: String) {
        self.calendarIdentifier = calendarIdentifier
    }

    func fetch(yearMonth: YearMonth) throws -> [CalendarEventRecord] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarEventManagementError.accessDenied
        }

        guard let calendar = selectedCalendar() else {
            throw CalendarEventManagementError.calendarNotFound
        }
        let calendarColor = CalendarDisplayColor(cgColor: calendar.cgColor)

        guard let startDate = monthStart(yearMonth),
              let endDate = Calendar.current.date(byAdding: .month, value: 1, to: startDate) else {
            throw CalendarEventManagementError.invalidDate
        }

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: [calendar]
        )

        return eventStore.events(matching: predicate).compactMap { event in
            guard let identifier = event.eventIdentifier,
                  let day = Calendar.current.dateComponents([.day], from: event.startDate).day else {
                return nil
            }

            return CalendarEventRecord(
                id: identifier,
                day: day,
                title: event.title?.isEmpty == false ? event.title! : "無題",
                detail: event.isAllDay ? "終日" : timeRangeText(start: event.startDate, end: event.endDate),
                isAllDay: event.isAllDay,
                startDate: event.startDate,
                endDate: event.isAllDay ? nil : event.endDate,
                calendarColor: calendarColor
            )
        }
    }

    func fetchCalendarColor() throws -> CalendarDisplayColor? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarEventManagementError.accessDenied
        }

        guard let calendar = selectedCalendar() else {
            throw CalendarEventManagementError.calendarNotFound
        }

        return CalendarDisplayColor(cgColor: calendar.cgColor)
    }

    func deleteEvent(identifier: String) throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarEventManagementError.accessDenied
        }

        guard let event = eventStore.event(withIdentifier: identifier) else {
            throw CalendarEventManagementError.invalidResponse
        }

        try eventStore.remove(event, span: .thisEvent, commit: true)
    }

    private func selectedCalendar() -> EKCalendar? {
        if calendarIdentifier.isEmpty {
            return eventStore.defaultCalendarForNewEvents
        }

        return eventStore.calendar(withIdentifier: calendarIdentifier)
    }

    private func monthStart(_ yearMonth: YearMonth) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: yearMonth.year, month: yearMonth.month, day: 1))
    }

    private func timeRangeText(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = .current
        formatter.dateFormat = "H:mm"
        return "\(formatter.string(from: start))-\(formatter.string(from: end))"
    }
}

struct NotionCalendarEventClient {
    let token: String
    let dataSourceID: String
    let dateProperty: String
    let titleProperty: String
    let tagProperty: String
    let tagValue: String

    func fetchEvents(yearMonth: YearMonth) async throws -> [CalendarEventRecord] {
        var cursor: String?
        var records: [CalendarEventRecord] = []
        var seenPageIDs = Set<String>()
        var requestedCursors = Set<String>()
        var pageCount = 0

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let monthStart = calendar.date(from: DateComponents(
            year: yearMonth.year,
            month: yearMonth.month,
            day: 1
        )),
        let queryStart = calendar.date(
            byAdding: .month,
            value: -1,
            to: monthStart
        ),
        let nextMonthStart = calendar.date(
            byAdding: .month,
            value: 1,
            to: monthStart
        ) else {
            throw CalendarEventManagementError.invalidResponse
        }

        repeat {
            if let cursor, !requestedCursors.insert(cursor).inserted {
                break
            }
            pageCount += 1
            guard pageCount <= 100 else { break }

            var body: [String: Any] = [
                "page_size": 100,
                "filter": [
                    "and": [
                        [
                            "property": dateProperty,
                            "date": [
                                "on_or_after": dateText(from: queryStart),
                                "before": dateText(yearMonth: yearMonth.nextMonth, day: 1)
                            ]
                        ],
                        [
                            "property": tagProperty,
                            "multi_select": ["contains": tagValue]
                        ]
                    ]
                ]
            ]
            if let cursor {
                body["start_cursor"] = cursor
            }

            let payload = try await sendRequest(
                url: URL(string: "https://api.notion.com/v1/databases/\(dataSourceID)/query")!,
                method: "POST",
                body: body
            )

            guard let results = payload["results"] as? [[String: Any]] else {
                throw CalendarEventManagementError.invalidResponse
            }

            for page in results {
                let isTrashed = (page["in_trash"] as? Bool) == true
                    || (page["archived"] as? Bool) == true

                guard let identifier = page["id"] as? String,
                      seenPageIDs.insert(identifier).inserted,
                      !isTrashed,
                      let properties = page["properties"] as? [String: Any],
                      let dateData = properties[dateProperty] as? [String: Any],
                      let dateValue = dateData["date"] as? [String: Any],
                      let start = dateValue["start"] as? String,
                      hasConfiguredTag(in: properties[tagProperty]) else {
                    continue
                }

                let title = title(from: properties[titleProperty])
                let isAllDay = !start.contains("T")
                let startDate = isAllDay ? dateOnlyDate(from: start) : parseISO8601Date(start)
                guard let startDate else { continue }
                let detail: String
                let endDate: Date?
                if start.contains("T"),
                   let end = dateValue["end"] as? String,
                   end.contains("T") {
                    detail = timeRangeText(start: start, end: end)
                    endDate = parseISO8601Date(end)
                } else {
                    detail = isAllDay ? "終日" : timeText(from: start)
                    endDate = isAllDay
                        ? (dateValue["end"] as? String).flatMap { dateOnlyDate(from: $0) }
                        : nil
                }

                let startsInMonth = startDate >= monthStart && startDate < nextMonthStart
                let continuesIntoMonth = startDate < monthStart
                    && (endDate.map { $0 > monthStart } ?? false)
                guard startsInMonth || continuesIntoMonth else { continue }

                let day = startsInMonth
                    ? (dayInSelectedMonth(from: start, yearMonth: yearMonth) ?? 1)
                    : 1
                records.append(CalendarEventRecord(
                    id: identifier,
                    day: day,
                    title: title.isEmpty ? "無題" : title,
                    detail: detail,
                    isAllDay: isAllDay,
                    startDate: startDate,
                    endDate: endDate,
                    calendarColor: nil
                ))
            }

            cursor = payload["has_more"] as? Bool == true
                ? payload["next_cursor"] as? String
                : nil
        } while cursor != nil

        return records
    }

    func deletePage(identifier: String) async throws {
        let payload = try await sendRequest(
            url: URL(string: "https://api.notion.com/v1/pages/\(identifier)")!,
            method: "PATCH",
            body: ["in_trash": true],
            notionVersion: "2026-03-11"
        )

        guard (payload["in_trash"] as? Bool) == true else {
            throw CalendarEventManagementError.invalidResponse
        }
    }

    private func sendRequest(
        url: URL,
        method: String,
        body: [String: Any]? = nil,
        notionVersion: String = "2022-06-28"
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CalendarEventManagementError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = responseObject?["message"] as? String ?? "Notion APIエラー"
            throw CalendarEventManagementError.requestFailed(message)
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return payload
    }

    private func title(from property: Any?) -> String {
        guard let property = property as? [String: Any],
              let values = property["title"] as? [[String: Any]] else {
            return ""
        }

        return values.compactMap { value in
            (value["plain_text"] as? String) ?? ((value["text"] as? [String: Any])?["content"] as? String)
        }
        .joined()
    }

    private func timeText(from value: String) -> String {
        if let date = parseISO8601Date(value) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ja_JP")
            formatter.timeZone = .current
            formatter.dateFormat = "H:mm"
            return formatter.string(from: date)
        }

        let time = value.split(separator: "T").dropFirst().first.map(String.init) ?? value
        return String(time.prefix(5))
    }

    private func timeRangeText(start: String, end: String) -> String {
        guard let startDate = parseISO8601Date(start),
              let endDate = parseISO8601Date(end) else {
            return timeText(from: start)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = .current
        formatter.dateFormat = "H:mm"
        return "\(formatter.string(from: startDate))-\(formatter.string(from: endDate))"
    }

    private func dayInSelectedMonth(from value: String, yearMonth: YearMonth) -> Int? {
        if value.contains("T"), let date = parseISO8601Date(value) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let components = calendar.dateComponents([.year, .month, .day], from: date)

            guard components.year == yearMonth.year,
                  components.month == yearMonth.month,
                  let day = components.day,
                  (1...yearMonth.numberOfDays).contains(day) else {
                return nil
            }

            return day
        }

        let dateText = String(value.prefix(10))
        let components = dateText.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3,
              components[0] == yearMonth.year,
              components[1] == yearMonth.month,
              (1...yearMonth.numberOfDays).contains(components[2]) else {
            return nil
        }

        return components[2]
    }

    private func parseISO8601Date(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func dateOnlyDate(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(value.prefix(10)))
    }

    private func hasConfiguredTag(in property: Any?) -> Bool {
        let expected = tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty,
              let property = property as? [String: Any] else {
            return false
        }

        if let values = property["multi_select"] as? [[String: Any]] {
            return values.contains { ($0["name"] as? String) == expected }
        }

        if let value = property["select"] as? [String: Any] {
            return (value["name"] as? String) == expected
        }

        if let values = property["rich_text"] as? [[String: Any]] {
            return values.contains { textValue(from: $0) == expected }
        }

        return false
    }

    private func textValue(from value: [String: Any]) -> String {
        (value["plain_text"] as? String)
            ?? ((value["text"] as? [String: Any])?["content"] as? String)
            ?? ""
    }

    private func dateText(yearMonth: YearMonth, day: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let date = calendar.date(from: DateComponents(year: yearMonth.year, month: yearMonth.month, day: day)) else {
            return String(format: "%04d-%02d-%02d", yearMonth.year, yearMonth.month, day)
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func dateText(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct GoogleCalendarOption: Identifiable, Hashable {
    let id: String
    let title: String
    let isPrimary: Bool

    var displayName: String {
        isPrimary ? "\(title)（メイン）" : title
    }

    func displayName(for locale: Locale) -> String {
        isPrimary && ShiftHubLocalization.isEnglish(locale) ? "\(title) (Primary)" : displayName
    }
}

struct GoogleOAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

enum GoogleTokenStore {
    private static let account = "google-calendar-oauth-tokens"

    static func load() -> GoogleOAuthTokens? {
        guard let value = KeychainStore.string(for: account),
              let data = value.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(GoogleOAuthTokens.self, from: data)
    }

    static func save(_ tokens: GoogleOAuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens),
              let value = String(data: data, encoding: .utf8) else {
            return
        }

        KeychainStore.set(value, for: account)
    }

    static func clear() {
        KeychainStore.set("", for: account)
    }
}

@MainActor
private final class GoogleCalendarProvider: ObservableObject {
    @Published private(set) var calendars: [GoogleCalendarOption] = []
    @Published private(set) var japaneseHolidayCalendarID: String?
    @Published private(set) var message = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isAuthorizing = false
    @Published private(set) var isAuthorized = false
    private var localeIdentifier = "ja"

    func setLocaleIdentifier(_ identifier: String) {
        localeIdentifier = identifier
    }

    func loadSavedState() {
        isAuthorized = GoogleTokenStore.load() != nil
    }

    func signIn() {
        isAuthorizing = true
        message = ""

        Task { @MainActor [weak self] in
            do {
                let tokens = try await GoogleOAuthClient.authorize(
                    localeIdentifier: self?.localeIdentifier ?? "ja"
                )
                GoogleTokenStore.save(tokens)
                self?.isAuthorized = true
                self?.calendars = []
                self?.japaneseHolidayCalendarID = nil
                self?.message = ShiftHubLocalization.string(
                    "Googleアカウントに接続しました。カレンダー一覧を取得してください。",
                    locale: Locale(identifier: self?.localeIdentifier ?? "ja")
                )
            } catch {
                self?.message = ShiftHubLocalization.format(
                    "Googleログインに失敗しました: %@",
                    locale: Locale(identifier: self?.localeIdentifier ?? "ja"),
                    arguments: ShiftHubLocalization.localizedErrorDescription(
                        error,
                        locale: Locale(identifier: self?.localeIdentifier ?? "ja")
                    )
                )
            }

            self?.isAuthorizing = false
        }
    }

    func loadCalendars() {
        isLoading = true
        message = ""

        Task { @MainActor [weak self] in
            do {
                let client = GoogleCalendarAPIClient(
                    clientID: GoogleOAuthConfiguration.clientID
                )
                let calendars = try await client.fetchCalendars()
                let holidayCalendarID = try await client.fetchJapaneseHolidayCalendarID()
                self?.calendars = calendars
                self?.japaneseHolidayCalendarID = holidayCalendarID
                self?.isAuthorized = true
                self?.message = calendars.isEmpty
                    ? ShiftHubLocalization.string(
                        "利用できるカレンダーが見つかりませんでした。",
                        locale: Locale(identifier: self?.localeIdentifier ?? "ja")
                    )
                    : ShiftHubLocalization.format(
                        "%@件のカレンダーを取得しました。",
                        locale: Locale(identifier: self?.localeIdentifier ?? "ja"),
                        arguments: String(calendars.count)
                    )
            } catch {
                self?.message = ShiftHubLocalization.format(
                    "カレンダー一覧を取得できませんでした: %@",
                    locale: Locale(identifier: self?.localeIdentifier ?? "ja"),
                    arguments: error.localizedDescription
                )
            }

            self?.isLoading = false
        }
    }
}

private struct GoogleOAuthCallback: Sendable {
    let code: String
    let state: String
}

private enum GoogleOAuthClient {
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let scopes = [
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    ]

    static func authorize(localeIdentifier: String) async throws -> GoogleOAuthTokens {
        let clientID = GoogleOAuthConfiguration.clientID
        let state = randomString(length: 32)
        let codeVerifier = randomString(length: 64)
        let codeChallenge = base64URL(SHA256.hash(data: Data(codeVerifier.utf8)))
#if os(iOS)
        let redirectURI = "\(GoogleOAuthConfiguration.callbackURLScheme):/oauthredirect"
#else
        let server = GoogleOAuthLoopbackServer(localeIdentifier: localeIdentifier)
        let redirectURI = try await server.start()
        defer { server.stop() }
#endif

        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authorizationURL = components?.url else {
            throw GoogleCalendarError.browserUnavailable
        }

#if os(macOS)
        guard NSWorkspace.shared.open(authorizationURL) else {
            throw GoogleCalendarError.browserUnavailable
        }
#endif

#if os(iOS)
        let callbackURL = try await GoogleOAuthWebAuthenticationSession.authenticate(
            authorizationURL: authorizationURL,
            callbackURLScheme: GoogleOAuthConfiguration.callbackURLScheme
        )
        guard let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value,
              let callbackState = callbackComponents.queryItems?.first(where: { $0.name == "state" })?.value else {
            throw GoogleCalendarError.invalidResponse
        }
        let callback = GoogleOAuthCallback(code: code, state: callbackState)
#else
        let callback = try await server.waitForCallback()
#endif
        guard callback.state == state else {
            throw GoogleCalendarError.invalidOAuthState
        }

        return try await exchangeCode(
            callback.code,
            clientID: clientID,
            redirectURI: redirectURI,
            codeVerifier: codeVerifier
        )
    }

    private static func exchangeCode(
        _ code: String,
        clientID: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> GoogleOAuthTokens {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var values = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]
        if let clientSecret = GoogleOAuthConfiguration.clientSecret, !clientSecret.isEmpty {
            values["client_secret"] = clientSecret
        }
        request.httpBody = formBody(values)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleCalendarError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GoogleCalendarError.requestFailed(message: "HTTP \(httpResponse.statusCode): \(responseMessage(from: data))")
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = payload["access_token"] as? String,
              let refreshToken = payload["refresh_token"] as? String,
              let expiresIn = payload["expires_in"] as? Double else {
            throw GoogleCalendarError.invalidResponse
        }

        return GoogleOAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    private static func formBody(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private static func randomString(length: Int) -> String {
        let bytes = (0..<length).map { _ in UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URL(_ digest: SHA256.Digest) -> String {
        base64URL(Data(digest))
    }

    private static func responseMessage(from data: Data) -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return body?.isEmpty == false ? body! : "不明なエラー"
        }

        if let error = payload["error"] as? [String: Any] {
            let code = error["status"] as? String
                ?? (error["code"] as? Int).map(String.init)
            let reason = error["reason"] as? String
                ?? (error["errors"] as? [[String: Any]])?.compactMap { $0["reason"] as? String }.first
            let message = error["message"] as? String
            let details = [code, reason, message]
                .compactMap { $0 }
            return details.isEmpty ? "不明なエラー" : details.joined(separator: ": ")
        }

        if let error = payload["error"] as? String {
            let description = payload["error_description"] as? String
            return [error, description]
                .compactMap { $0 }
                .joined(separator: ": ")
        }

        return payload["message"] as? String ?? "不明なエラー"
    }
}

#if os(iOS)
@MainActor
private final class GoogleOAuthWebAuthenticationSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    static func authenticate(authorizationURL: URL, callbackURLScheme: String) async throws -> URL {
        let coordinator = GoogleOAuthWebAuthenticationSession()
        return try await coordinator.start(
            authorizationURL: authorizationURL,
            callbackURLScheme: callbackURLScheme
        )
    }

    private func start(authorizationURL: URL, callbackURLScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: callbackURLScheme
            ) { [weak self] callbackURL, error in
                guard let self else { return }
                self.session = nil

                if let callbackURL {
                    self.finish(.success(callbackURL))
                } else if let error {
                    self.finish(.failure(error))
                } else {
                    self.finish(.failure(GoogleCalendarError.authorizationCancelled))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            guard session.start() else {
                self.session = nil
                self.finish(.failure(GoogleCalendarError.browserUnavailable))
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })
            ?? UIWindow(frame: UIScreen.main.bounds)
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
#endif

private final class GoogleOAuthLoopbackServer: @unchecked Sendable {
    private let localeIdentifier: String
    private let queue = DispatchQueue(label: "net.unwraps.Shift-Upload.google-oauth")
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<String, Error>?
    private var callbackContinuation: CheckedContinuation<GoogleOAuthCallback, Error>?
    private var pendingCallback: GoogleOAuthCallback?

    init(localeIdentifier: String) {
        self.localeIdentifier = localeIdentifier
    }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return }
                self.startContinuation = continuation

                do {
                    let listener = try NWListener(using: .tcp, on: .any)
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = listener?.port else {
                                self.failStart(GoogleCalendarError.invalidResponse)
                                return
                            }
                            self.finishStart("http://127.0.0.1:\(port.rawValue)/oauth2callback")
                        case .failed(let error):
                            self.failStart(error)
                        case .cancelled:
                            self.failStart(GoogleCalendarError.authorizationCancelled)
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        connection.start(queue: self?.queue ?? .global())
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, _, _ in
                            guard let self, let data else { return }
                            self.handle(data: data, connection: connection)
                        }
                    }
                    self.listener = listener
                    listener.start(queue: self.queue)
                } catch {
                    self.failStart(error)
                }
            }
        }
    }

    func waitForCallback() async throws -> GoogleOAuthCallback {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return }
                if let pendingCallback = self.pendingCallback {
                    self.pendingCallback = nil
                    continuation.resume(returning: pendingCallback)
                } else {
                    self.callbackContinuation = continuation
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
        }
    }

    private func finishStart(_ redirectURI: String) {
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(returning: redirectURI)
    }

    private func failStart(_ error: Error) {
        let continuation = startContinuation
        startContinuation = nil
        listener?.cancel()
        listener = nil
        continuation?.resume(throwing: error)
    }

    private func handle(data: Data, connection: NWConnection?) {
        guard let request = String(data: data, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let state = components.queryItems?.first(where: { $0.name == "state" })?.value else {
            sendResponse(
                to: connection,
                body: ShiftHubLocalization.string(
                    "認証情報を受け取れませんでした。Cal Hubに戻ってください。",
                    locale: Locale(identifier: localeIdentifier)
                )
            )
            return
        }

        sendResponse(
            to: connection,
            body: ShiftHubLocalization.string(
                "Googleログインが完了しました。このページを閉じてCal Hubに戻ってください。",
                locale: Locale(identifier: localeIdentifier)
            )
        )
        listener?.cancel()
        listener = nil

        let callback = GoogleOAuthCallback(code: code, state: state)
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(returning: callback)
        } else {
            pendingCallback = callback
        }
    }

    private func sendResponse(to connection: NWConnection?, body: String) {
        guard let connection else { return }
        let bodyData = Data(body.utf8)
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

struct GoogleCalendarAPIClient {
    let clientID: String
    let clientSecret: String? = GoogleOAuthConfiguration.clientSecret

    func fetchCalendars() async throws -> [GoogleCalendarOption] {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        components.queryItems = [
            URLQueryItem(name: "minAccessRole", value: "writer")
        ]

        let data = try await sendRequest(url: components.url!, method: "GET")
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = payload["items"] as? [[String: Any]] else {
            throw GoogleCalendarError.invalidResponse
        }

        let options: [GoogleCalendarOption] = items.compactMap { (item: [String: Any]) -> GoogleCalendarOption? in
            guard let rawID = item["id"] as? String,
                  let accessRole = item["accessRole"] as? String,
                  accessRole == "owner" || accessRole == "writer" else {
                return nil
            }

            let isPrimary = item["primary"] as? Bool ?? false
            let id = isPrimary ? "primary" : rawID
            let title = (item["summaryOverride"] as? String)
                ?? (item["summary"] as? String)
                ?? "名称未設定"
            return GoogleCalendarOption(id: id, title: title, isPrimary: isPrimary)
        }

        return options
        .reduce(into: [GoogleCalendarOption]()) { (result: inout [GoogleCalendarOption], calendar: GoogleCalendarOption) in
            guard !result.contains(where: { $0.id == calendar.id }) else { return }
            result.append(calendar)
        }
        .sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary {
                return lhs.isPrimary
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    func fetchJapaneseHolidayCalendarID() async throws -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        components.queryItems = [
            URLQueryItem(name: "minAccessRole", value: "reader")
        ]

        let data = try await sendRequest(url: components.url!, method: "GET")
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = payload["items"] as? [[String: Any]] else {
            throw GoogleCalendarError.invalidResponse
        }

        return items.compactMap { (item: [String: Any]) -> String? in
            guard let id = item["id"] as? String else { return nil }
            let title = ((item["summaryOverride"] as? String) ?? (item["summary"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let normalizedID = id.lowercased()
            guard title.contains("日本の祝日")
                    || title.contains("japanese holidays")
                    || title.contains("japanese holiday")
                    || normalizedID.contains("japanese#holiday") else {
                return nil
            }
            return id
        }.first
    }

    func createEvent(
        calendarID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool
    ) async throws -> String {
        guard endDate >= startDate else {
            throw GoogleCalendarError.invalidDate
        }

        let start: [String: Any]
        let end: [String: Any]
        if isAllDay {
            let calendar = Calendar.current
            let normalizedStartDate = calendar.startOfDay(for: startDate)
            let normalizedEndDate = calendar.startOfDay(for: endDate)
            guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: normalizedEndDate) else {
                throw GoogleCalendarError.invalidDate
            }

            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            start = ["date": formatter.string(from: normalizedStartDate)]
            end = ["date": formatter.string(from: endExclusive)]
        } else {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            formatter.timeZone = .current
            start = [
                "dateTime": formatter.string(from: startDate),
                "timeZone": TimeZone.current.identifier
            ]
            end = [
                "dateTime": formatter.string(from: endDate),
                "timeZone": TimeZone.current.identifier
            ]
        }

        let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events")!
        let body: [String: Any] = [
            "summary": title,
            "start": start,
            "end": end
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let responseData = try await sendRequest(url: url, method: "POST", body: bodyData)
        guard let responseObject = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let identifier = responseObject["id"] as? String else {
            throw GoogleCalendarError.invalidResponse
        }

        return identifier
    }

    func createEvent(
        calendarID: String,
        title: String,
        yearMonth: YearMonth,
        day: Int,
        startMinutes: Int?,
        endMinutes: Int?
    ) async throws {
        let start: [String: Any]
        let end: [String: Any]
        if let startMinutes, let endMinutes {
            guard let startDate = date(yearMonth: yearMonth, day: day, minutes: startMinutes),
                  let endDate = date(yearMonth: yearMonth, day: day, minutes: endMinutes) else {
                throw GoogleCalendarError.invalidDate
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            formatter.timeZone = .current
            start = [
                "dateTime": formatter.string(from: startDate),
                "timeZone": TimeZone.current.identifier
            ]
            end = [
                "dateTime": formatter.string(from: endDate),
                "timeZone": TimeZone.current.identifier
            ]
        } else {
            guard let date = date(yearMonth: yearMonth, day: day, minutes: 0),
                  let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: date) else {
                throw GoogleCalendarError.invalidDate
            }

            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            start = ["date": formatter.string(from: date)]
            end = ["date": formatter.string(from: nextDay)]
        }

        let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events")!
        let body: [String: Any] = [
            "summary": title,
            "start": start,
            "end": end
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await sendRequest(url: url, method: "POST", body: bodyData)
    }

    func fetchEvents(
        yearMonth: YearMonth,
        calendarID: String,
        isReadOnly: Bool = false
    ) async throws -> [CalendarEventRecord] {
        guard let startDate = monthStart(yearMonth),
              let endDate = Calendar.current.date(byAdding: .month, value: 1, to: startDate) else {
            throw CalendarEventManagementError.invalidDate
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        // URLクエリ内の「+09:00」は一部のHTTPサーバーで空白として解釈されるため、UTCのZ形式で送る。
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID(calendarID))/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: startDate)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: endDate)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "showDeleted", value: "false"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "2500")
        ]

        let data = try await sendRequest(url: components.url!, method: "GET")
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = payload["items"] as? [[String: Any]] else {
            throw CalendarEventManagementError.invalidResponse
        }
        let calendarColor = try? await fetchCalendarColor(calendarID: calendarID)

        return items.compactMap { (item: [String: Any]) -> CalendarEventRecord? in
            guard let identifier = item["id"] as? String,
                  let start = item["start"] as? [String: Any] else {
                return nil
            }

            let title = (item["summary"] as? String)?.isEmpty == false
                ? (item["summary"] as? String ?? "")
                : "無題"
            if let dateText = start["date"] as? String,
               let day = Int(dateText.split(separator: "-").last ?? ""),
               let startDate = dateOnlyDate(from: dateText) {
                let endDate = ((item["end"] as? [String: Any])?["date"] as? String)
                    .flatMap { dateOnlyDate(from: $0) }
                return CalendarEventRecord(
                    id: identifier,
                    day: day,
                    title: title,
                    detail: "終日",
                    isAllDay: true,
                    startDate: startDate,
                    endDate: endDate.map { date in
                        Calendar.current.date(byAdding: .day, value: -1, to: date)
                    } ?? nil,
                    calendarColor: calendarColor ?? nil,
                    isReadOnly: isReadOnly
                )
            }

            guard let dateTimeText = start["dateTime"] as? String,
                  let dateTime = ISO8601DateFormatter().date(from: dateTimeText),
                  let day = Calendar.current.dateComponents([.day], from: dateTime).day else {
                return nil
            }

            let endText = (item["end"] as? [String: Any])?["dateTime"] as? String
            let endDate = endText.flatMap { ISO8601DateFormatter().date(from: $0) } ?? dateTime
            return CalendarEventRecord(
                id: identifier,
                day: day,
                title: title,
                detail: timeRangeText(start: dateTime, end: endDate),
                isAllDay: false,
                startDate: dateTime,
                endDate: endDate,
                calendarColor: calendarColor ?? nil,
                isReadOnly: isReadOnly
            )
        }
    }

    func fetchJapaneseHolidayEvents(yearMonth: YearMonth) async throws -> [CalendarEventRecord] {
        guard let calendarID = try await fetchJapaneseHolidayCalendarID() else {
            return []
        }

        return try await fetchEvents(
            yearMonth: yearMonth,
            calendarID: calendarID,
            isReadOnly: true
        )
    }

    func fetchCalendarColor(calendarID: String) async throws -> CalendarDisplayColor? {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList/\(encodedCalendarID(calendarID))")!
        let data = try await sendRequest(url: url, method: "GET")
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CalendarEventManagementError.invalidResponse
        }

        return (payload["backgroundColor"] as? String).flatMap(CalendarDisplayColor.init(hex:))
    }

    func deleteEvent(calendarID: String, eventID: String) async throws {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID(calendarID))/events/\(eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID)")!
        _ = try await sendRequest(url: url, method: "DELETE")
    }

    private func monthStart(_ yearMonth: YearMonth) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: yearMonth.year, month: yearMonth.month, day: 1))
    }

    private func encodedCalendarID(_ calendarID: String) -> String {
        calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
    }

    private func timeRangeText(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = .current
        formatter.dateFormat = "H:mm"
        return "\(formatter.string(from: start))-\(formatter.string(from: end))"
    }

    private func dateOnlyDate(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private func sendRequest(url: URL, method: String, body: Data? = nil) async throws -> Data {
        guard let storedTokens = GoogleTokenStore.load() else {
            throw GoogleCalendarError.notAuthenticated
        }

        var tokens = storedTokens
        if tokens.expiresAt.timeIntervalSinceNow < 60 {
            tokens = try await refresh(tokens: tokens)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleCalendarError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            let refreshedTokens = try await refresh(tokens: tokens)
            var retryRequest = request
            retryRequest.setValue("Bearer \(refreshedTokens.accessToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
            guard let retryHTTPResponse = retryResponse as? HTTPURLResponse else {
                throw GoogleCalendarError.invalidResponse
            }
            guard (200..<300).contains(retryHTTPResponse.statusCode) else {
                throw GoogleCalendarError.requestFailed(message: "HTTP \(retryHTTPResponse.statusCode): \(responseMessage(from: retryData))")
            }
            return retryData
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GoogleCalendarError.requestFailed(message: "HTTP \(httpResponse.statusCode): \(responseMessage(from: data))")
        }
        return data
    }

    private func refresh(tokens: GoogleOAuthTokens) async throws -> GoogleOAuthTokens {
        var request = URLRequest(url: GoogleOAuthClient.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        var queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "refresh_token", value: tokens.refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        if let clientSecret, !clientSecret.isEmpty {
            queryItems.append(URLQueryItem(name: "client_secret", value: clientSecret))
        }
        components.queryItems = queryItems
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleCalendarError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = payload["access_token"] as? String,
              let expiresIn = payload["expires_in"] as? Double else {
            throw GoogleCalendarError.requestFailed(message: "認証トークンを更新できませんでした (HTTP \(httpResponse.statusCode)): \(responseMessage(from: data))")
        }

        let refreshedTokens = GoogleOAuthTokens(
            accessToken: accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
        GoogleTokenStore.save(refreshedTokens)
        return refreshedTokens
    }

    private func date(yearMonth: YearMonth, day: Int, minutes: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: yearMonth.year,
                month: yearMonth.month,
                day: day,
                hour: minutes / 60,
                minute: minutes % 60
            )
        )
    }

    private func responseMessage(from data: Data) -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return body?.isEmpty == false ? body! : "不明なエラー"
        }

        if let error = payload["error"] as? [String: Any] {
            let code = error["status"] as? String
                ?? (error["code"] as? Int).map(String.init)
            let reason = error["reason"] as? String
                ?? (error["errors"] as? [[String: Any]])?.compactMap { $0["reason"] as? String }.first
            let message = error["message"] as? String
            let details = [code, reason, message]
                .compactMap { $0 }
            return details.isEmpty ? "不明なエラー" : details.joined(separator: ": ")
        }

        if let error = payload["error"] as? String {
            let description = payload["error_description"] as? String
            return [error, description]
                .compactMap { $0 }
                .joined(separator: ": ")
        }

        return payload["message"] as? String ?? "不明なエラー"
    }
}

struct GoogleCalendarRegistrationResult {
    let savedCount: Int
    let skippedTitles: [String]
}

struct GoogleCalendarEventWriter {
    let clientID: String

    func register(
        cells: [ExtractedShiftCell],
        yearMonth: YearMonth?,
        definitions: [ShiftDefinition],
        calendarID: String,
        restTitle: String,
        includeRest: Bool
    ) async throws -> GoogleCalendarRegistrationResult {
        guard let yearMonth else {
            throw GoogleCalendarError.missingYearMonth
        }

        let client = GoogleCalendarAPIClient(clientID: clientID)
        let definitionByTitle = Dictionary(
            uniqueKeysWithValues: definitions.map { (normalizedTitle($0.title), $0) }
        )
        let registeredRestTitle = restTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "休"
            : restTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var skippedTitles: [String] = []
        var savedCount = 0

        for cell in cells {
            guard let day = Int(cell.dateText), (1...yearMonth.numberOfDays).contains(day) else {
                continue
            }

            let title = normalizedTitle(cell.valueText)
            guard !title.isEmpty else { continue }

            if title == "休" {
                guard includeRest else { continue }
                try await client.createEvent(
                    calendarID: calendarID,
                    title: registeredRestTitle,
                    yearMonth: yearMonth,
                    day: day,
                    startMinutes: nil,
                    endMinutes: nil
                )
                savedCount += 1
                continue
            }

            guard let definition = definitionByTitle[title] else {
                if !skippedTitles.contains(title) {
                    skippedTitles.append(title)
                }
                continue
            }

            try await client.createEvent(
                calendarID: calendarID,
                title: title,
                yearMonth: yearMonth,
                day: day,
                startMinutes: definition.startMinutes,
                endMinutes: definition.endMinutes
            )
            savedCount += 1
        }

        return GoogleCalendarRegistrationResult(savedCount: savedCount, skippedTitles: skippedTitles)
    }

    private func normalizedTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "／", with: "/")
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum GoogleCalendarError: LocalizedError {
    case browserUnavailable
    case authorizationCancelled
    case invalidOAuthState
    case invalidResponse
    case requestFailed(message: String)
    case notAuthenticated
    case invalidDate
    case missingYearMonth

    var errorDescription: String? {
        switch self {
        case .browserUnavailable:
            return "Googleログイン画面を開けませんでした。"
        case .authorizationCancelled:
            return "Googleログインがキャンセルされました。"
        case .invalidOAuthState:
            return "Google認証の確認に失敗しました。もう一度ログインしてください。"
        case .invalidResponse:
            return "Googleから無効な応答が返されました。"
        case .requestFailed(let message):
            return "Google Calendar APIエラー: \(message)"
        case .notAuthenticated:
            return "先にGoogleへログインしてください。"
        case .invalidDate:
            return "イベントの日付を作成できませんでした。"
        case .missingYearMonth:
            return "勤務表の年月を取得できませんでした。"
        }
    }
}

private struct AppleCalendarOption: Identifiable, Hashable {
    let id: String
    let title: String
    let sourceTitle: String

    var displayName: String {
        sourceTitle.isEmpty ? title : "\(title)（\(sourceTitle)）"
    }

    func displayName(for locale: Locale) -> String {
        sourceTitle.isEmpty ? title : "\(title) (\(sourceTitle))"
    }
}

@MainActor
private final class AppleCalendarProvider: ObservableObject {
    @Published private(set) var calendars: [AppleCalendarOption] = []
    @Published private(set) var message = ""
    @Published private(set) var isLoading = false
    private var localeIdentifier = "ja"

    func setLocaleIdentifier(_ identifier: String) {
        localeIdentifier = identifier
    }

    private let eventStore = EKEventStore()

    var defaultCalendarName: String {
        eventStore.defaultCalendarForNewEvents?.title ?? ""
    }

    func loadCalendarsIfAuthorized() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        refreshCalendars()
    }

    func loadCalendars() {
        isLoading = true
        message = ""

        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            refreshCalendars()
        case .notDetermined:
            eventStore.requestFullAccessToEvents { [weak self] granted, error in
                let provider = self
                Task { @MainActor in
                    guard let provider else { return }
                    if granted {
                        provider.refreshCalendars()
                    } else {
                        provider.isLoading = false
                        provider.message = error.map {
                            ShiftHubLocalization.localizedErrorDescription(
                                $0,
                                locale: Locale(identifier: provider.localeIdentifier)
                            )
                        }
                            ?? ShiftHubLocalization.string(
                                "カレンダーへのアクセスが許可されませんでした。",
                                locale: Locale(identifier: provider.localeIdentifier)
                            )
                    }
                }
            }
        case .denied, .restricted, .writeOnly:
            isLoading = false
            message = ShiftHubLocalization.string(
                "カレンダーへのアクセスが許可されていません。システム設定でアクセスを許可してください。",
                locale: Locale(identifier: localeIdentifier)
            )
        @unknown default:
            isLoading = false
            message = ShiftHubLocalization.string(
                "カレンダーへのアクセス状態を確認できませんでした。",
                locale: Locale(identifier: localeIdentifier)
            )
        }
    }

    private func refreshCalendars() {
        calendars = eventStore
            .calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map { AppleCalendarOption(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source?.title ?? "") }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        isLoading = false

        if calendars.isEmpty {
            message = ShiftHubLocalization.string(
                "利用できるカレンダーが見つかりませんでした。",
                locale: Locale(identifier: localeIdentifier)
            )
        } else {
            message = ""
        }
    }
}

struct AppleCalendarRegistrationResult {
    let savedCount: Int
    let skippedTitles: [String]
}

@MainActor
final class AppleCalendarEventWriter {
    private let eventStore = EKEventStore()

    func register(
        cells: [ExtractedShiftCell],
        yearMonth: YearMonth?,
        definitions: [ShiftDefinition],
        calendarIdentifier: String,
        restTitle: String,
        includeRest: Bool
    ) throws -> AppleCalendarRegistrationResult {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw AppleCalendarRegistrationError.accessDenied
        }

        guard let yearMonth else {
            throw AppleCalendarRegistrationError.missingYearMonth
        }

        let calendar: EKCalendar?
        if calendarIdentifier.isEmpty {
            calendar = eventStore.defaultCalendarForNewEvents
        } else {
            calendar = eventStore.calendar(withIdentifier: calendarIdentifier)
        }

        guard let calendar, calendar.allowsContentModifications else {
            throw AppleCalendarRegistrationError.calendarNotFound
        }

        let definitionByTitle = Dictionary(
            uniqueKeysWithValues: definitions.map { (normalizedTitle($0.title), $0) }
        )
        let registeredRestTitle = restTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "休"
            : restTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var skippedTitles: [String] = []
        var savedCount = 0

        for cell in cells {
            let title = normalizedTitle(cell.valueText)
            guard !title.isEmpty else { continue }

            if title == "休" {
                guard includeRest else { continue }
                try saveAllDayEvent(title: registeredRestTitle, yearMonth: yearMonth, dayText: cell.dateText, calendar: calendar)
                savedCount += 1
                continue
            }

            guard let definition = definitionByTitle[title] else {
                if !skippedTitles.contains(title) {
                    skippedTitles.append(title)
                }
                continue
            }

            try saveTimedEvent(
                title: title,
                yearMonth: yearMonth,
                dayText: cell.dateText,
                startMinutes: definition.startMinutes,
                endMinutes: definition.endMinutes,
                calendar: calendar
            )
            savedCount += 1
        }

        if savedCount > 0 {
            try eventStore.commit()
        }

        return AppleCalendarRegistrationResult(savedCount: savedCount, skippedTitles: skippedTitles)
    }

    func registerDateTimeEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        calendarIdentifier: String
    ) throws -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw AppleCalendarRegistrationError.accessDenied
        }

        let calendar: EKCalendar?
        if calendarIdentifier.isEmpty {
            calendar = eventStore.defaultCalendarForNewEvents
        } else {
            calendar = eventStore.calendar(withIdentifier: calendarIdentifier)
        }

        guard let calendar, calendar.allowsContentModifications else {
            throw AppleCalendarRegistrationError.calendarNotFound
        }

        guard endDate >= startDate else {
            throw AppleCalendarRegistrationError.invalidDate("終了日時")
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.calendar = calendar
        event.isAllDay = isAllDay

        if isAllDay {
            let calendar = Calendar.current
            let normalizedStartDate = calendar.startOfDay(for: startDate)
            let normalizedEndDate = calendar.startOfDay(for: endDate)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: normalizedEndDate),
                  let inclusiveEndDate = calendar.date(byAdding: .second, value: -1, to: nextDay) else {
                throw AppleCalendarRegistrationError.invalidDate("終了日時")
            }
            event.startDate = normalizedStartDate
            event.endDate = inclusiveEndDate
        } else {
            event.startDate = startDate
            event.endDate = endDate
        }

        try eventStore.save(event, span: .thisEvent, commit: true)
        guard let identifier = event.eventIdentifier else {
            throw AppleCalendarRegistrationError.invalidResponse
        }

        return identifier
    }

    private func saveAllDayEvent(title: String, yearMonth: YearMonth, dayText: String, calendar: EKCalendar) throws {
        guard let eventDate = date(yearMonth: yearMonth, dayText: dayText, minutes: 0),
              let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: eventDate),
              let endDate = Calendar.current.date(byAdding: .second, value: -1, to: nextDay) else {
            throw AppleCalendarRegistrationError.invalidDate(dayText)
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.calendar = calendar
        event.isAllDay = true
        event.startDate = eventDate
        event.endDate = endDate
        try eventStore.save(event, span: .thisEvent, commit: false)
    }

    private func saveTimedEvent(
        title: String,
        yearMonth: YearMonth,
        dayText: String,
        startMinutes: Int,
        endMinutes: Int,
        calendar: EKCalendar
    ) throws {
        guard let startDate = date(yearMonth: yearMonth, dayText: dayText, minutes: startMinutes),
              let endDate = date(yearMonth: yearMonth, dayText: dayText, minutes: endMinutes) else {
            throw AppleCalendarRegistrationError.invalidDate(dayText)
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.calendar = calendar
        event.startDate = startDate
        event.endDate = endDate
        try eventStore.save(event, span: .thisEvent, commit: false)
    }

    private func date(yearMonth: YearMonth, dayText: String, minutes: Int) -> Date? {
        guard let day = Int(dayText) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: yearMonth.year,
                month: yearMonth.month,
                day: day,
                hour: minutes / 60,
                minute: minutes % 60
            )
        )
    }

    private func normalizedTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "／", with: "/")
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum AppleCalendarRegistrationError: LocalizedError {
    case accessDenied
    case calendarNotFound
    case missingYearMonth
    case invalidDate(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "カレンダーへのアクセスが許可されていません。カレンダー一覧を取得してください。"
        case .calendarNotFound:
            return "登録先のAppleカレンダーが見つからないか、書き込みできません。"
        case .missingYearMonth:
            return "勤務表の年月を取得できませんでした。"
        case .invalidDate(let day):
            return "日付を作成できませんでした: \(day)"
        case .invalidResponse:
            return "Appleカレンダーから無効な応答が返されました。"
        }
    }
}
