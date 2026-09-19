import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#endif

// Calendar grid, destination controls, and event-band interactions.
private struct CalendarYearMonthPopup: View {
    @Binding var year: Int
    @Binding var month: Int
    let yearOptions: [Int]
    let isEnglish: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CalendarNumberOptionList(
                title: isEnglish ? "Year" : "年",
                options: yearOptions,
                selection: $year
            )

            CalendarNumberOptionList(
                title: isEnglish ? "Month" : "月",
                options: Array(1...12),
                selection: $month
            )
        }
        .padding(12)
        .frame(width: 220, height: 240)
        .font(.body)
        .foregroundStyle(.primary)
        .background(
            colorScheme == .dark ? Color.black : Color.white,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        }
        .shadow(radius: 10)
    }
}

struct CalendarOverlayAnchors {
    var monthTitle: Anchor<CGRect>?
    var destination: Anchor<CGRect>?

    init(monthTitle: Anchor<CGRect>? = nil, destination: Anchor<CGRect>? = nil) {
        self.monthTitle = monthTitle
        self.destination = destination
    }
}

struct CalendarOverlayAnchorKey: PreferenceKey {
    static var defaultValue = CalendarOverlayAnchors()

    static func reduce(value: inout CalendarOverlayAnchors, nextValue: () -> CalendarOverlayAnchors) {
        let next = nextValue()
        value.monthTitle = value.monthTitle ?? next.monthTitle
        value.destination = value.destination ?? next.destination
    }
}

private struct CalendarNumberOptionList: View {
    let title: String
    let options: [Int]
    @Binding var selection: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(options, id: \.self) { option in
                            Button {
                                selection = option
                            } label: {
                                HStack(spacing: 10) {
                                    Text(String(option))
                                        .font(.body)
                                        .lineLimit(1)

                                    if selection == option {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.weight(.semibold))
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 4)
                            .id(option)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CalendarDestinationPopup: View {
    let selection: CalendarDestination?
    @Binding var isPresented: Bool
    let onSelect: (CalendarDestination) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ForEach(CalendarDestination.allCases) { destination in
                Button {
                    onSelect(destination)
                    isPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                        Text(destination.title)
                        Spacer(minLength: 12)
                        if destination == selection {
                            Image(systemName: "checkmark")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .frame(height: 36)
            }
        }
        .frame(width: 180, height: 116)
        .foregroundStyle(.primary)
        .background(
            colorScheme == .dark ? Color.black : Color.white,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        }
        .shadow(radius: 10)
    }
}

struct CalendarDestinationSelector: View {
    let selection: CalendarDestination?
    let showsCalendarIcon: Bool
    @Binding var isPresented: Bool
    let rendersOverlay: Bool
    let buttonHeight: CGFloat
    let onOpen: () -> Void
    let onSelect: (CalendarDestination) -> Void

    init(
        selection: CalendarDestination?,
        showsCalendarIcon: Bool,
        isPresented: Binding<Bool>,
        rendersOverlay: Bool,
        buttonHeight: CGFloat = 40,
        onOpen: @escaping () -> Void,
        onSelect: @escaping (CalendarDestination) -> Void
    ) {
        self.selection = selection
        self.showsCalendarIcon = showsCalendarIcon
        self._isPresented = isPresented
        self.rendersOverlay = rendersOverlay
        self.buttonHeight = buttonHeight
        self.onOpen = onOpen
        self.onSelect = onSelect
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            onOpen()
            if isPresented {
                isPresented = false
            } else {
                DispatchQueue.main.async {
                    isPresented = true
                }
            }
        } label: {
            HStack(spacing: 5) {
                if showsCalendarIcon {
                    Image(systemName: "calendar")
                }

                Text(selection?.title ?? "カレンダー")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
            }
        }
        .buttonStyle(ToolbarSelectorButtonStyleD(buttonHeight: buttonHeight))
        .overlay(alignment: .topTrailing) {
            if rendersOverlay && isPresented {
                CalendarDestinationPopup(
                    selection: selection,
                    isPresented: $isPresented,
                    onSelect: onSelect
                )
                .offset(y: 50)
                .zIndex(100)
            }
        }
        .zIndex(rendersOverlay && isPresented ? 100 : 0)
        .accessibilityLabel("カレンダーを変更")
    }
}


struct CalendarEventManagerView: View {
    let destination: CalendarDestination
    let appleCalendarIdentifier: String
    let googleCalendarID: String
    let notionDataSourceID: String
    let notionDateProperty: String
    let notionTitleProperty: String
    let notionTagProperty: String
    let notionTagValue: String
    let appleCalendarName: String
    let googleCalendarName: String
    let notionDatabaseName: String
    let definitions: [ShiftDefinition]
    let onRegisterShift: (YearMonth, Int, String, RegistrationCompletion) -> Void
    let onRegisterDateTimeEvent: (String, Date, Date, Bool, DateTimeEventRegistrationCompletion) -> Void
    let onRegisterShifts: ([CalendarDaySelection], String, RegistrationCompletion) -> Void
    let onCalendarDestinationChange: (CalendarDestination) -> Void
    let onCalendarColorChange: (CalendarDisplayColor?) -> Void
    let onOpenShiftUpload: () -> Void
    let onOpenPDFList: () -> Void
    let onOpenSettings: () -> Void
    let isSynchronizing: Bool
    let isCloudSyncEnabled: Bool
    let onSynchronize: () -> Void

    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.japanese.rawValue
    @AppStorage("googleShowJapaneseHolidays") private var googleShowJapaneseHolidays = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: CalendarEventManagerModel
    @State private var selectedYear: Int
    @State private var selectedMonth: Int
    @State private var isShiftSelectionPresented = false
    @State private var isDateTimeEventRegistrationPresented = false
    @State private var dateTimeEventRegistrationStartDate = Date()
    @State private var pendingShiftRegistration: PendingShiftRegistration?
    @State private var shiftTitleAfterDelete: String?
    @State private var selectedDayForActions: Int?
    @State private var pendingDayActionsSelection: CalendarDaySelection?
    @State private var isDaySelectionMode = false
    @State private var selectedCalendarDays: Set<CalendarDaySelection> = []
    @State private var selectedEventForActions: CalendarEventRecord?
    @State private var selectedBandEventForActions: CalendarBandEventSelection?
    @State private var pendingBandEventForActions: CalendarBandEventSelection?
#if os(iOS)
    @State private var pendingInlineDeletion: CalendarEventRecord?
#endif
    @State private var isYearMonthPickerPresented = false
    @State private var isCalendarDestinationMenuPresented = false
    @State private var monthPageID: Int?
    @State private var pendingMonthPageID: Int?
    @State private var isMonthScrollActive = false
    @State private var eventBandRevealThroughDay = Int.max
    @State private var eventBandRevealGeneration = 0
    @State private var didLoadInitialMonth = false
    @State private var didEnterBackground = false
#if os(macOS)
    @State private var isCalendarLiveResizing = false
    @State private var isDayActionsPopoverPresented = false
#endif
    private let monthPageAnchor: YearMonth
    private static let monthPageRadius = 120

    init(
        destination: CalendarDestination,
        initialYearMonth: YearMonth?,
        appleCalendarIdentifier: String,
        googleCalendarID: String,
        appleCalendarName: String,
        googleCalendarName: String,
        notionDataSourceID: String,
        notionDatabaseName: String,
        notionDateProperty: String,
        notionTitleProperty: String,
        notionTagProperty: String,
        notionTagValue: String,
        definitions: [ShiftDefinition],
        onRegisterShift: @escaping (YearMonth, Int, String, RegistrationCompletion) -> Void,
        onRegisterDateTimeEvent: @escaping (String, Date, Date, Bool, DateTimeEventRegistrationCompletion) -> Void,
        onRegisterShifts: @escaping ([CalendarDaySelection], String, RegistrationCompletion) -> Void,
        onCalendarDestinationChange: @escaping (CalendarDestination) -> Void,
        onCalendarColorChange: @escaping (CalendarDisplayColor?) -> Void,
        onOpenShiftUpload: @escaping () -> Void,
        onOpenPDFList: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        isSynchronizing: Bool,
        isCloudSyncEnabled: Bool,
        onSynchronize: @escaping () -> Void
    ) {
        let initial = initialYearMonth ?? .current
        self.destination = destination
        self.appleCalendarIdentifier = appleCalendarIdentifier
        self.googleCalendarID = googleCalendarID
        self.notionDataSourceID = notionDataSourceID
        self.notionDateProperty = notionDateProperty
        self.notionTitleProperty = notionTitleProperty
        self.notionTagProperty = notionTagProperty
        self.notionTagValue = notionTagValue
        self.appleCalendarName = appleCalendarName
        self.googleCalendarName = googleCalendarName
        self.notionDatabaseName = notionDatabaseName
        self.definitions = definitions
        self.onRegisterShift = onRegisterShift
        self.onRegisterDateTimeEvent = onRegisterDateTimeEvent
        self.onRegisterShifts = onRegisterShifts
        self.onCalendarDestinationChange = onCalendarDestinationChange
        self.onCalendarColorChange = onCalendarColorChange
        self.onOpenShiftUpload = onOpenShiftUpload
        self.onOpenPDFList = onOpenPDFList
        self.onOpenSettings = onOpenSettings
        self.isSynchronizing = isSynchronizing
        self.isCloudSyncEnabled = isCloudSyncEnabled
        self.onSynchronize = onSynchronize
        self.monthPageAnchor = initial
        _selectedYear = State(initialValue: initial.year)
        _selectedMonth = State(initialValue: initial.month)
        _monthPageID = State(initialValue: Self.monthPageRadius)
        _pendingMonthPageID = State(initialValue: nil)
        _isMonthScrollActive = State(initialValue: false)
        let showJapaneseHolidays = UserDefaults.standard.bool(forKey: "googleShowJapaneseHolidays")
        _model = StateObject(wrappedValue: CalendarEventManagerModel(
            destination: destination,
            yearMonth: initial,
            appleCalendarIdentifier: appleCalendarIdentifier,
            googleCalendarID: googleCalendarID,
            googleShowJapaneseHolidays: showJapaneseHolidays,
            notionDataSourceID: notionDataSourceID,
            notionDateProperty: notionDateProperty,
            notionTitleProperty: notionTitleProperty,
            notionTagProperty: notionTagProperty,
            notionTagValue: notionTagValue
        ))
    }

    private var selectedYearMonth: YearMonth {
        YearMonth(year: selectedYear, month: selectedMonth)
    }

    private func localized(_ key: String) -> String {
        ShiftHubLocalization.string(key, locale: locale)
    }

    private var calendarEventManagerConfigurationKey: String {
        [
            destination.rawValue,
            appleCalendarIdentifier,
            googleCalendarID,
            String(googleShowJapaneseHolidays),
            notionDataSourceID,
            notionDateProperty,
            notionTitleProperty,
            notionTagProperty,
            notionTagValue
        ].joined(separator: "|")
    }

    private var managerAccentColor: Color {
        model.calendarColor?.color ?? Color.accentColor
    }

    private var yearOptions: [Int] {
        let currentYear = YearMonth.current.year
        let range = Array((currentYear - 10)...(currentYear + 10))
        return Array(Set(range + [selectedYear])).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
#if os(iOS)
            iOSHomeHeader

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    eventManagerTitleView
                        .font(.title2.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)

                    Spacer(minLength: 4)

                    calendarDestinationMenu
                }
                .zIndex(1)

                HStack(spacing: 8) {
                    monthTitleSelector
                        .font(.title3.bold())

                    Spacer(minLength: 4)

                    monthNavigationControls

                    Button {
                        model.load(forceRefresh: true)
                    } label: {
                        if model.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.footnote)
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(.leading, 8)
                    .buttonStyle(.plain)
                    .tint(.primary)
                    .accessibilityLabel("取得")
                    .disabled(model.isLoading || model.isDeleting)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .zIndex(1)
#else
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 12) {
                    eventManagerTitleView
                        .font(.title.bold())

                    Spacer(minLength: 8)

                    calendarDestinationMenu

                    Button {
                        model.load(forceRefresh: true)
                    } label: {
                        if model.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.plain)
                    .tint(.primary)
                    .help("取得")
                    .disabled(model.isLoading || model.isDeleting)
                }

                HStack(alignment: .center, spacing: 12) {
                    monthTitleSelector
                        .font(.system(size: 26, weight: .bold, design: .rounded))

                    if model.isLoading {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)

                            Text("イベントを取得中です...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    monthNavigationControls

                }
                .padding(.vertical)
            }
            .padding(24)
            .zIndex(isYearMonthPickerPresented ? 100 : 0)
#endif

            if isDaySelectionMode {
                daySelectionToolbar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            VStack(spacing: 0) {
                eventWeekdayHeader(columns: eventCalendarColumns)
#if os(iOS)
                    .padding(.horizontal, 12)
#else
                    .padding(.horizontal, 24)
#endif

                eventCalendarView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

#if os(iOS)
            ZStack(alignment: .topLeading) {
                if !model.message.isEmpty && !model.isLoading {
                    Text(LocalizedStringKey(model.message))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(minHeight: 20, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
#else
            if !model.message.isEmpty && !model.isLoading {
                Text(LocalizedStringKey(model.message))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
#endif
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
#else
        .frame(
            minWidth: 720,
            idealWidth: 720,
            maxWidth: .infinity,
            minHeight: 600,
            idealHeight: 600,
            maxHeight: .infinity,
            alignment: .topLeading
        )
#endif
        .contentShape(Rectangle())
        .onTapGesture {
            if isCalendarDestinationMenuPresented {
                isCalendarDestinationMenuPresented = false
            }
            if isYearMonthPickerPresented {
                isYearMonthPickerPresented = false
            }
        }
        .overlayPreferenceValue(CalendarOverlayAnchorKey.self) { anchors in
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    if isYearMonthPickerPresented || isCalendarDestinationMenuPresented {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                isYearMonthPickerPresented = false
                                isCalendarDestinationMenuPresented = false
                            }
                    }

                    if isYearMonthPickerPresented, let anchor = anchors.monthTitle {
                        let titleFrame = geometry[anchor]
                        CalendarYearMonthPopup(
                            year: $selectedYear,
                            month: $selectedMonth,
                            yearOptions: yearOptions,
                            isEnglish: locale.identifier.hasPrefix("en")
                        )
                        .position(
                            x: titleFrame.minX + 110,
                            y: titleFrame.minY + 42 + 120
                        )
                        .zIndex(1)
                    }
                    if isCalendarDestinationMenuPresented, let destinationAnchor = anchors.destination {
                        let destinationFrame = geometry[destinationAnchor]

                        CalendarDestinationPopup(
                            selection: destination,
                            isPresented: $isCalendarDestinationMenuPresented,
                            onSelect: onCalendarDestinationChange
                        )
                        .position(
                            x: destinationFrame.maxX - 90,
                            y: destinationFrame.minY + 50 + 58
                        )
                        .zIndex(1)
                    }
                }
            }
            .allowsHitTesting(isYearMonthPickerPresented || isCalendarDestinationMenuPresented)
        }
#if os(macOS)
        .toolbar {
            if isCloudSyncEnabled {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onSynchronize()
                    } label: {
                        if isSynchronizing {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 36, height: 36)
                        } else {
                            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.icloud")
                                .font(.body.weight(.semibold))
                                .frame(width: 36, height: 36)
                                .contentShape(Circle())
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSynchronizing)
                    .help("今すぐ同期")
                }
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    leaveDaySelectionModeAndOpen(onOpenPDFList)
                } label: {
                    Image(systemName: "folder")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(ShiftHubLocalization.string("PDF一覧", locale: locale))
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleDaySelectionMode()
                } label: {
                    Image(
                        systemName: isDaySelectionMode
                            ? "xmark"
                            : "circle.grid.2x2.topleft.checkmark.filled"
                    )
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(isDaySelectionMode ? "複数選択を解除" : "複数選択")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    leaveDaySelectionModeAndOpen(onOpenShiftUpload)
                } label: {
                    Image(systemName: "doc.viewfinder")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("勤務表")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    leaveDaySelectionModeAndOpen(onOpenSettings)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("設定")
            }
        }
#endif
        .onAppear {
            onCalendarColorChange(model.calendarColor)
            guard !didLoadInitialMonth else { return }
            didLoadInitialMonth = true
            model.setLocaleIdentifier(locale.identifier)
            model.load()
        }
        .onChange(of: model.calendarColor) { _, color in
            onCalendarColorChange(color)
        }
        .onChange(of: model.events) { _, events in
            guard !events.isEmpty else {
                showAllEventBandsImmediately()
                return
            }

            if model.shouldAnimateEventBandReveal {
                beginEventBandReveal()
            } else {
                showAllEventBandsImmediately()
            }
        }
#if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                didEnterBackground = true
            case .active where didEnterBackground:
                didEnterBackground = false
                model.refreshAllCachedMonths()
            default:
                break
            }
        }
#endif
        .onChange(of: isSynchronizing) { wasSynchronizing, isSynchronizing in
            guard wasSynchronizing, !isSynchronizing, isCloudSyncEnabled else { return }
            model.refreshAllCachedMonths()
        }
        .onChange(of: calendarEventManagerConfigurationKey) {
            model.updateConfiguration(
                destination: destination,
                appleCalendarIdentifier: appleCalendarIdentifier,
                googleCalendarID: googleCalendarID,
                googleShowJapaneseHolidays: googleShowJapaneseHolidays,
                notionDataSourceID: notionDataSourceID,
                notionDateProperty: notionDateProperty,
                notionTitleProperty: notionTitleProperty,
                notionTagProperty: notionTagProperty,
                notionTagValue: notionTagValue
            )
        }
        .onChange(of: model.yearMonth) {
            selectedYear = model.yearMonth.year
            selectedMonth = model.yearMonth.month

            if let pendingSelection = pendingDayActionsSelection,
               pendingSelection.yearMonth == model.yearMonth {
                pendingDayActionsSelection = nil
                Task { @MainActor in
                    await Task.yield()
                    selectedDayForActions = pendingSelection.day
#if os(macOS)
                    isDayActionsPopoverPresented = true
#endif
                }
            }

            if let pendingBandSelection = pendingBandEventForActions,
               pendingBandSelection.yearMonth == model.yearMonth {
                pendingBandEventForActions = nil
                Task { @MainActor in
                    await Task.yield()
                    selectedBandEventForActions = pendingBandSelection
                }
            }

            if model.shouldAnimateEventBandReveal {
                beginEventBandReveal()
            } else {
                showAllEventBandsImmediately()
            }
        }
        .onChange(of: selectedYear) {
            reloadSelectedMonth()
        }
        .onChange(of: selectedMonth) {
            reloadSelectedMonth()
        }
        .onChange(of: locale.identifier) {
            model.setLocaleIdentifier(locale.identifier)
            model.load()
        }
        .onChange(of: monthPageID) { _, pageID in
            guard let pageID,
                  (0...Self.monthPageRadius * 2).contains(pageID) else { return }
#if os(macOS)
            if isCalendarLiveResizing {
                return
            }
#endif

            pendingMonthPageID = pageID
            if !isMonthScrollActive {
                commitPendingMonthPage()
            }
        }
#if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)) { _ in
            isCalendarLiveResizing = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { _ in
            isCalendarLiveResizing = false
            if let currentPageID = pageID(for: model.yearMonth) {
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    monthPageID = currentPageID
                }
            }
        }
#endif
        .alert(
            shiftTitleAfterDelete == nil
                ? localized("イベントを削除しますか？")
                : localized("削除してイベントを登録しますか？"),
            isPresented: $model.isDeleteConfirmationPresented
        ) {
            Button(
                shiftTitleAfterDelete == nil
                    ? localized("削除")
                    : localized("削除して登録"),
                role: .destructive
            ) {
                let selectedTitle = shiftTitleAfterDelete
                let deletedEvent = model.pendingDeletion
                shiftTitleAfterDelete = nil
                model.deletePending {
                    if let selectedTitle, let deletedEvent {
                        onRegisterShift(
                            model.yearMonth,
                            deletedEvent.day,
                            selectedTitle,
                            RegistrationCompletion { model.load(forceRefresh: true) }
                        )
                    }
                }
            }
            Button(localized("キャンセル"), role: .cancel) {
                shiftTitleAfterDelete = nil
            }
        } message: {
            Text(pendingDeletionConfirmationText)
        }
        .sheet(isPresented: $isShiftSelectionPresented) {
            ShiftSelectionView(
                definitions: definitions,
                tint: managerAccentColor,
                locale: locale
            ) { title in
                if isDaySelectionMode {
                    completeMultipleShiftSelection(title)
                } else {
                    completeShiftSelection(title)
                }
            }
        }
        .sheet(isPresented: $isDateTimeEventRegistrationPresented) {
            DateTimeEventRegistrationView(
                initialStartDate: dateTimeEventRegistrationStartDate,
                locale: locale
            ) { title, startDate, endDate, isAllDay in
                isDateTimeEventRegistrationPresented = false
                onRegisterDateTimeEvent(
                    title,
                    startDate,
                    endDate,
                    isAllDay,
                    DateTimeEventRegistrationCompletion { eventID in
                        model.applyRegisteredDateTimeEvent(
                            id: eventID,
                            title: title,
                            startDate: startDate,
                            endDate: endDate,
                            isAllDay: isAllDay
                        )
                    }
                )
            }
            .environment(\.locale, locale)
        }
#if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
#endif
    }

    private var iOSHomeHeader: some View {
        HStack(spacing: 12) {
            if isCloudSyncEnabled {
                Button {
                    onSynchronize()
                } label: {
                    if isSynchronizing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 36, height: 36)
                    } else {
                        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.icloud")
                            .frame(width: 36, height: 36)
                    }
                }
                .buttonStyle(ToolbarIconButtonStyleD())
                .accessibilityLabel("今すぐ同期")
                .disabled(isSynchronizing)
            } else {
                Color.clear
                    .frame(width: 36, height: 36)
            }

            Text("Cal Hub")
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .center)
                .layoutPriority(1)

            HStack(spacing: 8) {
                Button {
                    leaveDaySelectionModeAndOpen(onOpenPDFList)
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(ToolbarIconButtonStyleD())
                .accessibilityLabel(ShiftHubLocalization.string("PDF一覧", locale: locale))

                Button {
                    toggleDaySelectionMode()
                } label: {
                    Image(
                        systemName: isDaySelectionMode
                            ? "xmark"
                            : "circle.grid.2x2.topleft.checkmark.filled"
                    )
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(ToolbarIconButtonStyleD())
                .accessibilityLabel(isDaySelectionMode ? "複数選択を解除" : "複数選択")

                Button {
                    leaveDaySelectionModeAndOpen(onOpenShiftUpload)
                } label: {
                    Image(systemName: "doc.viewfinder")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(ToolbarIconButtonStyleD())
                .accessibilityLabel("勤務表")

                Button {
                    leaveDaySelectionModeAndOpen(onOpenSettings)
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(ToolbarIconButtonStyleD())
                .accessibilityLabel("設定")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
    }

    private var daySelectionToolbar: some View {
        HStack(spacing: 10) {
            Text(
                ShiftHubLocalization.format(
                    "選択中: %@",
                    locale: locale,
                    arguments: "\(selectedCalendarDays.count)"
                )
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button {
                exitDaySelectionMode()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .background(.background.secondary.opacity(0.72), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(.primary.opacity(0.12), lineWidth: 1)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ShiftHubLocalization.string("キャンセル", locale: locale))

            Button {
                selectedCalendarDays.removeAll()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .background(.background.secondary.opacity(0.72), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(.primary.opacity(0.12), lineWidth: 1)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ShiftHubLocalization.string("選択を全解除", locale: locale))
            .disabled(selectedCalendarDays.isEmpty)

            Button {
                guard !selectedCalendarDays.isEmpty else { return }
                isShiftSelectionPresented = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.caption.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .background(.background.secondary.opacity(0.72), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(.primary.opacity(0.12), lineWidth: 1)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ShiftHubLocalization.string("イベント一覧から選択", locale: locale))
            .disabled(selectedCalendarDays.isEmpty)
        }
#if os(iOS)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
#else
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
#endif
    }

    private var calendarDestinationMenu: some View {
#if os(iOS)
        CalendarDestinationSelector(
            selection: destination,
            showsCalendarIcon: true,
            isPresented: $isCalendarDestinationMenuPresented,
            rendersOverlay: false,
            onOpen: { isYearMonthPickerPresented = false },
            onSelect: onCalendarDestinationChange
        )
        .anchorPreference(key: CalendarOverlayAnchorKey.self, value: .bounds) {
            CalendarOverlayAnchors(destination: $0)
        }
#else
        Menu {
            ForEach(CalendarDestination.allCases) { destination in
                Button {
                    onCalendarDestinationChange(destination)
                } label: {
                    Label(destination.title, systemImage: "calendar")
                }
            }
        } label: {
            calendarDestinationLabel
        }
        .buttonStyle(.bordered)
        .simultaneousGesture(
            TapGesture().onEnded {
                isYearMonthPickerPresented = false
            }
        )
        .accessibilityLabel("カレンダーを変更")
#endif
    }

    private var calendarDestinationLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "calendar")
            Text(destination.title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
        }
    }

    @ViewBuilder
    private var eventManagerTitleView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(eventManagerTitleText)

            if let connectedCalendarName {
                Text(connectedCalendarName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var connectedCalendarName: String? {
        let name: String
        switch destination {
        case .apple:
            name = appleCalendarName
        case .google:
            name = googleCalendarName
        case .notion:
            name = notionDatabaseName
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? nil : trimmedName
    }

    private var pendingDeletionConfirmationText: String {
        guard let event = model.pendingDeletion else { return "" }
        guard ShiftHubLocalization.isEnglish(locale) else { return event.confirmationText }

        let menuDetail = event.menuDetail(locale: locale)
        let key = menuDetail.isEmpty ? "%@日の「%@」" : "%@日の「%@」\n%@"
        return ShiftHubLocalization.format(
            key,
            locale: locale,
            arguments: String(event.day), event.title, menuDetail
        )
    }

    private var eventManagerTitleText: String {
        if locale.identifier.hasPrefix("en") {
            switch destination {
            case .apple:
                return "Manage events in Apple Calendar"
            case .google:
                return "Manage events in Google Calendar"
            case .notion:
                return "Manage events in the Notion database"
            }
        }

        switch destination {
        case .apple:
            return "Appleカレンダー"
        case .google:
            return "Googleカレンダー"
        case .notion:
            return "Notion DB"
        }
    }

    private var eventMonthTitle: String {
        if locale.identifier.hasPrefix("en") {
            return model.yearMonth.displayText(for: locale)
        }

        return String(format: "%04d-%02d", model.yearMonth.year, model.yearMonth.month)
    }

    private var monthTitleSelector: some View {
        Button {
            if isYearMonthPickerPresented {
                isYearMonthPickerPresented = false
            } else {
                DispatchQueue.main.async {
                    isYearMonthPickerPresented = true
                }
            }
        } label: {
            Text(eventMonthTitle)
                .monospacedDigit()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .anchorPreference(key: CalendarOverlayAnchorKey.self, value: .bounds) {
            CalendarOverlayAnchors(monthTitle: $0)
        }
        .zIndex(isYearMonthPickerPresented ? 100 : 0)
        .accessibilityLabel(locale.identifier.hasPrefix("en") ? "Select year and month" : "年と月を選択")
    }

    private var monthNavigationControls: some View {
        HStack(spacing: 12) {
            Button {
                isYearMonthPickerPresented = false
                moveMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(locale.identifier.hasPrefix("en") ? "Previous month" : "前の月")

            Button {
                isYearMonthPickerPresented = false
                moveMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(locale.identifier.hasPrefix("en") ? "Next month" : "次の月")
        }
    }

    private func moveMonth(by offset: Int) {
        let target = model.yearMonth.addingMonths(offset)
        moveMonth(to: target)
    }

    private func moveMonth(to target: YearMonth, animated: Bool = false) {
        guard let pageID = pageID(for: target) else { return }

        if animated {
            // Keep the pending date or event selection until the page scroll reaches idle.
            isMonthScrollActive = true
            withAnimation(.easeInOut(duration: 0.3)) {
                monthPageID = pageID
            }

            // The scroll phase callback normally commits this transition. Keep a
            // small fallback for platforms that do not report programmatic idle.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard pendingDayActionsSelection != nil || pendingBandEventForActions != nil,
                      pendingMonthPageID == pageID,
                      monthPageID == pageID else { return }
                commitPendingMonthPage()
            }
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                monthPageID = pageID
            }
        }
    }

    private func handleEventBandTap(
        event: CalendarEventRecord,
        yearMonth: YearMonth,
        day: Int
    ) {
        isCalendarDestinationMenuPresented = false
        isYearMonthPickerPresented = false
        selectedDayForActions = nil

        let selection = CalendarBandEventSelection(
            event: event,
            yearMonth: yearMonth,
            day: day
        )
        if selection.yearMonth == model.yearMonth {
            selectedBandEventForActions = selection
        } else {
            pendingBandEventForActions = selection
            moveMonth(to: selection.yearMonth, animated: true)
        }
    }

    private func reloadSelectedMonth() {
        guard selectedYearMonth != model.yearMonth else { return }
        pendingMonthPageID = nil
        if let pageID = pageID(for: selectedYearMonth) {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                monthPageID = pageID
            }
        }
        model.updateYearMonth(selectedYearMonth)
        model.load()
    }

    private func commitPendingMonthPage() {
        guard let pageID = pendingMonthPageID,
              (0...Self.monthPageRadius * 2).contains(pageID) else { return }
        pendingMonthPageID = nil

        let target = monthForPageID(pageID)
        guard target != model.yearMonth else { return }

        model.updateYearMonth(target)
        selectedYear = target.year
        selectedMonth = target.month
        model.load()
    }

    private func beginEventBandReveal() {
        eventBandRevealGeneration += 1
        let generation = eventBandRevealGeneration
        let dayCount = model.yearMonth.numberOfDays

        guard !model.events.isEmpty else {
            eventBandRevealThroughDay = dayCount
            return
        }

        eventBandRevealThroughDay = 0
        Task { @MainActor in
            for day in 1...dayCount {
                guard generation == eventBandRevealGeneration else { return }
                guard !isMonthScrollActive else {
                    eventBandRevealThroughDay = dayCount
                    return
                }

                withAnimation(.easeOut(duration: 0.08)) {
                    eventBandRevealThroughDay = day
                }

                do {
                    try await Task.sleep(nanoseconds: 20_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func showAllEventBandsImmediately() {
        eventBandRevealGeneration += 1
        eventBandRevealThroughDay = model.yearMonth.numberOfDays
    }

    private func eventBandRevealOpacity(
        for yearMonth: YearMonth,
        slot: Int,
        gridDates: [CalendarGridDate]
    ) -> Double {
        guard yearMonth == model.yearMonth,
              !model.events.isEmpty,
              let gridDate = gridDates.first(where: { $0.slot == slot }),
              gridDate.isInDisplayedMonth else {
            return 1
        }
        return gridDate.day <= eventBandRevealThroughDay ? 1 : 0
    }

    private func monthForPageID(_ pageID: Int) -> YearMonth {
        monthPageAnchor.addingMonths(pageID - Self.monthPageRadius)
    }

    private func pageID(for yearMonth: YearMonth) -> Int? {
        let offset = (yearMonth.year - monthPageAnchor.year) * 12
            + yearMonth.month - monthPageAnchor.month
        let pageID = Self.monthPageRadius + offset
        return (0...Self.monthPageRadius * 2).contains(pageID) ? pageID : nil
    }

    private func calendarGridDates(for yearMonth: YearMonth) -> [CalendarGridDate] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        guard let monthStart = calendar.date(from: DateComponents(
            year: yearMonth.year,
            month: yearMonth.month,
            day: 1
        )) else {
            return []
        }

        let leadingBlankCount = yearMonth.leadingBlankCount
        let monthSlotCount = leadingBlankCount + yearMonth.numberOfDays
        let rowCount = max(1, Int(ceil(Double(monthSlotCount) / 7.0)))
        let totalSlots = rowCount * 7
        let firstDate = calendar.date(
            byAdding: .day,
            value: -leadingBlankCount,
            to: monthStart
        ) ?? monthStart

        return (0..<totalSlots).compactMap { slot in
            guard let date = calendar.date(byAdding: .day, value: slot, to: firstDate) else {
                return nil
            }

            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                return nil
            }

            return CalendarGridDate(
                date: date,
                yearMonth: YearMonth(year: year, month: month),
                day: day,
                slot: slot,
                displayedMonth: yearMonth
            )
        }
    }

    private func calendarPageEvents(
        for yearMonth: YearMonth,
        events: [CalendarEventRecord]
    ) -> [CalendarEventRecord] {
        var pageEvents = events
        pageEvents.append(contentsOf: model.cachedEvents(for: yearMonth.previousMonth))
        pageEvents.append(contentsOf: model.cachedEvents(for: yearMonth.nextMonth))

        return Array(
            Dictionary(
                pageEvents.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            .values
        )
    }

    private func eventDisplaySegments(
        for yearMonth: YearMonth,
        events: [CalendarEventRecord],
        gridDates: [CalendarGridDate]
    ) -> [CalendarEventDisplaySegment] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let result = events.flatMap { (event: CalendarEventRecord) -> [CalendarEventDisplaySegment] in
            guard let fallbackDate = calendar.date(from: DateComponents(
                year: yearMonth.year,
                month: yearMonth.month,
                day: event.day
            )) else {
                return []
            }

            let startDate = calendar.startOfDay(for: event.startDate ?? fallbackDate)
            let endDate = calendar.startOfDay(for: event.endDate ?? event.startDate ?? fallbackDate)
            let matchingSlots = gridDates.filter { gridDate in
                let date = calendar.startOfDay(for: gridDate.date)
                return date >= startDate && date <= endDate
            }

            guard let firstSlot = matchingSlots.first?.slot,
                  let lastSlot = matchingSlots.last?.slot,
                  firstSlot <= lastSlot else {
                return []
            }

            var segments: [CalendarEventDisplaySegment] = []
            var segmentStartDay = firstSlot
            while segmentStartDay <= lastSlot {
                let segmentEndDay = min(lastSlot, ((segmentStartDay / 7) + 1) * 7 - 1)
                segments.append(
                    CalendarEventDisplaySegment(
                        event: event,
                        startDay: segmentStartDay,
                        endDay: segmentEndDay
                    )
                )
                segmentStartDay = segmentEndDay + 1
            }
            return segments
        }
        return result
    }

    private func singleDayEventBandSegments(
        for yearMonth: YearMonth,
        events: [CalendarEventRecord],
        segments: [CalendarEventDisplaySegment],
        gridDates: [CalendarGridDate]
    ) -> [CalendarEventDisplaySegment] {
        var result: [CalendarEventDisplaySegment] = []

        for gridDate in gridDates {
            let dayEvents = events.filter {
                $0.occurs(on: gridDate.date, fallbackYearMonth: yearMonth)
            }
            let segmentsForDay = segments.filter { $0.contains(day: gridDate.slot) }
            let segmentStartEvents = segmentsForDay
                .filter { $0.startDay == gridDate.slot }
                .map(\.event)
            let displayEvents = Array(
                Dictionary(
                    (dayEvents + segmentStartEvents).map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
            )
            .values
            )
            .filter { event in
                !segmentsForDay.contains {
                    $0.event.id == event.id
                        && $0.spanDays > 1
                }
            }
            .sorted(by: calendarEventComesBefore)
            .prefix(3)

            for event in displayEvents {
                result.append(CalendarEventDisplaySegment(
                    event: event,
                    startDay: gridDate.slot,
                    endDay: gridDate.slot
                ))
            }
        }

        return result
    }

    private func eventBandLayouts(
        for yearMonth: YearMonth,
        events: [CalendarEventRecord],
        segments: [CalendarEventDisplaySegment],
        gridDates: [CalendarGridDate]
    ) -> [CalendarEventBandLayout] {
        let candidates = Array(
            Dictionary(
                (segments.filter { $0.spanDays > 1 }
                    + singleDayEventBandSegments(
                        for: yearMonth,
                        events: events,
                        segments: segments,
                        gridDates: gridDates
                    )).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ).values
        )
        .sorted {
            if $0.startDay != $1.startDay {
                return $0.startDay < $1.startDay
            }
            if $0.endDay != $1.endDay {
                // Keep a longer band above an event that starts on the same day.
                return $0.endDay > $1.endDay
            }
            if calendarEventComesBefore($0.event, $1.event) {
                return true
            }
            if calendarEventComesBefore($1.event, $0.event) {
                return false
            }
            return $0.event.id < $1.event.id
        }

        var occupiedRanges: [Int: [[ClosedRange<Int>]]] = [:]
        var layouts: [CalendarEventBandLayout] = []
        for segment in candidates {
            let row = segment.startDay / 7
            let range = segment.startDay...segment.endDay
            var rowLanes = occupiedRanges[row, default: []]
            var lane = 0
            while lane < rowLanes.count,
                  rowLanes[lane].contains(where: { $0.overlaps(range) }) {
                lane += 1
            }
            if lane == rowLanes.count {
                rowLanes.append([])
            }
            rowLanes[lane].append(range)
            occupiedRanges[row] = rowLanes
            layouts.append(CalendarEventBandLayout(
                event: segment.event,
                startDay: segment.startDay,
                endDay: segment.endDay,
                lane: lane
            ))
        }

        // The card has room for three equal event lanes. Hidden events are
        // indicated in the date header and remain available from the day menu.
        return layouts
    }

    private func calendarEventBandMetrics(cardHeight: CGFloat) -> CalendarEventBandMetrics {
#if os(iOS)
        let dateHeaderHeight: CGFloat = 14
        let contentSpacing: CGFloat = 5
        let gap: CGFloat = 2
#else
        let dateHeaderHeight: CGFloat = 18
        let contentSpacing: CGFloat = 7
        let gap: CGFloat = 4
#endif
        let availableHeight = max(
            0,
            cardHeight - 12 - dateHeaderHeight - contentSpacing
        )
        let height = max(0, (availableHeight - gap * 2) / 3 - 1)
        return CalendarEventBandMetrics(
            top: 6 + dateHeaderHeight + contentSpacing,
            contentSpacing: contentSpacing,
            gap: gap,
            height: height,
            laneHeight: height + gap
        )
    }

    private func eventBandCornerStyle(
        for layout: CalendarEventBandLayout,
        segments: [CalendarEventDisplaySegment],
        gridDates: [CalendarGridDate]
    ) -> (squareLeading: Bool, squareTrailing: Bool) {
        let hasPreviousSegment = segments.contains {
            $0.event.id == layout.event.id && $0.endDay == layout.startDay - 1
        }
        let hasNextSegment = segments.contains {
            $0.event.id == layout.event.id && $0.startDay == layout.endDay + 1
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let continuesBeforeGrid: Bool
        let continuesAfterGrid: Bool

        if let firstGridDate = gridDates.first?.date,
           let lastGridDate = gridDates.last?.date {
            let firstDay = calendar.startOfDay(for: firstGridDate)
            let lastDay = calendar.startOfDay(for: lastGridDate)
            continuesBeforeGrid = layout.event.startDate.map {
                calendar.startOfDay(for: $0) < firstDay
            } ?? false
            continuesAfterGrid = layout.event.endDate.map {
                calendar.startOfDay(for: $0) > lastDay
            } ?? false
        } else {
            continuesBeforeGrid = false
            continuesAfterGrid = false
        }

        return (
            squareLeading: hasPreviousSegment || continuesBeforeGrid,
            squareTrailing: hasNextSegment || continuesAfterGrid
        )
    }

    private func eventBandGradient(
        for layout: CalendarEventBandLayout,
        eventColor: Color,
        gridDates: [CalendarGridDate]
    ) -> LinearGradient {
        let baseOpacity = isDaySelectionMode ? 0.08 : 0.25
        let dimmedOpacity = baseOpacity * 0.45
        let layoutDates = gridDates.filter {
            (layout.startDay...layout.endDay).contains($0.slot)
        }
        let span = max(1, layoutDates.count)
        let leadingOutsideCount = layoutDates.prefix {
            !$0.isInDisplayedMonth
        }.count
        let trailingOutsideCount = layoutDates.reversed().prefix {
            !$0.isInDisplayedMonth
        }.count

        let baseColor = eventColor.opacity(baseOpacity)
        let dimmedColor = eventColor.opacity(dimmedOpacity)
        let stops: [Gradient.Stop]

        if leadingOutsideCount == span || trailingOutsideCount == span {
            stops = [
                Gradient.Stop(color: dimmedColor, location: 0),
                Gradient.Stop(color: dimmedColor, location: 1)
            ]
        } else if leadingOutsideCount > 0 {
            let boundary = CGFloat(leadingOutsideCount) / CGFloat(span)
            stops = [
                Gradient.Stop(color: dimmedColor, location: 0),
                Gradient.Stop(color: dimmedColor, location: boundary),
                Gradient.Stop(color: baseColor, location: boundary),
                Gradient.Stop(color: baseColor, location: 1)
            ]
        } else if trailingOutsideCount > 0 {
            let boundary = CGFloat(span - trailingOutsideCount) / CGFloat(span)
            stops = [
                Gradient.Stop(color: baseColor, location: 0),
                Gradient.Stop(color: baseColor, location: boundary),
                Gradient.Stop(color: dimmedColor, location: boundary),
                Gradient.Stop(color: dimmedColor, location: 1)
            ]
        } else {
            stops = [
                Gradient.Stop(color: baseColor, location: 0),
                Gradient.Stop(color: baseColor, location: 1)
            ]
        }

        return LinearGradient(
            stops: stops,
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func eventBandDate(
        for layout: CalendarEventBandLayout,
        location: CGPoint,
        bandWidth: CGFloat,
        leadingExtension: CGFloat,
        trailingExtension: CGFloat,
        gridDates: [CalendarGridDate]
    ) -> CalendarGridDate? {
        let span = max(1, layout.spanDays)
        let contentWidth = max(1, bandWidth - leadingExtension - trailingExtension)
        let dayWidth = max(1, contentWidth / CGFloat(span))
        let contentLocation = location.x - leadingExtension
        let offset = min(
            span - 1,
            max(0, Int(contentLocation / dayWidth))
        )
        let slot = layout.startDay + offset
        return gridDates.first { $0.slot == slot }
    }

    private var eventCalendarColumns: [GridItem] {
#if os(iOS)
        return Array(repeating: GridItem(.flexible(minimum: 38), spacing: 4), count: 7)
#else
        Array(repeating: GridItem(.flexible(minimum: 72), spacing: 8), count: 7)
#endif
    }

    private var eventCalendarView: some View {
        return GeometryReader { geometry in
            let currentPageID = monthPageID ?? pageID(for: model.yearMonth) ?? Self.monthPageRadius

            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(0...(Self.monthPageRadius * 2), id: \.self) { pageID in
                        Group {
                            if abs(pageID - currentPageID) <= 2 {
                                let pageMonth = monthForPageID(pageID)
                                let pageEvents = pageMonth == model.yearMonth
                                    ? model.events
                                    : model.cachedEvents(for: pageMonth)

                                eventCalendarPage(
                                    for: pageMonth,
                                    events: pageEvents,
                                    availableWidth: geometry.size.width,
                                    availableHeight: geometry.size.height
                                )
                            } else {
                                Color.clear
                            }
                        }
                        .containerRelativeFrame(.horizontal)
                        .frame(height: geometry.size.height)
                        .id(pageID)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
            .scrollPosition(id: $monthPageID)
            .onScrollPhaseChange { _, phase in
                isMonthScrollActive = phase != .idle
                if phase != .idle {
                    eventBandRevealGeneration += 1
                    eventBandRevealThroughDay = model.yearMonth.numberOfDays
                }
                if phase == .idle {
                    commitPendingMonthPage()
                }
            }
#if os(macOS)
            .transaction { transaction in
                if isCalendarLiveResizing {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#if os(iOS)
        .sheet(item: $selectedBandEventForActions) { selection in
            CalHubDateActionSheetContainer {
                eventActionsPopover(for: selection.event, day: selection.day)
            }
                .presentationDragIndicator(.visible)
        }
#endif
    }

    private func eventCalendarPage(
        for yearMonth: YearMonth,
        events: [CalendarEventRecord],
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        let gridDates = calendarGridDates(for: yearMonth)
        let isCurrentMonth = yearMonth == model.yearMonth
        let pageEvents = calendarPageEvents(for: yearMonth, events: events)
        let displaySegments = eventDisplaySegments(
            for: yearMonth,
            events: pageEvents,
            gridDates: gridDates
        )
        let bandLayouts = eventBandLayouts(
            for: yearMonth,
            events: pageEvents,
            segments: displaySegments,
            gridDates: gridDates
        )
#if os(iOS)
        let gridSpacing: CGFloat = 5
        let columnSpacing: CGFloat = 4
        let horizontalInsets: CGFloat = 24
        let rowCount = 6
        let verticalInsets: CGFloat = 8
        let fittedCardHeight = (
            availableHeight
                - verticalInsets
                - CGFloat(max(rowCount - 1, 0)) * gridSpacing
        ) / CGFloat(max(rowCount, 1))
        let cardHeight = min(80, max(52, fittedCardHeight))
#else
        let cardHeight: CGFloat = 112
        let gridSpacing: CGFloat = 8
        let columnSpacing: CGFloat = 8
        let horizontalInsets: CGFloat = 48
#endif
        let bandMetrics = calendarEventBandMetrics(cardHeight: cardHeight)
        // Keep adjacent pages on the same band renderer while they are being
        // swiped into view; only the current page remains interactive.
        let renderEventBandsInOverlay = true
        let columnWidth = max(
            0,
            (availableWidth - horizontalInsets - CGFloat(6) * columnSpacing) / 7
        )
        return ScrollView {
            ZStack(alignment: .topLeading) {
                LazyVGrid(columns: eventCalendarColumns, spacing: gridSpacing) {
                    ForEach(gridDates) { gridDate in
                        eventDayCell(
                            gridDate: gridDate,
                            events: pageEvents,
                            segments: displaySegments,
                            isInteractive: isCurrentMonth,
                            isSelectionMode: isDaySelectionMode,
                            isSelected: selectedCalendarDays.contains(
                                CalendarDaySelection(
                                    year: gridDate.yearMonth.year,
                                    month: gridDate.yearMonth.month,
                                    day: gridDate.day
                                )
                            ),
                            cardHeight: cardHeight,
                            bandMetrics: bandMetrics,
                            bandLayouts: bandLayouts,
                            hideEventContent: renderEventBandsInOverlay
                        )
                    }
                }

                if renderEventBandsInOverlay {
                    ForEach(bandLayouts.filter { $0.lane < 3 }) { layout in
                        let row = layout.startDay / 7
                        let column = layout.startDay % 7
                        #if os(iOS)
                        let bandInset: CGFloat = 3
#else
                        let bandInset: CGFloat = 6
#endif
                        let cornerStyle = eventBandCornerStyle(
                            for: layout,
                            segments: displaySegments,
                            gridDates: gridDates
                        )
                        let continuesFromPreviousWeek = layout.startDay % 7 == 0
                            && cornerStyle.squareLeading
                        let continuesIntoNextWeek = layout.endDay % 7 == 6
                            && cornerStyle.squareTrailing
                        let leadingExtension = continuesFromPreviousWeek
                            ? bandInset + columnSpacing / 2
                            : 0
                        let trailingExtension = continuesIntoNextWeek
                            ? bandInset + columnSpacing / 2
                            : 0
                        let bandWidth = max(0, columnWidth * CGFloat(layout.spanDays)
                            + columnSpacing * CGFloat(layout.spanDays - 1)
                            - bandInset * 2
                            + leadingExtension
                            + trailingExtension)
                        let eventColor = layout.event.isRestEvent
                            ? Color.red
                            : layout.event.calendarColor?.color ?? Color.accentColor
                        let bandStartDate = gridDates.first {
                            $0.slot == layout.startDay
                        }
                        let bandTitleOpacity = bandStartDate?.isInDisplayedMonth == false
                            ? 0.45
                            : 1

                        ZStack(alignment: .leading) {
                            HStack(spacing: 0) {
                                Text(layout.event.title)
#if os(iOS)
                                    .font(.system(size: 8, weight: .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
#else
                                    .font(.caption.weight(.medium))
#endif
                                    .foregroundStyle(.primary.opacity(bandTitleOpacity))
                                    .padding(.horizontal, 6)

                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .allowsHitTesting(false)

                            Rectangle()
                                .fill(.clear)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .gesture(
                                    SpatialTapGesture()
                                        .onEnded { value in
                                            let tappedDate = eventBandDate(
                                                for: layout,
                                                location: value.location,
                                                bandWidth: bandWidth,
                                                leadingExtension: leadingExtension,
                                                trailingExtension: trailingExtension,
                                                gridDates: gridDates
                                            ) ?? bandStartDate
                                            handleEventBandTap(
                                                event: layout.event,
                                                yearMonth: tappedDate?.yearMonth ?? yearMonth,
                                                day: tappedDate?.day ?? 1
                                            )
                                        }
                                )
                                .accessibilityLabel(layout.event.title)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction {
                                    handleEventBandTap(
                                        event: layout.event,
                                        yearMonth: bandStartDate?.yearMonth ?? yearMonth,
                                        day: bandStartDate?.day ?? 1
                                    )
                                }
#if os(macOS)
                            .popover(
                                isPresented: bandEventPopoverBinding(
                                    for: layout.event,
                                    layout: layout,
                                    gridDates: gridDates
                                )
                            ) {
                                bandEventActionsPopover(
                                    for: layout.event,
                                    day: selectedBandEventForActions?.day
                                        ?? bandStartDate?.day
                                        ?? 1
                                )
                            }
#endif
                        }
                        .frame(width: bandWidth, height: bandMetrics.height)
                        .background {
                            CalendarEventBandShape(
                                squareLeading: cornerStyle.squareLeading,
                                squareTrailing: cornerStyle.squareTrailing
                            )
                                .fill(
                                    eventBandGradient(
                                        for: layout,
                                        eventColor: eventColor,
                                        gridDates: gridDates
                                    )
                                )
                        }
                        .position(
                            x: CGFloat(column) * (columnWidth + columnSpacing)
                                + bandInset - leadingExtension + bandWidth / 2,
                            y: CGFloat(row) * (cardHeight + gridSpacing)
                                + bandMetrics.top
                                + CGFloat(layout.lane) * bandMetrics.laneHeight
                                + bandMetrics.height / 2
                        )
                        .opacity(eventBandRevealOpacity(
                            for: yearMonth,
                            slot: layout.startDay,
                            gridDates: gridDates
                        ))
                        .zIndex(2)
                        .allowsHitTesting(
                            isCurrentMonth
                                && !isDaySelectionMode
                                && !model.isDeleting
                        )
                    }
                }

            }
#if os(iOS)
            .padding(.horizontal, 12)
#else
            .padding(.horizontal, 24)
#endif
#if os(iOS)
            .padding(.vertical, 4)
#else
            .padding(.vertical, 8)
#endif
        }
        .id("\(yearMonth.year)-\(yearMonth.month)")
    }

    private func eventWeekdayHeader(columns: [GridItem]) -> some View {
        let weekdays = locale.identifier.hasPrefix("en")
            ? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            : ["日", "月", "火", "水", "木", "金", "土"]

        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(weekdays, id: \.self) { weekday in
                Text(weekday)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
        .background(.background)
    }

    private func roundedTodayUnderline() -> some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 1, y: 1))
                path.addLine(to: CGPoint(x: max(1, proxy.size.width - 1), y: 1))
            }
            .stroke(managerAccentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(height: 2)
        .offset(y: 1)
    }

    private func eventDayCell(
        gridDate: CalendarGridDate,
        events: [CalendarEventRecord],
        segments: [CalendarEventDisplaySegment],
        isInteractive: Bool,
        isSelectionMode: Bool,
        isSelected: Bool,
        cardHeight: CGFloat,
        bandMetrics: CalendarEventBandMetrics,
        bandLayouts: [CalendarEventBandLayout],
        hideEventContent: Bool
    ) -> some View {
        let dayEvents = events.filter {
            $0.occurs(on: gridDate.date, fallbackYearMonth: gridDate.yearMonth)
        }
        let segmentsForDay = segments.filter { $0.contains(day: gridDate.slot) }
        let segmentStartEvents = segmentsForDay
            .filter { $0.startDay == gridDate.slot }
            .map(\.event)
        let allDisplayEvents = Array(
            Dictionary(
                (dayEvents + segmentStartEvents).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            .values
        )
        .filter { event in
            !segmentsForDay.contains {
                $0.event.id == event.id
                    && $0.startDay == gridDate.slot
                    && $0.spanDays > 1
            }
        }
            .sorted(by: calendarEventComesBefore)
            .prefix(3)
        let displayEvents = hideEventContent ? [] : allDisplayEvents
        let overflowCount = bandLayouts.filter {
            $0.lane >= 3 && $0.contains(day: gridDate.slot)
        }.count
        let weekdayColumn = gridDate.slot % 7
        let connectsToPreviousCard = weekdayColumn > 0 && segmentsForDay.contains {
            $0.startDay < gridDate.slot
        }
        let selection = CalendarDaySelection(
            year: gridDate.yearMonth.year,
            month: gridDate.yearMonth.month,
            day: gridDate.day
        )
        let isToday = Calendar.current.isDateInToday(gridDate.date)
#if os(iOS)
        let dateHeaderHeight: CGFloat = 14
#else
        let dateHeaderHeight: CGFloat = 18
#endif
        return Button {
            if isSelectionMode {
                guard gridDate.isInDisplayedMonth else {
                    return
                }
                if selectedCalendarDays.contains(selection) {
                    selectedCalendarDays.remove(selection)
                } else {
                    selectedCalendarDays.insert(selection)
                }
                return
            }

            guard isInteractive else { return }

            isCalendarDestinationMenuPresented = false
            isYearMonthPickerPresented = false

            if !gridDate.isInDisplayedMonth {
                pendingDayActionsSelection = selection
                moveMonth(to: gridDate.yearMonth, animated: true)
                return
            }

            Task { @MainActor in
                await Task.yield()
                selectedDayForActions = gridDate.day
#if os(macOS)
                isDayActionsPopoverPresented = true
#endif
            }
        } label: {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: bandMetrics.contentSpacing) {
                    Color.clear
                        .frame(height: dateHeaderHeight)

                    ForEach(displayEvents) { event in
                        let eventColor = event.isRestEvent
                            ? Color.red
                            : event.calendarColor?.color ?? Color.accentColor
                        HStack(alignment: .top, spacing: bandMetrics.gap) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title)
#if os(iOS)
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
#else
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
#endif

                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
#if os(iOS)
                        .padding(.leading, 4)
#else
                        .padding(.leading, 6)
#endif
                        .padding(.vertical, min(3, bandMetrics.height / 6))
                        .frame(height: bandMetrics.height, alignment: .leading)
                        .background(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(eventColor.opacity(isDaySelectionMode ? 0.08 : 0.18))
                                .allowsHitTesting(false)
                        }
                    }

                    if displayEvents.isEmpty {
                        Spacer(minLength: 0)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(gridDate.day)")
#if os(iOS)
                        .font(.caption.weight(.semibold))
#else
                        .font(.body.weight(.semibold))
#endif
                        .overlay(alignment: .bottom) {
                            if isToday {
                                roundedTodayUnderline()
                            }
                        }
                    Spacer(minLength: 0)

                    if hideEventContent && overflowCount > 0 {
                        Text(
                            ShiftHubLocalization.format(
                                "+%@件",
                                locale: locale,
                                arguments: String(overflowCount)
                            )
                        )
#if os(iOS)
                            .font(.system(size: 8, weight: .semibold))
#else
                            .font(.caption2.weight(.semibold))
#endif
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            .padding(6)
#if os(iOS)
            .frame(height: cardHeight, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .topLeading)
#else
            .frame(height: cardHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
#endif
            .contentShape(Rectangle())
            .background {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.background.secondary.opacity(0.45))
                        .allowsHitTesting(false)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelectionMode
                            ? managerAccentColor.opacity(isSelected ? 1 : 0.18)
                            : .clear,
                        lineWidth: isSelectionMode ? 2 : 0
                    )
            }
            .animation(.easeOut(duration: 0.16), value: isSelected)
        }
#if os(iOS)
        .frame(height: cardHeight, alignment: .top)
#else
        .frame(height: cardHeight, alignment: .top)
#endif
        .buttonStyle(
            CalendarDayCardButtonStyle(
                accent: isInteractive ? managerAccentColor : .accentColor,
                isSelectionMode: isSelectionMode
            )
        )
        .opacity(gridDate.isInDisplayedMonth ? 1 : 0.38)
        .zIndex(connectsToPreviousCard ? 0 : 1)
        .disabled(model.isDeleting || !isInteractive)
#if os(iOS)
        .sheet(
            isPresented: Binding(
                get: {
                    isInteractive
                        && gridDate.isInDisplayedMonth
                        && !isSelectionMode
                        && selectedDayForActions == gridDate.day
                },
                set: { isPresented in
                    if isInteractive
                        && gridDate.isInDisplayedMonth
                        && !isPresented
                        && selectedDayForActions == gridDate.day {
                        selectedDayForActions = nil
                    }
                }
            )
        ) {
            dayActionsPopover(
                for: gridDate.day,
                additionalEvents: segmentsForDay.map(\.event)
            )
                .presentationDragIndicator(.visible)
        }
#else
        .popover(
            isPresented: Binding(
                get: {
                    isInteractive
                        && gridDate.isInDisplayedMonth
                        && !isSelectionMode
                        && isDayActionsPopoverPresented
                        && selectedDayForActions == gridDate.day
                        && selectedBandEventForActions == nil
                },
                set: { isPresented in
                    if isInteractive
                        && gridDate.isInDisplayedMonth
                        && !isPresented
                        && selectedDayForActions == gridDate.day {
                        isDayActionsPopoverPresented = false
                        selectedDayForActions = nil
                    }
                }
            )
        ) {
            dayActionsPopover(
                for: gridDate.day,
                additionalEvents: segmentsForDay.map(\.event)
            )
        }
#endif
    }

    private func dayActionsPopover(
        for day: Int,
        additionalEvents: [CalendarEventRecord] = []
    ) -> some View {
        let dayEvents = Array(
            Dictionary(
                (model.events(for: day) + additionalEvents).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            .values
        )
        let actionableEvents = dayEvents.filter { !$0.isReadOnly }
        let displayOnlyEvents = dayEvents.filter(\.isReadOnly)

        return CalHubDateActionSheetContainer {
            VStack(alignment: .leading, spacing: 0) {
            Text(model.dayHeader(for: day, locale: locale))
                .font(.headline)
                .padding(.bottom, 10)

            ForEach(displayOnlyEvents) { event in
                eventListRowContent(for: event)
                    .padding(.top, 12)
            }

#if os(iOS)
            if actionableEvents.count == 1, let event = actionableEvents.first {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    eventListRowContent(for: event)
                        .padding(.top, 6)
                        .padding(.bottom, 6)
                }

                dateTimeEventRegistrationButton(forDay: day)
                    .padding(.top, 8)

                eventRegistrationButton(forDay: day)
                    .padding(.top, 8)

                Button {
                    selectedEventForActions = nil
                    selectedBandEventForActions = nil
                    presentShiftSelection(for: event, deleteExisting: true)
                } label: {
                    Label(localized("削除してイベント一覧から選択"), systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .padding(.top, 8)

                Button(role: .destructive) {
                    selectedEventForActions = nil
                    selectedDayForActions = nil
                    selectedBandEventForActions = nil
                    pendingInlineDeletion = nil
                    model.requestDelete(event)
                } label: {
                    Label(localized("削除"), systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .foregroundStyle(.red)
                .padding(.top, 8)
            } else {
                if !actionableEvents.isEmpty {
                    Text(localized("イベントを選択"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                        .padding(.bottom, 6)

                    eventSelectionList(for: day, events: actionableEvents)
                }

                eventRegistrationButton(forDay: day)
                    .padding(.top, 12)

                dateTimeEventRegistrationButton(forDay: day)
                    .padding(.top, 8)
            }
#else
            if !actionableEvents.isEmpty {
                if actionableEvents.count == 1, let event = actionableEvents.first {
                    VStack(alignment: .leading, spacing: 0) {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            eventListRowContent(for: event)
                            dateTimeEventRegistrationButton(forDay: day)
                            eventRegistrationButton(forDay: day)
                            eventActions(for: event)
                        }
                        .padding(.top, 12)
                    }
                } else {
                    Text(localized("イベントを選択"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                        .padding(.bottom, 6)

                    eventSelectionList(for: day, events: actionableEvents)
                }
            }
#endif

#if os(macOS)
            if actionableEvents.count != 1 {
                dateTimeEventRegistrationButton(forDay: day)
                    .padding(.top, 12)

                eventRegistrationButton(forDay: day)
                    .padding(.top, 8)
            }
#endif
            }
        }
    }

    private func eventRegistrationButton(forDay day: Int) -> some View {
        Button {
            presentShiftSelection(forDay: day, deleteExisting: false)
        } label: {
            Label(localized("イベント一覧から選択"), systemImage: "list.bullet")
#if os(iOS)
                .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .leading)
#else
                .frame(maxWidth: .infinity, alignment: .leading)
#endif
        }
#if os(iOS)
        .buttonStyle(.bordered)
        .controlSize(.regular)
#endif
    }

    private func dateTimeEventRegistrationButton(forDay day: Int) -> some View {
        Button {
            presentDateTimeEventRegistration(forDay: day)
        } label: {
            Label(localized("イベントを登録"), systemImage: "calendar.badge.plus")
#if os(iOS)
                .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .leading)
#else
                .frame(maxWidth: .infinity, alignment: .leading)
#endif
        }
#if os(iOS)
        .buttonStyle(.bordered)
        .controlSize(.regular)
#endif
    }

    private func eventListRowContent(for event: CalendarEventRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)

            Text(event.menuDetail(locale: locale))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func eventSelectionList(
        for day: Int,
        events: [CalendarEventRecord]
    ) -> some View {
        Group {
            if events.count > 3 {
                ScrollView {
                    eventSelectionRows(for: day, events: events)
                }
                .frame(maxHeight: 220)
            } else {
                eventSelectionRows(for: day, events: events)
            }
        }
    }

    @ViewBuilder
    private func eventSelectionRows(
        for day: Int,
        events: [CalendarEventRecord]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(events) { event in
                Divider()
#if os(macOS)
                HStack(spacing: 8) {
                    eventListRowContent(for: event)
                        .frame(width: 180, alignment: .leading)

                    Button(role: .destructive) {
                        selectedEventForActions = nil
                        selectedDayForActions = nil
                        selectedBandEventForActions = nil
                        isDayActionsPopoverPresented = false
                        shiftTitleAfterDelete = nil
                        model.requestDelete(event)
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .disabled(event.isReadOnly)
                    .help(localized("削除"))
                    .accessibilityLabel(localized("削除"))
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
#else
                HStack(spacing: 8) {
                    eventListRowContent(for: event)

                    Button(role: .destructive) {
                        selectedEventForActions = nil
                        selectedDayForActions = nil
                        selectedBandEventForActions = nil
                        pendingInlineDeletion = nil
                        model.requestDelete(event)
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .disabled(event.isReadOnly)
                    .accessibilityLabel(localized("削除"))
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
#endif
            }
        }
    }

#if os(iOS)
    private func eventActionsPopover(for event: CalendarEventRecord, day: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.dayHeader(for: day, locale: locale))
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.bottom, 10)

            Divider()

            Text(event.title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.top, 12)

            let menuDetail = event.menuDetail(locale: locale)
            if !menuDetail.isEmpty {
                Text(menuDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
            }

            if pendingInlineDeletion?.id == event.id {
                VStack(alignment: .leading, spacing: 10) {
                    Text(localized("イベントを削除しますか？"))
                        .font(.subheadline.weight(.medium))

                    HStack(spacing: 8) {
                        Button(role: .destructive) {
                            pendingInlineDeletion = nil
                            selectedEventForActions = nil
                            selectedBandEventForActions = nil
                            selectedDayForActions = nil
                            model.deleteImmediately(event)
                        } label: {
                            Label(localized("削除"), systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }

                        Button {
                            pendingInlineDeletion = nil
                        } label: {
                            Text(localized("キャンセル"))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                eventActions(for: event)
            }
        }
        .padding(16)
        .frame(minWidth: 280, alignment: .leading)
    }
#endif

#if os(macOS)
    private func bandEventPopoverBinding(
        for event: CalendarEventRecord,
        layout: CalendarEventBandLayout,
        gridDates: [CalendarGridDate]
    ) -> Binding<Bool> {
        Binding(
            get: {
                guard let selection = selectedBandEventForActions,
                      selection.event.id == event.id else {
                    return false
                }
                return gridDates.contains {
                    (layout.startDay...layout.endDay).contains($0.slot)
                        && $0.yearMonth == selection.yearMonth
                        && $0.day == selection.day
                }
            },
            set: { isPresented in
                guard !isPresented,
                      let selection = selectedBandEventForActions,
                      selection.event.id == event.id,
                      gridDates.contains(where: {
                          (layout.startDay...layout.endDay).contains($0.slot)
                              && $0.yearMonth == selection.yearMonth
                              && $0.day == selection.day
                      }) else {
                    return
                }
                selectedBandEventForActions = nil
            }
        )
    }

    private func bandEventActionsPopover(for event: CalendarEventRecord, day: Int) -> some View {
        CalHubDateActionSheetContainer {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.dayHeader(for: day, locale: locale))
                    .font(.headline)
                    .padding(.bottom, 10)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    eventListRowContent(for: event)
                    eventActions(for: event)
                }
                .padding(.top, 12)
            }
        }
    }
#endif

    @ViewBuilder
    private func eventActions(for event: CalendarEventRecord) -> some View {
#if os(iOS)
        VStack(spacing: 8) {
            Button {
                selectedEventForActions = nil
                selectedBandEventForActions = nil
                presentShiftSelection(for: event, deleteExisting: true)
            } label: {
                Label(localized("削除してイベント一覧から選択"), systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(event.isReadOnly)

            Button(role: .destructive) {
                pendingInlineDeletion = event
            } label: {
                Label(localized("削除"), systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(event.isReadOnly)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
#else
        VStack(alignment: .leading, spacing: 8) {
            Button {
                selectedEventForActions = nil
                selectedBandEventForActions = nil
                presentShiftSelection(for: event, deleteExisting: true)
            } label: {
                Label(localized("削除してイベント一覧から選択"), systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(event.isReadOnly)

            Button(role: .destructive) {
                selectedEventForActions = nil
                selectedDayForActions = nil
                selectedBandEventForActions = nil
                shiftTitleAfterDelete = nil
                model.requestDelete(event)
            } label: {
                Label(localized("削除"), systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.red)
            .disabled(event.isReadOnly)
        }
#endif
    }

    private func presentShiftSelection(for event: CalendarEventRecord, deleteExisting: Bool) {
        selectedDayForActions = nil
        selectedBandEventForActions = nil
        pendingShiftRegistration = PendingShiftRegistration(
            day: event.day,
            event: event,
            deleteExisting: deleteExisting
        )
        isShiftSelectionPresented = true
    }

    private func presentDateTimeEventRegistration(forDay day: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let startOfDay = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: model.yearMonth.year,
            month: model.yearMonth.month,
            day: day
        )),
        let initialStartDate = calendar.date(byAdding: .hour, value: 9, to: startOfDay) else {
            return
        }

        selectedDayForActions = nil
        dateTimeEventRegistrationStartDate = initialStartDate
        Task { @MainActor in
            await Task.yield()
            isDateTimeEventRegistrationPresented = true
        }
    }

    private func leaveDaySelectionModeAndOpen(_ action: () -> Void) {
        if isDaySelectionMode {
            exitDaySelectionMode()
        }
        action()
    }

    private func enterDaySelectionMode() {
        selectedDayForActions = nil
        isCalendarDestinationMenuPresented = false
        isYearMonthPickerPresented = false
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedCalendarDays.removeAll()
            isDaySelectionMode = true
        }
    }

    private func toggleDaySelectionMode() {
        if isDaySelectionMode {
            exitDaySelectionMode()
        } else {
            enterDaySelectionMode()
        }
    }

    private func exitDaySelectionMode() {
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedCalendarDays.removeAll()
            isDaySelectionMode = false
        }
    }

    private func completeMultipleShiftSelection(_ title: String) {
        let selections = selectedCalendarDays.sorted {
            if $0.year != $1.year { return $0.year < $1.year }
            if $0.month != $1.month { return $0.month < $1.month }
            return $0.day < $1.day
        }

        guard !selections.isEmpty else { return }

        isShiftSelectionPresented = false
        exitDaySelectionMode()
        let registeredYearMonths = Set(selections.map {
            YearMonth(year: $0.year, month: $0.month)
        })
        onRegisterShifts(
            selections,
            title,
            RegistrationCompletion {
                model.invalidateCachedMonths(registeredYearMonths)
                model.load(forceRefresh: true)
            }
        )
    }

    private func presentShiftSelection(forDay day: Int, deleteExisting: Bool) {
        selectedDayForActions = nil
        pendingShiftRegistration = PendingShiftRegistration(
            day: day,
            event: nil,
            deleteExisting: deleteExisting
        )
        isShiftSelectionPresented = true
    }

    private func completeShiftSelection(_ title: String) {
        guard let pendingShiftRegistration else { return }
        self.pendingShiftRegistration = nil

        if pendingShiftRegistration.deleteExisting {
            guard let event = pendingShiftRegistration.event else { return }
            shiftTitleAfterDelete = title
            model.requestDelete(event)
        } else {
            onRegisterShift(
                model.yearMonth,
                pendingShiftRegistration.day,
                title,
                RegistrationCompletion { model.load(forceRefresh: true) }
            )
        }
    }
}
