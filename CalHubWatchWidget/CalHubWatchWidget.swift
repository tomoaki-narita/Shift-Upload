import SwiftUI
import WidgetKit
import CoreText

private struct CalHubWatchEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchWidgetSnapshot?
}

private struct CalHubWatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> CalHubWatchEntry {
        CalHubWatchEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (CalHubWatchEntry) -> Void) {
        completion(CalHubWatchEntry(date: .now, snapshot: WatchWidgetData.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CalHubWatchEntry>) -> Void) {
        let now = Date()
        let snapshot = WatchWidgetData.load()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 2, to: today) ?? now.addingTimeInterval(48 * 60 * 60)
        var boundaries = Set<Date>([now])

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) {
            boundaries.insert(tomorrow)
        }
        boundaries.insert(end)

        for event in snapshot?.events ?? [] where !WatchWidgetData.isAllDaySpan(event) {
            if let start = event.startDate, start > now, start < end {
                boundaries.insert(start)
            }
            if let finish = event.endDate, finish > now, finish < end {
                boundaries.insert(finish)
            }
        }

        let dates = boundaries.sorted().prefix(80)
        let entries = dates.map { CalHubWatchEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(
            entries: entries,
            policy: .after(now.addingTimeInterval(6 * 60 * 60))
        ))
    }
}

private struct WatchWidgetSnapshot: Codable {
    let version: Int
    let localeIdentifier: String
    let updatedAt: Date
    let inlineTimeEnabled: Bool?
    let inlineStartTimeEnabled: Bool?
    let inlineEndTimeEnabled: Bool?
    let cornerTimeEnabled: Bool?
    let cornerStartTimeEnabled: Bool?
    let cornerEndTimeEnabled: Bool?
    let rectangularTimeEnabled: Bool?
    let rectangularStartTimeEnabled: Bool?
    let rectangularEndTimeEnabled: Bool?
    let events: [WatchWidgetEvent]
}

private struct WatchWidgetEvent: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let date: Date
    let startDate: Date?
    let endDate: Date?
    let isAllDay: Bool
    let isRestEvent: Bool
    let red: Double?
    let green: Double?
    let blue: Double?
    let alpha: Double?

    var accentComponents: (red: Double, green: Double, blue: Double) {
        if let red, let green, let blue {
            return (red, green, blue)
        }
        return (0.25, 0.58, 0.95)
    }
}

private struct SelectedWatchEvent {
    let event: WatchWidgetEvent
    let isPrimary: Bool
}

private enum WatchWidgetData {
    private static let appGroupIdentifier = "group.net.unwraps.Shift-Hub"
    private static let snapshotFileName = "watch-calendar-snapshot.json"
    private static let inlineTimeRangePreferenceKey = "calendarInlineTimeRangeEnabled"
    private static let circularLocale = Locale(identifier: "en_US_POSIX")

    static func load() -> WatchWidgetSnapshot? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ),
        let data = try? Data(contentsOf: container.appendingPathComponent(snapshotFileName)) else {
            return nil
        }
        return try? JSONDecoder().decode(WatchWidgetSnapshot.self, from: data)
    }

    static func locale(_ snapshot: WatchWidgetSnapshot?) -> Locale {
        Locale(identifier: snapshot?.localeIdentifier ?? Locale.current.identifier)
    }

    static func weekdayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = circularLocale
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: date).uppercased(with: circularLocale)
    }

    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = circularLocale
        formatter.setLocalizedDateFormatFromTemplate("d")
        return formatter.string(from: date)
    }

    static func color(_ event: WatchWidgetEvent) -> Color {
        let components = event.accentComponents
        return Color(
            red: components.red,
            green: components.green,
            blue: components.blue,
            opacity: event.alpha ?? 1
        )
    }

    static func isAllDaySpan(_ event: WatchWidgetEvent) -> Bool {
        guard !event.isAllDay,
              let start = event.startDate,
              let end = event.endDate else { return event.isAllDay }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: start)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        return start.timeIntervalSince(dayStart) < 60
            && end >= nextDay.addingTimeInterval(-60)
            && end < nextDay
    }

    static func occurs(_ event: WatchWidgetEvent, on day: Date) -> Bool {
        let calendar = Calendar.current
        let target = calendar.startOfDay(for: day)
        guard let start = event.startDate else {
            return calendar.isDate(event.date, inSameDayAs: target)
        }
        if event.isAllDay {
            if let end = event.endDate { return target >= calendar.startOfDay(for: start) && target < end }
            return calendar.isDate(start, inSameDayAs: target)
        }
        let lastDay = calendar.startOfDay(for: event.endDate ?? start)
        return target >= calendar.startOfDay(for: start) && target <= lastDay
    }

    static func events(on day: Date, snapshot: WatchWidgetSnapshot?) -> [WatchWidgetEvent] {
        (snapshot?.events ?? []).filter { occurs($0, on: day) }.sorted {
            let left = $0.startDate ?? $0.date
            let right = $1.startDate ?? $1.date
            if left != right { return left < right }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    static func allDayEvents(on day: Date, snapshot: WatchWidgetSnapshot?) -> [WatchWidgetEvent] {
        events(on: day, snapshot: snapshot).filter(isAllDaySpan)
    }

    static func selectedTimedEvent(snapshot: WatchWidgetSnapshot?, now: Date) -> SelectedWatchEvent? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let timed = (snapshot?.events ?? []).filter { event in
            guard !isAllDaySpan(event) else { return false }
            let end = event.endDate ?? event.startDate ?? event.date
            let start = event.startDate ?? event.date
            return end >= today && start < (calendar.date(byAdding: .day, value: 1, to: tomorrow) ?? tomorrow)
        }.sorted {
            ($0.startDate ?? $0.date) < ($1.startDate ?? $1.date)
        }

        if let next = timed.first(where: { ($0.startDate ?? $0.date) > now }) {
            return SelectedWatchEvent(event: next, isPrimary: true)
        }

        if let active = timed.last(where: {
            ($0.startDate ?? $0.date) <= now && ($0.endDate ?? $0.startDate ?? $0.date) > now
        }) {
            return SelectedWatchEvent(event: active, isPrimary: false)
        }
        return nil
    }

    static func startsAfterNow(_ event: WatchWidgetEvent, now: Date) -> Bool {
        if isAllDaySpan(event) {
            return Calendar.current.startOfDay(for: event.date) >= Calendar.current.startOfDay(for: now)
        }
        return (event.endDate ?? event.startDate ?? event.date) > now
    }

    static func hasNotStarted(_ event: WatchWidgetEvent, now: Date) -> Bool {
        (event.startDate ?? event.date) > now
    }

    static func displayableEvents(_ events: [WatchWidgetEvent], now: Date) -> [WatchWidgetEvent] {
        let currentEvents = events.filter {
            isAllDaySpan($0) || startsAfterNow($0, now: now)
        }
        let timedCount = currentEvents.filter { !isAllDaySpan($0) }.count
        guard timedCount >= 4 else { return currentEvents }
        return currentEvents.filter { !isAllDaySpan($0) }
    }

    static func prioritizedEvents(
        _ events: [WatchWidgetEvent],
        now: Date,
        limit: Int
    ) -> [WatchWidgetEvent] {
        let upcoming = events.filter { hasNotStarted($0, now: now) }
        let inProgress = events.filter { !hasNotStarted($0, now: now) && startsAfterNow($0, now: now) }
        let past = events.filter { !startsAfterNow($0, now: now) }.sorted {
            ($0.startDate ?? $0.date) > ($1.startDate ?? $1.date)
        }
        var selected = Array((upcoming + inProgress + past).prefix(limit))
        let shouldHideAllDay = events.filter { !isAllDaySpan($0) }.count >= 4
        if !shouldHideAllDay,
           limit > 0,
           let allDay = events.first(where: isAllDaySpan),
           !selected.contains(where: { $0.id == allDay.id }) {
            selected = Array(selected.prefix(limit - 1)) + [allDay]
        }
        return selected.sorted {
            ($0.startDate ?? $0.date) < ($1.startDate ?? $1.date)
        }
    }

    static func dateText(_ date: Date, format: String, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static func timeText(_ event: WatchWidgetEvent, locale: Locale) -> String {
        if isAllDaySpan(event) { return locale.identifier.hasPrefix("ja") ? "終日" : "All day" }
        guard let start = event.startDate else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let startText = formatter.string(from: start)
        guard let end = event.endDate else { return startText }
        return "\(startText)–\(formatter.string(from: end))"
    }

    static func startTimeText(_ event: WatchWidgetEvent, locale: Locale) -> String {
        if isAllDaySpan(event) { return locale.identifier.hasPrefix("ja") ? "終日" : "All day" }
        guard let start = event.startDate else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: start)
    }

    static func inlineTimeText(
        _ event: WatchWidgetEvent,
        locale: Locale,
        snapshot: WatchWidgetSnapshot?
    ) -> String {
        return configuredTimeText(
            event,
            locale: locale,
            enabled: snapshot?.inlineTimeEnabled ?? true,
            showsStart: snapshot?.inlineStartTimeEnabled ?? true,
            showsEnd: snapshot?.inlineEndTimeEnabled ?? false
        )
    }

    static func configuredTimeText(
        _ event: WatchWidgetEvent,
        locale: Locale,
        enabled: Bool,
        showsStart: Bool,
        showsEnd: Bool
    ) -> String {
        guard !isAllDaySpan(event) else {
            return locale.identifier.hasPrefix("ja") ? "終日" : "All day"
        }
        guard enabled else { return "" }

        let startText = startTimeText(event, locale: locale)
        guard showsStart || showsEnd else { return "" }

        guard showsEnd, let end = event.endDate else {
            return showsStart ? startText : ""
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let endText = formatter.string(from: end)
        return showsStart ? "\(startText)-\(endText)" : endText
    }

    static func abbreviatedTitle(_ title: String, limit: Int = 6) -> String {
        guard title.count > limit else { return title }
        return String(title.prefix(limit - 1)) + "…"
    }

    static func moreText(_ count: Int, locale: Locale) -> String {
        locale.identifier.hasPrefix("ja") ? "+\(count)件" : "+\(count) more"
    }
}

private struct CalHubInlineComplication: View {
    let entry: CalHubWatchEntry

    var body: some View {
        let locale = WatchWidgetData.locale(entry.snapshot)
        let allDay = WatchWidgetData.allDayEvents(on: entry.date, snapshot: entry.snapshot)
        let selected = WatchWidgetData.selectedTimedEvent(snapshot: entry.snapshot, now: entry.date)
        let event = selected?.event ?? allDay.last

        return HStack(spacing: 4) {
            if let event {
                let start = event.startDate ?? event.date
                let isTomorrow = selected != nil && Calendar.current.isDateInTomorrow(start)

                let eventTitle = WatchWidgetData.abbreviatedTitle(
                    event.title,
                    limit: isTomorrow ? 10 : 14
                )
                let startText = selected == nil
                    ? ""
                    : " \(WatchWidgetData.inlineTimeText(event, locale: locale, snapshot: entry.snapshot))"

                let inlineText: Text = isTomorrow
                    ? Text("TMR ")
                        .foregroundStyle(.primary)
                    + Text(eventTitle)
                        .foregroundStyle(.primary)
                    + Text(startText)
                        .foregroundStyle(.primary)
                    : Text(eventTitle)
                        .foregroundStyle(.primary)
                    + Text(startText)
                        .foregroundStyle(.primary)

                inlineText
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.5)
                    .layoutPriority(1)
                    .widgetAccentable()
            } else {
                Text(locale.identifier.hasPrefix("ja") ? "予定なし" : "No events")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 10, weight: .medium))
    }
}

private struct CalHubCircularComplication: View {
    let entry: CalHubWatchEntry

    var body: some View {
        let locale = WatchWidgetData.locale(entry.snapshot)
        let today = Calendar.current.startOfDay(for: entry.date)
        let allDay = WatchWidgetData.allDayEvents(on: today, snapshot: entry.snapshot)
        let selected = WatchWidgetData.selectedTimedEvent(snapshot: entry.snapshot, now: entry.date)
        let weekdayContent = CurvedWatchLabel.Content(
            title: WatchWidgetData.weekdayText(today),
            detail: "",
            originalTitleLength: WatchWidgetData.weekdayText(today).count
        )
        let titleContent: CurvedWatchLabel.Content = {
            if let selected {
                let start = selected.event.startDate ?? selected.event.date
                let isTomorrow = Calendar.current.isDateInTomorrow(start)
                let title = isTomorrow
                    ? "TMR\(selected.event.title)"
                    : selected.event.title
                return CurvedWatchLabel.Content(
                    title: title,
                    detail: "",
                    originalTitleLength: title.count,
                    titlePrefixLength: isTomorrow ? 3 : 0,
                    titlePrefixColor: WatchWidgetData.color(selected.event),
                    titleIsPrimary: selected.isPrimary,
                    dropsDetailWhenConstrained: true
                )
            }
            if let lastAllDay = allDay.last {
                let more = max(allDay.count - 1, 0)
                return CurvedWatchLabel.Content(
                    title: lastAllDay.title.uppercased(with: locale),
                    detail: more > 0 ? WatchWidgetData.moreText(more, locale: locale).uppercased(with: locale) : "",
                    originalTitleLength: lastAllDay.title.count,
                    dropsDetailWhenConstrained: true
                )
            }
            let noEvents = "NO EVENTS"
            return CurvedWatchLabel.Content(
                title: noEvents,
                detail: "",
                originalTitleLength: noEvents.count
            )
        }()

        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)

            ZStack {
                CurvedWatchLabel(
                    rings: Array(allDay.suffix(1)),
                    content: weekdayContent,
                    titleFontSize: 12,
                    detailFontSize: 8,
                    ringIndex: 0,
                    forceFullCircle: false,
                    hideArcs: true,
                    centerAngle: -.pi / 2,
                    maximumSpan: .pi,
                    additionalRadiusInset: 1,
                    minimumFontScale: 0.65,
                    truncatesText: false,
                    trackingScale: 0.2,
                    spanFillRatio: 0.9
                )

                CurvedWatchLabel(
                    rings: Array(allDay.suffix(1)),
                    content: titleContent,
                    titleFontSize: 12,
                    detailFontSize: 8,
                    ringIndex: 0,
                    forceFullCircle: false,
                    hideArcs: true,
                    centerAngle: .pi / 2,
                    maximumSpan: .pi,
                    additionalRadiusInset: 0,
                    minimumFontScale: 0.5,
                    truncatesText: true,
                    trackingScale: 0.3,
                    spanFillRatio: 1.0
                )

                VStack(spacing: 0) {
                    Text(WatchWidgetData.dayText(today))
                        .font(.system(size: 25, weight: .bold))
                        .lineLimit(1)
                }
            }
            .frame(width: diameter, height: diameter)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

private struct CurvedWatchLabel: View {
    struct Content {
        let title: String
        let detail: String
        let originalTitleLength: Int
        let titlePrefixLength: Int
        let titlePrefixColor: Color?
        let titleIsPrimary: Bool
        let detailIsPrimary: Bool
        let detailBeforeTitle: Bool
        let dropsDetailWhenConstrained: Bool

        init(
            title: String,
            detail: String,
            originalTitleLength: Int,
            titlePrefixLength: Int = 0,
            titlePrefixColor: Color? = nil,
            titleIsPrimary: Bool = true,
            detailIsPrimary: Bool = false,
            detailBeforeTitle: Bool = false,
            dropsDetailWhenConstrained: Bool = false
        ) {
            self.title = title
            self.detail = detail
            self.originalTitleLength = originalTitleLength
            self.titlePrefixLength = titlePrefixLength
            self.titlePrefixColor = titlePrefixColor
            self.titleIsPrimary = titleIsPrimary
            self.detailIsPrimary = detailIsPrimary
            self.detailBeforeTitle = detailBeforeTitle
            self.dropsDetailWhenConstrained = dropsDetailWhenConstrained
        }

        var titleText: String { title }
        var detailText: String { detail }
    }

    let rings: [WatchWidgetEvent]
    let content: Content?
    let titleFontSize: CGFloat
    let detailFontSize: CGFloat
    let ringIndex: Int
    let forceFullCircle: Bool
    let hideArcs: Bool
    let centerAngle: CGFloat
    let maximumSpan: CGFloat
    let additionalRadiusInset: CGFloat
    let minimumFontScale: CGFloat
    let truncatesText: Bool
    let trackingScale: CGFloat
    let spanFillRatio: CGFloat

    private struct GlyphCell {
        let text: String
        let isTitle: Bool
        let isSpacer: Bool
        let fontSize: CGFloat
        let isPrimary: Bool
        let color: Color?
    }

    private struct MeasuredGlyph {
        let cell: GlyphCell
        let text: GraphicsContext.ResolvedText
        let size: CGSize
        let baseline: CGFloat
        let advance: CGFloat
        let cellWidth: CGFloat
        let opticalBounds: CGRect?
    }

    private struct PositionedGlyph {
        let glyph: MeasuredGlyph
        let width: CGFloat
        let angle: CGFloat
        let rotation: CGFloat
        let baseline: CGPoint
    }

    static let edgePadding: CGFloat = 2
    static let ringInset: CGFloat = 1
    static let arcLineWidth: CGFloat = 3.5

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let diameter = min(size.width, size.height)
                let glyphRadiusInset = hideArcs
                    ? max(titleFontSize, detailFontSize) * 0.35
                    : 0
                let arcRadius = diameter / 2
                    - CGFloat(ringIndex) * 7
                    - Self.ringInset
                    - glyphRadiusInset
                    - additionalRadiusInset
                let textSpan = max(
                    maximumSpan - max(titleFontSize, detailFontSize) * 0.82 / max(arcRadius, 1),
                    0.1
                )
                let measurementArea = CGSize(width: max(size.width, 1), height: max(size.height, 1))
                var renderContent = content
                var cells = Self.cells(
                    for: renderContent,
                    titleFontSize: titleFontSize,
                    detailFontSize: detailFontSize
                )
                func measure(_ cells: [GlyphCell]) -> [MeasuredGlyph] {
                    cells.map { cell in
                        let text = Self.resolve(cell, in: &context)
                        let measuredSize = text.measure(in: measurementArea)
                        let advance = max(measuredSize.width, 0.1)
                        let cellWidth = cell.isSpacer
                            ? Self.measuredSpaceWidth(for: cell, in: &context, area: measurementArea, referenceWidth: advance)
                            : advance
                        return MeasuredGlyph(
                            cell: cell,
                            text: text,
                            size: measuredSize,
                            baseline: text.firstBaseline(in: measuredSize),
                            advance: advance,
                            cellWidth: cellWidth,
                            opticalBounds: Self.opticalBounds(
                                for: cell.text,
                                fontSize: cell.fontSize
                            )
                        )
                    }
                }
                var measuredGlyphs = measure(cells)
                if let content = renderContent,
                   content.dropsDetailWhenConstrained,
                   !content.detail.isEmpty {
                    let titleGlyphs = measuredGlyphs.filter { $0.cell.isTitle && !$0.cell.isSpacer }
                    let detailGlyphs = measuredGlyphs.filter { !$0.cell.isTitle && !$0.cell.isSpacer }
                    let measuredWidth = measuredGlyphs.reduce(CGFloat.zero) { $0 + $1.cellWidth }
                    let fixedCellWidth = CGFloat(titleGlyphs.count)
                        * (titleGlyphs.map(\.advance).max() ?? titleFontSize) * 1.1
                        + CGFloat(detailGlyphs.count)
                        * (detailGlyphs.map(\.advance).max() ?? detailFontSize) * 1.1
                    let availableWidth = max(textSpan * max(arcRadius, 1), 1)
                    if max(measuredWidth, fixedCellWidth) > availableWidth {
                        renderContent = Content(
                            title: content.title,
                            detail: "",
                            originalTitleLength: content.originalTitleLength,
                            titlePrefixLength: content.titlePrefixLength,
                            titlePrefixColor: content.titlePrefixColor,
                            titleIsPrimary: content.titleIsPrimary,
                            detailIsPrimary: content.detailIsPrimary,
                            detailBeforeTitle: content.detailBeforeTitle,
                            dropsDetailWhenConstrained: content.dropsDetailWhenConstrained
                        )
                        cells = Self.cells(
                            for: renderContent,
                            titleFontSize: titleFontSize,
                            detailFontSize: detailFontSize
                        )
                        measuredGlyphs = measure(cells)
                    }
                }
                let measuredBaseTextWidth = measuredGlyphs.reduce(CGFloat.zero) { total, glyph in
                    total + glyph.cellWidth
                }
                let baseTitleMaximumWidth = measuredGlyphs
                    .filter { $0.cell.isTitle && !$0.cell.isSpacer }
                    .map(\.advance)
                    .max()
                    ?? titleFontSize
                let baseDetailMaximumWidth = measuredGlyphs
                    .filter { !$0.cell.isTitle && !$0.cell.isSpacer }
                    .map(\.advance)
                    .max()
                    ?? detailFontSize
                let titleGlyphCount = measuredGlyphs.filter {
                    $0.cell.isTitle && !$0.cell.isSpacer
                }.count
                let detailGlyphCount = measuredGlyphs.filter {
                    !$0.cell.isTitle && !$0.cell.isSpacer
                }.count
                let fixedCellTextWidth = CGFloat(titleGlyphCount)
                    * baseTitleMaximumWidth * 1.1
                    + CGFloat(detailGlyphCount) * baseDetailMaximumWidth * 1.1
                let baseTextWidth = max(measuredBaseTextWidth, fixedCellTextWidth)
                let circumference = textSpan * max(arcRadius, 1)
                let endClearance: CGFloat = 0
                let availableTextWidth = max(circumference - endClearance, 1)
                let naturalFontScale = min(1, availableTextWidth / max(baseTextWidth, 1))
                var fontScale = max(minimumFontScale, naturalFontScale)
                var fillsCircle = forceFullCircle
                    || (!truncatesText && naturalFontScale < minimumFontScale)

                // Keep the smallest readable font as the hard lower bound. If even
                // that size cannot fit, remove characters from the end rather than
                // inserting an ellipsis, which would itself become another glyph.
                if naturalFontScale < minimumFontScale, let content {
                    let minimumCells = measure(Self.cells(
                        for: content,
                        titleFontSize: titleFontSize * minimumFontScale,
                        detailFontSize: detailFontSize * minimumFontScale
                    ))
                    let minimumTitleCellWidth = minimumCells
                        .filter { $0.cell.isTitle && !$0.cell.isSpacer }
                        .map(\.advance)
                        .max()
                        ?? titleFontSize * minimumFontScale
                    let minimumDetailCellWidth = minimumCells
                        .filter { !$0.cell.isTitle && !$0.cell.isSpacer }
                        .map(\.advance)
                        .max()
                        ?? detailFontSize * minimumFontScale
                    /* let minimumTitleTracking = minimumCells
                        .first { $0.cell.isTitle && $0.cell.isSpacer }?.cellWidth
                        ?? minimumTitleCellWidth * trackingScale
                    let minimumDetailTracking = minimumCells
                        .first { !$0.cell.isTitle && $0.cell.isSpacer }?.cellWidth
                        ?? minimumDetailCellWidth * trackingScale
                    let minimumTitleCellWidth = minimumTitleGlyphWidth + minimumTitleTracking
                    let minimumDetailCellWidth = minimumDetailGlyphWidth + minimumDetailTracking */
                    let reservedDetailWidth = CGFloat(detailGlyphCount) * minimumDetailCellWidth
                        + (detailGlyphCount > 0 ? minimumDetailCellWidth : 0)
                    let titleCapacity = max(
                        1,
                        Int(floor(max(0, availableTextWidth - reservedDetailWidth) / max(minimumTitleCellWidth, 1)))
                    )
                    if truncatesText && content.title.count > titleCapacity {
                        renderContent = Content(
                            title: String(content.title.prefix(titleCapacity)),
                            detail: content.detail,
                            originalTitleLength: content.originalTitleLength,
                            titlePrefixLength: content.titlePrefixLength,
                            titlePrefixColor: content.titlePrefixColor,
                            titleIsPrimary: content.titleIsPrimary,
                            detailIsPrimary: content.detailIsPrimary,
                            detailBeforeTitle: content.detailBeforeTitle,
                            dropsDetailWhenConstrained: content.dropsDetailWhenConstrained
                        )
                        fontScale = minimumFontScale
                        fillsCircle = false
                    }
                }
                if fontScale < 0.999 {
                    cells = Self.cells(
                        for: renderContent,
                        titleFontSize: titleFontSize * fontScale,
                        detailFontSize: detailFontSize * fontScale
                    )
                    measuredGlyphs = measure(cells)
                }
                let titleGlyphWidth = measuredGlyphs
                    .filter { $0.cell.isTitle && !$0.cell.isSpacer }
                    .map(\.advance)
                    .max() ?? titleFontSize * fontScale
                let detailGlyphWidth = measuredGlyphs
                    .filter { !$0.cell.isTitle && !$0.cell.isSpacer }
                    .map(\.advance)
                    .max() ?? detailFontSize * fontScale
                let titleTracking = measuredGlyphs
                    .first { $0.cell.isTitle && $0.cell.isSpacer }?.cellWidth
                    ?? titleGlyphWidth * trackingScale
                let detailTracking = measuredGlyphs
                    .first { !$0.cell.isTitle && $0.cell.isSpacer }?.cellWidth
                    ?? detailGlyphWidth * trackingScale
                let glyphs = measuredGlyphs.map { glyph in
                    guard !glyph.cell.isSpacer else { return glyph }
                    let uniformWidth = (glyph.cell.isTitle ? titleGlyphWidth : detailGlyphWidth)
                        + (glyph.cell.isTitle ? titleTracking : detailTracking)
                    return MeasuredGlyph(
                        cell: glyph.cell,
                        text: glyph.text,
                        size: glyph.size,
                        baseline: glyph.baseline,
                        advance: glyph.advance,
                        cellWidth: uniformWidth,
                        opticalBounds: glyph.opticalBounds
                    )
                }
                let totalTextWidth = glyphs.reduce(CGFloat.zero) { total, glyph in
                    total + glyph.cellWidth
                }
                func layout(at radius: CGFloat) -> (gapAngle: CGFloat, glyphs: [PositionedGlyph]) {
                    let circumference = textSpan * max(radius, 1)
                    let circleEndGap: CGFloat = 0
                    let placementWidth = fillsCircle
                        ? max(circumference - circleEndGap, 1)
                        : max(
                            totalTextWidth,
                            circumference * spanFillRatio
                        )
                    let gapAngle = content == nil
                        ? 0
                        : fillsCircle
                        ? textSpan - circleEndGap / max(radius, 1)
                            : min(2 * .pi - 0.1, (totalTextWidth + Self.edgePadding * 2) / max(radius, 1))
                    let fullCircleCellWidth = placementWidth / CGFloat(max(glyphs.count, 1))
                    var distance: CGFloat = 0
                    let positioned = glyphs.enumerated().map { index, glyph in
                        let width = fillsCircle ? fullCircleCellWidth : glyph.cellWidth
                        // Place the measured text run symmetrically around the bottom
                        // of the circle. The opening padding belongs to the arc, not
                        // to the text's center calculation.
                        let cellCenterDistance = fillsCircle
                            ? (CGFloat(index) + 0.5) * width - placementWidth / 2
                            : distance + width / 2 - placementWidth / 2
                        let pathDirection: CGFloat = centerAngle < 0 ? 1 : -1
                        let angle = centerAngle + pathDirection * cellCenterDistance / max(radius, 1)
                        let rotation = centerAngle < 0
                            ? angle + .pi / 2
                            : angle - .pi / 2
                        let baseline = CGPoint(
                            x: center.x + radius * cos(angle),
                            y: center.y + radius * sin(angle)
                        )
                        if !fillsCircle {
                            distance += width
                        }
                        return PositionedGlyph(
                            glyph: glyph,
                            width: width,
                            angle: angle,
                            rotation: rotation,
                            baseline: baseline
                        )
                    }
                    return (gapAngle, positioned)
                }

                // Keep the glyphs on the same visual outer edge after scaling.
                // The previous inset was based on the unscaled 12pt font, so a
                // smaller label kept the old radius and drifted toward the center.
                let scaledGlyphRadiusInset = hideArcs
                    ? max(titleFontSize, detailFontSize) * 0.35 * fontScale
                    : 0
                let pathRadius = diameter / 2
                    - CGFloat(ringIndex) * 7
                    - Self.ringInset
                    - scaledGlyphRadiusInset
                    - additionalRadiusInset
                var textLayout = layout(at: pathRadius)
                textLayout = (
                    textLayout.gapAngle,
                    textLayout.glyphs.map { positioned in
                        guard !positioned.glyph.cell.isSpacer else { return positioned }
                        let corners = Self.corners(of: positioned)
                        let glyphCenter = CGPoint(
                            x: corners.reduce(0) { $0 + $1.x } / CGFloat(corners.count),
                            y: corners.reduce(0) { $0 + $1.y } / CGFloat(corners.count)
                        )
                        let glyphRadius = hypot(
                            glyphCenter.x - center.x,
                            glyphCenter.y - center.y
                        )
                        let dx = positioned.baseline.x - center.x
                        let dy = positioned.baseline.y - center.y
                        let baselineRadius = max(hypot(dx, dy), 0.1)
                        let radialCorrection = pathRadius - glyphRadius
                        return PositionedGlyph(
                            glyph: positioned.glyph,
                            width: positioned.width,
                            angle: positioned.angle,
                            rotation: positioned.rotation,
                            baseline: CGPoint(
                                x: positioned.baseline.x + dx / baselineRadius * radialCorrection,
                                y: positioned.baseline.y + dy / baselineRadius * radialCorrection
                            )
                        )
                    }
                )
                let visualLayout = fillsCircle || abs(centerAngle - .pi / 2) > 0.001
                    ? (gapAngle: textLayout.gapAngle, glyphs: textLayout.glyphs)
                    : Self.visualEdgeLayout(
                        textLayout.glyphs,
                        around: center,
                        radius: arcRadius
                    )
                textLayout = (
                    visualLayout.gapAngle,
                    visualLayout.glyphs
                )
                let fittingOffset = !hideArcs
                    ? Self.fittingOffset(
                        for: Self.drawnBounds(of: textLayout.glyphs),
                        in: size
                    )
                    : CGPoint.zero
                if fittingOffset != .zero {
                    textLayout = (
                        textLayout.gapAngle,
                        textLayout.glyphs.map { positioned in
                            PositionedGlyph(
                                glyph: positioned.glyph,
                                width: positioned.width,
                                angle: positioned.angle,
                                rotation: positioned.rotation,
                                baseline: CGPoint(
                                    x: positioned.baseline.x + fittingOffset.x,
                                    y: positioned.baseline.y + fittingOffset.y
                                )
                            )
                        }
                    )
                }
                // The text determines only the opening. Any remaining circumference
                // is drawn as the arc, including when the text was scaled down.
                let hidesArcs = hideArcs || fillsCircle
                let gapFraction = hidesArcs
                    ? 0.5
                    : textLayout.gapAngle / (2 * .pi) / 2

                if content != nil && !hidesArcs {
                    for (index, event) in rings.enumerated() {
                    let radius = diameter / 2 - CGFloat(index) * 7 - Self.ringInset
                    guard radius > 0 else { continue }
                    let rect = CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    let trimmedCircle = Circle().trim(from: gapFraction, to: 1 - gapFraction)
                    let rotation = CGAffineTransform(translationX: center.x, y: center.y)
                        .rotated(by: .pi / 2)
                        .translatedBy(x: -center.x, y: -center.y)
                    context.stroke(
                        trimmedCircle.path(in: rect).applying(rotation),
                        with: .color(WatchWidgetData.color(event)),
                        style: StrokeStyle(lineWidth: Self.arcLineWidth, lineCap: .round)
                    )
                    }
                }

                for positionedGlyph in textLayout.glyphs {
                    let glyph = positionedGlyph.glyph
                    if !glyph.cell.isSpacer {
                        var glyphContext = context
                        glyphContext.translateBy(
                            x: positionedGlyph.baseline.x,
                            y: positionedGlyph.baseline.y
                        )
                        glyphContext.rotate(by: Angle(radians: positionedGlyph.rotation))
                        glyphContext.draw(
                            glyph.text,
                            in: CGRect(
                                x: -glyph.advance / 2,
                                y: -glyph.baseline,
                                width: glyph.advance,
                                height: glyph.size.height
                            )
                        )
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
    }

    private static func cells(
        for content: Content?,
        titleFontSize: CGFloat,
        detailFontSize: CGFloat
    ) -> [GlyphCell] {
        guard let content else { return [] }
        var cells: [GlyphCell] = []

        func appendCharacters(
            _ text: String,
            isTitle: Bool,
            fontSize: CGFloat,
            isPrimary: Bool,
            prefixLength: Int = 0,
            prefixColor: Color? = nil
        ) {
            let characters = Array(text)
            for (index, character) in characters.enumerated() {
                let value = String(character)
                let color = index >= prefixLength ? prefixColor : nil
                if character.isWhitespace {
                    cells.append(GlyphCell(
                        text: " ",
                        isTitle: isTitle,
                        isSpacer: true,
                        fontSize: fontSize,
                        isPrimary: isPrimary,
                        color: color
                    ))
                } else {
                    cells.append(GlyphCell(
                        text: value,
                        isTitle: isTitle,
                        isSpacer: false,
                        fontSize: fontSize,
                        isPrimary: isPrimary,
                        color: color
                    ))
                }
            }
        }

        func appendTitle() {
            appendCharacters(
                content.titleText,
                isTitle: true,
                fontSize: titleFontSize,
                isPrimary: content.titleIsPrimary,
                prefixLength: content.titlePrefixLength,
                prefixColor: content.titlePrefixColor
            )
        }

        func appendDetail() {
            guard !content.detailText.isEmpty else { return }
            cells.append(GlyphCell(
                text: " ",
                isTitle: false,
                isSpacer: true,
                fontSize: detailFontSize,
                isPrimary: content.detailIsPrimary,
                color: nil
            ))
            appendCharacters(
                content.detailText,
                isTitle: false,
                fontSize: detailFontSize,
                isPrimary: content.detailIsPrimary
            )
        }

        if content.detailBeforeTitle {
            appendDetail()
            appendTitle()
        } else {
            appendTitle()
            appendDetail()
        }

        return cells
    }

    private static func resolve(
        _ cell: GlyphCell,
        in context: inout GraphicsContext
    ) -> GraphicsContext.ResolvedText {
        context.resolve(
            Text(cell.text)
                .font(.system(size: cell.fontSize, weight: .bold, design: .rounded))
                .foregroundColor(cell.color ?? (cell.isPrimary ? .primary : .secondary))
        )
    }

    private static func measuredSpaceWidth(
        for cell: GlyphCell,
        in context: inout GraphicsContext,
        area: CGSize,
        referenceWidth: CGFloat
    ) -> CGFloat {
        let referenceCell = GlyphCell(
            text: "F",
            isTitle: cell.isTitle,
            isSpacer: false,
            fontSize: cell.fontSize,
            isPrimary: cell.isPrimary,
            color: nil
        )
        let reference = resolve(referenceCell, in: &context).measure(in: area).width
        let separatedCell = GlyphCell(
            text: "F F",
            isTitle: cell.isTitle,
            isSpacer: false,
            fontSize: cell.fontSize,
            isPrimary: cell.isPrimary,
            color: nil
        )
        let separated = resolve(separatedCell, in: &context).measure(in: area).width
        let joinedCell = GlyphCell(
            text: "FF",
            isTitle: cell.isTitle,
            isSpacer: false,
            fontSize: cell.fontSize,
            isPrimary: cell.isPrimary,
            color: nil
        )
        let joined = resolve(joinedCell, in: &context).measure(in: area).width
        let measured = separated - joined
        // A standalone space can be collapsed by Canvas. Derive its minimum from the
        // same rounded font metrics instead of using a display-size-specific offset.
        return max(measured, reference * 0.2, referenceWidth * 0.2)
    }

    private static func maximumGlyphWidth(
        fontSize: CGFloat,
        isTitle: Bool,
        in context: inout GraphicsContext,
        area: CGSize
    ) -> CGFloat {
        let characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-./:"
        return characters.reduce(CGFloat.zero) { maximum, character in
            let cell = GlyphCell(
                text: String(character),
                isTitle: isTitle,
                isSpacer: false,
                fontSize: fontSize,
                isPrimary: true,
                color: nil
            )
            let width = resolve(cell, in: &context).measure(in: area).width
            return max(maximum, width)
        }
    }

    private static func opticalBounds(for value: String, fontSize: CGFloat) -> CGRect? {
        guard let scalar = value.unicodeScalars.first,
              value.unicodeScalars.count == 1 else { return nil }

        let font = CTFontCreateWithName("SFProRounded-Bold" as CFString, fontSize, nil)
        var character = UniChar(scalar.value)
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 else {
            return nil
        }

        var bounds = CGRect.zero
        CTFontGetOpticalBoundsForGlyphs(font, &glyph, &bounds, 1, 0)
        return bounds.isNull || bounds.isInfinite ? nil : bounds
    }

    private static func bounds(of glyphs: [PositionedGlyph]) -> CGRect {
        let corners = glyphs
            .filter { !$0.glyph.cell.isSpacer }
            .flatMap { corners(of: $0) }

        guard let first = corners.first else { return .zero }
        let minX = corners.dropFirst().reduce(first.x) { min($0, $1.x) }
        let maxX = corners.dropFirst().reduce(first.x) { max($0, $1.x) }
        let minY = corners.dropFirst().reduce(first.y) { min($0, $1.y) }
        let maxY = corners.dropFirst().reduce(first.y) { max($0, $1.y) }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private static func drawnBounds(of glyphs: [PositionedGlyph]) -> CGRect {
        let corners = glyphs
            .filter { !$0.glyph.cell.isSpacer }
            .flatMap { drawnCorners(of: $0) }

        guard let first = corners.first else { return .zero }
        let minX = corners.dropFirst().reduce(first.x) { min($0, $1.x) }
        let maxX = corners.dropFirst().reduce(first.x) { max($0, $1.x) }
        let minY = corners.dropFirst().reduce(first.y) { min($0, $1.y) }
        let maxY = corners.dropFirst().reduce(first.y) { max($0, $1.y) }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private static func corners(of positioned: PositionedGlyph) -> [CGPoint] {
        let glyph = positioned.glyph
        let localBounds: CGRect
        if let opticalBounds = glyph.opticalBounds {
            localBounds = CGRect(
                x: -glyph.advance / 2 + opticalBounds.minX,
                y: -opticalBounds.maxY,
                width: opticalBounds.width,
                height: opticalBounds.height
            )
        } else {
            localBounds = CGRect(
                x: -glyph.advance / 2,
                y: -glyph.baseline,
                width: glyph.advance,
                height: glyph.size.height
            )
        }
        let rotation = positioned.rotation
        let sinRotation = sin(rotation)
        let cosRotation = cos(rotation)

        return [localBounds.minX, localBounds.maxX].flatMap { x in
            [localBounds.minY, localBounds.maxY].map { y in
                CGPoint(
                    x: positioned.baseline.x + cosRotation * x - sinRotation * y,
                    y: positioned.baseline.y + sinRotation * x + cosRotation * y
                )
            }
        }
    }

    private static func drawnCorners(of positioned: PositionedGlyph) -> [CGPoint] {
        let glyph = positioned.glyph
        let localBounds = CGRect(
            x: -glyph.advance / 2,
            y: -glyph.baseline,
            width: glyph.advance,
            height: glyph.size.height
        )
        let rotation = positioned.rotation
        let sinRotation = sin(rotation)
        let cosRotation = cos(rotation)

        return [localBounds.minX, localBounds.maxX].flatMap { x in
            [localBounds.minY, localBounds.maxY].map { y in
                CGPoint(
                    x: positioned.baseline.x + cosRotation * x - sinRotation * y,
                    y: positioned.baseline.y + sinRotation * x + cosRotation * y
                )
            }
        }
    }

    private static func fittingOffset(for bounds: CGRect, in size: CGSize) -> CGPoint {
        var x: CGFloat = 0
        var y: CGFloat = 0

        if bounds.minX < 0 { x = -bounds.minX }
        if bounds.maxX + x > size.width { x -= bounds.maxX + x - size.width }
        if bounds.minY < 0 { y = -bounds.minY }
        if bounds.maxY + y > size.height { y -= bounds.maxY + y - size.height }

        return CGPoint(x: x, y: y)
    }

    private static func visualEdgeLayout(
        _ glyphs: [PositionedGlyph],
        around center: CGPoint,
        radius: CGFloat
    ) -> (gapAngle: CGFloat, glyphs: [PositionedGlyph]) {
        let visible = glyphs.filter { !$0.glyph.cell.isSpacer }
        guard let first = visible.first, let last = visible.last else {
            return (0, glyphs)
        }

        let visualCenters = visible.map { positioned in
            let corners = drawnCorners(of: positioned)
            return CGPoint(
                x: corners.reduce(0) { $0 + $1.x } / CGFloat(corners.count),
                y: corners.reduce(0) { $0 + $1.y } / CGFloat(corners.count)
            )
        }
        let visualCenter = CGPoint(
            x: visualCenters.reduce(0) { $0 + $1.x } / CGFloat(visualCenters.count),
            y: visualCenters.reduce(0) { $0 + $1.y } / CGFloat(visualCenters.count)
        )
        let visualCenterAngle = atan2(visualCenter.y - center.y, visualCenter.x - center.x)
        let angularShift = .pi / 2 - visualCenterAngle

        let firstLeftEdge = corners(of: first)
            .map { bottomAngleOffset(of: $0, around: center) }
            .max() ?? 0
        let lastRightEdge = corners(of: last)
            .map { bottomAngleOffset(of: $0, around: center) }
            .min() ?? 0
        let visualSpan = firstLeftEdge - lastRightEdge
        let gapAngle = min(
            2 * .pi - 0.1,
            visualSpan + Self.edgePadding * 2 / max(radius, 1)
        )

        guard abs(angularShift) > 0.0001 else {
            return (gapAngle, glyphs)
        }

        let cosine = cos(angularShift)
        let sine = sin(angularShift)
        let shifted = glyphs.map { positioned in
            let dx = positioned.baseline.x - center.x
            let dy = positioned.baseline.y - center.y
            return PositionedGlyph(
                glyph: positioned.glyph,
                width: positioned.width,
                angle: positioned.angle + angularShift,
                rotation: positioned.rotation + angularShift,
                baseline: CGPoint(
                    x: center.x + cosine * dx - sine * dy,
                    y: center.y + sine * dx + cosine * dy
                )
            )
        }
        return (gapAngle, shifted)
    }

    private static func bottomAngleOffset(of point: CGPoint, around center: CGPoint) -> CGFloat {
        var offset = atan2(point.y - center.y, point.x - center.x) - .pi / 2
        while offset > .pi { offset -= 2 * .pi }
        while offset < -.pi { offset += 2 * .pi }
        return offset
    }

}

private struct CalHubCornerComplication: View {
    let entry: CalHubWatchEntry

    var body: some View {
        let locale = WatchWidgetData.locale(entry.snapshot)
        let allDay = WatchWidgetData.allDayEvents(on: entry.date, snapshot: entry.snapshot)
        let selected = WatchWidgetData.selectedTimedEvent(snapshot: entry.snapshot, now: entry.date)
        let event = selected?.event ?? allDay.last

        let markers = selected.map { [$0.event] } ?? Array(allDay.suffix(1))

        HStack(spacing: 2) {
            ForEach(markers) { event in
                Image(systemName: "capsule.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(WatchWidgetData.color(event))
            }
        }
        .widgetCurvesContent()
        .widgetLabel {
            if let event {
                let start = event.startDate ?? event.date
                let isTomorrow = selected != nil && Calendar.current.isDateInTomorrow(start)
                let eventTitle = WatchWidgetData.abbreviatedTitle(
                    event.title,
                    limit: isTomorrow ? 10 : 14
                )
                let cornerTime = selected.map {
                    WatchWidgetData.configuredTimeText(
                        $0.event,
                        locale: locale,
                        enabled: entry.snapshot?.cornerTimeEnabled ?? true,
                        showsStart: entry.snapshot?.cornerStartTimeEnabled ?? true,
                        showsEnd: entry.snapshot?.cornerEndTimeEnabled ?? false
                    )
                } ?? ""
                let startTime = cornerTime.isEmpty ? "" : " \(cornerTime)"

                if isTomorrow {
                    (
                        Text("TMR ")
                            .foregroundStyle(.primary)
                        + Text(eventTitle)
                            .foregroundStyle(WatchWidgetData.color(event))
                        + Text(startTime)
                            .foregroundStyle(WatchWidgetData.color(event))
                    )
                } else {
                    (
                        Text(eventTitle)
                            .foregroundStyle(WatchWidgetData.color(event))
                        + Text(startTime)
                            .foregroundStyle(WatchWidgetData.color(event))
                    )
                }
            } else {
                Text(locale.identifier.hasPrefix("ja") ? "予定なし" : "No events")
            }
        }
    }
}

private struct RectangularTimedLineBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 18

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CalHubRectangularComplication: View {
    let entry: CalHubWatchEntry
    @State private var timedLineBottom: CGFloat = 18

    var body: some View {
        let locale = WatchWidgetData.locale(entry.snapshot)
        let today = Calendar.current.startOfDay(for: entry.date)
        let events = WatchWidgetData.events(on: today, snapshot: entry.snapshot)
        let allDay = events.filter(WatchWidgetData.isAllDaySpan)
        let unfinishedTimedEvents = events.filter {
            !WatchWidgetData.isAllDaySpan($0)
                && WatchWidgetData.startsAfterNow($0, now: entry.date)
        }
        let prioritizedTimedEvents = WatchWidgetData.prioritizedEvents(
            unfinishedTimedEvents,
            now: entry.date,
            limit: 2
        )
        let allDayTitleSlots = max(2 - prioritizedTimedEvents.count, 0)
        let prioritizedAllDayEvents = WatchWidgetData.prioritizedEvents(
            allDay,
            now: entry.date,
            limit: allDayTitleSlots
        )
        let displayedEvents = (prioritizedTimedEvents + prioritizedAllDayEvents)
            .sorted {
                let leftDate = $0.startDate ?? $0.date
                let rightDate = $1.startDate ?? $1.date
                if leftDate != rightDate { return leftDate < rightDate }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        let hasDisplayedTimedEvent = displayedEvents.contains {
            !WatchWidgetData.isAllDaySpan($0)
        }
        let titleCandidates = unfinishedTimedEvents + allDay
        let futureCount = titleCandidates.filter { WatchWidgetData.hasNotStarted($0, now: entry.date) }.count
        let displayedFutureCount = displayedEvents.filter {
            WatchWidgetData.hasNotStarted($0, now: entry.date)
        }.count
        let remaining = max(futureCount - displayedFutureCount, 0)
        let markerLeadingPadding = allDay.isEmpty
            ? 0
            : 2 + CGFloat(allDay.count) * (2 + 4)
        let eventRowSpacing: CGFloat = 3
        let dateFormat = locale.identifier.hasPrefix("ja") ? "M - d EEE" : "EEE MMM d"

        VStack(alignment: .leading, spacing: 3) {
            Text(WatchWidgetData.dateText(today, format: dateFormat, locale: locale)
                .uppercased(with: locale))
                .font(.system(size: 11, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if displayedEvents.isEmpty && allDay.isEmpty {
                Text(locale.identifier.hasPrefix("ja") ? "イベントはありません" : "No events")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                GeometryReader { geometry in
                    let rowCount = max(displayedEvents.count, 1)
                    let availableRowHeight = max(
                        (geometry.size.height - CGFloat(max(rowCount - 1, 0)) * eventRowSpacing)
                            / CGFloat(rowCount),
                        1
                    )
                    let rowScale = min(max((availableRowHeight - 1) / 20, 0.6), 1)
                    let titleSize = 10 * rowScale
                    let timeSize = 8 * rowScale

                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: eventRowSpacing) {
                            ForEach(Array(displayedEvents.enumerated()), id: \.element.id) { index, event in
                                let isAllDay = WatchWidgetData.isAllDaySpan(event)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 3) {
                                        Text(event.title)
                                            .font(.system(size: titleSize, weight: .semibold))
                                            .lineLimit(1)
                                        if index == displayedEvents.count - 1 && remaining > 0 {
                                            Text(WatchWidgetData.moreText(remaining, locale: locale))
                                                .font(.system(size: 7 * rowScale))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .fixedSize(horizontal: true, vertical: false)
                                        }
                                    }
                                    Text(
                                        WatchWidgetData.configuredTimeText(
                                            event,
                                            locale: locale,
                                            enabled: entry.snapshot?.rectangularTimeEnabled ?? true,
                                            showsStart: entry.snapshot?.rectangularStartTimeEnabled ?? true,
                                            showsEnd: entry.snapshot?.rectangularEndTimeEnabled ?? false
                                        )
                                    )
                                        .font(.system(size: timeSize))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .layoutPriority(1)
                                }
                                .foregroundStyle(
                                    WatchWidgetData.startsAfterNow(event, now: entry.date)
                                        ? .primary : .secondary
                                )
                                .padding(.leading, isAllDay ? 0 : 6)
                                .frame(height: availableRowHeight, alignment: .topLeading)
                                .background(alignment: .leading) {
                                    GeometryReader { row in
                                        Capsule()
                                            .fill(isAllDay ? .clear : WatchWidgetData.color(event))
                                            .frame(width: 2, height: row.size.height)
                                            .background {
                                                if !isAllDay {
                                                    GeometryReader { geometry in
                                                        Color.clear
                                                            .preference(
                                                                key: RectangularTimedLineBottomKey.self,
                                                                value: geometry.frame(in: .named("rectangularEventList")).maxY
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
                            minHeight: displayedEvents.isEmpty ? geometry.size.height : 0,
                            alignment: .topLeading
                        )
                        .background(alignment: .leading) {
                            if !allDay.isEmpty {
                                GeometryReader { eventBlock in
                                    let markerHeight = !hasDisplayedTimedEvent
                                        ? eventBlock.size.height
                                        : min(timedLineBottom, eventBlock.size.height)
                                    HStack(spacing: 4) {
                                        ForEach(allDay) { event in
                                            Capsule()
                                                .fill(WatchWidgetData.color(event))
                                                .frame(width: 2, height: markerHeight)
                                        }
                                    }
                                    .padding(.leading, 2)
                                }
                            }
                        }
                        .coordinateSpace(name: "rectangularEventList")
                        .onPreferenceChange(RectangularTimedLineBottomKey.self) { bottom in
                            timedLineBottom = bottom
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct CalHubWatchWidget: Widget {
    let kind = "CalHubWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CalHubWatchProvider()) { entry in
            CalHubWatchWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Cal Hub")
        .description("今日と翌日のイベントを表示します。")
        .supportedFamilies([
            .accessoryInline,
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular
        ])
    }
}

private struct CalHubWatchWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CalHubWatchEntry

    @ViewBuilder
    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                CalHubInlineComplication(entry: entry)
            case .accessoryCircular:
                CalHubCircularComplication(entry: entry)
            case .accessoryCorner:
                CalHubCornerComplication(entry: entry)
            case .accessoryRectangular:
                CalHubRectangularComplication(entry: entry)
            default:
                CalHubInlineComplication(entry: entry)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
