import Foundation
import CoreGraphics
import SwiftUI

struct CalendarEventMetadata: Equatable, Hashable {
    var notes: String = ""
    var location: String = ""
    var url: String = ""
    var tagValue: String = ""
    var propertyValues: [String: String] = [:]

    nonisolated static let empty = CalendarEventMetadata()

    nonisolated var isEmpty: Bool {
        notes.isEmpty && location.isEmpty && url.isEmpty && tagValue.isEmpty && propertyValues.isEmpty
    }

    nonisolated var normalized: CalendarEventMetadata {
        CalendarEventMetadata(
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            location: location.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            tagValue: tagValue.trimmingCharacters(in: .whitespacesAndNewlines),
            propertyValues: propertyValues.reduce(into: [:]) { result, item in
                result[item.key] = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
    }
}

struct CalendarEventDraft: Equatable, Hashable {
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var metadata: CalendarEventMetadata = .empty
}

struct CalendarEventMetadataFieldLabels: Equatable, Hashable {
    let notes: String
    let location: String
    let url: String
    let tag: String
    let notesIsAvailable: Bool
    let locationIsAvailable: Bool
    let urlIsAvailable: Bool
    let tagIsAvailable: Bool
    let tagDefaultValue: String
    let additionalProperties: [NotionPropertyOption]
    let defaultPropertyValues: [String: String]

    var hasAvailableFields: Bool {
        notesIsAvailable || locationIsAvailable || urlIsAvailable || tagIsAvailable
            || !additionalProperties.isEmpty
    }
}

struct CalendarDisplayColor: Hashable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    nonisolated init?(hex: String) {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard normalized.count == 6,
              let value = UInt64(normalized, radix: 16) else {
            return nil
        }

        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
        alpha = 1
    }

    nonisolated init?(cgColor: CGColor) {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: colorSpace, intent: .defaultIntent, options: nil),
              let components = converted.components,
              components.count >= 3 else {
            return nil
        }

        red = Double(components[0])
        green = Double(components[1])
        blue = Double(components[2])
        alpha = Double(converted.alpha)
    }
}

struct CalendarEventRecord: Identifiable, Hashable {
    let id: String
    let day: Int
    let title: String
    let detail: String
    let isAllDay: Bool
    let startDate: Date?
    let endDate: Date?
    let metadata: CalendarEventMetadata
    let calendarColor: CalendarDisplayColor?
    let isReadOnly: Bool

    nonisolated init(
        id: String,
        day: Int,
        title: String,
        detail: String,
        isAllDay: Bool,
        startDate: Date? = nil,
        endDate: Date? = nil,
        metadata: CalendarEventMetadata = .empty,
        calendarColor: CalendarDisplayColor?,
        isReadOnly: Bool = false
    ) {
        self.id = id
        self.day = day
        self.title = title
        self.detail = detail
        self.isAllDay = isAllDay
        self.startDate = startDate
        self.endDate = endDate
        self.metadata = metadata
        self.calendarColor = calendarColor
        self.isReadOnly = isReadOnly
    }

    var isRestEvent: Bool {
        let normalizedTitle = title
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ["休", "休み", "休日", "off"].contains(normalizedTitle)
    }

    var spansMultipleDays: Bool {
        guard let startDate, let endDate else { return false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.startOfDay(for: endDate) > calendar.startOfDay(for: startDate)
    }

    func menuDetail(locale: Locale) -> String {
        guard spansMultipleDays,
              let startDate,
              let endDate else {
            if detail.isEmpty || detail == "終日" || detail == "All day" {
                return ShiftHubLocalization.string("終日", locale: locale)
            }
            return detail
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = isAllDay ? "MM-dd" : "MM-dd H:mm"
        return "\(formatter.string(from: startDate)) - \(formatter.string(from: endDate))"
    }

    func starts(on day: Int, in yearMonth: YearMonth) -> Bool {
        guard let startDate else { return self.day == day }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: startDate)
        return components.year == yearMonth.year
            && components.month == yearMonth.month
            && components.day == day
    }

    func occurs(on date: Date, fallbackYearMonth: YearMonth?) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let targetDay = calendar.startOfDay(for: date)

        if let startDate {
            let startDay = calendar.startOfDay(for: startDate)
            let endDay = calendar.startOfDay(for: endDate ?? startDate)
            return targetDay >= startDay && targetDay <= endDay
        }

        guard let fallbackYearMonth,
              let fallbackDate = calendar.date(from: DateComponents(
                  year: fallbackYearMonth.year,
                  month: fallbackYearMonth.month,
                  day: day
              )) else {
            return false
        }

        return calendar.isDate(targetDay, inSameDayAs: fallbackDate)
    }

    var confirmationText: String {
        let displayedDetail = menuDetail(locale: Locale(identifier: "ja"))
        return displayedDetail.isEmpty ? "\(day)日の「\(title)」" : "\(day)日の「\(title)」\n\(displayedDetail)"
    }
}

struct CalendarEventDisplaySegment: Identifiable, Hashable {
    let event: CalendarEventRecord
    let startDay: Int
    let endDay: Int

    var id: String {
        "\(event.id)-\(startDay)-\(endDay)"
    }

    var spanDays: Int {
        endDay - startDay + 1
    }

    func contains(day: Int) -> Bool {
        (startDay...endDay).contains(day)
    }
}

struct CalendarBandEventSelection: Identifiable {
    let event: CalendarEventRecord
    let yearMonth: YearMonth
    let day: Int

    var id: String {
        "\(event.id)-\(day)"
    }
}

struct CalendarEventBandLayout: Identifiable, Hashable {
    let event: CalendarEventRecord
    let startDay: Int
    let endDay: Int
    let lane: Int

    var id: String {
        "\(event.id)-\(startDay)-\(endDay)"
    }

    var spanDays: Int {
        endDay - startDay + 1
    }

    func contains(day: Int) -> Bool {
        (startDay...endDay).contains(day)
    }
}

struct CalendarEventBandMetrics {
    let top: CGFloat
    let contentSpacing: CGFloat
    let gap: CGFloat
    let height: CGFloat
    let laneHeight: CGFloat
}

struct CalendarEventBandShape: Shape {
    let squareLeading: Bool
    let squareTrailing: Bool

    func path(in rect: CGRect) -> Path {
#if os(macOS)
        let radius = min(10, min(rect.width, rect.height) / 2)
#else
        let radius = min(6, min(rect.width, rect.height) / 2)
#endif
        let topLeading = squareLeading ? 0 : radius
        let bottomLeading = squareLeading ? 0 : radius
        let topTrailing = squareTrailing ? 0 : radius
        let bottomTrailing = squareTrailing ? 0 : radius

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeading, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topTrailing, y: rect.minY))
        if topTrailing > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - topTrailing, y: rect.minY + topTrailing),
                radius: topTrailing,
                startAngle: .degrees(-90),
                endAngle: .degrees(0),
                clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomTrailing))
        if bottomTrailing > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - bottomTrailing, y: rect.maxY - bottomTrailing),
                radius: bottomTrailing,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: rect.minX + bottomLeading, y: rect.maxY))
        if bottomLeading > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + bottomLeading, y: rect.maxY - bottomLeading),
                radius: bottomLeading,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeading))
        if topLeading > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + topLeading, y: rect.minY + topLeading),
                radius: topLeading,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
        }
        path.closeSubpath()
        return path
    }
}

func calendarEventComesBefore(
    _ lhs: CalendarEventRecord,
    _ rhs: CalendarEventRecord
) -> Bool {
    if lhs.isReadOnly != rhs.isReadOnly {
        return !lhs.isReadOnly
    }

    switch (lhs.startDate, rhs.startDate) {
    case let (lhsDate?, rhsDate?):
        if lhsDate != rhsDate {
            return lhsDate < rhsDate
        }
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    default:
        break
    }

    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
}

struct CalendarDaySelection: Hashable {
    let year: Int
    let month: Int
    let day: Int

    var yearMonth: YearMonth {
        YearMonth(year: year, month: month)
    }
}

struct CalendarGridDate: Identifiable, Hashable {
    let date: Date
    let yearMonth: YearMonth
    let day: Int
    let slot: Int
    let displayedMonth: YearMonth

    var id: Date { date }

    var isInDisplayedMonth: Bool {
        yearMonth == displayedMonth
    }
}
