import Combine
import Foundation

final class CalendarEventManagerModel: ObservableObject {
    private struct MonthCacheEntry {
        let events: [CalendarEventRecord]
        let calendarColor: CalendarDisplayColor?
    }

    @Published private(set) var events: [CalendarEventRecord] = []
    @Published private(set) var loadedDays: Set<Int> = []
    @Published private(set) var calendarColor: CalendarDisplayColor? = nil
    @Published private(set) var isLoading = false
    @Published private(set) var isDeleting = false
    @Published private(set) var isUpdating = false
    @Published var isDeleteConfirmationPresented = false
    @Published private(set) var pendingDeletion: CalendarEventRecord?
    @Published private(set) var message = ""
    @Published private(set) var shouldAnimateEventBandReveal = false
    @Published private(set) var cacheRevision = 0

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
    private var prefetchTasks: [YearMonth: Task<Void, Never>] = [:]
    private var prefetchTokens: [YearMonth: UUID] = [:]
    private var queuedPrefetchMonths = Set<YearMonth>()

    // Retain a bounded cache around the visible month; only adjacent months are prefetched.
    private static let cacheMonthRadius = 12
    private static let maximumConcurrentPrefetches = 2
    private static let prefetchThrottleNanoseconds: UInt64 = 100_000_000

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
    }

    func updateYearMonth(_ yearMonth: YearMonth) {
        self.yearMonth = yearMonth
        if let cachedMonth = monthCache[yearMonth] {
            shouldAnimateEventBandReveal = false
            display(cachedMonth)
        } else {
            shouldAnimateEventBandReveal = false
            let carryOverEvents = Array(
                Dictionary(
                    (monthCache[yearMonth.addingMonths(-1)]?.events ?? [])
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

    func setLocaleIdentifier(_ identifier: String) {
        guard localeIdentifier != identifier else { return }
        localeIdentifier = identifier
        invalidateMonthCache()
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
        let hasChanged = self.destination != destination
            || self.appleCalendarIdentifier != appleCalendarIdentifier
            || self.googleCalendarID != googleCalendarID
            || self.googleShowJapaneseHolidays != googleShowJapaneseHolidays
            || self.notionDataSourceID != notionDataSourceID
            || self.notionDateProperty != notionDateProperty
            || self.notionTitleProperty != notionTitleProperty
            || self.notionTagProperty != notionTagProperty
            || self.notionTagValue != notionTagValue
            || self.notionNotesProperty != notionNotesProperty
            || self.notionLocationProperty != notionLocationProperty
            || self.notionURLProperty != notionURLProperty
            || self.notionMetadataProperties != notionMetadataProperties

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

        if hasChanged {
            invalidateMonthCache()
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
        var cachedEvents = monthCache[yearMonth]?.events ?? []
        cachedEvents.append(contentsOf: (monthCache[yearMonth.addingMonths(-1)]?.events ?? [])
            .filter(\.spansMultipleDays))

        return Array(
            Dictionary(
                cachedEvents.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            .values
        )
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

    func events(for day: Int) -> [CalendarEventRecord] {
        events
            .filter { $0.starts(on: day, in: yearMonth) }
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
                    self.invalidateMonthCache()
                    self.load(forceRefresh: true)
                } else {
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

    func dayHeader(for day: Int, locale: Locale) -> String {
        let weekdays = locale.identifier.hasPrefix("en")
            ? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            : ["日", "月", "火", "水", "木", "金", "土"]
        let weekday = yearMonth.weekdayIndex(for: day)
            .map { weekdays[$0 - 1] } ?? ""
        return locale.identifier.hasPrefix("en")
            ? "\(day) (\(weekday))"
            : "\(day)日（\(weekday)）"
    }

    func load(forceRefresh: Bool = false) {
        guard forceRefresh || loadTask == nil else { return }

        loadGeneration += 1
        let generation = loadGeneration
        let targetMonth = yearMonth
        let hadDisplayedMonth = !events.isEmpty || !loadedDays.isEmpty
        let requestedCacheGeneration = cacheGeneration
        loadTask?.cancel()
        prefetchKickoffTask?.cancel()
        prefetchKickoffTask = nil

        updateCacheWindow(around: targetMonth)
        if forceRefresh {
            removeCachedMonth(for: targetMonth)
            cancelPrefetch(for: targetMonth)
        }

        if let cachedMonth = monthCache[targetMonth] {
            shouldAnimateEventBandReveal = false
            display(cachedMonth)
            isLoading = false
            loadTask = nil
            schedulePrefetchAfterDisplay(around: targetMonth, generation: generation)
            return
        }

        cancelPrefetch(for: targetMonth)
        if !forceRefresh || !hadDisplayedMonth {
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
                let fetchedMonth = try await self.fetchMonth(targetMonth)
                guard !Task.isCancelled,
                      self.loadGeneration == generation,
                      self.cacheGeneration == requestedCacheGeneration,
                      self.yearMonth == targetMonth else { return }

                self.shouldAnimateEventBandReveal = true
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

    private func fetchMonth(_ yearMonth: YearMonth) async throws -> MonthCacheEntry {
        let fetchedEvents: [CalendarEventRecord]
        let fetchedCalendarColor: CalendarDisplayColor?

        switch destination {
        case .apple:
            let calendarIdentifier = appleCalendarIdentifier
            let result = try await Task.detached(priority: .utility) {
                let client = AppleCalendarEventClient(calendarIdentifier: calendarIdentifier)
                return (
                    calendarColor: try client.fetchCalendarColor(),
                    events: try client.fetch(yearMonth: yearMonth)
                )
            }.value
            fetchedCalendarColor = result.calendarColor
            fetchedEvents = result.events
        case .google:
            guard GoogleTokenStore.load() != nil else {
                throw CalendarEventManagementError.invalidSettings("Googleの認証設定を確認してください。")
            }

            let client = GoogleCalendarAPIClient(clientID: GoogleOAuthConfiguration.clientID)
            var googleEvents = try await client.fetchEvents(
                yearMonth: yearMonth,
                calendarID: googleCalendarID
            )
            if googleShowJapaneseHolidays {
                googleEvents.append(contentsOf: try await client.fetchJapaneseHolidayEvents(yearMonth: yearMonth))
            }
            fetchedEvents = googleEvents
            if let eventColor = fetchedEvents.compactMap({ $0.calendarColor }).first {
                fetchedCalendarColor = eventColor
            } else {
                fetchedCalendarColor = try? await client.fetchCalendarColor(calendarID: googleCalendarID)
            }
        case .notion:
            guard let token = KeychainStore.string(for: "notion-access-token"),
                  !token.isEmpty,
                  !notionDataSourceID.isEmpty else {
                throw CalendarEventManagementError.invalidSettings("NotionのアクセストークンとデータベースIDを設定してください。")
            }

            fetchedEvents = try await NotionCalendarEventClient(
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
            ).fetchEvents(yearMonth: yearMonth)
            fetchedCalendarColor = nil
        }

        let displayLocale = Locale(identifier: localeIdentifier)
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

    private func display(_ cachedMonth: MonthCacheEntry) {
        calendarColor = cachedMonth.calendarColor
        var displayedEvents = cachedMonth.events
        displayedEvents.append(contentsOf: (monthCache[yearMonth.addingMonths(-1)]?.events ?? [])
            .filter(\.spansMultipleDays))
        displayedEvents = Array(
            Dictionary(
                displayedEvents.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            .values
        )
        events = displayedEvents
        loadedDays = Set(displayedEvents.map(\.day))
        message = message(for: cachedMonth.events)
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

    private func updateCacheWindow(around yearMonth: YearMonth) {
        let allowedMonths = cacheWindow(around: yearMonth)
        monthCache = monthCache.filter { allowedMonths.contains($0.key) }
        queuedPrefetchMonths.formIntersection(allowedMonths)

        let obsoleteMonths = prefetchTasks.keys.filter { !allowedMonths.contains($0) }
        for month in obsoleteMonths {
            cancelPrefetch(for: month)
        }
    }

    private func schedulePrefetch(around yearMonth: YearMonth) {
        updateCacheWindow(around: yearMonth)
        let allowedMonths = cacheWindow(around: yearMonth)
        let nearbyMonths = allowedMonths.filter {
            monthDistance($0, from: yearMonth) <= 1
        }
        queuedPrefetchMonths.formUnion(
            nearbyMonths.filter {
                $0 != yearMonth && monthCache[$0] == nil && prefetchTasks[$0] == nil
            }
        )
        startQueuedPrefetches(around: yearMonth)
    }

    private func startQueuedPrefetches(around yearMonth: YearMonth) {
        while prefetchTasks.count < Self.maximumConcurrentPrefetches,
              let targetMonth = queuedPrefetchMonths.min(by: {
                  monthDistance($0, from: yearMonth) < monthDistance($1, from: yearMonth)
              }) {
            queuedPrefetchMonths.remove(targetMonth)
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
        prefetchKickoffTask?.cancel()
        let requestedCacheGeneration = cacheGeneration

        // Let the visible month settle before starting the adjacent-month prefetches.
        prefetchKickoffTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }

            guard let self,
                  !Task.isCancelled,
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
        cacheGeneration += 1
        monthCache.removeAll()
        queuedPrefetchMonths.removeAll()
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

    private func store(_ cachedMonth: MonthCacheEntry, for yearMonth: YearMonth) {
        monthCache[yearMonth] = cachedMonth
        cacheRevision &+= 1
        if yearMonth == self.yearMonth {
            display(cachedMonth)
        }
    }

    private func removeCachedMonth(for yearMonth: YearMonth) {
        guard monthCache.removeValue(forKey: yearMonth) != nil else { return }
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

                shouldAnimateEventBandReveal = false
                events.removeAll { $0.id == target.id }
                updateCachedDisplayedMonth()
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
}
