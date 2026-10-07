import Foundation

struct JapaneseHolidayCalendarClient {
    private static let sourceURL = URL(string: "https://www8.cao.go.jp/chosei/shukujitsu/syukujitsu.csv")!
    private static let cachedCSVKey = "japaneseHolidayCSV"
    private static let cachedAtKey = "japaneseHolidayCSVFetchedAt"
    private static let refreshInterval: TimeInterval = 30 * 24 * 60 * 60

    private struct Holiday {
        let date: Date
        let title: String
    }

    static func fetchEvents(
        yearMonth: YearMonth,
        color: CalendarDisplayColor?,
        locale: Locale
    ) async throws -> [CalendarEventRecord] {
        let holidays = try await loadHolidays()
        let calendar = Calendar(identifier: .gregorian)
        guard let monthStart = calendar.date(from: DateComponents(year: yearMonth.year, month: yearMonth.month)),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
            return []
        }

        return holidays
            .filter { $0.date >= monthStart && $0.date < nextMonth }
            .map { holiday in
                let day = calendar.component(.day, from: holiday.date)
                let dateKey = Self.dateKey(holiday.date)
                return CalendarEventRecord(
                    id: "japanese-holiday-\(dateKey)",
                    day: day,
                    title: localizedTitle(holiday.title, locale: locale),
                    detail: "終日",
                    isAllDay: true,
                    startDate: holiday.date,
                    endDate: holiday.date,
                    metadata: .empty,
                    calendarColor: color,
                    isReadOnly: true
                )
            }
    }

    private static func loadHolidays() async throws -> [Holiday] {
        let defaults = UserDefaults.standard
        let cachedCSV = defaults.string(forKey: cachedCSVKey)
        let cachedAt = defaults.object(forKey: cachedAtKey) as? Date

        if let cachedCSV,
           let cachedAt,
           Date().timeIntervalSince(cachedAt) < refreshInterval {
            return correctedHolidays(parse(cachedCSV))
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: sourceURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  200..<300 ~= httpResponse.statusCode else {
                throw URLError(.badServerResponse)
            }

            let csv = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .shiftJIS)
            guard let csv, !csv.isEmpty else {
                throw URLError(.cannotDecodeContentData)
            }

            defaults.set(csv, forKey: cachedCSVKey)
            defaults.set(Date(), forKey: cachedAtKey)
            return correctedHolidays(parse(csv))
        } catch {
            if let cachedCSV {
                return correctedHolidays(parse(cachedCSV))
            }
            throw error
        }
    }

    private static func parse(_ csv: String) -> [Holiday] {
        let calendar = Calendar(identifier: .gregorian)
        return csv
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line in
                let columns = line.split(separator: ",", omittingEmptySubsequences: false)
                guard columns.count >= 2 else { return nil }

                let dateText = columns[0]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
                    .replacingOccurrences(of: "-", with: "/")
                let title = columns[1]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let dateParts = dateText.split(separator: "/").compactMap { Int($0) }
                guard dateParts.count == 3,
                      let date = calendar.date(from: DateComponents(
                          year: dateParts[0],
                          month: dateParts[1],
                          day: dateParts[2]
                      )),
                      !title.isEmpty else {
                    return nil
                }
                return Holiday(date: date, title: title)
            }
    }

    private static func correctedHolidays(_ holidays: [Holiday]) -> [Holiday] {
        let calendar = Calendar(identifier: .gregorian)
        let sortedHolidays = holidays.sorted { $0.date < $1.date }
        let holidayByDate = Dictionary(uniqueKeysWithValues: sortedHolidays.map { ($0.date, $0) })
        let sundayHolidayNames = sortedHolidays.reduce(into: [Date: String]()) { result, holiday in
            guard holiday.title != "休日",
                  calendar.component(.weekday, from: holiday.date) == 1 else {
                return
            }
            result[holiday.date] = holiday.title
        }

        var substituteHolidayNames: [Date: String] = [:]
        for (sundayDate, holidayName) in sundayHolidayNames {
            var candidateDate = calendar.date(byAdding: .day, value: 1, to: sundayDate)
            while let date = candidateDate,
                  let holiday = holidayByDate[date],
                  holiday.title != "休日" {
                candidateDate = calendar.date(byAdding: .day, value: 1, to: date)
            }
            guard let candidateDate,
                  holidayByDate[candidateDate]?.title == "休日" else {
                continue
            }
            substituteHolidayNames[candidateDate] = "\(holidayName) 振替休日"
        }

        return sortedHolidays.map { holiday in
            guard holiday.title == "休日" else {
                return holiday
            }
            if let substituteName = substituteHolidayNames[holiday.date] {
                return Holiday(date: holiday.date, title: substituteName)
            }

            let previousDate = calendar.date(byAdding: .day, value: -1, to: holiday.date)
            let nextDate = calendar.date(byAdding: .day, value: 1, to: holiday.date)
            let isBetweenNationalHolidays =
                previousDate.flatMap { holidayByDate[$0]?.title }?.isEmpty == false &&
                nextDate.flatMap { holidayByDate[$0]?.title }?.isEmpty == false

            if isBetweenNationalHolidays {
                return Holiday(date: holiday.date, title: "国民の休日")
            }
            return holiday
        }
    }

    private static func localizedTitle(_ title: String, locale: Locale) -> String {
        guard ShiftHubLocalization.isEnglish(locale) else {
            return title
        }

        let substituteSuffix = " 振替休日"
        if title.hasSuffix(substituteSuffix) {
            let baseTitle = String(title.dropLast(substituteSuffix.count))
            return "\(englishName(for: baseTitle)) Substitute Holiday"
        }

        switch title {
        case "休日":
            return "Holiday"
        case "振替休日":
            return "Substitute Holiday"
        case "国民の休日":
            return "Holiday between National Holidays"
        default:
            return englishName(for: title)
        }
    }

    private static func englishName(for title: String) -> String {
        let names: [String: String] = [
            "元日": "New Year's Day",
            "成人の日": "Coming of Age Day",
            "建国記念の日": "National Foundation Day",
            "天皇誕生日": "Emperor's Birthday",
            "春分の日": "Vernal Equinox Day",
            "昭和の日": "Showa Day",
            "憲法記念日": "Constitution Memorial Day",
            "みどりの日": "Greenery Day",
            "こどもの日": "Children's Day",
            "海の日": "Marine Day",
            "山の日": "Mountain Day",
            "敬老の日": "Respect for the Aged Day",
            "秋分の日": "Autumnal Equinox Day",
            "スポーツの日": "Sports Day",
            "文化の日": "Culture Day",
            "勤労感謝の日": "Labor Thanksgiving Day"
        ]
        return names[title] ?? title
    }

    private static func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
