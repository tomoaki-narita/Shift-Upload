import SwiftUI
import WidgetKit
import EventKit

private struct CalHubWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: CalHubWidgetSnapshot?
}

private struct CalHubWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> CalHubWidgetEntry {
        CalHubWidgetEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (CalHubWidgetEntry) -> Void) {
        Task {
            completion(CalHubWidgetEntry(date: .now, snapshot: await currentSnapshot()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CalHubWidgetEntry>) -> Void) {
        Task {
            let now = Date()
            let snapshot = await currentSnapshot()
            var dates = [now]
        if let snapshot {
            for event in snapshot.events {
                for boundary in [event.startDate, event.endDate].compactMap({ $0 }) where boundary > now {
                    dates.append(boundary)
                }
            }
        }
        if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) {
            dates.append(tomorrow)
        }
        let entries = Array(Set(dates)).sorted().map {
            CalHubWidgetEntry(date: $0, snapshot: snapshot)
        }
            let refreshInterval: TimeInterval = snapshot?.sourceKind == "apple"
                ? 30 * 60
                : 60 * 60
            completion(Timeline(
                entries: entries,
                policy: .after(now.addingTimeInterval(refreshInterval))
            ))
        }
    }

    private func currentSnapshot() async -> CalHubWidgetSnapshot? {
        guard let cachedSnapshot = CalHubWidgetSharedData.load() else { return nil }
        if cachedSnapshot.sourceKind == "apple" {
            return refreshedAppleCalendarSnapshot(from: cachedSnapshot) ?? cachedSnapshot
        }
        if ["google", "notion"].contains(cachedSnapshot.sourceKind),
           Date().timeIntervalSince(cachedSnapshot.updatedAt) >= 60 * 60 {
            return await CalHubRemoteSnapshotLoader.refresh(cachedSnapshot) ?? cachedSnapshot
        }
        return cachedSnapshot
    }

    private func refreshedAppleCalendarSnapshot(
        from cachedSnapshot: CalHubWidgetSnapshot?
    ) -> CalHubWidgetSnapshot? {
        guard let cachedSnapshot,
              cachedSnapshot.sourceKind == "apple",
              let calendarIdentifier = cachedSnapshot.appleCalendarIdentifier,
              !calendarIdentifier.isEmpty,
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return nil
        }

        let eventStore = EKEventStore()
        eventStore.refreshSourcesIfNecessary()
        guard let selectedCalendar = eventStore.calendar(withIdentifier: calendarIdentifier) else {
            return nil
        }

        let systemCalendar = Calendar.current
        let startDate = systemCalendar.startOfDay(for: .now)
        guard let monthStart = systemCalendar.dateInterval(of: .month, for: startDate)?.start,
              let endDate = systemCalendar.date(byAdding: .month, value: 2, to: monthStart) else {
            return nil
        }

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: [selectedCalendar]
        )
        let fallbackAccent = cachedSnapshot.events.first.map {
            (red: $0.red, green: $0.green, blue: $0.blue)
        }
        let events = eventStore.events(matching: predicate).compactMap { event -> CalHubWidgetEvent? in
            guard let identifier = event.eventIdentifier else { return nil }
            let title = (event.title?.isEmpty == false ? event.title : nil) ?? "Untitled"
            return CalHubWidgetEvent(
                id: identifier,
                title: title,
                detail: event.isAllDay ? "All day" : "",
                date: systemCalendar.startOfDay(for: event.startDate),
                startDate: event.startDate,
                endDate: event.isAllDay ? nil : event.endDate,
                isAllDay: event.isAllDay,
                isRestEvent: isRestEventTitle(title),
                red: fallbackAccent?.red,
                green: fallbackAccent?.green,
                blue: fallbackAccent?.blue
            )
        }

        let tomorrow = systemCalendar.date(byAdding: .day, value: 1, to: startDate) ?? startDate
        let cachedHasFutureEvents = cachedSnapshot.events.contains {
            ($0.startDate ?? $0.date) >= tomorrow
        }
        let refreshedHasFutureEvents = events.contains {
            ($0.startDate ?? $0.date) >= tomorrow
        }
        guard !cachedHasFutureEvents || refreshedHasFutureEvents else {
            return nil
        }

        return CalHubWidgetSnapshot(
            configurationKey: cachedSnapshot.configurationKey,
            localeIdentifier: cachedSnapshot.localeIdentifier,
            updatedAt: .now,
            events: events,
            sourceKind: cachedSnapshot.sourceKind,
            appleCalendarIdentifier: calendarIdentifier,
            remoteConfiguration: cachedSnapshot.remoteConfiguration,
            sourceRed: cachedSnapshot.sourceRed,
            sourceGreen: cachedSnapshot.sourceGreen,
            sourceBlue: cachedSnapshot.sourceBlue,
            metadataOptionColors: cachedSnapshot.metadataOptionColors
        )
    }

    private func isRestEventTitle(_ title: String) -> Bool {
        let normalizedTitle = title
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ["休", "休み", "休日", "off"].contains(normalizedTitle)
    }
}

private enum CalHubWidgetFormat {
    static var isSundayInRedEnabled: Bool {
        CalHubWidgetSharedData.isSundayInRedEnabled
    }

    static func isSunday(_ date: Date) -> Bool {
        Calendar.current.component(.weekday, from: date) == 1
    }

    static func cardBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.15, green: 0.15, blue: 0.15)
            : Color(red: 0.96, green: 0.96, blue: 0.96)
    }

    static func locale(_ entry: CalHubWidgetEntry) -> Locale {
        Locale(identifier: entry.snapshot?.localeIdentifier ?? Locale.current.identifier)
    }

    static func date(_ date: Date, format: String, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static func eventTime(_ event: CalHubWidgetEvent, locale: Locale) -> String {
        if event.isAllDay { return locale.identifier.hasPrefix("ja") ? "終日" : "All day" }
        guard let start = event.startDate else { return event.detail }
        let timeFormat = locale.identifier.hasPrefix("ja") ? "H:mm" : "h:mm a"
        let startText = date(start, format: timeFormat, locale: locale)
        guard let end = event.endDate else { return startText }
        return "\(startText)–\(date(end, format: timeFormat, locale: locale))"
    }

    static func occurs(_ event: CalHubWidgetEvent, on date: Date) -> Bool {
        let calendar = Calendar.current
        let target = calendar.startOfDay(for: date)
        if let start = event.startDate {
            let first = calendar.startOfDay(for: start)
            let last = calendar.startOfDay(for: event.endDate ?? start)
            return target >= first && target <= last
        }
        return calendar.isDate(event.date, inSameDayAs: target)
    }

    static func startsAfterNow(_ event: CalHubWidgetEvent, now: Date) -> Bool {
        guard let end = event.endDate else {
            return Calendar.current.startOfDay(for: event.date) >= Calendar.current.startOfDay(for: now)
        }
        return end > now
    }

    static func hasNotStarted(_ event: CalHubWidgetEvent, now: Date) -> Bool {
        (event.startDate ?? event.date) > now
    }

    static func isAllDaySpan(_ event: CalHubWidgetEvent) -> Bool {
        guard !event.isAllDay,
              let start = event.startDate,
              let end = event.endDate else {
            return event.isAllDay
        }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: start)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return false
        }
        return start.timeIntervalSince(dayStart) < 60
            && end >= nextDay.addingTimeInterval(-60)
            && end < nextDay
    }

    static func stableSorted<T>(
        _ elements: [T],
        by areInIncreasingOrder: (T, T) -> Bool
    ) -> [T] {
        elements.enumerated().sorted { lhs, rhs in
            if areInIncreasingOrder(lhs.element, rhs.element) { return true }
            if areInIncreasingOrder(rhs.element, lhs.element) { return false }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func eventComesBefore(
        _ lhs: CalHubWidgetEvent,
        _ rhs: CalHubWidgetEvent,
        descending: Bool = false
    ) -> Bool {
        let lhsStart = lhs.startDate ?? lhs.date
        let rhsStart = rhs.startDate ?? rhs.date
        if lhsStart != rhsStart {
            return descending ? lhsStart > rhsStart : lhsStart < rhsStart
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    static func events(on date: Date, snapshot: CalHubWidgetSnapshot?) -> [CalHubWidgetEvent] {
        stableSorted((snapshot?.events ?? []).filter { occurs($0, on: date) }) {
            eventComesBefore($0, $1)
        }
    }

    static func prioritizedEvents(
        _ events: [CalHubWidgetEvent],
        now: Date,
        limit: Int
    ) -> [CalHubWidgetEvent] {
        let upcoming = events.filter { hasNotStarted($0, now: now) }
        let timedEventCount = events.filter { !isAllDaySpan($0) }.count
        let shouldHideAllDayTitle = timedEventCount >= 4
        let inProgress = stableSorted(events.filter {
            !hasNotStarted($0, now: now) && startsAfterNow($0, now: now)
        }) {
            eventComesBefore($0, $1)
        }
        let past = stableSorted(events.filter { !startsAfterNow($0, now: now) }) {
            eventComesBefore($0, $1, descending: true)
        }
        var selected = Array((upcoming + inProgress + past).prefix(limit))
        if !shouldHideAllDayTitle,
           limit > 0,
           let allDayEvent = events.first(where: isAllDaySpan),
           !selected.contains(where: { $0.id == allDayEvent.id }) {
            selected = Array(selected.prefix(limit - 1)) + [allDayEvent]
        }
        return stableSorted(selected) {
            eventComesBefore($0, $1)
        }
    }

    static func eventsForDisplay(_ events: [CalHubWidgetEvent], now: Date) -> [CalHubWidgetEvent] {
        let currentEvents = events.filter { isAllDaySpan($0) || startsAfterNow($0, now: now) }
        let timedEventCount = currentEvents.filter { !isAllDaySpan($0) }.count
        guard timedEventCount >= 4 else { return currentEvents }
        return currentEvents.filter { !isAllDaySpan($0) }
    }

    static func upcoming(snapshot: CalHubWidgetSnapshot?, now: Date, limit: Int) -> [CalHubWidgetEvent] {
        Array(stableSorted((snapshot?.events ?? []).filter { startsAfterNow($0, now: now) }) {
            eventComesBefore($0, $1)
        }.prefix(limit))
    }

    static func accent(_ event: CalHubWidgetEvent) -> Color {
        let components = event.accentComponents
        return Color(red: components.red, green: components.green, blue: components.blue)
    }

    static func deepLink(
        _ date: Date,
        eventID: String? = nil,
        registerEvent: Bool = false,
        opensCalendar: Bool = false
    ) -> URL? {
        CalHubWidgetSharedData.url(
            for: date,
            eventID: eventID,
            registerEvent: registerEvent,
            opensCalendar: opensCalendar
        )
    }
}

private enum CalHubWidgetLayout {
    static let eventLineWidth: CGFloat = 4
    static let allDayMarkerSpacing: CGFloat = 4
    static let allDayMarkerLeadingInset: CGFloat = 2
    static let capsuleTitleSpacing: CGFloat = 7
    static var allDayTitleInset: CGFloat {
        max(capsuleTitleSpacing - allDayMarkerSpacing + allDayMarkerLeadingInset, 0)
    }

    static func markerLeadingPadding(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return allDayMarkerLeadingInset + CGFloat(count) * (eventLineWidth + allDayMarkerSpacing)
    }
}

private struct CalHubWidgetDateMark: View {
    let date: Date
    let locale: Locale
    let headerSize: CGFloat
    let dateSize: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(CalHubWidgetFormat.date(date, format: "d", locale: locale))
                .font(.system(size: dateSize, weight: .bold))
                .foregroundStyle(
                    CalHubWidgetFormat.isSundayInRedEnabled && CalHubWidgetFormat.isSunday(date)
                        ? Color.red
                        : Color.primary
                )
                .lineLimit(1)
                .minimumScaleFactor(0.45)
            VStack(alignment: .center, spacing: 0) {
                Text(CalHubWidgetFormat.date(date, format: locale.identifier.hasPrefix("ja") ? "M" : "MMM", locale: locale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(CalHubWidgetFormat.date(date, format: "EEE", locale: locale))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .font(.system(size: headerSize, weight: .bold))
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct CalHubWidgetEventRow: View {
    let event: CalHubWidgetEvent
    let locale: Locale
    let titleSize: CGFloat
    let isPrimary: Bool
    var capsuleHeight: CGFloat = 30
    var timeSize: CGFloat = 12
    var titleFont: Font? = nil
    var timeFont: Font? = nil
    var titleMinimumScaleFactor: CGFloat = 0.45
    var timeMinimumScaleFactor: CGFloat = 0.65
    var trailingText: String? = nil
    var trailingTextFont: Font? = nil
    var showsCapsule = true
    var reservesCapsuleSpace = false
    var capsuleTitleSpacing: CGFloat = CalHubWidgetLayout.capsuleTitleSpacing
    var capsuleMatchesContentHeight = false
    var textLeadingInset: CGFloat = 0

    private var reservesCapsule: Bool {
        showsCapsule || reservesCapsuleSpace
    }

    private var eventText: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(event.title)
                .font(titleFont ?? .system(size: titleSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(titleMinimumScaleFactor)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(CalHubWidgetFormat.eventTime(event, locale: locale))
                    .font(timeFont ?? .system(size: timeSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(timeMinimumScaleFactor)
                Spacer(minLength: 5)
                if let trailingText {
                    Text(trailingText)
                        .font(trailingTextFont ?? .caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .foregroundStyle(isPrimary ? Color.primary : Color.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        Group {
            if capsuleMatchesContentHeight {
                eventText
                    .padding(.leading, reservesCapsule ? capsuleTitleSpacing + 4 : textLeadingInset)
                    .background(alignment: .leading) {
                        if reservesCapsule {
                            GeometryReader { geometry in
                                Capsule()
                                    .fill(showsCapsule ? CalHubWidgetFormat.accent(event) : .clear)
                                    .frame(width: CalHubWidgetLayout.eventLineWidth, height: geometry.size.height)
                            }
                        }
                    }
            } else {
                HStack(
                    alignment: .center,
                    spacing: reservesCapsule ? capsuleTitleSpacing : 0
                ) {
                    if reservesCapsule {
                        Capsule()
                            .fill(showsCapsule ? CalHubWidgetFormat.accent(event) : .clear)
                            .frame(width: CalHubWidgetLayout.eventLineWidth, height: capsuleHeight)
                    }
                    eventText
                        .padding(.leading, reservesCapsule ? 0 : textLeadingInset)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct CalHubWidgetAllDayMarkers: View {
    let events: [CalHubWidgetEvent]
    let height: CGFloat

    var body: some View {
        HStack(spacing: CalHubWidgetLayout.allDayMarkerSpacing) {
            ForEach(events) { event in
                Capsule()
                    .fill(CalHubWidgetFormat.accent(event))
                    .frame(width: CalHubWidgetLayout.eventLineWidth, height: height)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CalHubSmallWidgetView: View {
    let entry: CalHubWidgetEntry

    var body: some View {
        let locale = CalHubWidgetFormat.locale(entry)
        let today = Calendar.current.startOfDay(for: entry.date)
        let events = CalHubWidgetFormat.events(on: today, snapshot: entry.snapshot)
        let displayableEvents = CalHubWidgetFormat.eventsForDisplay(events, now: entry.date)
        let displayedEvent = displayableEvents.first {
            CalHubWidgetFormat.hasNotStarted($0, now: entry.date)
        } ?? displayableEvents.last {
            CalHubWidgetFormat.startsAfterNow($0, now: entry.date)
        } ?? displayableEvents.last
        let allDayMarkerEvents = displayableEvents.filter(CalHubWidgetFormat.isAllDaySpan)
        let futureEventCount = displayableEvents.filter {
            CalHubWidgetFormat.hasNotStarted($0, now: entry.date)
        }.count
        let displayedFutureEventCount = displayedEvent.map {
            CalHubWidgetFormat.hasNotStarted($0, now: entry.date) ? 1 : 0
        } ?? 0
        let remainingCount = max(futureEventCount - displayedFutureEventCount, 0)
        let displayedEventIsPrimary = displayedEvent.map {
            CalHubWidgetFormat.startsAfterNow($0, now: entry.date)
        } ?? false
        GeometryReader { geometry in
            let contentWidth = max(geometry.size.width - 24, 1)
            let contentHeight = max(geometry.size.height - 16, 1)
            let titleSize = min(max(contentWidth * 0.14, 16), 20)
            let headerSize = min(max(contentWidth * 0.19, 19), 22)
            let headerWidth = min(max(contentWidth * 0.25, 29), 40)
            let eventCapsuleHeight = titleSize * 1.2 + 12 * 1.2 - 1
            let eventHeight = displayedEvent == nil
                ? headerSize * 2
                : titleSize + 14 + (remainingCount > 0 ? 12 : 0)
            let dateWidth = max(contentWidth - headerWidth - 2, 1)
            let dateHeight = max(contentHeight - eventHeight - 8, 1)
            let dateSize = min(dateWidth, dateHeight)

            VStack(alignment: .leading, spacing: 0) {
                CalHubWidgetDateMark(date: today, locale: locale, headerSize: headerSize, dateSize: dateSize)

                if let displayedEvent {
                    if remainingCount == 0 {
                        Spacer(minLength: 0)
                    }
                    HStack(alignment: .center, spacing: 4) {
                        if !allDayMarkerEvents.isEmpty {
                            CalHubWidgetAllDayMarkers(
                                events: allDayMarkerEvents,
                                height: eventCapsuleHeight
                            )
                        }
                        Link(destination: CalHubWidgetFormat.deepLink(today, eventID: displayedEvent.id)
                            ?? CalHubWidgetFormat.deepLink(today)!) {
                            CalHubWidgetEventRow(
                                event: displayedEvent,
                                locale: locale,
                                titleSize: titleSize,
                                isPrimary: displayedEventIsPrimary,
                                capsuleHeight: eventCapsuleHeight,
                                showsCapsule: !CalHubWidgetFormat.isAllDaySpan(displayedEvent)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    if remainingCount > 0 {
                        Spacer(minLength: 0)
                        HStack {
                            Spacer(minLength: 0)
                            Text("+\(remainingCount)\(locale.identifier.hasPrefix("ja") ? "件" : " more")")
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Spacer(minLength: 0)
                    }
                } else {
                    Spacer(minLength: 0)
                    Text(locale.identifier.hasPrefix("ja") ? "イベントはありません" : "No events")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
//            .padding(.horizontal, 12)
//            .padding(.vertical, 8)
        }
        .widgetURL(CalHubWidgetFormat.deepLink(today))
    }
}

private struct CalHubMediumWidgetView: View {
    let entry: CalHubWidgetEntry

    var body: some View {
        let locale = CalHubWidgetFormat.locale(entry)
        let today = Calendar.current.startOfDay(for: entry.date)
        let todayEvents = CalHubWidgetFormat.events(on: today, snapshot: entry.snapshot)
        let displayableEvents = CalHubWidgetFormat.eventsForDisplay(todayEvents, now: entry.date)
        #if os(macOS)
        let displayedEventLimit = 4
        #else
        let displayedEventLimit = 3
        #endif
        let displayedEvents = CalHubWidgetFormat.prioritizedEvents(
            displayableEvents,
            now: entry.date,
            limit: displayedEventLimit
        )
        let allDayMarkerEvents = todayEvents.filter(CalHubWidgetFormat.isAllDaySpan)
        let extendsSingleAllDayEvent = todayEvents.count == 1 && !allDayMarkerEvents.isEmpty
        let futureEventCount = todayEvents.filter {
            CalHubWidgetFormat.hasNotStarted($0, now: entry.date)
        }.count
        let displayedFutureEventCount = displayedEvents.filter {
            CalHubWidgetFormat.hasNotStarted($0, now: entry.date)
        }.count
        let remainingCount = max(futureEventCount - displayedFutureEventCount, 0)

        GeometryReader { geometry in
            let contentWidth = max(geometry.size.width, 1)
            let contentHeight = max(geometry.size.height, 1)
            let leftWidth = contentWidth * 0.39
            let headerSize = min(max(leftWidth * 0.19, 18), 24)
            let dateSize = min(leftWidth, max((contentHeight - headerSize * 1.2 + 6) / 1.2, 1))
            let rightWidth = max(contentWidth - leftWidth - 12, 1)
            let eventTitleSize = min(max(rightWidth * 0.095, 13), 16)
            let eventRowSpacing: CGFloat = remainingCount > 0 ? 2 : 4
            let markerLeadingPadding = allDayMarkerEvents.isEmpty
                ? 0
                : CalHubWidgetLayout.markerLeadingPadding(count: allDayMarkerEvents.count)

            HStack(spacing: 12) {
                VStack(spacing: -6) {
                    HStack(spacing: 5) {
                        Text(CalHubWidgetFormat.date(today, format: locale.identifier.hasPrefix("ja") ? "M" : "MMM", locale: locale))
                            .foregroundStyle(.secondary)
                        Text(CalHubWidgetFormat.date(today, format: "EEE", locale: locale))
                            .foregroundStyle(.red)
                    }
                    .font(.system(size: headerSize, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                    Text(CalHubWidgetFormat.date(today, format: "d", locale: locale))
                        .font(.system(size: dateSize, weight: .bold))
                        .foregroundStyle(
                            CalHubWidgetFormat.isSundayInRedEnabled && CalHubWidgetFormat.isSunday(today)
                                ? Color.red
                                : Color.primary
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                }
                .frame(width: leftWidth, height: contentHeight, alignment: .center)

                VStack(alignment: .leading, spacing: 0) {
                    if displayedEvents.isEmpty {
                        Text(locale.identifier.hasPrefix("ja") ? "イベントはありません" : "No events")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    } else {
                        GeometryReader { eventArea in
                            let markerBlockHeight = extendsSingleAllDayEvent
                                ? eventArea.size.height
                                : 0
                            VStack(spacing: 0) {
                                VStack(alignment: .leading, spacing: eventRowSpacing) {
                                    ForEach(displayedEvents.indices, id: \.self) { index in
                                        let event = displayedEvents[index]
                                        Link(destination: CalHubWidgetFormat.deepLink(today, eventID: event.id)
                                            ?? CalHubWidgetFormat.deepLink(today)!) {
                                            CalHubWidgetEventRow(
                                                event: event,
                                                locale: locale,
                                                titleSize: eventTitleSize,
                                                isPrimary: CalHubWidgetFormat.startsAfterNow(event, now: entry.date),
                                                timeSize: 10,
                                                trailingText: index == displayedEvents.count - 1 && remainingCount > 0
                                                    ? "+\(remainingCount)\(locale.identifier.hasPrefix("ja") ? "件" : " more")"
                                                    : nil,
                                                showsCapsule: !CalHubWidgetFormat.isAllDaySpan(event),
                                                reservesCapsuleSpace: !allDayMarkerEvents.isEmpty
                                                    && !CalHubWidgetFormat.isAllDaySpan(event),
                                                capsuleMatchesContentHeight: true,
                                                textLeadingInset: CalHubWidgetFormat.isAllDaySpan(event)
                                                    ? max(
                                                        CalHubWidgetLayout.capsuleTitleSpacing
                                                            - CalHubWidgetLayout.allDayMarkerSpacing,
                                                        0
                                                    )
                                                    : 0
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.leading, markerLeadingPadding)
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: markerBlockHeight,
                                    alignment: .topLeading
                                )
                                .background(alignment: .leading) {
                                    if !allDayMarkerEvents.isEmpty {
                                        GeometryReader { eventBlock in
                                            CalHubWidgetAllDayMarkers(
                                                events: allDayMarkerEvents,
                                                height: min(eventBlock.size.height, eventArea.size.height)
                                            )
                                            .padding(.leading, CalHubWidgetLayout.allDayMarkerLeadingInset)
                                        }
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(width: eventArea.size.width, height: eventArea.size.height)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.vertical, remainingCount > 0 ? 2 : 4)
                .padding(.trailing, 12)
            }
        }
        .widgetURL(CalHubWidgetFormat.deepLink(today))
    }
}

private struct CalHubLargeWidgetView: View {
    let entry: CalHubWidgetEntry

    var body: some View {
        let locale = CalHubWidgetFormat.locale(entry)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: entry.date)
        let weekday = calendar.component(.weekday, from: today)
        let weekStart = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today) ?? today
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
        let events = CalHubWidgetFormat.events(on: today, snapshot: entry.snapshot)
        let displayableEvents = CalHubWidgetFormat.eventsForDisplay(events, now: entry.date)
        #if os(macOS)
        let displayedEventLimit = 5
        #else
        let displayedEventLimit = 4
        #endif
        let displayedEvents = CalHubWidgetFormat.prioritizedEvents(
            displayableEvents,
            now: entry.date,
            limit: displayedEventLimit
        )
        let allDayMarkerEvents = events.filter(CalHubWidgetFormat.isAllDaySpan)
        let futureEventCount = events.filter {
            CalHubWidgetFormat.hasNotStarted($0, now: entry.date)
        }.count
        let displayedFutureEventCount = displayedEvents.filter {
            CalHubWidgetFormat.hasNotStarted($0, now: entry.date)
        }.count
        let remainingCount = max(futureEventCount - displayedFutureEventCount, 0)
        let eventTitleSize: CGFloat = 17
        let eventTimeSize: CGFloat = 12
        let eventCapsuleHeight = eventTitleSize * 1.2 + eventTimeSize * 1.2 - 1
        let eventRowSpacing: CGFloat = allDayMarkerEvents.isEmpty ? 0 : 3
        let markerLeadingPadding = allDayMarkerEvents.isEmpty
            ? 0
            : CalHubWidgetLayout.markerLeadingPadding(count: allDayMarkerEvents.count)
        GeometryReader { geometry in
            let headerSize = min(max(geometry.size.width * 0.065, 18), 26)
            let dateSize = min(max(geometry.size.width * 0.18, 48), 72)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    Text(CalHubWidgetFormat.date(today, format: "d", locale: locale))
                        .font(.system(size: dateSize, weight: .bold))
                        .foregroundStyle(
                            CalHubWidgetFormat.isSundayInRedEnabled && CalHubWidgetFormat.isSunday(today)
                                ? Color.red
                                : Color.primary
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(CalHubWidgetFormat.date(today, format: "MMMM", locale: locale))
                            .foregroundStyle(.secondary)
                        Text(CalHubWidgetFormat.date(today, format: "EEEE", locale: locale))
                            .foregroundStyle(.red)
                    }
                    .font(.system(size: headerSize, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    Spacer(minLength: 4)
                    Link(destination: CalHubWidgetFormat.deepLink(today, registerEvent: true)
                        ?? CalHubWidgetFormat.deepLink(today)!) {
                        Image(systemName: "plus")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        let isToday = calendar.isDate(day, inSameDayAs: today)
                        let isPast = calendar.startOfDay(for: day) < today
                        Link(destination: CalHubWidgetFormat.deepLink(day) ?? URL(string: "calhub://calendar")!) {
                            VStack(spacing: 4) {
                                let isSunday = CalHubWidgetFormat.isSunday(day)
                                Text(CalHubWidgetFormat.date(
                                    day,
                                    format: locale.identifier.hasPrefix("en") ? "EEE" : "EEEEE",
                                    locale: locale
                                ))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(
                                        CalHubWidgetFormat.isSundayInRedEnabled && isSunday
                                            ? Color.red
                                            : Color.secondary
                                    )
                                Text(CalHubWidgetFormat.date(day, format: "d", locale: locale))
                                    .font(.callout.weight(isToday ? .bold : .regular))
                                    .foregroundStyle(
                                        isToday || (CalHubWidgetFormat.isSundayInRedEnabled && isSunday)
                                            ? Color.red
                                            : Color.primary
                                    )
                                    .frame(width: 25, height: 25)
                            }
                            .frame(maxWidth: .infinity)
                            .opacity(isPast ? 0.38 : 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Divider()
                if displayedEvents.isEmpty {
                    Text(locale.identifier.hasPrefix("ja") ? "今日の予定なし" : "No events")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    GeometryReader { eventArea in
                        VStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: eventRowSpacing) {
                                ForEach(displayedEvents.indices, id: \.self) { index in
                                    let event = displayedEvents[index]
                                    let isAllDay = CalHubWidgetFormat.isAllDaySpan(event)
                                    Link(destination: CalHubWidgetFormat.deepLink(today, eventID: event.id)
                                        ?? CalHubWidgetFormat.deepLink(today)!) {
                                        CalHubWidgetEventRow(
                                            event: event,
                                            locale: locale,
                                            titleSize: eventTitleSize,
                                            isPrimary: CalHubWidgetFormat.startsAfterNow(event, now: entry.date),
                                            capsuleHeight: eventCapsuleHeight,
                                            timeSize: eventTimeSize,
                                            titleFont: .callout.weight(.semibold),
                                            timeFont: .caption,
                                            trailingText: index == displayedEvents.count - 1 && remainingCount > 0
                                                ? "+\(remainingCount)\(locale.identifier.hasPrefix("ja") ? "件" : " more")"
                                                : nil,
                                            showsCapsule: !isAllDay,
                                            reservesCapsuleSpace: !allDayMarkerEvents.isEmpty && !isAllDay,
                                            capsuleMatchesContentHeight: true,
                                            textLeadingInset: isAllDay
                                                ? max(
                                                    CalHubWidgetLayout.capsuleTitleSpacing
                                                        - CalHubWidgetLayout.allDayMarkerSpacing,
                                                    0
                                                )
                                                : 0
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                                }
                                .padding(.leading, markerLeadingPadding)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .background(alignment: .leading) {
                                    if !allDayMarkerEvents.isEmpty {
                                        GeometryReader { eventBlock in
                                            CalHubWidgetAllDayMarkers(
                                                events: allDayMarkerEvents,
                                                height: min(eventBlock.size.height, eventArea.size.height)
                                            )
                                            .padding(.leading, CalHubWidgetLayout.allDayMarkerLeadingInset)
                                        }
                                    }
                                }
                            Spacer(minLength: 0)
                        }
                        .frame(width: eventArea.size.width, height: eventArea.size.height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
//            .padding(14)
        }
        .widgetURL(CalHubWidgetFormat.deepLink(today))
    }
}

private struct CalHubWeeklyDayGroup: Identifiable {
    let date: Date
    let events: [CalHubWidgetEvent]
    let allDayMarkerEvents: [CalHubWidgetEvent]
    let remainingCount: Int
    let isMonthHeader: Bool

    var id: String {
        let prefix = isMonthHeader ? "month" : "day"
        return "\(prefix)-\(date.timeIntervalSinceReferenceDate)"
    }
}

private struct CalHubWeeklyWidgetView: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: CalHubWidgetEntry

    var body: some View {
        let locale = CalHubWidgetFormat.locale(entry)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: entry.date)
        let monthCaption = CalHubWidgetFormat.date(
            today,
            format: locale.identifier.hasPrefix("ja") ? "yyyy年M月" : "MMMM yyyy",
            locale: locale
        )
        let dayGroups = makeDayGroups(today: today, calendar: calendar)

        GeometryReader { geometry in
            let eventCount = dayGroups.reduce(0) { $0 + max($1.events.count, 1) }
            let rowSpacing: CGFloat = 3
            let verticalPadding: CGFloat = 0
            let monthHeaderHeight: CGFloat = 20
            let monthHeaderSpacing: CGFloat = 3
            let availableRowHeight = (geometry.size.height - verticalPadding * 2
                - monthHeaderHeight - monthHeaderSpacing
                - CGFloat(max(eventCount - 1, 0)) * rowSpacing)
                / CGFloat(max(eventCount, 1))
            let rowScale = min(max((availableRowHeight - 1) / 31, 0.56), 1.12)
            let titleSize = 15 * rowScale
            let timeSize = 11 * rowScale
            let labelSize = max(12, 15 * rowScale)
            let isEnglish = locale.identifier.hasPrefix("en")
            let dateLabelSpacing: CGFloat = isEnglish ? 2 : 4
            let dateNumberWidth = labelSize * 1.2
            let dateColumnWidth: CGFloat = isEnglish
                ? 54
                : dateNumberWidth + dateLabelSpacing + labelSize
            let dateToEventSpacing: CGFloat = isEnglish ? 4 : 6
            let capsuleHeight = titleSize * 1.2 + timeSize * 1.2 + 1

            VStack(alignment: .leading, spacing: monthHeaderSpacing) {
                HStack(alignment: .center, spacing: 4) {
                    Link(destination: CalHubWidgetFormat.deepLink(today, opensCalendar: true)
                        ?? CalHubWidgetFormat.deepLink(today)!) {
                        Text(monthCaption)
                            .font(.system(size: labelSize, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 4)
                    Link(destination: CalHubWidgetFormat.deepLink(today, registerEvent: true)
                        ?? CalHubWidgetFormat.deepLink(today)!) {
                        Image(systemName: "plus")
                            .font(.system(size: labelSize + 3, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: monthHeaderHeight, alignment: .center)

                if dayGroups.isEmpty {
                    Text(locale.identifier.hasPrefix("ja") ? "今後の予定はありません" : "No upcoming events")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    VStack(alignment: .leading, spacing: rowSpacing) {
                        ForEach(dayGroups) { group in
                            if group.isMonthHeader {
                                Link(destination: CalHubWidgetFormat.deepLink(group.date, opensCalendar: true)
                                    ?? CalHubWidgetFormat.deepLink(group.date)!) {
                                    Text(CalHubWidgetFormat.date(
                                        group.date,
                                        format: locale.identifier.hasPrefix("ja") ? "yyyy年M月" : "MMMM yyyy",
                                        locale: locale
                                    ))
                                    .font(.system(size: labelSize, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(height: availableRowHeight, alignment: .center)
                                }
                                .buttonStyle(.plain)
                            } else {
                                HStack(alignment: .top, spacing: dateToEventSpacing) {
                                Link(destination: CalHubWidgetFormat.deepLink(group.date)
                                    ?? URL(string: "calhub://calendar")!) {
                                    HStack(spacing: dateLabelSpacing) {
                                        let isToday = calendar.isDate(group.date, inSameDayAs: today)
                                        let isSunday = CalHubWidgetFormat.isSunday(group.date)
                                        if locale.identifier.hasPrefix("en") {
                                            Text(CalHubWidgetFormat.date(group.date, format: "EEE", locale: locale))
                                                .foregroundStyle(
                                                    isToday || (CalHubWidgetFormat.isSundayInRedEnabled && isSunday)
                                                        ? Color.red
                                                        : Color.secondary
                                                )
                                                .frame(width: 32, alignment: .leading)
                                            Text(CalHubWidgetFormat.date(group.date, format: "d", locale: locale))
                                                .foregroundStyle(
                                                    CalHubWidgetFormat.isSundayInRedEnabled && isSunday
                                                        ? Color.red
                                                        : (isToday ? Color.primary : Color.secondary)
                                                )
                                        } else {
                                            Text(CalHubWidgetFormat.date(group.date, format: "d", locale: locale))
                                                .foregroundStyle(
                                                    CalHubWidgetFormat.isSundayInRedEnabled && isSunday
                                                        ? Color.red
                                                        : (isToday ? Color.primary : Color.secondary)
                                                )
                                                .frame(width: dateNumberWidth, alignment: .trailing)
                                            Text(CalHubWidgetFormat.date(group.date, format: "EEE", locale: locale))
                                                .foregroundStyle(
                                                    isToday || (CalHubWidgetFormat.isSundayInRedEnabled && isSunday)
                                                        ? Color.red
                                                        : Color.secondary
                                                )
                                                .frame(width: labelSize, alignment: .leading)
                                        }
                                    }
                                    .font(.system(size: labelSize, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .frame(width: dateColumnWidth, alignment: .leading)
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: rowSpacing) {
                                    if group.events.isEmpty {
                                        HStack(spacing: 4) {
                                            Text(locale.identifier.hasPrefix("ja") ? "イベントはありません" : "No events")
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.7)
                                            Spacer(minLength: 0)
                                            if group.remainingCount > 0 {
                                                Text("+\(group.remainingCount)\(locale.identifier.hasPrefix("ja") ? "件" : " more")")
                                                    .lineLimit(1)
                                                    .fixedSize(horizontal: true, vertical: false)
                                            }
                                        }
                                        .font(.system(size: labelSize, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 5)
                                        .padding(.leading, group.allDayMarkerEvents.isEmpty
                                            ? 19
                                            : 11 + CGFloat(max(group.allDayMarkerEvents.count - 1, 0)) * 6)
                                    } else {
                                        ForEach(group.events.indices, id: \.self) { eventIndex in
                                            let event = group.events[eventIndex]
                                            let isAllDay = CalHubWidgetFormat.isAllDaySpan(event)
                                            Link(destination: CalHubWidgetFormat.deepLink(group.date, eventID: event.id)
                                                ?? CalHubWidgetFormat.deepLink(group.date)!) {
                                                CalHubWidgetEventRow(
                                                    event: event,
                                                    locale: locale,
                                                    titleSize: titleSize,
                                                    isPrimary: CalHubWidgetFormat.startsAfterNow(event, now: entry.date),
                                                    capsuleHeight: capsuleHeight,
                                                    timeSize: timeSize,
                                                    titleMinimumScaleFactor: 1,
                                                    timeMinimumScaleFactor: 1,
                                                    trailingText: eventIndex == group.events.count - 1 && group.remainingCount > 0
                                                        ? "+\(group.remainingCount)\(locale.identifier.hasPrefix("ja") ? "件" : " more")"
                                                        : nil,
                                                    trailingTextFont: .system(size: max(8, timeSize - 1)),
                                                    showsCapsule: !isAllDay,
                                                    reservesCapsuleSpace: !group.allDayMarkerEvents.isEmpty && !isAllDay,
                                                    capsuleTitleSpacing: 7,
                                                    capsuleMatchesContentHeight: true,
                                                    textLeadingInset: isAllDay
                                                        ? CalHubWidgetLayout.capsuleTitleSpacing
                                                            - CalHubWidgetLayout.allDayMarkerSpacing
                                                        : 0
                                                )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                .padding(.leading, group.allDayMarkerEvents.isEmpty
                                    ? 2
                                    : 2 + CGFloat(group.allDayMarkerEvents.count) * 8)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .background(alignment: .leading) {
                                    if !group.allDayMarkerEvents.isEmpty {
                                        GeometryReader { eventGroup in
                                            CalHubWidgetAllDayMarkers(
                                                events: group.allDayMarkerEvents,
                                                height: eventGroup.size.height
                                            )
                                            .padding(.leading, CalHubWidgetLayout.allDayMarkerLeadingInset)
                                        }
                                    }
                                }
                            }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .padding(.vertical, verticalPadding)
        }
        .containerBackground(for: .widget) {
            CalHubWidgetFormat.cardBackground(for: colorScheme)
        }
    }

    private func makeDayGroups(today: Date, calendar: Calendar) -> [CalHubWeeklyDayGroup] {
        let monthStart = calendar.dateInterval(of: .month, for: today)?.start ?? today
        let candidateEnd = calendar.date(byAdding: .month, value: 2, to: monthStart)
            ?? calendar.date(byAdding: .day, value: 62, to: today)
            ?? today
        let candidateDayCount = max(calendar.dateComponents([.day], from: today, to: candidateEnd).day ?? 0, 1)
        let candidateDays = (0..<candidateDayCount).compactMap { offset -> Date? in
            calendar.date(byAdding: .day, value: offset, to: today)
        }
        let candidatesByDay = candidateDays.map { day in
            let dayEvents = CalHubWidgetFormat.events(on: day, snapshot: entry.snapshot)
            let timedEvents = dayEvents.filter { !CalHubWidgetFormat.isAllDaySpan($0) }
            let unfinishedTimedEvents = timedEvents.filter {
                CalHubWidgetFormat.startsAfterNow($0, now: entry.date)
            }
            let titleEvents = unfinishedTimedEvents.isEmpty
                ? dayEvents.filter(CalHubWidgetFormat.isAllDaySpan)
                : unfinishedTimedEvents
            let displayedEvents = CalHubWidgetFormat.stableSorted(titleEvents) {
                CalHubWidgetFormat.eventComesBefore($0, $1)
            }
            return (date: day, allEvents: dayEvents, events: displayedEvents)
        }
        #if os(macOS)
        let displayedRowLimit = 9
        #else
        let displayedRowLimit = 8
        #endif
        var displayedRowCount = 0
        var dayGroups: [CalHubWeeklyDayGroup] = []
        var previousDate = today
        for day in candidatesByDay {
            guard displayedRowCount < displayedRowLimit else { break }

            let startsNewMonth = !calendar.isDate(
                day.date,
                equalTo: previousDate,
                toGranularity: .month
            )
            if startsNewMonth {
                guard displayedRowLimit - displayedRowCount >= 2 else { break }
                dayGroups.append(CalHubWeeklyDayGroup(
                    date: day.date,
                    events: [],
                    allDayMarkerEvents: [],
                    remainingCount: 0,
                    isMonthHeader: true
                ))
                displayedRowCount += 1
            }

            let shownEvents = Array(day.events.prefix(displayedRowLimit - displayedRowCount))
            displayedRowCount += max(shownEvents.count, 1)
            dayGroups.append(CalHubWeeklyDayGroup(
                date: day.date,
                events: shownEvents,
                allDayMarkerEvents: day.allEvents.filter(CalHubWidgetFormat.isAllDaySpan),
                remainingCount: 0,
                isMonthHeader: false
            ))
            previousDate = day.date
        }
        let remainingCount: Int
        if let lastGroup = dayGroups.last,
           let lastDay = candidatesByDay.first(where: { $0.date == lastGroup.date }) {
            remainingCount = max(lastDay.events.count - lastGroup.events.count, 0)
        } else {
            remainingCount = 0
        }
        if let lastGroupIndex = dayGroups.indices.last {
            let lastGroup = dayGroups[lastGroupIndex]
            dayGroups[lastGroupIndex] = CalHubWeeklyDayGroup(
                date: lastGroup.date,
                events: lastGroup.events,
                allDayMarkerEvents: lastGroup.allDayMarkerEvents,
                remainingCount: remainingCount,
                isMonthHeader: lastGroup.isMonthHeader
            )
        }

        return dayGroups
    }
}

struct CalHubCalendarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: CalHubWidgetSharedData.widgetKind, provider: CalHubWidgetProvider()) { entry in
            CalHubWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Cal Hub")
        .description("今日と今後のカレンダー予定を表示します。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct CalHubWeeklyCalendarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: CalHubWidgetSharedData.weeklyWidgetKind, provider: CalHubWidgetProvider()) { entry in
            CalHubWeeklyWidgetView(entry: entry)
        }
        .configurationDisplayName("Cal Hub Week")
        .description("今日からの予定を最大8行で表示します。")
        .supportedFamilies([.systemLarge])
    }
}

@main
struct CalHubWidgetBundle: WidgetBundle {
    var body: some Widget {
        CalHubCalendarWidget()
        CalHubWeeklyCalendarWidget()
    }
}

private struct CalHubWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: CalHubWidgetEntry

    @ViewBuilder
    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                CalHubSmallWidgetView(entry: entry)
            case .systemMedium:
                CalHubMediumWidgetView(entry: entry)
            default:
                CalHubLargeWidgetView(entry: entry)
            }
        }
        .containerBackground(for: .widget) {
            CalHubWidgetFormat.cardBackground(for: colorScheme)
        }
    }
}
