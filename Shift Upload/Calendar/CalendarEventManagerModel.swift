import Combine
import CryptoKit
import Foundation
import os

private let calendarFetchLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ShiftUpload",
    category: "CalendarFetch"
)

@MainActor
final class CalendarEventManagerModel: ObservableObject {
    private struct MonthCacheEntry: Codable {
        let events: [CalendarEventRecord]
        let calendarColor: CalendarDisplayColor?
        let fetchedAt: Date

        nonisolated init(
            events: [CalendarEventRecord],
            calendarColor: CalendarDisplayColor?,
            fetchedAt: Date = Date()
        ) {
            self.events = events
            self.calendarColor = calendarColor
            self.fetchedAt = fetchedAt
        }
    }

    private struct PersistedMonthCache: Codable {
        let version: Int
        let entry: MonthCacheEntry
    }

    private struct NotionMetadataIdentity: Codable, Equatable {
        let name: String
        let type: String
    }

    private struct MonthFetchConfiguration {
        let destination: CalendarDestination
        let appleCalendarIdentifier: String
        let googleCalendarID: String
        let googleShowJapaneseHolidays: Bool
        let notionDataSourceID: String
        let notionDateProperty: String
        let notionTitleProperty: String
        let notionTagProperty: String
        let notionTagValue: String
        let notionNotesProperty: String
        let notionLocationProperty: String
        let notionURLProperty: String
        let notionMetadataProperties: [NotionPropertyOption]
        let localeIdentifier: String
    }

    @Published private(set) var events: [CalendarEventRecord] = [] {
        didSet {
            guard events != oldValue else { return }
            eventsRevision &+= 1
        }
    }
    private(set) var eventsRevision = 0
    @Published private(set) var loadedDays: Set<Int> = []
    @Published private(set) var calendarColor: CalendarDisplayColor? = nil
    @Published private(set) var isLoading = false
    @Published private(set) var isDeleting = false
    @Published private(set) var isUpdating = false
    @Published var isDeleteConfirmationPresented = false
    @Published private(set) var pendingDeletion: CalendarEventRecord?
    @Published private(set) var message = ""
    @Published private(set) var shouldAnimateEventBandReveal = false
    @Published private(set) var cachedMonthRevision = 0

    let diagnosticID = UUID().uuidString

    private var destination: CalendarDestination
    @Published private(set) var yearMonth: YearMonth
    private var appleCalendarIdentifier: String
    private var googleCalendarID: String
    private var googleShowJapaneseHolidays: Bool
    private var notionDataSourceID: String
    private var notionDateProperty: String
    private var notionTitleProperty: String
    private var notionTagProperty: String
    private var notionTagValue: String
    private var notionNotesProperty: String
    private var notionLocationProperty: String
    private var notionURLProperty: String
    private var notionMetadataProperties: [NotionPropertyOption]
    private var localeIdentifier = "ja"
    private var loadTask: Task<Void, Never>?
    private var prefetchKickoffTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var cacheGeneration = 0
    private var monthCache: [YearMonth: MonthCacheEntry] = [:]
    private var displayFallbackMonthCache: [YearMonth: MonthCacheEntry] = [:]
    private var persistentCacheMisses = Set<YearMonth>()
    private var persistentCachePreloadTasks: [YearMonth: Task<Void, Never>] = [:]
    private var persistentCachePreloadTokens: [YearMonth: UUID] = [:]
    private var queuedPersistentCachePreloads = Set<YearMonth>()
    private var persistentCachePreloadAnchor: YearMonth?
    private var prefetchTasks: [YearMonth: Task<Void, Never>] = [:]
    private var prefetchTokens: [YearMonth: UUID] = [:]
    private var queuedPrefetchMonths = Set<YearMonth>()
    private var backgroundCacheRefreshQueue: [YearMonth] = []
    private var backgroundCacheRefreshTask: Task<Void, Never>?
    private var backgroundCacheRefreshToken: UUID?
    private var backgroundCacheRefreshMonths = Set<YearMonth>()
    private var didPrunePersistentCache = false
    private var isMonthScrollActive = false
#if DEBUG
    private var debugPublisherMonitor: AnyCancellable?
#endif

    // Retain a wider memory window and prepare the next few swipe destinations.
    private static let cacheMonthRadius = 6
    private static let prefetchMonthRadius = 3
    private static let maximumConcurrentPrefetches = 2
    private static let maximumConcurrentPersistentCachePreloads = 2
    private static let prefetchThrottleNanoseconds: UInt64 = 50_000_000
    private static let persistentCacheRefreshInterval: TimeInterval = 10 * 60
    private static let persistentCacheLifetime: TimeInterval = 30 * 24 * 60 * 60

    init(
        destination: CalendarDestination,
        yearMonth: YearMonth,
        appleCalendarIdentifier: String,
        googleCalendarID: String,
        googleShowJapaneseHolidays: Bool,
        notionDataSourceID: String,
        notionDateProperty: String,
        notionTitleProperty: String,
        notionTagProperty: String,
        notionTagValue: String,
        notionNotesProperty: String,
        notionLocationProperty: String,
        notionURLProperty: String,
        notionMetadataProperties: [NotionPropertyOption] = []
    ) {
        self.destination = destination
        self.yearMonth = yearMonth
        self.appleCalendarIdentifier = appleCalendarIdentifier
        self.googleCalendarID = googleCalendarID
        self.googleShowJapaneseHolidays = googleShowJapaneseHolidays
        self.notionDataSourceID = notionDataSourceID
        self.notionDateProperty = notionDateProperty
        self.notionTitleProperty = notionTitleProperty
        self.notionTagProperty = notionTagProperty
        self.notionTagValue = notionTagValue
        self.notionNotesProperty = notionNotesProperty
        self.notionLocationProperty = notionLocationProperty
        self.notionURLProperty = notionURLProperty
        self.notionMetadataProperties = notionMetadataProperties
#if DEBUG
        let modelID = diagnosticID
        debugPublisherMonitor = objectWillChange.sink { _ in
            guard !Thread.isMainThread else { return }
            let stack = Thread.callStackSymbols.prefix(24).joined(separator: "\n")
            calendarFetchLogger.error(
                "off-main calendar publisher model=\(modelID) stack=\(stack, privacy: .public)"
            )
        }
#endif
    }

    func updateYearMonth(_ yearMonth: YearMonth) {
        self.yearMonth = yearMonth
        if let cachedMonth = monthCache[yearMonth] ?? displayFallbackMonthCache[yearMonth] {
            shouldAnimateEventBandReveal = false
            display(cachedMonth)
        } else {
            shouldAnimateEventBandReveal = false
            let carryOverEvents = Array(
                Dictionary(
                    ((monthCache[yearMonth.addingMonths(-1)]
                        ?? displayFallbackMonthCache[yearMonth.addingMonths(-1)])?.events ?? [])
                        .filter(\.spansMultipleDays)
                        .map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                .values
            )
            calendarColor = nil
            events = carryOverEvents
            loadedDays = Set(carryOverEvents.map(\.day))
            message = ""
        }
    }

    func setMonthScrollActive(_ isActive: Bool) {
        guard isMonthScrollActive != isActive else { return }
        isMonthScrollActive = isActive
        guard isActive else {
            schedulePrefetchAfterDisplay(around: yearMonth, generation: loadGeneration)
            return
        }

        prefetchKickoffTask?.cancel()
        prefetchKickoffTask = nil
        calendarFetchLogger.notice(
            "month prefetch paused inFlightRetained=\(self.prefetchTasks.count)"
        )
    }

    func setLocaleIdentifier(_ identifier: String) {
        guard localeIdentifier != identifier else { return }
        let previousLocale = localeIdentifier
        let previousNamespace = String(persistentCacheNamespace.prefix(8))
        localeIdentifier = identifier
        calendarFetchLogger.notice(
            "locale changed model=\(self.diagnosticID.prefix(6)) from=\(previousLocale) to=\(identifier) namespace=\(previousNamespace)->\(self.persistentCacheNamespace.prefix(8))"
        )
        invalidateMonthCache(preservingNearbyDisplay: true)
    }

    func updateConfiguration(
        destination: CalendarDestination,
        appleCalendarIdentifier: String,
        googleCalendarID: String,
        googleShowJapaneseHolidays: Bool,
        notionDataSourceID: String,
        notionDateProperty: String,
        notionTitleProperty: String,
        notionTagProperty: String,
        notionTagValue: String,
        notionNotesProperty: String,
        notionLocationProperty: String,
        notionURLProperty: String,
        notionMetadataProperties: [NotionPropertyOption]
    ) {
        let previousNotionMetadataIdentity = Self.notionMetadataIdentity(
            self.notionMetadataProperties
        )
        let nextNotionMetadataIdentity = Self.notionMetadataIdentity(notionMetadataProperties)
        let changedFields = [
            self.destination != destination ? "destination" : nil,
            self.appleCalendarIdentifier != appleCalendarIdentifier ? "appleCalendar" : nil,
            self.googleCalendarID != googleCalendarID ? "googleCalendar" : nil,
            self.googleShowJapaneseHolidays != googleShowJapaneseHolidays ? "googleHolidays" : nil,
            self.notionDataSourceID != notionDataSourceID ? "notionDataSource" : nil,
            self.notionDateProperty != notionDateProperty ? "notionDateProperty" : nil,
            self.notionTitleProperty != notionTitleProperty ? "notionTitleProperty" : nil,
            self.notionTagProperty != notionTagProperty ? "notionTagProperty" : nil,
            self.notionTagValue != notionTagValue ? "notionTagValue" : nil,
            self.notionNotesProperty != notionNotesProperty ? "notionNotesProperty" : nil,
            self.notionLocationProperty != notionLocationProperty ? "notionLocationProperty" : nil,
            self.notionURLProperty != notionURLProperty ? "notionURLProperty" : nil,
            previousNotionMetadataIdentity != nextNotionMetadataIdentity ? "notionMetadata" : nil
        ].compactMap { $0 }
        let previousNamespace = String(persistentCacheNamespace.prefix(8))

        self.destination = destination
        self.appleCalendarIdentifier = appleCalendarIdentifier
        self.googleCalendarID = googleCalendarID
        self.googleShowJapaneseHolidays = googleShowJapaneseHolidays
        self.notionDataSourceID = notionDataSourceID
        self.notionDateProperty = notionDateProperty
        self.notionTitleProperty = notionTitleProperty
        self.notionTagProperty = notionTagProperty
        self.notionTagValue = notionTagValue
        self.notionNotesProperty = notionNotesProperty
        self.notionLocationProperty = notionLocationProperty
        self.notionURLProperty = notionURLProperty
        self.notionMetadataProperties = notionMetadataProperties

        if !changedFields.isEmpty {
            calendarFetchLogger.notice(
                "configuration changed model=\(self.diagnosticID.prefix(6)) fields=\(changedFields.joined(separator: ",")) namespace=\(previousNamespace)->\(self.persistentCacheNamespace.prefix(8))"
            )
            invalidateMonthCache(preservingNearbyDisplay: changedFields == ["notionMetadata"])
            load()
        }
    }

    func invalidateCachedMonths(_ yearMonths: Set<YearMonth>) {
        for yearMonth in yearMonths {
            removeCachedMonth(for: yearMonth)
            cancelPrefetch(for: yearMonth)
        }
    }

    func refreshAllCachedMonths() {
        invalidateMonthCache()
        load(forceRefresh: true)
    }

    func cachedEvents(for yearMonth: YearMonth) -> [CalendarEventRecord] {
        var cachedEvents = (monthCache[yearMonth] ?? displayFallbackMonthCache[yearMonth])?.events ?? []
        let previousMonth = yearMonth.addingMonths(-1)
        cachedEvents.append(contentsOf: ((monthCache[previousMonth] ?? displayFallbackMonthCache[previousMonth])?.events ?? [])
            .filter(\.spansMultipleDays))

        return Array(
            Dictionary(
                cachedEvents.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            .values
        )
    }

    func preloadPersistentCache(around yearMonth: YearMonth) {
        persistentCachePreloadAnchor = yearMonth
        monthCache = monthCache.filter {
            monthDistance($0.key, from: yearMonth) <= Self.cacheMonthRadius
        }
        queuedPersistentCachePreloads = Set(
            (-Self.prefetchMonthRadius...Self.prefetchMonthRadius).map {
                yearMonth.addingMonths($0)
            }
        )
        startPersistentCachePreloads()
    }

    private func startPersistentCachePreloads() {
        guard let anchor = persistentCachePreloadAnchor else { return }

        while persistentCachePreloadTasks.count < Self.maximumConcurrentPersistentCachePreloads,
              let targetMonth = queuedPersistentCachePreloads.min(by: {
                  monthDistance($0, from: anchor) < monthDistance($1, from: anchor)
            }) {
            queuedPersistentCachePreloads.remove(targetMonth)
            guard monthCache[targetMonth] == nil,
                  !persistentCacheMisses.contains(targetMonth),
                  persistentCachePreloadTasks[targetMonth] == nil,
                  let url = persistentCacheFileURL(for: targetMonth) else { continue }

            let token = UUID()
            let requestedCacheGeneration = cacheGeneration
            persistentCachePreloadTokens[targetMonth] = token
            persistentCachePreloadTasks[targetMonth] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.finishPersistentCachePreload(for: targetMonth, token: token)
                }

                let data = await Task.detached(priority: .utility) {
                    try? Data(contentsOf: url)
                }.value
                guard !Task.isCancelled,
                      self.cacheGeneration == requestedCacheGeneration,
                      self.persistentCachePreloadTokens[targetMonth] == token else { return }

                guard let data else {
                    self.calendarFetchLoggerPersistentCacheMiss(for: targetMonth, url: url)
                    return
                }
                guard let anchor = self.persistentCachePreloadAnchor,
                      self.monthDistance(targetMonth, from: anchor) <= Self.cacheMonthRadius else {
                    return
                }
                guard let cachedMonth = self.decodePersistentMonth(data, for: targetMonth, url: url) else {
                    return
                }

                if self.monthCache[targetMonth] == nil {
                    self.monthCache[targetMonth] = cachedMonth
                    self.cachedMonthRevision += 1
                    calendarFetchLogger.notice(
                        "persistent cache preloaded month=\(targetMonth.year)-\(targetMonth.month) events=\(cachedMonth.events.count)"
                    )
                    if self.isPersistentCacheStale(cachedMonth) {
                        self.enqueueBackgroundCacheRefresh(for: targetMonth)
                    }
                }
            }
        }
    }

    private func finishPersistentCachePreload(for yearMonth: YearMonth, token: UUID) {
        guard persistentCachePreloadTokens[yearMonth] == token else { return }
        persistentCachePreloadTasks.removeValue(forKey: yearMonth)
        persistentCachePreloadTokens.removeValue(forKey: yearMonth)
        startPersistentCachePreloads()
    }

    private func calendarFetchLoggerPersistentCacheMiss(for yearMonth: YearMonth, url: URL) {
        let namespace = String(persistentCacheNamespace.prefix(8))
        let reason = FileManager.default.fileExists(atPath: url.path) ? "io" : "file-not-found"
        if reason == "file-not-found" {
            persistentCacheMisses.insert(yearMonth)
        }
        calendarFetchLogger.debug(
            "persistent cache miss month=\(yearMonth.year)-\(yearMonth.month) reason=\(reason) namespace=\(namespace)"
        )
    }

    @MainActor
    func fetchEventsByMonth(for year: Int) async -> [YearMonth: [CalendarEventRecord]] {
        var result: [YearMonth: [CalendarEventRecord]] = [:]
        for firstMonthNumber in stride(from: 1, through: 12, by: 2) {
            guard !Task.isCancelled else { break }
            let firstMonth = YearMonth(year: year, month: firstMonthNumber)
            let secondMonth = YearMonth(year: year, month: firstMonthNumber + 1)
            async let firstEntry = fetchMonthIfNeeded(firstMonth)
            async let secondEntry = fetchMonthIfNeeded(secondMonth)
            let (first, second) = await (firstEntry, secondEntry)
            if let first {
                store(first, for: firstMonth)
                if isPersistentCacheStale(first) {
                    enqueueBackgroundCacheRefresh(for: firstMonth)
                }
            }
            if let second {
                store(second, for: secondMonth)
                if isPersistentCacheStale(second) {
                    enqueueBackgroundCacheRefresh(for: secondMonth)
                }
            }
            result[firstMonth] = first?.events
            result[secondMonth] = second?.events
        }
        return result
    }

    @MainActor
    func refreshEventsByMonth(for year: Int) async -> [YearMonth: [CalendarEventRecord]] {
        let yearMonths = Set((1...12).map { YearMonth(year: year, month: $0) })
        return await refreshCachedMonths(for: yearMonths)
    }

    @MainActor
    func refreshCachedMonths(for yearMonths: Set<YearMonth>) async -> [YearMonth: [CalendarEventRecord]] {
        cancelBackgroundCacheRefreshes()
        let orderedMonths = yearMonths.sorted {
            ($0.year, $0.month) < ($1.year, $1.month)
        }
        var index = 0
        while index + 1 < orderedMonths.count {
            guard !Task.isCancelled else { break }
            let firstMonth = orderedMonths[index]
            let secondMonth = orderedMonths[index + 1]
            async let firstEntry = try? fetchMonth(firstMonth)
            async let secondEntry = try? fetchMonth(secondMonth)
            let (first, second) = await (firstEntry, secondEntry)
            if let first {
                store(first, for: firstMonth)
            }
            if let second {
                store(second, for: secondMonth)
            }
            if first != nil || second != nil {
                cachedMonthRevision += 1
            }
            index += 2
        }
        if index < orderedMonths.count, !Task.isCancelled {
            let yearMonth = orderedMonths[index]
            if let refreshedMonth = try? await fetchMonth(yearMonth) {
                store(refreshedMonth, for: yearMonth)
                cachedMonthRevision += 1
            }
        }

        var result: [YearMonth: [CalendarEventRecord]] = [:]
        for yearMonth in orderedMonths {
            result[yearMonth] = monthCache[yearMonth]?.events
        }
        return result
    }

    @MainActor
    func revalidateCachedMonths(for yearMonths: Set<YearMonth>) {
        var loadedPersistentCache = false
        for yearMonth in yearMonths {
            if monthCache[yearMonth] == nil,
               let cachedMonth = loadPersistentMonth(for: yearMonth) {
                monthCache[yearMonth] = cachedMonth
                loadedPersistentCache = true
            }
            if let cachedMonth = monthCache[yearMonth], isPersistentCacheStale(cachedMonth) {
                enqueueBackgroundCacheRefresh(for: yearMonth)
            }
        }
        if loadedPersistentCache {
            cachedMonthRevision += 1
        }
    }

    @MainActor
    func cachedEventsByMonth(
        for year: Int,
        loadingPersistentCache: Bool = false
    ) -> [YearMonth: [CalendarEventRecord]] {
        var result: [YearMonth: [CalendarEventRecord]] = [:]
        for month in 1...12 {
            let yearMonth = YearMonth(year: year, month: month)
            if monthCache[yearMonth] == nil,
               loadingPersistentCache,
               let cachedMonth = loadPersistentMonth(for: yearMonth) {
                monthCache[yearMonth] = cachedMonth
            }
            if let cachedMonth = monthCache[yearMonth] ?? displayFallbackMonthCache[yearMonth] {
                result[yearMonth] = cachedMonth.events
                if loadingPersistentCache,
                   monthCache[yearMonth] != nil,
                   isPersistentCacheStale(cachedMonth) {
                    enqueueBackgroundCacheRefresh(for: yearMonth)
                }
            } else {
                result[yearMonth] = nil
            }
        }
        return result
    }

    @MainActor
    private func fetchMonthIfNeeded(_ yearMonth: YearMonth) async -> MonthCacheEntry? {
        if let cachedMonth = monthCache[yearMonth] { return cachedMonth }
        if let cachedMonth = loadPersistentMonth(for: yearMonth) {
            return cachedMonth
        }
        return try? await fetchMonth(yearMonth)
    }

    var groupedDays: [Int] {
        Array(Set(events.map(\.day))).sorted()
    }

    var displayedMonthText: String {
        let locale = Locale(identifier: localeIdentifier)
        return localeIdentifier.hasPrefix("en")
            ? yearMonth.displayText(for: locale)
            : String(format: "%04d-%02d", yearMonth.year, yearMonth.month)
    }

    func events(for day: Int, yearMonth: YearMonth? = nil) -> [CalendarEventRecord] {
        let targetYearMonth = yearMonth ?? self.yearMonth
        let sourceEvents = yearMonth.map { cachedEvents(for: $0) } ?? events
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let targetDate = calendar.date(from: DateComponents(
            year: targetYearMonth.year,
            month: targetYearMonth.month,
            day: day
        )) else {
            return []
        }

        return sourceEvents
            .filter { $0.occurs(on: targetDate, fallbackYearMonth: targetYearMonth) }
            .sorted(by: calendarEventComesBefore)
    }

    func applyRegisteredDateTimeEvent(
        id: String,
        draft: CalendarEventDraft
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let startComponents = calendar.dateComponents([.year, .month, .day], from: draft.startDate)
        guard let eventYear = startComponents.year,
              let eventMonth = startComponents.month,
              let day = startComponents.day,
              eventYear == yearMonth.year,
              eventMonth == yearMonth.month else {
            return
        }

        let displayLocale = Locale(identifier: localeIdentifier)
        let event = CalendarEventRecord(
            id: id,
            day: day,
            title: draft.title,
            detail: draft.isAllDay
                ? ShiftHubLocalization.string("終日", locale: displayLocale)
                : registeredTimeRangeText(start: draft.startDate, end: draft.endDate),
            isAllDay: draft.isAllDay,
            startDate: draft.startDate,
            endDate: draft.endDate,
            metadata: draft.metadata,
            calendarColor: calendarColor
        )

        // Keep the current screen and its cache in sync without invalidating or re-fetching other months.
        shouldAnimateEventBandReveal = false
        events.removeAll { $0.id == id }
        events.append(event)
        events.sort(by: calendarEventComesBefore)
        loadedDays = Set(events.map(\.day))

        if let cachedMonth = monthCache[yearMonth] {
            var updatedEvents = cachedMonth.events.filter { $0.id != id }
            updatedEvents.append(event)
            updatedEvents.sort(by: calendarEventComesBefore)
            store(
                MonthCacheEntry(
                    events: updatedEvents,
                    calendarColor: cachedMonth.calendarColor
                ),
                for: yearMonth
            )
        } else {
            message = message(for: events)
        }
    }

    func updateEvent(
        _ target: CalendarEventRecord,
        draft: CalendarEventDraft
    ) {
        guard !target.isReadOnly, !isUpdating else { return }

        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            message = ShiftHubLocalization.string(
                "イベントタイトルを入力してください。",
                locale: Locale(identifier: localeIdentifier)
            )
            return
        }

        let calendar = Calendar.current
        let normalizedStartDate = draft.isAllDay ? calendar.startOfDay(for: draft.startDate) : draft.startDate
        let normalizedEndDate = draft.isAllDay ? calendar.startOfDay(for: draft.endDate) : draft.endDate
        guard normalizedEndDate >= normalizedStartDate else {
            message = ShiftHubLocalization.string(
                "終了日時は開始日時以降にしてください。",
                locale: Locale(identifier: localeIdentifier)
            )
            return
        }

        isUpdating = true
        message = ""

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                switch destination {
                case .apple:
                    try AppleCalendarEventClient(
                        calendarIdentifier: appleCalendarIdentifier
                    ).updateEvent(
                        identifier: target.id,
                        title: trimmedTitle,
                        startDate: normalizedStartDate,
                        endDate: normalizedEndDate,
                        isAllDay: draft.isAllDay,
                        metadata: draft.metadata
                    )
                case .google:
                    guard GoogleTokenStore.load() != nil else {
                        throw CalendarEventManagementError.invalidSettings("Googleの認証設定を確認してください。")
                    }

                    try await GoogleCalendarAPIClient(
                        clientID: GoogleOAuthConfiguration.clientID
                    ).updateEvent(
                        calendarID: googleCalendarID,
                        eventID: target.id,
                        title: trimmedTitle,
                        startDate: normalizedStartDate,
                        endDate: normalizedEndDate,
                        isAllDay: draft.isAllDay,
                        metadata: draft.metadata
                    )
                case .notion:
                    guard let token = KeychainStore.string(for: "notion-access-token") else {
                        throw CalendarEventManagementError.invalidSettings("Notionのアクセストークンを設定してください。")
                    }

                    try await NotionCalendarEventClient(
                        token: token,
                        dataSourceID: notionDataSourceID,
                        dateProperty: notionDateProperty,
                        titleProperty: notionTitleProperty,
                        tagProperty: notionTagProperty,
                        tagValue: notionTagValue,
                        notesProperty: notionNotesProperty,
                        locationProperty: notionLocationProperty,
                        urlProperty: notionURLProperty,
                        metadataProperties: notionMetadataProperties
                    ).updatePage(
                        identifier: target.id,
                        title: trimmedTitle,
                        startDate: normalizedStartDate,
                        endDate: normalizedEndDate,
                        isAllDay: draft.isAllDay,
                        metadata: draft.metadata
                    )
                }

                if self.destination == .notion {
                    self.events.removeAll { $0.id == target.id }
                    self.loadedDays = Set(self.events.map(\.day))
                    self.clearPersistentCacheForCurrentConfiguration()
                    self.invalidateMonthCache()
                    self.load(forceRefresh: true)
                } else {
                    self.clearPersistentCacheForCurrentConfiguration()
                    self.applyUpdatedDateTimeEvent(
                        id: target.id,
                        title: trimmedTitle,
                        startDate: normalizedStartDate,
                        endDate: normalizedEndDate,
                        isAllDay: draft.isAllDay,
                        metadata: draft.metadata
                    )
                }
                self.message = ShiftHubLocalization.string(
                    "イベントを更新しました。",
                    locale: Locale(identifier: self.localeIdentifier)
                )
            } catch {
                self.message = ShiftHubLocalization.format(
                    "イベントの更新に失敗しました: %@",
                    locale: Locale(identifier: self.localeIdentifier),
                    arguments: error.localizedDescription
                )
            }

            self.isUpdating = false
        }
    }

    private func applyUpdatedDateTimeEvent(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        metadata: CalendarEventMetadata
    ) {
        guard let existingEvent = events.first(where: { $0.id == id }) else { return }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: startDate)
        let isInDisplayedMonth = components.year == yearMonth.year
            && components.month == yearMonth.month
        let updatedEvent: CalendarEventRecord?
        if isInDisplayedMonth, let day = components.day {
            let displayLocale = Locale(identifier: localeIdentifier)
            updatedEvent = CalendarEventRecord(
                id: id,
                day: day,
                title: title,
                detail: isAllDay
                    ? ShiftHubLocalization.string("終日", locale: displayLocale)
                    : registeredTimeRangeText(start: startDate, end: endDate),
                isAllDay: isAllDay,
                startDate: startDate,
                endDate: endDate,
                metadata: metadata,
                calendarColor: existingEvent.calendarColor,
                isReadOnly: existingEvent.isReadOnly
            )
        } else {
            updatedEvent = nil
        }

        shouldAnimateEventBandReveal = false
        events.removeAll { $0.id == id }
        if let updatedEvent {
            events.append(updatedEvent)
            events.sort(by: calendarEventComesBefore)
        }
        loadedDays = Set(events.map(\.day))
        updateCachedDisplayedMonth()
    }

    func dayHeader(
        for day: Int,
        yearMonth: YearMonth? = nil,
        locale: Locale
    ) -> String {
        let displayYearMonth = yearMonth ?? self.yearMonth
        let weekdays = locale.identifier.hasPrefix("en")
            ? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            : ["日", "月", "火", "水", "木", "金", "土"]
        let weekday = displayYearMonth.weekdayIndex(for: day)
            .map { weekdays[$0 - 1] } ?? ""
        let dateText = displayYearMonth.displayText(for: day, locale: locale)
        return locale.identifier.hasPrefix("en")
            ? "\(dateText) (\(weekday))"
            : "\(dateText)（\(weekday)）"
    }

    func load(forceRefresh: Bool = false) {
        loadGeneration += 1
        let generation = loadGeneration
        let targetMonth = yearMonth
        let hadDisplayedMonth = !events.isEmpty || !loadedDays.isEmpty
        let requestedCacheGeneration = cacheGeneration
        loadTask?.cancel()
        prefetchKickoffTask?.cancel()
        prefetchKickoffTask = nil

        updateCacheWindow(around: targetMonth)
        let loadLogMessage =
            "load requested month=\(targetMonth.year)-\(targetMonth.month) "
                + "forceRefresh=\(forceRefresh) "
                + "cacheEntries=\(monthCache.count) "
                + "model=\(diagnosticID.prefix(6)) "
                + "cacheNamespace=\(persistentCacheNamespace.prefix(8))"
        calendarFetchLogger.debug("\(loadLogMessage, privacy: .public)")
        if forceRefresh {
            monthCache.removeValue(forKey: targetMonth)
            cancelPrefetch(for: targetMonth)
        }

        var cachedMonth = monthCache[targetMonth]
        if cachedMonth == nil && !forceRefresh {
            cachedMonth = loadPersistentMonth(for: targetMonth)
            if let cachedMonth {
                monthCache[targetMonth] = cachedMonth
            }
        }

        var loadedNeighborCache = false
        for neighborMonth in [targetMonth.addingMonths(-1), targetMonth.addingMonths(1)] {
            guard monthCache[neighborMonth] == nil,
                  let neighborCache = loadPersistentMonth(for: neighborMonth) else { continue }
            monthCache[neighborMonth] = neighborCache
            loadedNeighborCache = true
            if isPersistentCacheStale(neighborCache) {
                enqueueBackgroundCacheRefresh(for: neighborMonth)
            }
        }
        if loadedNeighborCache {
            cachedMonthRevision += 1
        }
#if os(iOS)
        prepareWatchSyncSnapshot()
#else
        publishWidgetSnapshotIfRelevant(YearMonth.current)
#endif

        if let cachedMonth {
            let cacheLogMessage =
                "cache hit month=\(targetMonth.year)-\(targetMonth.month) "
                    + "events=\(cachedMonth.events.count)"
            calendarFetchLogger.notice("\(cacheLogMessage, privacy: .public)")
            shouldAnimateEventBandReveal = false
            display(cachedMonth)
            if !forceRefresh && !isPersistentCacheStale(cachedMonth) {
                isLoading = false
                loadTask = nil
                schedulePrefetchAfterDisplay(around: targetMonth, generation: generation)
                return
            }
            if !forceRefresh {
                enqueueBackgroundCacheRefresh(for: targetMonth)
                isLoading = false
                loadTask = nil
                schedulePrefetchAfterDisplay(around: targetMonth, generation: generation)
                return
            }
        }

        if cachedMonth == nil && !hadDisplayedMonth {
            clearDisplayedMonth()
        }
        if forceRefresh {
            message = ""
        }
        isLoading = true

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                if self.loadGeneration == generation {
                    self.isLoading = false
                    self.loadTask = nil
                }
            }

            do {
                let fetchedMonth: MonthCacheEntry
                if self.prefetchTasks[targetMonth] != nil {
                    // Reuse an adjacent-month fetch that is already in flight
                    // instead of cancelling it and starting the same request again.
                    if let prefetchedMonth = try await self.waitForPrefetch(targetMonth) {
                        fetchedMonth = prefetchedMonth
                    } else {
                        fetchedMonth = try await self.fetchMonth(targetMonth)
                    }
                } else {
                    fetchedMonth = try await self.fetchMonth(targetMonth)
                }
                guard !Task.isCancelled,
                      self.loadGeneration == generation,
                      self.cacheGeneration == requestedCacheGeneration,
                      self.yearMonth == targetMonth else { return }

                // Display the requested month without waiting for neighbor prefetches.
                self.shouldAnimateEventBandReveal = !hadDisplayedMonth
                self.store(fetchedMonth, for: targetMonth)
                self.schedulePrefetchAfterDisplay(around: targetMonth, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard self.loadGeneration == generation,
                      self.cacheGeneration == requestedCacheGeneration,
                      self.yearMonth == targetMonth else { return }
                if !hadDisplayedMonth {
                    self.clearDisplayedMonth()
                }
                self.message = ShiftHubLocalization.localizedErrorDescription(
                    error,
                    locale: Locale(identifier: self.localeIdentifier)
                )
            }
        }
    }

    private func waitForPrefetch(_ yearMonth: YearMonth) async throws -> MonthCacheEntry? {
        while prefetchTasks[yearMonth] != nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return monthCache[yearMonth]
    }

    private func fetchMonth(_ yearMonth: YearMonth) async throws -> MonthCacheEntry {
        let start = DispatchTime.now().uptimeNanoseconds
        calendarFetchLogger.debug(
            "fetch begin month=\(yearMonth.year)-\(yearMonth.month)"
        )
        let configuration = MonthFetchConfiguration(
            destination: destination,
            appleCalendarIdentifier: appleCalendarIdentifier,
            googleCalendarID: googleCalendarID,
            googleShowJapaneseHolidays: googleShowJapaneseHolidays,
            notionDataSourceID: notionDataSourceID,
            notionDateProperty: notionDateProperty,
            notionTitleProperty: notionTitleProperty,
            notionTagProperty: notionTagProperty,
            notionTagValue: notionTagValue,
            notionNotesProperty: notionNotesProperty,
            notionLocationProperty: notionLocationProperty,
            notionURLProperty: notionURLProperty,
            notionMetadataProperties: notionMetadataProperties,
            localeIdentifier: localeIdentifier
        )
        let fetchTask = Task.detached(priority: .utility) {
            try await Self.fetchMonth(yearMonth, configuration: configuration)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await fetchTask.value
            } onCancel: {
                fetchTask.cancel()
            }
            let elapsedMilliseconds = Double(
                DispatchTime.now().uptimeNanoseconds - start
            ) / 1_000_000
            let elapsedText = String(format: "%.2f", elapsedMilliseconds)
            let fetchLogMessage =
                "fetch end month=\(yearMonth.year)-\(yearMonth.month) "
                    + "events=\(result.events.count) "
                    + "duration=\(elapsedText)ms"
            calendarFetchLogger.notice("\(fetchLogMessage, privacy: .public)")
            return result
        } catch {
            let elapsedMilliseconds = Double(
                DispatchTime.now().uptimeNanoseconds - start
            ) / 1_000_000
            let elapsedText = String(format: "%.2f", elapsedMilliseconds)
            let fetchErrorLogMessage =
                "fetch failed month=\(yearMonth.year)-\(yearMonth.month) "
                    + "duration=\(elapsedText)ms"
            calendarFetchLogger.error("\(fetchErrorLogMessage, privacy: .public)")
            throw error
        }
    }

    private nonisolated static func fetchMonth(
        _ yearMonth: YearMonth,
        configuration: MonthFetchConfiguration
    ) async throws -> MonthCacheEntry {
        let fetchedEvents: [CalendarEventRecord]
        let fetchedCalendarColor: CalendarDisplayColor?

        switch configuration.destination {
        case .apple:
            let calendarIdentifier = configuration.appleCalendarIdentifier
            let client = AppleCalendarEventClient(calendarIdentifier: calendarIdentifier)
            fetchedCalendarColor = try client.fetchCalendarColor()
            fetchedEvents = try client.fetch(yearMonth: yearMonth)
        case .google:
            guard GoogleTokenStore.load() != nil else {
                throw CalendarEventManagementError.invalidSettings("Googleの認証設定を確認してください。")
            }

            let client = GoogleCalendarAPIClient(clientID: GoogleOAuthConfiguration.clientID)
            var googleEvents = try await client.fetchEvents(
                yearMonth: yearMonth,
                calendarID: configuration.googleCalendarID
            )
            if configuration.googleShowJapaneseHolidays {
                googleEvents.append(contentsOf: try await client.fetchJapaneseHolidayEvents(yearMonth: yearMonth))
            }
            fetchedEvents = googleEvents
            if let eventColor = fetchedEvents.compactMap({ $0.calendarColor }).first {
                fetchedCalendarColor = eventColor
            } else {
                fetchedCalendarColor = try? await client.fetchCalendarColor(calendarID: configuration.googleCalendarID)
            }
        case .notion:
            guard let token = KeychainStore.string(for: "notion-access-token"),
                  !token.isEmpty,
                  !configuration.notionDataSourceID.isEmpty else {
                throw CalendarEventManagementError.invalidSettings("NotionのアクセストークンとデータベースIDを設定してください。")
            }

            fetchedEvents = try await NotionCalendarEventClient(
                token: token,
                dataSourceID: configuration.notionDataSourceID,
                dateProperty: configuration.notionDateProperty,
                titleProperty: configuration.notionTitleProperty,
                tagProperty: configuration.notionTagProperty,
                tagValue: configuration.notionTagValue,
                notesProperty: configuration.notionNotesProperty,
                locationProperty: configuration.notionLocationProperty,
                urlProperty: configuration.notionURLProperty,
                metadataProperties: configuration.notionMetadataProperties
            ).fetchEvents(yearMonth: yearMonth)
            fetchedCalendarColor = nil
        }

        let displayLocale = Locale(identifier: configuration.localeIdentifier)
        return MonthCacheEntry(
            events: fetchedEvents.map { event in
                CalendarEventRecord(
                    id: event.id,
                    day: event.day,
                    title: event.title == "無題"
                        ? ShiftHubLocalization.string("無題", locale: displayLocale)
                        : event.title,
                    detail: event.detail == "終日"
                        ? ShiftHubLocalization.string("終日", locale: displayLocale)
                        : event.detail,
                    isAllDay: event.isAllDay,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    metadata: event.metadata,
                    calendarColor: event.calendarColor,
                    isReadOnly: event.isReadOnly
                )
            },
            calendarColor: fetchedCalendarColor
        )
    }

    private var persistentCacheNamespace: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let notionMetadata = (try? encoder.encode(Self.notionMetadataIdentity(notionMetadataProperties)))?
            .base64EncodedString() ?? ""
        let configuration = [
            destination.rawValue,
            appleCalendarIdentifier,
            googleCalendarID,
            String(googleShowJapaneseHolidays),
            notionDataSourceID,
            notionDateProperty,
            notionTitleProperty,
            notionTagProperty,
            notionTagValue,
            notionNotesProperty,
            notionLocationProperty,
            notionURLProperty,
            notionMetadata,
            localeIdentifier
        ]
        let data = (try? encoder.encode(configuration)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func notionMetadataIdentity(
        _ properties: [NotionPropertyOption]
    ) -> [NotionMetadataIdentity] {
        properties
            .map { NotionMetadataIdentity(name: $0.name, type: $0.type) }
            .sorted {
                ($0.name, $0.type) < ($1.name, $1.type)
            }
    }

    private func persistentCacheFileURL(for yearMonth: YearMonth) -> URL? {
        guard let applicationSupportURL = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }

        let directoryURL = applicationSupportURL
            .appendingPathComponent("Shift Upload/CalendarEventCache", isDirectory: true)
        var namespaceURL = directoryURL.appendingPathComponent(
            persistentCacheNamespace,
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            if !didPrunePersistentCache {
                prunePersistentCache(in: directoryURL)
                didPrunePersistentCache = true
            }
            try FileManager.default.createDirectory(
                at: namespaceURL,
                withIntermediateDirectories: true
            )
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? namespaceURL.setResourceValues(resourceValues)
        } catch {
            return nil
        }

        return namespaceURL.appendingPathComponent(
            String(format: "%04d-%02d.json", yearMonth.year, yearMonth.month)
        )
    }

    private func prunePersistentCache(in directoryURL: URL) {
        guard let namespaces = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let expirationDate = Date().addingTimeInterval(-Self.persistentCacheLifetime)
        for namespaceURL in namespaces {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: namespaceURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for fileURL in files {
                let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if modifiedAt < expirationDate {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
            if (try? FileManager.default.contentsOfDirectory(atPath: namespaceURL.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: namespaceURL)
            }
        }
    }

    private func loadPersistentMonth(for yearMonth: YearMonth) -> MonthCacheEntry? {
        let namespace = String(persistentCacheNamespace.prefix(8))
        guard let url = persistentCacheFileURL(for: yearMonth) else {
            calendarFetchLogger.error(
                "persistent cache read failed month=\(yearMonth.year)-\(yearMonth.month) reason=url-unavailable namespace=\(namespace)"
            )
            return nil
        }

        guard !persistentCacheMisses.contains(yearMonth) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            persistentCacheMisses.insert(yearMonth)
            calendarFetchLogger.debug(
                "persistent cache miss month=\(yearMonth.year)-\(yearMonth.month) reason=file-not-found namespace=\(namespace)"
            )
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let readError = error as NSError
            calendarFetchLogger.error(
                "persistent cache read failed month=\(yearMonth.year)-\(yearMonth.month) reason=io domain=\(readError.domain) code=\(readError.code) namespace=\(namespace)"
            )
            return nil
        }

        return decodePersistentMonth(data, for: yearMonth, url: url)
    }

    private func decodePersistentMonth(
        _ data: Data,
        for yearMonth: YearMonth,
        url: URL
    ) -> MonthCacheEntry? {
        let namespace = String(persistentCacheNamespace.prefix(8))
        let cached: PersistedMonthCache
        do {
            cached = try JSONDecoder().decode(PersistedMonthCache.self, from: data)
        } catch {
            let decodeError = error as NSError
            calendarFetchLogger.error(
                "persistent cache read failed month=\(yearMonth.year)-\(yearMonth.month) reason=decode domain=\(decodeError.domain) code=\(decodeError.code) namespace=\(namespace)"
            )
            return nil
        }

        guard cached.version == 1 else {
            calendarFetchLogger.error(
                "persistent cache read failed month=\(yearMonth.year)-\(yearMonth.month) reason=version version=\(cached.version) namespace=\(namespace)"
            )
            return nil
        }

        let age = Date().timeIntervalSince(cached.entry.fetchedAt)
        guard age <= Self.persistentCacheLifetime else {
            try? FileManager.default.removeItem(at: url)
            calendarFetchLogger.notice(
                "persistent cache expired month=\(yearMonth.year)-\(yearMonth.month) ageSeconds=\(Int(age)) namespace=\(namespace)"
            )
            return nil
        }

        calendarFetchLogger.notice(
            "persistent cache hit month=\(yearMonth.year)-\(yearMonth.month) events=\(cached.entry.events.count) ageSeconds=\(Int(age)) namespace=\(namespace)"
        )
        return cached.entry
    }

    private func persistMonth(_ entry: MonthCacheEntry, for yearMonth: YearMonth) {
        let namespace = String(persistentCacheNamespace.prefix(8))
        guard let url = persistentCacheFileURL(for: yearMonth) else {
            calendarFetchLogger.error(
                "persistent cache write failed month=\(yearMonth.year)-\(yearMonth.month) reason=url-unavailable namespace=\(namespace)"
            )
            return
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(PersistedMonthCache(version: 1, entry: entry))
        } catch {
            let encodeError = error as NSError
            calendarFetchLogger.error(
                "persistent cache write failed month=\(yearMonth.year)-\(yearMonth.month) reason=encode domain=\(encodeError.domain) code=\(encodeError.code) namespace=\(namespace)"
            )
            return
        }

        do {
#if os(iOS)
            try data.write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
#else
            try data.write(to: url, options: .atomic)
#endif
            persistentCacheMisses.remove(yearMonth)
            calendarFetchLogger.notice(
                "persistent cache saved month=\(yearMonth.year)-\(yearMonth.month) events=\(entry.events.count) bytes=\(data.count) namespace=\(namespace)"
            )
        } catch {
            let writeError = error as NSError
            calendarFetchLogger.error(
                "persistent cache write failed month=\(yearMonth.year)-\(yearMonth.month) reason=io domain=\(writeError.domain) code=\(writeError.code) namespace=\(namespace)"
            )
        }
    }

    private func clearPersistentCacheForCurrentConfiguration() {
        guard let applicationSupportURL = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return
        }
        let directoryURL = applicationSupportURL
            .appendingPathComponent("Shift Upload/CalendarEventCache", isDirectory: true)
            .appendingPathComponent(persistentCacheNamespace, isDirectory: true)
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func isPersistentCacheStale(_ entry: MonthCacheEntry) -> Bool {
        Date().timeIntervalSince(entry.fetchedAt) > Self.persistentCacheRefreshInterval
    }

    private func enqueueBackgroundCacheRefresh(for yearMonth: YearMonth) {
        guard backgroundCacheRefreshMonths.insert(yearMonth).inserted else { return }
        backgroundCacheRefreshQueue.append(yearMonth)
        guard backgroundCacheRefreshTask == nil else { return }

        let requestedCacheGeneration = cacheGeneration
        let refreshToken = UUID()
        backgroundCacheRefreshToken = refreshToken
        backgroundCacheRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.backgroundCacheRefreshQueue.isEmpty {
                let targetMonth = self.backgroundCacheRefreshQueue.removeFirst()
                do {
                    let refreshedMonth = try await self.fetchMonth(targetMonth)
                    guard !Task.isCancelled,
                          self.cacheGeneration == requestedCacheGeneration,
                          self.backgroundCacheRefreshToken == refreshToken else {
                        if self.backgroundCacheRefreshToken == refreshToken {
                            self.backgroundCacheRefreshMonths.remove(targetMonth)
                        }
                        continue
                    }
                    self.store(refreshedMonth, for: targetMonth)
                    self.cachedMonthRevision += 1
                } catch {
                    // Keep displaying the last successfully cached data while offline.
                }
                if self.backgroundCacheRefreshToken == refreshToken {
                    self.backgroundCacheRefreshMonths.remove(targetMonth)
                }
            }
            if self.cacheGeneration == requestedCacheGeneration,
               self.backgroundCacheRefreshToken == refreshToken {
                self.backgroundCacheRefreshTask = nil
                self.backgroundCacheRefreshToken = nil
            }
        }
    }

    private func cancelBackgroundCacheRefreshes() {
        backgroundCacheRefreshTask?.cancel()
        backgroundCacheRefreshTask = nil
        backgroundCacheRefreshToken = nil
        backgroundCacheRefreshQueue.removeAll()
        backgroundCacheRefreshMonths.removeAll()
    }

    private func display(_ cachedMonth: MonthCacheEntry) {
        if calendarColor != cachedMonth.calendarColor {
            calendarColor = cachedMonth.calendarColor
        }

        var incomingEvents = cachedMonth.events
        incomingEvents.append(contentsOf: (monthCache[yearMonth.addingMonths(-1)]?.events ?? [])
            .filter(\.spansMultipleDays))

        var seenIDs = Set<String>()
        let uniqueIncomingEvents = incomingEvents.filter { seenIDs.insert($0.id).inserted }
        var previousEventsByID = Dictionary(
            events.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var addedCount = 0
        var updatedCount = 0
        var unchangedCount = 0
        let reconciledEvents = uniqueIncomingEvents.map { incomingEvent in
            guard let previousEvent = previousEventsByID.removeValue(forKey: incomingEvent.id) else {
                addedCount += 1
                return incomingEvent
            }
            guard previousEvent != incomingEvent else {
                unchangedCount += 1
                return previousEvent
            }
            updatedCount += 1
            return incomingEvent
        }.sorted(by: calendarEventComesBefore)
        let removedCount = previousEventsByID.count

        if reconciledEvents != events {
            events = reconciledEvents
        }
        let updatedLoadedDays = Set(reconciledEvents.map(\.day))
        if updatedLoadedDays != loadedDays {
            loadedDays = updatedLoadedDays
        }
        let updatedMessage = message(for: cachedMonth.events)
        if updatedMessage != message {
            message = updatedMessage
        }

        if addedCount + updatedCount + removedCount > 0 {
            calendarFetchLogger.debug(
                "month event diff month=\(self.yearMonth.year)-\(self.yearMonth.month) added=\(addedCount) updated=\(updatedCount) removed=\(removedCount) unchanged=\(unchangedCount)"
            )
        }
    }

    private func clearDisplayedMonth() {
        calendarColor = nil
        events = []
        loadedDays = []
        message = ""
    }

    private func message(for events: [CalendarEventRecord]) -> String {
        let locale = Locale(identifier: localeIdentifier)
        let registeredEventCount = events.lazy.filter { !$0.isReadOnly }.count
        return registeredEventCount == 0
            ? ShiftHubLocalization.string("この月に登録されたイベントはありません。", locale: locale)
            : ShiftHubLocalization.format(
                "%@件のイベントを取得しました。",
                locale: locale,
                arguments: String(registeredEventCount)
            )
    }

    private func registeredTimeRangeText(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeIdentifier)
        formatter.timeZone = .current
        formatter.dateFormat = localeIdentifier.hasPrefix("en") ? "h:mm a" : "H:mm"
        return "\(formatter.string(from: start))-\(formatter.string(from: end))"
    }

    private func cacheWindow(around yearMonth: YearMonth) -> Set<YearMonth> {
        Set((-Self.cacheMonthRadius...Self.cacheMonthRadius).map { yearMonth.addingMonths($0) })
    }

    private func prefetchWindow(around yearMonth: YearMonth) -> Set<YearMonth> {
        Set((-Self.prefetchMonthRadius...Self.prefetchMonthRadius).map { yearMonth.addingMonths($0) })
    }

    private func updateCacheWindow(around yearMonth: YearMonth) {
        let allowedMonths = cacheWindow(around: yearMonth)
        monthCache = monthCache.filter { allowedMonths.contains($0.key) }
        displayFallbackMonthCache = displayFallbackMonthCache.filter {
            allowedMonths.contains($0.key)
        }
        let prefetchMonths = prefetchWindow(around: yearMonth)
        queuedPrefetchMonths.formIntersection(prefetchMonths)

        let obsoleteMonths = prefetchTasks.keys.filter { !prefetchMonths.contains($0) }
        for month in obsoleteMonths {
            cancelPrefetch(for: month)
        }
    }

    private func schedulePrefetch(around yearMonth: YearMonth) {
        guard !isMonthScrollActive else { return }
        updateCacheWindow(around: yearMonth)
        let allowedMonths = prefetchWindow(around: yearMonth)
        let nearbyMonths = allowedMonths.filter {
            monthDistance($0, from: yearMonth) <= Self.prefetchMonthRadius
        }
        queuedPrefetchMonths.formUnion(
            nearbyMonths.filter {
                $0 != yearMonth && monthCache[$0] == nil && prefetchTasks[$0] == nil
            }
        )
        startQueuedPrefetches(around: yearMonth)
    }

    private func startQueuedPrefetches(around yearMonth: YearMonth) {
        while !isMonthScrollActive,
              prefetchTasks.count < Self.maximumConcurrentPrefetches,
              let targetMonth = queuedPrefetchMonths.min(by: {
                  monthDistance($0, from: yearMonth) < monthDistance($1, from: yearMonth)
              }) {
            queuedPrefetchMonths.remove(targetMonth)
            if let cachedMonth = loadPersistentMonth(for: targetMonth) {
                monthCache[targetMonth] = cachedMonth
                if monthDistance(targetMonth, from: yearMonth) <= 1 {
                    cachedMonthRevision += 1
                }
                if isPersistentCacheStale(cachedMonth) {
                    enqueueBackgroundCacheRefresh(for: targetMonth)
                }
                continue
            }

            let token = UUID()
            let requestedCacheGeneration = cacheGeneration
            prefetchTokens[targetMonth] = token

            let task = Task { @MainActor [weak self] in
                guard let self else { return }

                defer {
                    self.finishPrefetch(for: targetMonth, token: token)
                }

                do {
                    try await Task.sleep(nanoseconds: Self.prefetchThrottleNanoseconds)
                    guard !Task.isCancelled else { return }
                    let fetchedMonth = try await self.fetchMonth(targetMonth)
                    guard !Task.isCancelled,
                          self.cacheGeneration == requestedCacheGeneration,
                          self.prefetchTokens[targetMonth] == token,
                          self.cacheWindow(around: self.yearMonth).contains(targetMonth) else { return }
                    self.store(fetchedMonth, for: targetMonth)
                } catch {
                    return
                }
            }
            prefetchTasks[targetMonth] = task
        }
    }

    private func schedulePrefetchAfterDisplay(around yearMonth: YearMonth, generation: Int) {
        guard !isMonthScrollActive else { return }
        prefetchKickoffTask?.cancel()
        let requestedCacheGeneration = cacheGeneration

        // Let the visible month settle briefly before starting background prefetches.
        prefetchKickoffTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }

            guard let self,
                  !Task.isCancelled,
                  !self.isMonthScrollActive,
                  self.loadGeneration == generation,
                  self.cacheGeneration == requestedCacheGeneration,
                  self.yearMonth == yearMonth else { return }

            self.prefetchKickoffTask = nil
            self.schedulePrefetch(around: yearMonth)
        }
    }

    private func finishPrefetch(for yearMonth: YearMonth, token: UUID) {
        guard prefetchTokens[yearMonth] == token else { return }
        prefetchTasks.removeValue(forKey: yearMonth)
        prefetchTokens.removeValue(forKey: yearMonth)
        startQueuedPrefetches(around: self.yearMonth)
    }

    private func cancelPrefetch(for yearMonth: YearMonth) {
        queuedPrefetchMonths.remove(yearMonth)
        prefetchTasks[yearMonth]?.cancel()
        prefetchTasks.removeValue(forKey: yearMonth)
        prefetchTokens.removeValue(forKey: yearMonth)
    }

    private func invalidateMonthCache() {
        invalidateMonthCache(preservingNearbyDisplay: false)
    }

    private func invalidateMonthCache(preservingNearbyDisplay: Bool) {
        cacheGeneration += 1
        persistentCacheMisses.removeAll()
        queuedPersistentCachePreloads.removeAll()
        persistentCachePreloadTasks.values.forEach { $0.cancel() }
        persistentCachePreloadTasks.removeAll()
        persistentCachePreloadTokens.removeAll()
        persistentCachePreloadAnchor = nil
        if preservingNearbyDisplay {
            displayFallbackMonthCache = monthCache
            if !displayFallbackMonthCache.isEmpty {
                cachedMonthRevision += 1
            }
        } else {
            displayFallbackMonthCache.removeAll()
        }
        monthCache.removeAll()
        queuedPrefetchMonths.removeAll()
        backgroundCacheRefreshTask?.cancel()
        backgroundCacheRefreshTask = nil
        backgroundCacheRefreshToken = nil
        backgroundCacheRefreshQueue.removeAll()
        backgroundCacheRefreshMonths.removeAll()
        prefetchKickoffTask?.cancel()
        prefetchKickoffTask = nil
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks.removeAll()
        prefetchTokens.removeAll()
    }

    private func monthDistance(_ yearMonth: YearMonth, from reference: YearMonth) -> Int {
        abs((yearMonth.year - reference.year) * 12 + yearMonth.month - reference.month)
    }

    private func updateCachedDisplayedMonth() {
        store(MonthCacheEntry(events: events, calendarColor: calendarColor), for: yearMonth)
    }

    private func prepareMonthCachesAfterDeleting(eventID: String) {
        for cachedMonth in Array(displayFallbackMonthCache.keys) {
            guard let entry = displayFallbackMonthCache[cachedMonth] else { continue }
            displayFallbackMonthCache[cachedMonth] = MonthCacheEntry(
                events: entry.events.filter { $0.id != eventID },
                calendarColor: entry.calendarColor,
                fetchedAt: entry.fetchedAt
            )
        }
        for cachedMonth in Array(monthCache.keys) {
            guard let entry = monthCache[cachedMonth] else { continue }
            monthCache[cachedMonth] = MonthCacheEntry(
                events: entry.events.filter { $0.id != eventID },
                calendarColor: entry.calendarColor,
                fetchedAt: entry.fetchedAt
            )
        }
        for (cachedMonth, entry) in displayFallbackMonthCache where monthCache[cachedMonth] == nil {
            monthCache[cachedMonth] = entry
        }
    }

    private func store(_ cachedMonth: MonthCacheEntry, for yearMonth: YearMonth) {
        monthCache[yearMonth] = cachedMonth
        displayFallbackMonthCache.removeValue(forKey: yearMonth)
        persistMonth(cachedMonth, for: yearMonth)
        publishWidgetSnapshotIfRelevant(yearMonth)
        if yearMonth == self.yearMonth {
            display(cachedMonth)
        } else if monthDistance(yearMonth, from: self.yearMonth) <= 1
            || persistentCachePreloadAnchor.map({ monthDistance(yearMonth, from: $0) <= 1 }) == true {
            cachedMonthRevision += 1
        }
    }

    private func publishWidgetSnapshotIfRelevant(_ storedMonth: YearMonth) {
        let currentMonth = YearMonth.current
        let nextMonth = currentMonth.addingMonths(1)
        guard storedMonth == currentMonth || storedMonth == nextMonth,
              monthCache[currentMonth] != nil || displayFallbackMonthCache[currentMonth] != nil else {
            return
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let today = calendar.dateInterval(of: .day, for: .now)?.start,
              let endOfNextMonth = calendar.date(
                from: DateComponents(year: nextMonth.year, month: nextMonth.month, day: 1)
              ) else { return }

        let sourceEvents = [(currentMonth, cachedEvents(for: currentMonth)),
                            (nextMonth, cachedEvents(for: nextMonth))]
            .flatMap { item in item.1.map { (item.0, $0) } }
        var seenEventIDs = Set<String>()
        let events = sourceEvents
            .filter { seenEventIDs.insert($0.1.id).inserted }
            .compactMap { item -> CalHubWidgetEvent? in
                let (month, event) = item
                let eventDate = event.startDate ?? calendar.date(from: DateComponents(
                    year: month.year,
                    month: month.month,
                    day: event.day
                ))
                guard let eventDate,
                      (event.endDate ?? eventDate) >= today,
                      eventDate < endOfNextMonth else { return nil }
                return CalHubWidgetEvent(
                    id: event.id,
                    title: event.title,
                    detail: event.detail,
                    date: calendar.startOfDay(for: eventDate),
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    isRestEvent: event.isRestEvent,
                    red: event.calendarColor?.red,
                    green: event.calendarColor?.green,
                    blue: event.calendarColor?.blue
                )
            }
            .enumerated()
            .sorted { lhs, rhs in
                let lhsStart = lhs.element.startDate ?? lhs.element.date
                let rhsStart = rhs.element.startDate ?? rhs.element.date
                if lhsStart != rhsStart { return lhsStart < rhsStart }
                let titleOrder = lhs.element.title.localizedStandardCompare(rhs.element.title)
                return titleOrder == .orderedSame ? lhs.offset < rhs.offset : titleOrder == .orderedAscending
            }
            .map(\.element)

        let snapshot = CalHubWidgetSnapshot(
            configurationKey: persistentCacheNamespace,
            localeIdentifier: localeIdentifier,
            updatedAt: .now,
            events: events,
            sourceKind: destination.rawValue,
            appleCalendarIdentifier: destination == .apple ? appleCalendarIdentifier : nil,
            remoteConfiguration: CalHubWidgetRemoteConfiguration(
                googleCalendarID: googleCalendarID,
                googleShowJapaneseHolidays: googleShowJapaneseHolidays,
                notionDataSourceID: notionDataSourceID,
                notionDateProperty: notionDateProperty,
                notionTitleProperty: notionTitleProperty,
                notionTagProperty: notionTagProperty,
                notionTagValue: notionTagValue
            )
        )
        CalHubWidgetSharedData.save(snapshot)
#if os(iOS)
        CalHubWatchSyncManager.shared.publish(snapshot)
#endif
    }

#if os(iOS)
    private func prepareWatchSyncSnapshot() {
        let currentMonth = YearMonth.current
        let nextMonth = currentMonth.addingMonths(1)

        for month in [currentMonth, nextMonth] where monthCache[month] == nil {
            if let cachedMonth = loadPersistentMonth(for: month) {
                monthCache[month] = cachedMonth
                if isPersistentCacheStale(cachedMonth) {
                    enqueueBackgroundCacheRefresh(for: month)
                }
            } else {
                enqueueBackgroundCacheRefresh(for: month)
            }
        }

        publishWidgetSnapshotIfRelevant(currentMonth)
    }
#endif

    private func removeCachedMonth(for yearMonth: YearMonth) {
        monthCache.removeValue(forKey: yearMonth)
        displayFallbackMonthCache.removeValue(forKey: yearMonth)
        if let url = persistentCacheFileURL(for: yearMonth) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func requestDelete(_ event: CalendarEventRecord) {
        guard !event.isReadOnly else { return }
        pendingDeletion = event
        isDeleteConfirmationPresented = true
    }

    func deleteImmediately(_ event: CalendarEventRecord, completion: (() -> Void)? = nil) {
        guard !event.isReadOnly else { return }
        pendingDeletion = event
        deletePending(completion: completion)
    }

    func deletePending(completion: (() -> Void)? = nil) {
        guard let target = pendingDeletion, !target.isReadOnly, !isDeleting else { return }

        isDeleting = true
        message = ""

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await deleteRemoteEvent(target)

                shouldAnimateEventBandReveal = false
                events.removeAll { $0.id == target.id }
                loadedDays = Set(events.map(\.day))
                prepareMonthCachesAfterDeleting(eventID: target.id)
                clearPersistentCacheForCurrentConfiguration()
                invalidateMonthCache(preservingNearbyDisplay: true)
                load(forceRefresh: true)
                message = ShiftHubLocalization.string(
                    "イベントを削除しました。",
                    locale: Locale(identifier: localeIdentifier)
                )
                pendingDeletion = nil
                completion?()
            } catch {
                message = ShiftHubLocalization.format(
                    "イベントの削除に失敗しました: %@",
                    locale: Locale(identifier: localeIdentifier),
                    arguments: error.localizedDescription
                )
            }

            isDeleting = false
        }
    }

    func deleteEvents(
        _ targets: [CalendarEventRecord],
        completion: (([CalendarEventRecord]) -> Void)? = nil
    ) {
        guard !isDeleting else { return }
        var seenIDs = Set<String>()
        let deletableTargets = targets.filter {
            !$0.isReadOnly && seenIDs.insert($0.id).inserted
        }
        guard !deletableTargets.isEmpty else {
            completion?(targets)
            return
        }

        isDeleting = true
        message = ""

        Task { @MainActor [weak self] in
            guard let self else { return }

            var deletedIDs = Set<String>()
            var failedEvents: [CalendarEventRecord] = []
            var firstError: Error?

            for event in deletableTargets {
                do {
                    try await deleteRemoteEvent(event)
                    deletedIDs.insert(event.id)
                } catch {
                    failedEvents.append(event)
                    firstError = firstError ?? error
                }
            }

            if !deletedIDs.isEmpty {
                shouldAnimateEventBandReveal = false
                events.removeAll { deletedIDs.contains($0.id) }
                loadedDays = Set(events.map(\.day))
                for eventID in deletedIDs {
                    prepareMonthCachesAfterDeleting(eventID: eventID)
                }
                clearPersistentCacheForCurrentConfiguration()
                invalidateMonthCache(preservingNearbyDisplay: true)
                load(forceRefresh: true)
            }

            if failedEvents.isEmpty {
                message = ShiftHubLocalization.format(
                    "%@件のイベントを削除しました。",
                    locale: Locale(identifier: localeIdentifier),
                    arguments: "\(deletedIDs.count)"
                )
            } else {
                message = ShiftHubLocalization.format(
                    "一部のイベントを削除できませんでした: %@",
                    locale: Locale(identifier: localeIdentifier),
                    arguments: firstError?.localizedDescription ?? "不明なエラー"
                )
            }

            pendingDeletion = nil
            isDeleting = false
            completion?(failedEvents)
        }
    }

    private func deleteRemoteEvent(_ target: CalendarEventRecord) async throws {
        switch destination {
        case .apple:
            try AppleCalendarEventClient(
                calendarIdentifier: appleCalendarIdentifier
            ).deleteEvent(identifier: target.id)
        case .google:
            guard GoogleTokenStore.load() != nil else {
                throw CalendarEventManagementError.invalidSettings("Googleの認証設定を確認してください。")
            }

            try await GoogleCalendarAPIClient(
                clientID: GoogleOAuthConfiguration.clientID
            ).deleteEvent(calendarID: googleCalendarID, eventID: target.id)
        case .notion:
            guard let token = KeychainStore.string(for: "notion-access-token") else {
                throw CalendarEventManagementError.invalidSettings("Notionのアクセストークンを設定してください。")
            }

            try await NotionCalendarEventClient(
                token: token,
                dataSourceID: notionDataSourceID,
                dateProperty: notionDateProperty,
                titleProperty: notionTitleProperty,
                tagProperty: notionTagProperty,
                tagValue: notionTagValue
            ).deletePage(identifier: target.id)
        }
    }
}
