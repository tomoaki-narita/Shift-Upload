import Foundation
import WidgetKit

struct CalHubWidgetRemoteConfiguration: Codable, Equatable {
    let googleCalendarID: String
    let googleShowJapaneseHolidays: Bool
    let notionDataSourceID: String
    let notionDateProperty: String
    let notionTitleProperty: String
    let notionTagProperty: String
    let notionTagValue: String
}

struct CalHubWidgetSnapshot: Codable, Equatable {
    let configurationKey: String
    let localeIdentifier: String
    let updatedAt: Date
    let events: [CalHubWidgetEvent]
    let sourceKind: String?
    let appleCalendarIdentifier: String?
    let remoteConfiguration: CalHubWidgetRemoteConfiguration?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.configurationKey == rhs.configurationKey
            && lhs.localeIdentifier == rhs.localeIdentifier
            && lhs.events == rhs.events
            && lhs.sourceKind == rhs.sourceKind
            && lhs.appleCalendarIdentifier == rhs.appleCalendarIdentifier
            && lhs.remoteConfiguration == rhs.remoteConfiguration
    }
}

struct CalHubWidgetNavigation: Equatable {
    let id: UUID
    let date: Date
    let eventID: String?
    let registerEvent: Bool
    let opensCalendar: Bool

    init(
        date: Date,
        eventID: String? = nil,
        registerEvent: Bool = false,
        opensCalendar: Bool = false
    ) {
        id = UUID()
        self.date = date
        self.eventID = eventID
        self.registerEvent = registerEvent
        self.opensCalendar = opensCalendar
    }
}

struct CalHubWidgetEvent: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let date: Date
    let startDate: Date?
    let endDate: Date?
    let isAllDay: Bool
    let isRestEvent: Bool
    let red: Double?
    let green: Double?
    let blue: Double?

    var accentComponents: (red: Double, green: Double, blue: Double) {
        if let red, let green, let blue { return (red, green, blue) }
        if isRestEvent { return (0.96, 0.23, 0.28) }
        return (0.25, 0.58, 0.95)
    }
}

enum CalHubWidgetSharedData {
    static let appGroupIdentifier = "group.net.unwraps.Shift-Hub"
    static let sundayInRedPreferenceKey = "calendarSundayInRedEnabled"
    static let widgetKind = "CalHubCalendarWidget"
    static let weeklyWidgetKind = "CalHubWeeklyCalendarWidget"
    private static let snapshotFileName = "calendar-widget-snapshot.json"

    static var isSundayInRedEnabled: Bool {
        UserDefaults(suiteName: appGroupIdentifier)?.bool(forKey: sundayInRedPreferenceKey) ?? false
    }

    static func reloadTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func save(_ snapshot: CalHubWidgetSnapshot) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return }

        let fileURL = container.appendingPathComponent(snapshotFileName)
        if let existingData = try? Data(contentsOf: fileURL),
           let existing = try? JSONDecoder().decode(CalHubWidgetSnapshot.self, from: existingData),
           existing == snapshot {
            return
        }

        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            #if DEBUG
            print("Widget snapshot write failed: \(error.localizedDescription)")
            #endif
        }
    }

    static func load() -> CalHubWidgetSnapshot? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return nil }
        let fileURL = container.appendingPathComponent(snapshotFileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CalHubWidgetSnapshot.self, from: data)
    }

    static func url(
        for date: Date,
        eventID: String? = nil,
        registerEvent: Bool = false,
        opensCalendar: Bool = false,
        calendar: Calendar = .current
    ) -> URL? {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return nil }
        components.timeZone = calendar.timeZone
        var urlComponents = URLComponents()
        urlComponents.scheme = "calhub"
        urlComponents.host = "calendar"
        var queryItems = [URLQueryItem(
            name: "date",
            value: String(format: "%04d-%02d-%02d", year, month, day)
        )]
        if let eventID {
            queryItems.append(URLQueryItem(name: "event", value: eventID))
        }
        if registerEvent {
            queryItems.append(URLQueryItem(name: "action", value: "register"))
        }
        if opensCalendar {
            queryItems.append(URLQueryItem(name: "view", value: "month"))
        }
        urlComponents.queryItems = queryItems
        return urlComponents.url
    }

    static func date(from url: URL, calendar: Calendar = .current) -> Date? {
        guard url.scheme == "calhub",
              url.host == "calendar",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "date" })?.value else { return nil }
        let pieces = value.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2]))
    }

    static func eventID(from url: URL) -> String? {
        guard url.scheme == "calhub", url.host == "calendar" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "event" })?.value
    }

    static func requestsEventRegistration(from url: URL) -> Bool {
        guard url.scheme == "calhub", url.host == "calendar" else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "action" })?.value == "register"
    }

    static func requestsCalendarView(from url: URL) -> Bool {
        guard url.scheme == "calhub", url.host == "calendar" else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "view" })?.value == "month"
    }
}
