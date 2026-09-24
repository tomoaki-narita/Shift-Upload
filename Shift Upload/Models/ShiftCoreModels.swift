import Foundation
import SwiftUI

struct ShiftDefinition: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var startMinutes: Int
    var endMinutes: Int

    var timeRangeText: String {
        "\(Self.timeText(from: startMinutes))-\(Self.timeText(from: endMinutes))"
    }

    init(id: UUID = UUID(), title: String, startMinutes: Int, endMinutes: Int) {
        self.id = id
        self.title = title
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""

        if let startMinutes = try container.decodeIfPresent(Int.self, forKey: .startMinutes),
           let endMinutes = try container.decodeIfPresent(Int.self, forKey: .endMinutes) {
            self.startMinutes = startMinutes
            self.endMinutes = endMinutes
            return
        }

        let oldTimeRange = try container.decodeIfPresent(String.self, forKey: .timeRange) ?? ""
        let parsedMinutes = Self.minutes(from: oldTimeRange)
        startMinutes = parsedMinutes?.start ?? 510
        endMinutes = parsedMinutes?.end ?? 1050
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(startMinutes, forKey: .startMinutes)
        try container.encode(endMinutes, forKey: .endMinutes)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case timeRange
        case startMinutes
        case endMinutes
    }

    private static func timeText(from minutes: Int) -> String {
        let clampedMinutes = min(max(minutes, 0), 1_439)
        return String(format: "%d:%02d", clampedMinutes / 60, clampedMinutes % 60)
    }

    private static func minutes(from timeRange: String) -> (start: Int, end: Int)? {
        let parts = timeRange.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let start = minutes(fromTimeText: parts[0]),
              let end = minutes(fromTimeText: parts[1]) else {
            return nil
        }

        return (start, end)
    }

    private static func minutes(fromTimeText text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }

        return hour * 60 + minute
    }
}

struct YearMonth: Hashable {
    let year: Int
    let month: Int

    static var current: YearMonth {
        let components = Calendar.current.dateComponents([.year, .month], from: Date())
        return YearMonth(year: components.year ?? 2026, month: components.month ?? 1)
    }

    var displayText: String {
        "\(year)年\(month)月"
    }

    func displayText(for locale: Locale) -> String {
        guard locale.identifier.hasPrefix("en") else {
            return displayText
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
            return "\(year)-\(month)"
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    func displayText(for day: Int, locale: Locale) -> String {
        guard locale.identifier.hasPrefix("en") else {
            return "\(year)年\(month)月\(day)日"
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return "\(year)-\(month)-\(day)"
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    var nextMonth: YearMonth {
        addingMonths(1)
    }

    var previousMonth: YearMonth {
        addingMonths(-1)
    }

    func addingMonths(_ offset: Int) -> YearMonth {
        let absoluteMonth = year * 12 + (month - 1) + offset
        return YearMonth(
            year: absoluteMonth / 12,
            month: absoluteMonth % 12 + 1
        )
    }

    var leadingBlankCount: Int {
        guard let weekdayIndex = weekdayIndex(for: 1) else {
            return 0
        }

        return weekdayIndex - 1
    }

    func weekdayIndex(for day: Int) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }

        return calendar.component(.weekday, from: date)
    }

    var numberOfDays: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        guard let date = calendar.date(from: DateComponents(year: year, month: month)),
              let range = calendar.range(of: .day, in: .month, for: date) else {
            return 31
        }

        return range.count
    }
}

enum ShiftDisplayMode: String, CaseIterable, Identifiable {
    case calendar
    case timeline
    case list

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .timeline:
            return "横並び"
        case .calendar:
            return "カレンダー"
        case .list:
            return "リスト"
        }
    }

    var systemImage: String {
        switch self {
        case .timeline:
            return "rectangle"
        case .calendar:
            return "calendar"
        case .list:
            return "list.bullet"
        }
    }
}
