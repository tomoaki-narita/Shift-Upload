import SwiftUI

struct ContentView: View {
    @StateObject private var receiver = WatchSnapshotReceiver.shared
    @State private var scrollPosition: Int? = 0
    @State private var selectedEvent: WatchSnapshotEvent?
    @State private var hasInitializedPosition = false

    private let dayRange = -100_000...100_000

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack(alignment: .topLeading) {
                    ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(dayRange, id: \.self) { dayOffset in
                            WatchSmallCalendarView(
                                day: day(for: dayOffset),
                                now: .now,
                                snapshot: receiver.snapshot,
                                onSelectEvent: { selectedEvent = $0 }
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .id(dayOffset)
                        }
                    }
                    .scrollTargetLayout()
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .ignoresSafeArea(.container, edges: .vertical)
                .scrollPosition(id: $scrollPosition)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                .scrollClipDisabled(false)
                .clipped()
                    .onAppear {
                        receiver.activate()
                        guard !hasInitializedPosition else { return }
                        hasInitializedPosition = true
                        proxy.scrollTo(0, anchor: .center)
                    }

                    Button {
                        Task { @MainActor in
                            scrollPosition = nil
                            await Task.yield()
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(0, anchor: .center)
                                scrollPosition = 0
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("今日に戻る")
                    .padding(.leading, 4)
                    .padding(.top, 4)
                    .zIndex(10)
                }
            }
        }
            .ignoresSafeArea(.container, edges: .vertical)
            .navigationDestination(item: $selectedEvent) { event in
                WatchEventDetailView(event: event, locale: Locale(identifier: receiver.snapshot?.localeIdentifier ?? Locale.current.identifier))
            }
        }
    }

    private func day(for dayOffset: Int) -> Date {
        Calendar.current.date(
            byAdding: .day,
            value: dayOffset,
            to: Calendar.current.startOfDay(for: .now)
        ) ?? .now
    }
}

private struct WatchEventDetailView: View {
    let event: WatchSnapshotEvent
    let locale: Locale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(eventColor)
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)

                    Text(event.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                if let detail = event.detail,
                   !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("詳細")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(detail)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ForEach(
                    (event.metadata ?? [:])
                        .filter {
                            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }
                        .sorted { $0.key < $1.key },
                    id: \.key
                ) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.key)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        let colors = event.optionColors?[item.key] ?? [:]
                        let values = optionValues(from: item.value)
                        if !colors.isEmpty && !values.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(values, id: \.self) { value in
                                    Text(value)
                                        .font(.body)
                                        .foregroundStyle(tagForegroundColor(colors[value] ?? "gray"))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            tagBackgroundColor(colors[value] ?? "gray"),
                                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        )
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(item.value)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(locale.identifier.hasPrefix("ja") ? "イベント" : "Event")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func optionValues(from value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let values = try? JSONDecoder().decode([String].self, from: data) {
            return values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return trimmed
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func tagBackgroundColor(_ colorName: String) -> Color {
        switch colorName.lowercased() {
        case "blue": return Color(red: 0.20, green: 0.47, blue: 0.66)
        case "brown": return Color(red: 0.56, green: 0.34, blue: 0.20)
        case "green": return Color(red: 0.22, green: 0.55, blue: 0.34)
        case "orange": return Color(red: 0.73, green: 0.42, blue: 0.16)
        case "pink": return Color(red: 0.72, green: 0.35, blue: 0.53)
        case "purple": return Color(red: 0.48, green: 0.33, blue: 0.62)
        case "red": return Color(red: 0.70, green: 0.25, blue: 0.25)
        case "yellow": return Color(red: 0.68, green: 0.54, blue: 0.16)
        default: return Color.secondary.opacity(0.55)
        }
    }

    private func tagForegroundColor(_ colorName: String) -> Color {
        switch colorName.lowercased() {
        case "gray", "default", "yellow": return .primary
        default: return .white
        }
    }

    private var eventTime: String {
        if event.isAllDay {
            return locale.identifier.hasPrefix("ja") ? "終日" : "All day"
        }

        guard let start = event.startDate else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .current
        formatter.dateFormat = locale.identifier.hasPrefix("ja") ? "H:mm" : "h:mm a"

        let startText = formatter.string(from: start)
        guard let end = event.endDate else { return startText }
        return "\(startText)–\(formatter.string(from: end))"
    }

    private var eventDate: String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .current
        formatter.dateFormat = locale.identifier.hasPrefix("ja")
            ? "yyyy年M月d日（EEE）"
            : "EEE, MMM d, yyyy"
        return formatter.string(from: event.date)
    }

    private var eventColor: Color {
        Color(
            red: event.red ?? 0.25,
            green: event.green ?? 0.58,
            blue: event.blue ?? 0.95
        )
    }
}

private struct WatchSmallCalendarView: View {
    let day: Date
    let now: Date
    let snapshot: WatchSnapshot?
    let onSelectEvent: (WatchSnapshotEvent) -> Void
    @State private var timedLineBottom: CGFloat = 18

    private var calendar: Calendar { Calendar.current }
    private var locale: Locale {
        Locale(identifier: snapshot?.localeIdentifier ?? Locale.current.identifier)
    }

    private var events: [WatchSnapshotEvent] {
        let target = calendar.startOfDay(for: day)
        return (snapshot?.events ?? [])
            .filter { occurs($0, on: target) }
            .sorted {
                let left = $0.startDate ?? $0.date
                let right = $1.startDate ?? $1.date
                if left != right { return left < right }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    private var displayNow: Date {
        calendar.isDate(day, inSameDayAs: now)
            ? now
            : calendar.startOfDay(for: day)
    }

    private var timedEvents: [WatchSnapshotEvent] {
        events.filter {
            !isAllDaySpan($0) && startsAfterNow($0, now: displayNow)
        }
    }

    private var allDayEvents: [WatchSnapshotEvent] {
        events.filter(isAllDaySpan)
    }

    private var displayedEvents: [WatchSnapshotEvent] {
        let prioritizedTimed = prioritizedEvents(timedEvents, limit: 2)
        let allDaySlots = max(2 - prioritizedTimed.count, 0)
        let prioritizedAllDay = prioritizedEvents(allDayEvents, limit: allDaySlots)

        return (prioritizedTimed + prioritizedAllDay).sorted {
            let left = $0.startDate ?? $0.date
            let right = $1.startDate ?? $1.date
            if left != right { return left < right }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private var remainingCount: Int {
        let candidates = timedEvents + allDayEvents
        let futureCount = candidates.filter { hasNotStarted($0, now: displayNow) }.count
        let displayedFutureCount = displayedEvents.filter {
            hasNotStarted($0, now: displayNow)
        }.count
        return max(futureCount - displayedFutureCount, 0)
    }

    private var markerLeadingPadding: CGFloat {
        allDayEvents.isEmpty ? 0 : 2 + CGFloat(allDayEvents.count) * (2 + 4)
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(geometry.size.width - 4, 1)
            let headerSize = min(max(contentWidth * 0.18, 19), 22)
            let compactRowHeight = min(max(contentWidth * 0.1, 32), 44)
            let displayedRowCount = max(displayedEvents.count, 1)
            let eventRowCount = allDayEvents.isEmpty
                ? displayedRowCount
                : max(displayedRowCount, 2)
            let eventListHeight = compactRowHeight * CGFloat(eventRowCount)
                + CGFloat(max(eventRowCount - 1, 0)) * 3
            let dateSize = min(
                contentWidth * 0.9,
                geometry.size.height * 0.55
            )

            VStack(alignment: .leading, spacing: 0) {
                WatchDateMark(
                    date: day,
                    locale: locale,
                    headerSize: headerSize,
                    dateSize: dateSize,
                    sundayInRedEnabled: snapshot?.sundayInRedEnabled ?? false,
                    sourceColor: Color(
                        red: snapshot?.sourceRed ?? 0.25,
                        green: snapshot?.sourceGreen ?? 0.58,
                        blue: snapshot?.sourceBlue ?? 0.95
                    ),
                    showsTodayIndicator: calendar.isDate(day, inSameDayAs: now)
                )

                if displayedEvents.isEmpty && allDayEvents.isEmpty {
                    Spacer(minLength: 0)
                    Text(locale.identifier.hasPrefix("ja") ? "イベントはありません" : "No events")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                } else {
                    ZStack(alignment: .topLeading) {
                        let rowSpacing: CGFloat = 3
                        let rowHeight = compactRowHeight
                        let rowScale = min(max((rowHeight - 1) / 20, 0.6), 1)
                        let titleSize = 14 * rowScale
                        let timeSize = 11 * rowScale

                        VStack(alignment: .leading, spacing: rowSpacing) {
                            ForEach(Array(displayedEvents.enumerated()), id: \.element.id) { index, event in
                                let isAllDay = isAllDaySpan(event)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 3) {
                                        Text(event.title)
                                            .font(.system(size: titleSize, weight: .semibold))
                                            .lineLimit(1)
                                        if index == displayedEvents.count - 1 && remainingCount > 0 {
                                            Text("+\(remainingCount)\(locale.identifier.hasPrefix("ja") ? "件" : " more")")
                                                .font(.system(size: 7 * rowScale))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .fixedSize(horizontal: true, vertical: false)
                                        }
                                    }

                                    Text(eventTime(event))
                                        .font(.system(size: timeSize))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .layoutPriority(1)
                                }
                                .foregroundStyle(
                                    startsAfterNow(event, now: displayNow)
                                        ? .primary : .secondary
                                )
                                .padding(.leading, isAllDay ? 0 : 6)
                                .frame(height: rowHeight, alignment: .topLeading)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelectEvent(event)
                                }
                                .background(alignment: .leading) {
                                    GeometryReader { row in
                                        Capsule()
                                            .fill(isAllDay ? .clear : eventColor(event))
                                            .frame(width: 3, height: row.size.height)
                                            .background {
                                                if !isAllDay {
                                                    GeometryReader { marker in
                                                        Color.clear
                                                            .preference(
                                                                key: WatchRectangularTimedLineBottomKey.self,
                                                                value: marker
                                                                    .frame(in: .named("watchRectangularEventList"))
                                                                    .maxY
                                                            )
                                                    }
                                                }
                                            }
                                    }
                                }
                            }
                        }
                        .padding(.leading, markerLeadingPadding)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: eventListHeight,
                            maxHeight: eventListHeight,
                            alignment: .topLeading
                        )
                        .background(alignment: .leading) {
                            if !allDayEvents.isEmpty {
                                let hasDisplayedTimedEvent = displayedEvents.contains { !isAllDaySpan($0) }
                                let markerHeight = hasDisplayedTimedEvent
                                    ? min(timedLineBottom, eventListHeight)
                                    : eventListHeight
                                HStack(spacing: 4) {
                                    ForEach(allDayEvents) { event in
                                        Capsule()
                                            .fill(eventColor(event))
                                            .frame(width: 3, height: markerHeight)
                                    }
                                }
                                .padding(.leading, 2)
                            }
                        }
                        .coordinateSpace(name: "watchRectangularEventList")
                        .onPreferenceChange(WatchRectangularTimedLineBottomKey.self) { bottom in
                            timedLineBottom = bottom
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: eventListHeight, alignment: .topLeading)
                    .offset(y: -18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private func occurs(_ event: WatchSnapshotEvent, on date: Date) -> Bool {
        let target = calendar.startOfDay(for: date)
        if let start = event.startDate {
            let first = calendar.startOfDay(for: start)
            let last = calendar.startOfDay(for: event.endDate ?? start)
            return target >= first && target <= last
        }
        return calendar.isDate(event.date, inSameDayAs: target)
    }

    private func startsAfterNow(_ event: WatchSnapshotEvent, now: Date) -> Bool {
        guard let end = event.endDate else {
            return calendar.startOfDay(for: event.date) >= calendar.startOfDay(for: now)
        }
        return end > now
    }

    private func hasNotStarted(_ event: WatchSnapshotEvent, now: Date) -> Bool {
        (event.startDate ?? event.date) > now
    }

    private func isAllDaySpan(_ event: WatchSnapshotEvent) -> Bool {
        guard !event.isAllDay,
              let start = event.startDate,
              let end = event.endDate else {
            return event.isAllDay
        }

        let dayStart = calendar.startOfDay(for: start)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return false
        }

        return start.timeIntervalSince(dayStart) < 60
            && end >= nextDay.addingTimeInterval(-60)
            && end < nextDay
    }

    private func prioritizedEvents(
        _ sourceEvents: [WatchSnapshotEvent],
        limit: Int
    ) -> [WatchSnapshotEvent] {
        let upcoming = sourceEvents.filter { hasNotStarted($0, now: displayNow) }
        let inProgress = sourceEvents
            .filter {
                !hasNotStarted($0, now: displayNow)
                    && startsAfterNow($0, now: displayNow)
            }
            .sorted { eventComesBefore($0, $1) }
        let past = sourceEvents
            .filter { !startsAfterNow($0, now: displayNow) }
            .sorted {
                eventComesBefore($0, $1, descending: true)
            }

        var selected = Array((upcoming + inProgress + past).prefix(limit))
        let timedEventCount = sourceEvents.filter { !isAllDaySpan($0) }.count
        let shouldHideAllDayTitle = timedEventCount >= 4

        if !shouldHideAllDayTitle,
           limit > 0,
           let allDayEvent = sourceEvents.first(where: isAllDaySpan),
           !selected.contains(where: { $0.id == allDayEvent.id }) {
            selected = Array(selected.prefix(limit - 1)) + [allDayEvent]
        }

        return selected.sorted { eventComesBefore($0, $1) }
    }

    private func eventComesBefore(
        _ lhs: WatchSnapshotEvent,
        _ rhs: WatchSnapshotEvent,
        descending: Bool = false
    ) -> Bool {
        let lhsStart = lhs.startDate ?? lhs.date
        let rhsStart = rhs.startDate ?? rhs.date
        if lhsStart != rhsStart {
            return descending ? lhsStart > rhsStart : lhsStart < rhsStart
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private func eventTime(_ event: WatchSnapshotEvent) -> String {
        if isAllDaySpan(event) {
            return locale.identifier.hasPrefix("ja") ? "終日" : "All day"
        }
        guard let start = event.startDate else { return "" }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .current
        formatter.dateFormat = locale.identifier.hasPrefix("ja") ? "H:mm" : "h:mm a"
        let startText = formatter.string(from: start)

        guard let end = event.endDate else { return startText }
        return "\(startText)–\(formatter.string(from: end))"
    }

    private func eventColor(_ event: WatchSnapshotEvent) -> Color {
        Color(
            red: event.red ?? 0.25,
            green: event.green ?? 0.58,
            blue: event.blue ?? 0.95
        )
    }
}

private struct WatchRectangularTimedLineBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 18

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct WatchDateMark: View {
    let date: Date
    let locale: Locale
    let headerSize: CGFloat
    let dateSize: CGFloat
    let sundayInRedEnabled: Bool
    let sourceColor: Color
    let showsTodayIndicator: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(dateText(date, format: "d"))
                .font(.system(size: dateSize, weight: .bold))
                .foregroundStyle(sundayInRedEnabled && isSunday(date) ? .red : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .layoutPriority(1)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .center, spacing: 0) {
                Text(dateText(date, format: locale.identifier.hasPrefix("ja") ? "M" : "MMM"))
                    .foregroundStyle(.secondary)
                Text(dateText(date, format: "EEE"))
                    .foregroundStyle(.red)
                if showsTodayIndicator {
                    Circle()
                        .fill(sourceColor)
                        .frame(width: 7, height: 7)
                        .padding(.top, 7)
                }
            }
            .font(.system(size: headerSize, weight: .bold))
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func dateText(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private func isSunday(_ date: Date) -> Bool {
        Calendar.current.component(.weekday, from: date) == 1
    }
}

private struct WatchEventRow: View {
    let event: WatchSnapshotEvent
    let locale: Locale
    let titleSize: CGFloat
    let isPrimary: Bool
    let capsuleHeight: CGFloat
    let showsCapsule: Bool
    let trailingText: String?

    var body: some View {
        HStack(alignment: .center, spacing: showsCapsule ? 7 : 0) {
            if showsCapsule {
                Capsule()
                    .fill(eventColor)
                    .frame(width: 4, height: capsuleHeight)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(eventTime)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)

                    Spacer(minLength: 4)

                    if let trailingText {
                        Text(trailingText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .foregroundStyle(isPrimary ? .primary : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var eventTime: String {
        if event.isAllDay { return locale.identifier.hasPrefix("ja") ? "終日" : "All day" }
        guard let start = event.startDate else { return "" }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .current
        formatter.dateFormat = locale.identifier.hasPrefix("ja") ? "H:mm" : "h:mm a"
        let startText = formatter.string(from: start)

        guard let end = event.endDate else { return startText }
        return "\(startText)–\(formatter.string(from: end))"
    }

    private var eventColor: Color {
        Color(
            red: event.red ?? 0.25,
            green: event.green ?? 0.58,
            blue: event.blue ?? 0.95
        )
    }
}
