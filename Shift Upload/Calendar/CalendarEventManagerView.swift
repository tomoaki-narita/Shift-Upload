import Foundation
import SwiftUI
import os

#if os(macOS)
import AppKit
#endif

#if os(macOS)
struct CalHubTitlebarLogoAccessory: NSViewRepresentable {
    let isDark: Bool
    let isVisible: Bool

    private static let identifier = NSUserInterfaceItemIdentifier("CalHubTitlebarLogo")

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            Self.install(in: view.window, isDark: isDark, isVisible: isVisible)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.install(in: nsView.window, isDark: isDark, isVisible: isVisible)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        guard let window = nsView.window else { return }
        remove(from: window)
    }

    static func removeFromCurrentWindow() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        remove(from: window)
    }

    private static func install(in window: NSWindow?, isDark: Bool, isVisible: Bool) {
        guard let window else { return }

        if !isVisible {
            remove(from: window)
            return
        }

        if let existing = window.titlebarAccessoryViewControllers.first(where: {
            $0.view.identifier == identifier
        }) {
            window.titleVisibility = .visible
            existing.view.setFrameSize(NSSize(width: 26, height: existing.view.frame.height))
            existing.view.subviews
                .compactMap { $0 as? NSTextField }
                .forEach { $0.removeFromSuperview() }
            if let imageView = existing.view.subviews.compactMap({ $0 as? NSImageView }).first {
                layoutImageView(imageView, in: existing.view)
            }
            updateBrand(in: existing.view, isDark: isDark)
            return
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 26, height: 0))
        container.identifier = identifier

        let imageView = NSImageView(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(imageView)
        layoutImageView(imageView, in: container)

        let controller = NSTitlebarAccessoryViewController()
        controller.view = container
        controller.layoutAttribute = .left
        updateBrand(in: container, isDark: isDark)
        window.addTitlebarAccessoryViewController(controller)
    }

    private static func remove(from window: NSWindow) {
        var removedAccessory = false
        for index in window.titlebarAccessoryViewControllers.indices.reversed() {
            let controller = window.titlebarAccessoryViewControllers[index]
            guard controller.view.identifier == identifier else { continue }
            window.removeTitlebarAccessoryViewController(at: index)
            removedAccessory = true
        }
        if removedAccessory {
            window.titleVisibility = .visible
        }
    }

    private static func layoutImageView(_ imageView: NSImageView, in container: NSView) {
        NSLayoutConstraint.deactivate(
            container.constraints.filter {
                $0.firstItem === imageView || $0.secondItem === imageView
            }
        )
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.layer?.setAffineTransform(.identity)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 22),
            imageView.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    private static func updateBrand(in container: NSView, isDark: Bool) {
        guard let imageView = container.subviews.compactMap({ $0 as? NSImageView }).first else {
            return
        }

        let image = NSImage(named: NSImage.Name("CalHub-clear"))
        image?.isTemplate = true
        imageView.image = image
        imageView.contentTintColor = isDark ? .white : .black
    }
}
#endif

private enum CalendarDisplayMode: String, CaseIterable, Hashable {
    case month
    case week
    case year
}

private enum CalendarDayActionsSheet: Identifiable {
    case month(day: Int)
    case week(CalendarDaySelection)

    var id: String {
        switch self {
        case .month(let day):
            return "month-\(day)"
        case .week(let selection):
            return "week-\(selection.year)-\(selection.month)-\(selection.day)"
        }
    }
}

private let calendarWeekPagingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ShiftUpload",
    category: "WeekPaging"
)

private let calendarRenderingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ShiftUpload",
    category: "CalendarRendering"
)

private let calendarRenderingLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "ShiftUpload",
    category: "CalendarRendering"
)

private func measureCalendarRendering<T>(
    _ name: StaticString,
    details: String,
    operation: () -> T
) -> T {
    let signpostID = OSSignpostID(log: calendarRenderingLog)
    let start = DispatchTime.now().uptimeNanoseconds
    os_signpost(
        .begin,
        log: calendarRenderingLog,
        name: name,
        signpostID: signpostID,
        "%{public}s",
        details
    )

    let result = operation()

    let elapsedMilliseconds = Double(
        DispatchTime.now().uptimeNanoseconds - start
    ) / 1_000_000
    os_signpost(
        .end,
        log: calendarRenderingLog,
        name: name,
        signpostID: signpostID,
        "duration=%.2fms %{public}s",
        elapsedMilliseconds,
        details
    )

    // Keep the console readable: Instruments receives every interval, while
    // the console only reports work that is long enough to explain a hitch.
    if elapsedMilliseconds >= 8 {
        let elapsedText = String(format: "%.2f", elapsedMilliseconds)
        let logMessage =
            "slow \(String(describing: name)) "
                + "duration=\(elapsedText)ms "
                + "\(details)"
        calendarRenderingLogger.notice("\(logMessage, privacy: .public)")
    }

    return result
}

private func logCalendarRenderingEvent(
    _ name: StaticString,
    details: String
) {
    os_signpost(
        .event,
        log: calendarRenderingLog,
        name: name,
        "%{public}s",
        details
    )
}

private struct CalendarTimedEventSegment: Identifiable {
    let event: CalendarEventRecord
    let gridDate: CalendarGridDate
    let startMinute: Int
    let endMinute: Int
    let continuesFromPreviousDay: Bool
    let continuesIntoNextDay: Bool

    var id: String {
        "\(event.id)-\(gridDate.yearMonth.year)-\(gridDate.yearMonth.month)-\(gridDate.day)"
    }
}

private struct CalendarTimedEventLayout: Identifiable {
    let segment: CalendarTimedEventSegment
    let lane: Int
    let laneCount: Int

    var id: String {
        segment.id
    }
}

private struct CalendarTimedEventLayoutResult {
    let layouts: [CalendarTimedEventLayout]
    let overflowCounts: [Date: Int]
}

private enum CalendarLayoutCacheKind: Hashable {
    case monthSegments
    case monthBands
    case weekSegments
    case weekBands
    case weekTimeline
    case yearMarkers
}

private struct CalendarLayoutCacheKey: Hashable {
    let kind: CalendarLayoutCacheKind
    let pageDate: Date
    let eventSignature: Int
}

private final class CalendarEventLayoutCache {
    private var displaySegments: [CalendarLayoutCacheKey: [CalendarEventDisplaySegment]] = [:]
    private var bandLayouts: [CalendarLayoutCacheKey: [CalendarEventBandLayout]] = [:]
    private var timedLayouts: [CalendarLayoutCacheKey: CalendarTimedEventLayoutResult] = [:]
    private var yearMarkerColorsByKey: [CalendarLayoutCacheKey: [Int: Color]] = [:]

    func removeAll() {
        displaySegments.removeAll(keepingCapacity: true)
        bandLayouts.removeAll(keepingCapacity: true)
        timedLayouts.removeAll(keepingCapacity: true)
        yearMarkerColorsByKey.removeAll(keepingCapacity: true)
    }

    func yearMarkerColors(
        for key: CalendarLayoutCacheKey,
        build: () -> [Int: Color]
    ) -> [Int: Color] {
        if let cached = yearMarkerColorsByKey[key] {
            return cached
        }

        let result = build()
        yearMarkerColorsByKey[key] = result
        return result
    }

    func displaySegments(
        for key: CalendarLayoutCacheKey,
        build: () -> [CalendarEventDisplaySegment]
    ) -> [CalendarEventDisplaySegment] {
        if let cached = displaySegments[key] {
            return cached
        }

        let result = build()
        displaySegments[key] = result
        return result
    }

    func bandLayouts(
        for key: CalendarLayoutCacheKey,
        build: () -> [CalendarEventBandLayout]
    ) -> [CalendarEventBandLayout] {
        if let cached = bandLayouts[key] {
            return cached
        }

        let result = build()
        bandLayouts[key] = result
        return result
    }

    func timedLayouts(
        for key: CalendarLayoutCacheKey,
        build: () -> CalendarTimedEventLayoutResult
    ) -> CalendarTimedEventLayoutResult {
        if let cached = timedLayouts[key] {
            return cached
        }

        let result = build()
        timedLayouts[key] = result
        return result
    }
}

private struct CalendarTimelineSegmentShape: Shape {
    let squareTop: Bool
    let squareBottom: Bool

    func path(in rect: CGRect) -> Path {
#if os(macOS)
        let radius = min(8, min(rect.width, rect.height) / 2)
#else
        let radius = min(5, min(rect.width, rect.height) / 2)
#endif
        let topLeading = squareTop ? 0 : radius
        let topTrailing = squareTop ? 0 : radius
        let bottomLeading = squareBottom ? 0 : radius
        let bottomTrailing = squareBottom ? 0 : radius

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
        .frame(width: 200, height: 240)
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

private struct CalendarHeaderWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
                        Image(systemName: destination.systemImage)
                            .frame(width: 20, height: 20)
                        Text(destination.title)
                            .fixedSize(horizontal: true, vertical: false)
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
        .frame(minWidth: 180, maxWidth: 200, minHeight: 116, maxHeight: 116)
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
    let buttonMinimumWidth: CGFloat?
    let buttonHeight: CGFloat
    let onOpen: () -> Void
    let onSelect: (CalendarDestination) -> Void

    init(
        selection: CalendarDestination?,
        showsCalendarIcon: Bool,
        isPresented: Binding<Bool>,
        rendersOverlay: Bool,
        buttonMinimumWidth: CGFloat? = nil,
        buttonHeight: CGFloat = 40,
        onOpen: @escaping () -> Void,
        onSelect: @escaping (CalendarDestination) -> Void
    ) {
        self.selection = selection
        self.showsCalendarIcon = showsCalendarIcon
        self._isPresented = isPresented
        self.rendersOverlay = rendersOverlay
        self.buttonMinimumWidth = buttonMinimumWidth
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
                    Image(systemName: selection?.systemImage ?? "calendar")
                        .frame(width: 20, height: 20)
                }

                Text(selection?.title ?? "カレンダー")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
            }
        }
        .buttonStyle(ToolbarSelectorButtonStyleD(
            buttonHeight: buttonHeight,
            minimumWidth: buttonMinimumWidth
        ))
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
    let notionNotesProperty: String
    let notionLocationProperty: String
    let notionURLProperty: String
    let notionMetadataProperties: [NotionPropertyOption]
    let metadataFieldLabels: CalendarEventMetadataFieldLabels
    let appleCalendarName: String
    let googleCalendarName: String
    let notionDatabaseName: String
    let definitions: [ShiftDefinition]
    let onRegisterShift: (YearMonth, Int, String, RegistrationCompletion) -> Void
    let onRegisterDateTimeEvent: (CalendarEventDraft, DateTimeEventRegistrationCompletion) -> Void
    let onRegisterShifts: ([CalendarDaySelection], String, RegistrationCompletion) -> Void
    let onCalendarDestinationChange: (CalendarDestination) -> Void
    let onCalendarColorChange: (CalendarDisplayColor?) -> Void
    let onOpenShiftUpload: () -> Void
    let onOpenPDFList: () -> Void
    let onOpenSettings: () -> Void
    let isSynchronizing: Bool
    let isCloudSyncEnabled: Bool
    let onSynchronize: () -> Void
    let isTitlebarLogoVisible: Bool

    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.japanese.rawValue
    @AppStorage("googleShowJapaneseHolidays") private var googleShowJapaneseHolidays = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: CalendarEventManagerModel
    @State private var selectedYear: Int
    @State private var selectedMonth: Int
    @State private var calendarFocusDate: Date
    @State private var yearModeReturnFocusDate: Date?
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
    @State private var eventBeingEdited: CalendarEventRecord?
    @State private var selectedBandEventForActions: CalendarBandEventSelection?
    @State private var selectedWeekDayForActions: CalendarDaySelection?
#if os(macOS)
    @State private var selectedTimelineEventForActions: CalendarBandEventSelection?
#endif
    @State private var pendingBandEventForActions: CalendarBandEventSelection?
#if os(iOS)
    @State private var pendingInlineDeletion: CalendarEventRecord?
#endif
    @State private var isYearMonthPickerPresented = false
    @State private var isCalendarDestinationMenuPresented = false
    @State private var calendarDisplayMode: CalendarDisplayMode = .month
    @State private var calendarHeaderWidth: CGFloat = 343
    @State private var yearPageID: Int?
    @State private var queuedYearNavigationSteps = 0
    @State private var isYearButtonNavigationActive = false
    @State private var didObserveYearButtonScroll = false
    @State private var yearEventsByYear: [Int: [YearMonth: [CalendarEventRecord]]] = [:]
    @State private var isLoadingYearEvents = false
    @State private var yearEventRefreshID = 0
    @State private var shouldForceRefreshYearEvents = false
    @State private var calendarCacheRevalidationID = 0
    @State private var isRefreshingVisibleMonths = false
    @State private var weekContentInset: CGFloat = 0
    @State private var weekPageID: Date?
    @State private var pendingWeekMonthAnchorDate: Date?
    @State private var programmaticWeekPageID: Date?
    @State private var isRebuildingWeekPages = false
    @State private var weekPageRebuildGeneration = 0
    @State private var monthPageID: Int?
    @State private var pendingMonthPageID: Int?
    @State private var isMonthScrollActive = false
    @State private var eventBandRevealThroughDay = Int.max
    @State private var eventBandRevealGeneration = 0
    @State private var didLoadInitialMonth = false
    @State private var didEnterBackground = false
    @State private var calendarEventLayoutCache = CalendarEventLayoutCache()
#if os(macOS)
    @State private var isCalendarLiveResizing = false
    @State private var isDayActionsPopoverPresented = false
    // macOS can deliver the click that dismisses a popover to the view behind it.
    // Ignore that one trailing band tap so the same popover is not reopened.
    @State private var bandPopoverDismissalDeadline = Date.distantPast
#endif
    @State private var monthPageAnchor: YearMonth
    private let yearPageAnchor: Int
    @State private var weekPageTemplates: [[CalendarGridDate]]
    private static let monthPageRadius = 120
    // Keep the week pager bounded. A 20-year page set makes SwiftUI measure a
    // large number of event-band views when switching from month to week.
    // This matches the model's six-month neighbor cache on either side.
    private static let weekPageMonthRadius = 6
    private static let calendarControlHeight: CGFloat = 34

    private var calendarDayActionsSheetBinding: Binding<CalendarDayActionsSheet?> {
        Binding(
            get: {
                if let selection = selectedWeekDayForActions {
                    return .week(selection)
                }
                if let day = selectedDayForActions {
                    return .month(day: day)
                }
                return nil
            },
            set: { selection in
                guard selection == nil else { return }
                selectedWeekDayForActions = nil
                selectedDayForActions = nil
            }
        )
    }

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
        notionNotesProperty: String,
        notionLocationProperty: String,
        notionURLProperty: String,
        notionMetadataProperties: [NotionPropertyOption],
        metadataFieldLabels: CalendarEventMetadataFieldLabels,
        definitions: [ShiftDefinition],
        onRegisterShift: @escaping (YearMonth, Int, String, RegistrationCompletion) -> Void,
        onRegisterDateTimeEvent: @escaping (CalendarEventDraft, DateTimeEventRegistrationCompletion) -> Void,
        onRegisterShifts: @escaping ([CalendarDaySelection], String, RegistrationCompletion) -> Void,
        onCalendarDestinationChange: @escaping (CalendarDestination) -> Void,
        onCalendarColorChange: @escaping (CalendarDisplayColor?) -> Void,
        onOpenShiftUpload: @escaping () -> Void,
        onOpenPDFList: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        isSynchronizing: Bool,
        isCloudSyncEnabled: Bool,
        onSynchronize: @escaping () -> Void,
        isTitlebarLogoVisible: Bool
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
        self.notionNotesProperty = notionNotesProperty
        self.notionLocationProperty = notionLocationProperty
        self.notionURLProperty = notionURLProperty
        self.notionMetadataProperties = notionMetadataProperties
        self.metadataFieldLabels = metadataFieldLabels
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
        self.isTitlebarLogoVisible = isTitlebarLogoVisible
        _monthPageAnchor = State(initialValue: initial)
        self.yearPageAnchor = initial.year
        _weekPageTemplates = State(initialValue: Self.makeWeekPageTemplates(around: initial))
        _selectedYear = State(initialValue: initial.year)
        _selectedMonth = State(initialValue: initial.month)
        _calendarFocusDate = State(initialValue: initial == .current
            ? Date()
            : Calendar.current.date(from: DateComponents(
                year: initial.year,
                month: initial.month,
                day: 1
            )) ?? Date())
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
            notionTagValue: notionTagValue,
            notionNotesProperty: notionNotesProperty,
            notionLocationProperty: notionLocationProperty,
            notionURLProperty: notionURLProperty,
            notionMetadataProperties: notionMetadataProperties
        ))
    }

    private var selectedYearMonth: YearMonth {
        YearMonth(year: selectedYear, month: selectedMonth)
    }

    private var displayedYearEvents: [YearMonth: [CalendarEventRecord]] {
        yearEventsByYear[selectedYear] ?? [:]
    }

    private func localized(_ key: String) -> String {
        ShiftHubLocalization.string(key, locale: locale)
    }

    private func beginEditing(_ event: CalendarEventRecord) {
        guard !event.isReadOnly else { return }
        selectedEventForActions = nil
        selectedBandEventForActions = nil
        selectedWeekDayForActions = nil
#if os(macOS)
        selectedTimelineEventForActions = nil
#endif
        eventBeingEdited = event
    }

    private func editingStartDate(for event: CalendarEventRecord) -> Date {
        if let startDate = event.startDate {
            return startDate
        }

        return Calendar.current.date(from: DateComponents(
            year: model.yearMonth.year,
            month: model.yearMonth.month,
            day: event.day
        )) ?? Date()
    }

    private func editingEndDate(for event: CalendarEventRecord, startDate: Date) -> Date {
        if let endDate = event.endDate {
            return endDate
        }

        if event.isAllDay {
            return startDate
        }

        return Calendar.current.date(byAdding: .hour, value: 1, to: startDate) ?? startDate
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
            notionTagValue,
            notionNotesProperty,
            notionLocationProperty,
            notionURLProperty,
            notionMetadataProperties.map { "\($0.name):\($0.type)" }.joined(separator: ",")
        ].joined(separator: "|")
    }

    private var managerAccentColor: Color {
        model.calendarColor?.color ?? Color.accentColor
    }

    private var calendarBaseBackground: Color {
#if os(iOS)
        colorScheme == .dark
            ? Color(red: 0.1176, green: 0.1176, blue: 0.1176)
            : Color.white
#else
        Color(nsColor: .windowBackgroundColor)
#endif
    }

    private var calendarCardBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.15, green: 0.15, blue: 0.15)
            : Color(red: 0.96, green: 0.96, blue: 0.96)
    }

    private var isBandPopoverPresented: Bool {
#if os(macOS)
        selectedBandEventForActions != nil || selectedTimelineEventForActions != nil
#else
        false
#endif
    }

    private var yearOptions: [Int] {
        let currentYear = YearMonth.current.year
        let range = Array((currentYear - 10)...(currentYear + 10))
        return Array(Set(range + [selectedYear])).sorted()
    }

    private func handleSelectedYearChange() {
        isLoadingYearEvents = false
        if calendarDisplayMode == .year {
            if yearPageID != selectedYear {
                yearPageID = selectedYear
            }
            calendarFocusDate = dateByReplacingYear(of: calendarFocusDate, with: selectedYear)
        } else {
            reloadSelectedMonth()
        }
    }

    private func handleSelectedMonthChange() {
        if calendarDisplayMode == .year {
            let previousDay = Calendar.current.component(.day, from: calendarFocusDate)
            calendarFocusDate = calendarDate(
                yearMonth: selectedYearMonth,
                day: min(previousDay, selectedYearMonth.numberOfDays)
            )
            yearModeReturnFocusDate = calendarFocusDate
        } else {
            reloadSelectedMonth()
        }
    }

    private func handleLocaleChange() {
        model.setLocaleIdentifier(locale.identifier)
        model.load()
    }

    private func handleInitialCalendarAppearance() {
        onCalendarColorChange(model.calendarColor)
        guard !didLoadInitialMonth else { return }
        didLoadInitialMonth = true
        model.setLocaleIdentifier(locale.identifier)
        model.load()
    }

    private var yearEventsTaskID: String? {
        calendarDisplayMode == .year
            ? "\(selectedYear)-\(yearEventRefreshID)-\(calendarCacheRevalidationID)"
            : nil
    }

    private var monthWeekCacheTaskID: String? {
        guard calendarDisplayMode != .year else { return nil }
        let monthKey = cacheMonthsForCurrentDisplay
            .sorted { ($0.year, $0.month) < ($1.year, $1.month) }
            .map { "\($0.year)-\($0.month)" }
            .joined(separator: ",")
        let weekPageKey = weekPageID?.timeIntervalSinceReferenceDate ?? 0
        return "\(calendarDisplayMode.rawValue)-\(monthKey)-\(weekPageKey)-\(calendarCacheRevalidationID)"
    }

    private var cacheMonthsForCurrentDisplay: Set<YearMonth> {
        guard calendarDisplayMode != .year else { return [] }
        return [model.yearMonth.previousMonth, model.yearMonth, model.yearMonth.nextMonth]
    }

    private func monitorVisibleMonthWeekCaches() async {
        guard calendarDisplayMode != .year else { return }
        model.revalidateCachedMonths(for: cacheMonthsForCurrentDisplay)
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
            } catch {
                return
            }
            guard scenePhase == .active,
                  calendarDisplayMode != .year else { continue }
            model.revalidateCachedMonths(for: cacheMonthsForCurrentDisplay)
        }
    }

    private func monitorSelectedYearEvents() async {
        let forceRefresh = shouldForceRefreshYearEvents
        shouldForceRefreshYearEvents = false
        await loadEventsForSelectedYear(forceRefresh: forceRefresh)

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
            } catch {
                return
            }
            guard scenePhase == .active,
                  calendarDisplayMode == .year else { continue }
            await loadEventsForSelectedYear()
        }
    }

    private func loadEventsForSelectedYear(forceRefresh: Bool = false) async {
        guard calendarDisplayMode == .year else { return }
        let year = selectedYear
        if !forceRefresh {
            let cachedEvents = model.cachedEventsByMonth(
                for: year,
                loadingPersistentCache: true
            )
            if !cachedEvents.isEmpty {
                yearEventsByYear[year] = cachedEvents
            }
        }
        let hasCachedEvents = yearEventsByYear[year]?.isEmpty == false
        let shouldShowLoading = forceRefresh || !hasCachedEvents
        if shouldShowLoading {
            isLoadingYearEvents = true
        }
        defer {
            if shouldShowLoading && selectedYear == year && calendarDisplayMode == .year {
                isLoadingYearEvents = false
            }
        }

        let fetchedEvents: [YearMonth: [CalendarEventRecord]]
        if forceRefresh {
            fetchedEvents = await model.refreshEventsByMonth(for: year)
        } else {
            fetchedEvents = await model.fetchEventsByMonth(for: year)
        }
        guard !Task.isCancelled else { return }
        yearEventsByYear[year] = fetchedEvents
    }

    private func handleDateTimeEventRegistration(_ draft: CalendarEventDraft) {
        isDateTimeEventRegistrationPresented = false
        let completion = DateTimeEventRegistrationCompletion { eventID in
            model.applyRegisteredDateTimeEvent(id: eventID, draft: draft)
        }
        onRegisterDateTimeEvent(draft, completion)
    }

    private func handleEventEdit(_ event: CalendarEventRecord, draft: CalendarEventDraft) {
        eventBeingEdited = nil
        model.updateEvent(event, draft: draft)
    }

    private func eventEditingSheet(for event: CalendarEventRecord) -> some View {
        let startDate = editingStartDate(for: event)
        return DateTimeEventRegistrationView(
            initialStartDate: startDate,
            locale: locale,
            initialTitle: event.title,
            initialEndDate: editingEndDate(for: event, startDate: startDate),
            initialIsAllDay: event.isAllDay,
            initialMetadata: event.metadata,
            metadataFieldLabels: metadataFieldLabels,
            isEditing: true
        ) { draft in
            handleEventEdit(event, draft: draft)
        }
        .environment(\.locale, locale)
    }

    private func handleShiftSelection(_ title: String) {
        if isDaySelectionMode {
            completeMultipleShiftSelection(title)
        } else {
            completeShiftSelection(title)
        }
    }

    private var shiftSelectionSheetContent: some View {
        ShiftSelectionView(
            definitions: definitions,
            tint: managerAccentColor,
            locale: locale,
            onSelect: handleShiftSelection
        )
    }

    private var dateTimeEventRegistrationSheetContent: some View {
        DateTimeEventRegistrationView(
            initialStartDate: dateTimeEventRegistrationStartDate,
            locale: locale,
            metadataFieldLabels: metadataFieldLabels,
            onRegister: handleDateTimeEventRegistration
        )
        .environment(\.locale, locale)
    }

    private func handleCalendarEventManagerConfigurationChange() {
        yearEventsByYear.removeAll()
        yearEventRefreshID += 1
        model.updateConfiguration(
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
            notionMetadataProperties: notionMetadataProperties
        )
    }

    private func handleModelYearMonthChange() {
        selectedYear = model.yearMonth.year
        selectedMonth = model.yearMonth.month

        if let anchorDate = pendingWeekMonthAnchorDate {
            pendingWeekMonthAnchorDate = nil
            if calendarDisplayMode == .week {
                scheduleWeekPageRebuild(anchorDate: anchorDate)
            }
        } else if calendarDisplayMode == .week,
                  weekPageID == nil,
                  !isRebuildingWeekPages {
            scheduleWeekPageRebuild()
        }

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

#if os(macOS)
    @ToolbarContentBuilder
    private var calendarToolbarContent: some ToolbarContent {
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
            .help(ShiftHubLocalization.string("履歴", locale: locale))
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

    private var titlebarLogoAccessory: some View {
        CalHubTitlebarLogoAccessory(
            isDark: colorScheme == .dark,
            isVisible: isTitlebarLogoVisible
        )
        .frame(width: 0, height: 0)
    }

    private func beginCalendarLiveResize() {
        isCalendarLiveResizing = true
    }

    private func endCalendarLiveResize() {
        isCalendarLiveResizing = false
        guard let currentPageID = pageID(for: model.yearMonth) else { return }

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            monthPageID = currentPageID
        }
    }
#endif

    private var calendarRootView: some View {
        VStack(alignment: .leading, spacing: 0) {
#if os(iOS)
            iOSHomeHeader

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    eventManagerTitleView
                        .font(.title2.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)

                    Spacer(minLength: 4)

                    calendarDestinationMenu
                }
                .zIndex(1)

                HStack(spacing: 2) {
                    monthTitleSelector
                        .font(.title.bold())
#if os(iOS)
                        .layoutPriority(3)
#else
                        .layoutPriority(1)
#endif

                    Spacer(minLength: 0)

                    monthNavigationControls

#if os(iOS)
                    Spacer(minLength: 0)
#endif

                    calendarDisplayModeSelector
#if os(iOS)
                        .layoutPriority(2)
#endif

                    newEventButton

                    Button {
                        refreshDisplayedCalendar()
                    } label: {
                        if model.isLoading || isLoadingYearEvents || isRefreshingVisibleMonths {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.footnote)
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(.leading, 4)
                    .buttonStyle(.plain)
                    .tint(.primary)
                    .accessibilityLabel("取得")
                    .disabled(model.isLoading || isLoadingYearEvents || isRefreshingVisibleMonths || model.isDeleting)
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: CalendarHeaderWidthPreferenceKey.self,
                            value: geometry.size.width
                        )
                    }
                }
                .onPreferenceChange(CalendarHeaderWidthPreferenceKey.self) { width in
                    guard width > 0, abs(width - calendarHeaderWidth) > 0.5 else { return }
                    calendarHeaderWidth = width
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .zIndex(1)
#else
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 12) {
                    eventManagerTitleView
                        .font(.title.bold())

                    Spacer(minLength: 8)

                    calendarDestinationMenu
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

                    Spacer(minLength: 0)

                    monthNavigationControls

                    calendarDisplayModeSelector

                    newEventButton

                    Button {
                        refreshDisplayedCalendar()
                    } label: {
                        if model.isLoading || isLoadingYearEvents || isRefreshingVisibleMonths {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.plain)
                    .tint(.primary)
                    .help("取得")
                    .disabled(model.isLoading || isLoadingYearEvents || isRefreshingVisibleMonths || model.isDeleting)

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

            calendarDisplayContent
#if os(iOS)
                .sheet(item: calendarDayActionsSheetBinding) { selection in
                    calendarDayActionsSheetContent(for: selection)
                        .presentationDragIndicator(.visible)
                }
#endif

#if os(iOS)
            ZStack(alignment: .center) {
                if calendarDisplayMode == .year {
                    footerSummary(title: displayedYearFooterTitle, message: yearFooterMessage)
                        .font(.caption2)
                } else if !model.message.isEmpty && !model.isLoading {
                    footerSummary(title: model.displayedMonthText, message: model.message)
                        .font(.caption2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(minHeight: 20, alignment: .center)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 12)
#else
            ZStack(alignment: .center) {
                if calendarDisplayMode == .year {
                    footerSummary(title: displayedYearFooterTitle, message: yearFooterMessage)
                        .font(.callout)
                } else if !model.message.isEmpty && !model.isLoading {
                    footerSummary(title: model.displayedMonthText, message: model.message)
                        .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .center)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 12)
#endif
        }
#if os(macOS)
        .animation(.easeInOut(duration: 0.2), value: model.message)
        .animation(.easeInOut(duration: 0.2), value: model.isLoading)
#endif
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
        .background(calendarBaseBackground)
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
                            x: titleFrame.minX + 100,
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
                            x: destinationFrame.maxX - 100,
                            y: destinationFrame.minY + 50 + 58
                        )
                        .zIndex(1)
                    }
                }
            }
            .allowsHitTesting(isYearMonthPickerPresented || isCalendarDestinationMenuPresented)
        }
#if os(macOS)
        .toolbar { calendarToolbarContent }
#endif
#if os(macOS)
        .background { titlebarLogoAccessory }
#endif
        .onAppear {
            handleInitialCalendarAppearance()
        }
        .task(id: yearEventsTaskID) {
            await monitorSelectedYearEvents()
        }
        .task(id: monthWeekCacheTaskID) {
            await monitorVisibleMonthWeekCaches()
        }
        .onChange(of: model.calendarColor) { _, color in
            onCalendarColorChange(color)
        }
        .onChange(of: model.events) { _, events in
            calendarEventLayoutCache.removeAll()
            let logMessage =
                "events changed count=\(events.count) "
                    + "month=\(model.yearMonth.year)-\(model.yearMonth.month)"
            calendarRenderingLogger.debug("\(logMessage, privacy: .public)")
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
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive, .background:
                didEnterBackground = true
            case .active where didEnterBackground:
                didEnterBackground = false
                calendarCacheRevalidationID += 1
            default:
                break
            }
        }
        .onChange(of: isSynchronizing) { wasSynchronizing, isSynchronizing in
            guard wasSynchronizing, !isSynchronizing, isCloudSyncEnabled else { return }
            model.refreshAllCachedMonths()
            yearEventsByYear.removeAll()
            yearEventRefreshID += 1
        }
        .onChange(of: calendarEventManagerConfigurationKey) {
            handleCalendarEventManagerConfigurationChange()
        }
        .onChange(of: model.cachedMonthRevision) { _, _ in
            guard calendarDisplayMode == .year else { return }
            yearEventsByYear[selectedYear] = model.cachedEventsByMonth(for: selectedYear)
        }
        .onChange(of: model.yearMonth) { handleModelYearMonthChange() }
        .onChange(of: selectedYear) { handleSelectedYearChange() }
        .onChange(of: selectedMonth) { handleSelectedMonthChange() }
        .onChange(of: locale.identifier) { handleLocaleChange() }
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
        .onChange(of: calendarDisplayMode) { _, mode in
            if mode != .year {
                isLoadingYearEvents = false
                queuedYearNavigationSteps = 0
                isYearButtonNavigationActive = false
                didObserveYearButtonScroll = false
            }
            logCalendarRenderingEvent(
                "CalendarDisplayModeChange",
                details: "mode=\(mode.rawValue) events=\(model.events.count)"
            )
            let logMessage =
                "display mode changed to \(mode.rawValue) "
                    + "events=\(model.events.count) "
                    + "pageCount=\(weekPageTemplates.count)"
            calendarRenderingLogger.notice("\(logMessage, privacy: .public)")
            withAnimation(.easeInOut(duration: 0.25)) {
                weekContentInset = mode == .week
                    ? max(0, 40 - calendarBaseHorizontalInset)
                    : 0
            }

            guard mode == .week else {
                pendingWeekMonthAnchorDate = nil
                programmaticWeekPageID = nil
                isRebuildingWeekPages = false
                weekPageRebuildGeneration += 1
                return
            }
            let entryAnchorDate = pendingWeekMonthAnchorDate ?? weekModeEntryAnchorDate()
            pendingWeekMonthAnchorDate = nil
            if !isRebuildingWeekPages {
                scheduleWeekPageRebuild(anchorDate: entryAnchorDate)
            }
        }
        .onChange(of: weekPageID) { oldPageID, newPageID in
            if calendarDisplayMode == .week, let newPageID {
                calendarFocusDate = Calendar.current.date(byAdding: .day, value: 3, to: newPageID)
                    ?? newPageID
            }
            handleWeekPageChange(from: oldPageID, to: newPageID)
        }
#if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)) { _ in
            beginCalendarLiveResize()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { _ in
            endCalendarLiveResize()
        }
#endif
    }

    private var calendarAlertView: some View {
        calendarRootView
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
    }

    private var calendarShiftSelectionSheetView: some View {
        calendarAlertView
        .sheet(isPresented: $isShiftSelectionPresented) {
            shiftSelectionSheetContent
        }
    }

    private var calendarDateTimeRegistrationSheetView: some View {
        calendarShiftSelectionSheetView
        .sheet(isPresented: $isDateTimeEventRegistrationPresented) {
            dateTimeEventRegistrationSheetContent
        }
    }

    private var calendarEventEditingSheetView: some View {
        calendarDateTimeRegistrationSheetView
        .sheet(item: $eventBeingEdited) { event in
            eventEditingSheet(for: event)
        }
    }

    private var calendarPresentedView: some View {
        calendarEventEditingSheetView
#if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
#endif
    }

    var body: some View {
        calendarPresentedView
    }

    private var iOSHomeHeader: some View {
        HStack(spacing: 12) {
            calHubBrandView
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
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
                }

                Button {
                    leaveDaySelectionModeAndOpen(onOpenPDFList)
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(ToolbarIconButtonStyleD())
                .accessibilityLabel(ShiftHubLocalization.string("履歴", locale: locale))

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
        CalendarDestinationSelector(
            selection: destination,
            showsCalendarIcon: true,
            isPresented: $isCalendarDestinationMenuPresented,
            rendersOverlay: false,
            buttonMinimumWidth: nil,
            buttonHeight: Self.calendarControlHeight,
            onOpen: { isYearMonthPickerPresented = false },
            onSelect: onCalendarDestinationChange
        )
        .anchorPreference(key: CalendarOverlayAnchorKey.self, value: .bounds) {
            CalendarOverlayAnchors(destination: $0)
        }
    }

    private var newEventButton: some View {
        Button {
            presentDateTimeEventRegistration()
        } label: {
            Image(systemName: "plus")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("イベントを登録"))
#if os(macOS)
        .help(localized("イベントを登録"))
#endif
    }

    private var calHubBrandView: some View {
        HStack(spacing: 6) {
            calHubLogoView

            Text("Cal Hub")
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var calHubLogoView: some View {
        Image("CalHub-clear")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(colorScheme == .dark ? .white : .black)
            .frame(width: 24, height: 24)
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
        .contentShape(Rectangle())
        .onTapGesture {
            jumpToToday()
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(locale.identifier.hasPrefix("en") ? "Go to today" : "今日へ移動")
        .accessibilityAction {
            jumpToToday()
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
                return "Apple Calendar"
            case .google:
                return "Google Calendar"
            case .notion:
                return "Notion database"
            }
        }

        switch destination {
        case .apple:
            return "Appleカレンダー"
        case .google:
            return "Googleカレンダー"
        case .notion:
            return "Notion database"
        }
    }

    private var eventMonthTitle: String {
        if calendarDisplayMode == .year {
            return String(selectedYear)
        }
        let displayYearMonth: YearMonth
        if calendarDisplayMode == .month {
            let pageID = monthPageID ?? pageID(for: model.yearMonth) ?? Self.monthPageRadius
            displayYearMonth = monthForPageID(pageID)
        } else {
            displayYearMonth = model.yearMonth
        }
        if locale.identifier.hasPrefix("en") {
            return displayYearMonth.displayText(for: locale)
        }

        return String(format: "%04d-%02d", displayYearMonth.year, displayYearMonth.month)
    }

    private var calendarBaseHorizontalInset: CGFloat {
#if os(iOS)
        return 12
#else
        return 24
#endif
    }

    @ViewBuilder
    private var calendarDisplayContent: some View {
        VStack(spacing: 0) {
            if calendarDisplayMode != .year {
                eventWeekdayHeader(columns: eventCalendarColumns)
                    .padding(.leading, calendarBaseHorizontalInset + weekContentInset)
                    .padding(.trailing, calendarBaseHorizontalInset)
            }

            if calendarDisplayMode == .month {
                eventCalendarView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if calendarDisplayMode == .week {
                GeometryReader { geometry in
                    let cardHeight = eventCalendarCardHeight(
                        availableHeight: geometry.size.height
                    )
                    let cardAreaHeight = weekCalendarHeight(for: cardHeight)
                    let timelineHeight = max(0, geometry.size.height - cardAreaHeight)

                    weekCalendarView(
                        cardHeight: cardHeight,
                        timelineHeight: timelineHeight
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            } else {
                yearCalendarView
            }
        }
        .animation(.easeInOut(duration: 0.25), value: weekContentInset)
    }

    private var yearCalendarView: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach((yearPageAnchor - 100)...(yearPageAnchor + 100), id: \.self) { year in
                        yearCalendarPage(year: year, height: geometry.size.height)
                            .frame(width: geometry.size.width)
                            .id(year)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
            .scrollPosition(id: $yearPageID)
            .onChange(of: yearPageID) { _, pageID in
                guard let pageID,
                      pageID != selectedYear else { return }
                selectedYear = pageID
            }
            .onScrollPhaseChange { _, phase in
                guard phase == .idle else {
                    if isYearButtonNavigationActive {
                        didObserveYearButtonScroll = true
                    }
                    return
                }
                if isYearButtonNavigationActive {
                    guard didObserveYearButtonScroll else { return }
                    didObserveYearButtonScroll = false
                    guard queuedYearNavigationSteps == 0 else {
                        advanceQueuedYearNavigation()
                        return
                    }
                    isYearButtonNavigationActive = false
                }
                guard let settledYear = yearPageID,
                      settledYear != selectedYear else { return }
                selectedYear = settledYear
            }
        }
    }

    private func yearCalendarPage(year: Int, height: CGFloat) -> some View {
        let cardSpacing: CGFloat = 5
        let cardHeight = max(76, (height - 16 - cardSpacing * 3) / 4)
        return VStack(spacing: cardSpacing) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: cardSpacing) {
                    ForEach(1...3, id: \.self) { column in
                        let month = row * 3 + column
                        yearMonthCard(
                            YearMonth(year: year, month: month),
                            height: cardHeight
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: cardHeight)
            }
        }
        .padding(.horizontal, calendarBaseHorizontalInset)
        .padding(.vertical, 8)
        .frame(height: height, alignment: .center)
    }

    private func yearMonthCard(_ yearMonth: YearMonth, height: CGFloat) -> some View {
        let events = yearEventsByYear[yearMonth.year]?[yearMonth] ?? []
        let days = yearMonthCalendarDays(yearMonth)
        let eventSignature = events.hashValue
        let markerCacheKey = CalendarLayoutCacheKey(
            kind: .yearMarkers,
            pageDate: calendarDate(yearMonth: yearMonth, day: 1),
            eventSignature: eventSignature
        )
        let markerColors = calendarEventLayoutCache.yearMarkerColors(for: markerCacheKey) {
            yearEventMarkerColors(for: yearMonth, events: events)
        }
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dateCellHeight = max(10, (height - 23) / 6)
        let monthText = locale.identifier.hasPrefix("en")
            ? yearMonth.monthName(for: locale)
            : "\(yearMonth.month)"

        let card = Button {
            selectYearMonth(yearMonth)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(monthText)
#if os(macOS)
                    .font(.system(size: 23, weight: .semibold))
                    .padding(.leading, 4)
                    .padding(.top, 6)
#else
                    .font(.system(size: 18, weight: .semibold))
#endif
                    .foregroundStyle(
                        today.year == yearMonth.year && today.month == yearMonth.month
                            ? .red
                            : .primary
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Canvas { context, size in
                    let cellWidth = size.width / 7
#if os(macOS)
                    let markerSize = min(4, max(1.5, min(dateCellHeight * 0.17, cellWidth * 0.12)))
                    let markerBottomInset = min(2, dateCellHeight * 0.12)
                    let dateLabelGap = min(1.0, dateCellHeight * 0.05)
                    let dateLabelAreaHeight = max(
                        8,
                        dateCellHeight - markerSize - markerBottomInset - dateLabelGap
                    )
                    let dateLabelSize = min(12, dateLabelAreaHeight * 0.9)
                    let dateLabelCenterOffset = min(dateCellHeight * 0.3, dateLabelSize * 0.65)
                    let markerTopOffset = dateLabelCenterOffset + dateLabelSize * 0.55 + dateLabelGap
#else
                    let markerSize: CGFloat = 2
                    let markerBottomInset: CGFloat = 1
                    let dateLabelSize: CGFloat = 8
                    let dateLabelCenterOffset = (dateCellHeight - 2) / 2
                    let markerTopOffset = dateCellHeight - markerSize - markerBottomInset
#endif
                    let todayNumber = today.year == yearMonth.year && today.month == yearMonth.month
                        ? today.day
                        : nil

                    for (slot, day) in days.enumerated() {
                        guard let day else { continue }
                        let column = slot % 7
                        let row = slot / 7
                        let cellTop = CGFloat(row) * dateCellHeight
                        let cellCenterX = (CGFloat(column) + 0.5) * cellWidth

                        let label = Text("\(day)")
#if os(macOS)
                            .font(.system(size: dateLabelSize, weight: .regular, design: .rounded))
#else
                            .font(.system(size: 8, weight: .regular, design: .rounded))
#endif
                            .foregroundColor(todayNumber == day ? .red : .primary)
                        context.draw(
                            label,
                            at: CGPoint(x: cellCenterX, y: cellTop + dateLabelCenterOffset),
                            anchor: .center
                        )

                        if let color = markerColors[day] {
                            let markerRect = CGRect(
                                x: cellCenterX - markerSize / 2,
                                y: cellTop + markerTopOffset,
                                width: markerSize,
                                height: markerSize
                            )
                            context.fill(Path(ellipseIn: markerRect), with: .color(color))
                        }
                    }
                }
                .frame(height: dateCellHeight * 6)
            }
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .frame(height: height)
        .background(calendarCardBackground, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(yearMonth.displayText(for: locale))
        return card
    }

    private func yearEventMarkerColors(
        for yearMonth: YearMonth,
        events: [CalendarEventRecord]
    ) -> [Int: Color] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let monthStart = calendar.date(from: DateComponents(
            year: yearMonth.year,
            month: yearMonth.month,
            day: 1
        )),
        let monthEnd = calendar.date(byAdding: .day, value: yearMonth.numberOfDays - 1, to: monthStart) else {
            return [:]
        }

        var markerColors: [Int: Color] = [:]
        for event in events {
            let firstDay: Int
            let lastDay: Int

            if let startDate = event.startDate {
                let start = calendar.startOfDay(for: startDate)
                let end = calendar.startOfDay(for: event.endDate ?? startDate)
                guard end >= start, end >= monthStart, start <= monthEnd else { continue }

                firstDay = calendar.component(.day, from: max(start, monthStart))
                lastDay = calendar.component(.day, from: min(end, monthEnd))
            } else {
                firstDay = event.day
                lastDay = event.day
            }

            guard firstDay > 0, lastDay <= yearMonth.numberOfDays, firstDay <= lastDay else {
                continue
            }
            for day in firstDay...lastDay where markerColors[day] == nil {
                markerColors[day] = yearMarkerColor(for: event)
            }
        }
        return markerColors
    }

    private func yearMonthCalendarDays(_ yearMonth: YearMonth) -> [Int?] {
        let days: [Int?] = Array(repeating: nil, count: yearMonth.leadingBlankCount)
            + (1...yearMonth.numberOfDays).map { Optional($0) }
        return days + Array(repeating: nil, count: 42 - days.count)
    }

    private func calendarDate(yearMonth: YearMonth, day: Int) -> Date {
        Calendar.current.date(from: DateComponents(
            year: yearMonth.year,
            month: yearMonth.month,
            day: day
        )) ?? .now
    }

    private func yearMarkerColor(for event: CalendarEventRecord) -> Color {
        event.isRestEvent ? .red : event.calendarColor?.color ?? .accentColor
    }

    private func selectYearMonth(_ yearMonth: YearMonth) {
        selectedYear = yearMonth.year
        selectedMonth = yearMonth.month
        calendarFocusDate = calendarDate(yearMonth: yearMonth, day: 1)
        yearModeReturnFocusDate = nil
        pendingMonthPageID = nil
        model.updateYearMonth(yearMonth)
        model.load()
        monthPageAnchor = yearMonth
        monthPageID = Self.monthPageRadius
        calendarDisplayMode = .month
    }

    private var displayedYearFooterTitle: String {
        locale.identifier.hasPrefix("en") ? String(selectedYear) : "\(selectedYear)年"
    }

    private var yearFooterMessage: String {
        if isLoadingYearEvents {
            return locale.identifier.hasPrefix("en") ? "Loading events..." : "イベントを取得中です..."
        }
        let count = displayedYearEvents.values.reduce(0) { $0 + $1.count }
        return locale.identifier.hasPrefix("en")
            ? "\(count) events retrieved."
            : "\(count)件のイベントを取得しました。"
    }

    private func moveYear(by offset: Int) {
        queuedYearNavigationSteps += offset
        guard !isYearButtonNavigationActive else { return }
        isYearButtonNavigationActive = true
        advanceQueuedYearNavigation()
    }

    private func advanceQueuedYearNavigation() {
        guard queuedYearNavigationSteps != 0 else { return }
        let step = queuedYearNavigationSteps > 0 ? 1 : -1
        queuedYearNavigationSteps -= step
        didObserveYearButtonScroll = false
        let fromYear = yearPageID ?? selectedYear
        withAnimation(.easeInOut(duration: 0.3)) {
            yearPageID = fromYear + step
        }
    }

    private func refreshDisplayedCalendar() {
        if calendarDisplayMode == .year {
            shouldForceRefreshYearEvents = true
            isLoadingYearEvents = true
            yearEventRefreshID += 1
            return
        }

        let months = cacheMonthsForCurrentDisplay
        isRefreshingVisibleMonths = true
        Task { @MainActor in
            _ = await model.refreshCachedMonths(for: months)
            isRefreshingVisibleMonths = false
        }
    }

    private func footerSummary(title: String, message: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(verbatim: title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            Text(verbatim: message)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
    }

    private func eventCalendarCardHeight(availableHeight: CGFloat) -> CGFloat {
#if os(iOS)
        let gridSpacing: CGFloat = 5
        let rowCount = 6
        let verticalInsets: CGFloat = 8
        let fittedCardHeight = (
            availableHeight
                - verticalInsets
                - CGFloat(max(rowCount - 1, 0)) * gridSpacing
        ) / CGFloat(max(rowCount, 1))
        return min(80, max(52, fittedCardHeight))
#else
        let gridSpacing: CGFloat = 8
        let rowCount = 6
        let verticalInsets: CGFloat = 16
        let fittedCardHeight = (
            availableHeight
                - verticalInsets
                - CGFloat(max(rowCount - 1, 0)) * gridSpacing
        ) / CGFloat(rowCount)
        return max(52, fittedCardHeight)
#endif
    }

    private func weekCalendarHeight(for cardHeight: CGFloat) -> CGFloat {
        let timelineGap: CGFloat = 5
#if os(iOS)
        return cardHeight + 5 + timelineGap
#else
        return cardHeight + 13 + timelineGap
#endif
    }

    private func weekCalendarView(cardHeight: CGFloat, timelineHeight: CGFloat) -> some View {
        GeometryReader { geometry in
            let weekPages = calendarWeekPages(for: model.yearMonth)
            let weekCount = max(1, weekPages.count)
            let pageEvents = calendarPageEvents(for: model.yearMonth, events: model.events)
            let leadingInset = calendarBaseHorizontalInset + weekContentInset
            let trailingInset = calendarBaseHorizontalInset

            ZStack(alignment: .topLeading) {
                weekTimelineHourLabels(height: timelineHeight)
                    .offset(y: weekCalendarHeight(for: cardHeight))
                    .zIndex(0)

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(0..<weekCount, id: \.self) { weekIndex in
                            let weekDates = weekPages[weekIndex]
                            let weekEvents = weekPageEvents(
                                for: weekDates,
                                events: pageEvents
                            )
                            VStack(spacing: 0) {
                                weekCalendarPage(
                                    dates: weekDates,
                                    events: weekEvents,
                                    availableWidth: geometry.size.width,
                                    cardHeight: cardHeight,
                                    leadingInset: leadingInset,
                                    trailingInset: trailingInset
                                )
                                .frame(
                                    height: weekCalendarHeight(for: cardHeight),
                                    alignment: .top
                                )

                                weekTimelineView(
                                    dates: weekDates,
                                    events: weekEvents,
                                    availableWidth: geometry.size.width,
                                    height: timelineHeight,
                                    leadingInset: leadingInset,
                                    trailingInset: trailingInset
                                )
                                .frame(height: timelineHeight, alignment: .top)
                            }
                            // Give every page an explicit viewport width. Relying on
                            // containerRelativeFrame here can initially measure a
                            // page from its content width, leaving only the first
                            // columns visible until a drag forces a re-layout.
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height,
                                alignment: .top
                            )
                            .id(weekDates.first?.date ?? Date.distantPast)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
                .scrollPosition(id: $weekPageID)
                .zIndex(1)
            }
        }
#if os(iOS)
        .sheet(item: $selectedBandEventForActions) { selection in
            CalHubDateActionSheetContainer {
                eventActionsPopover(
                    for: selection.event,
                    day: selection.day,
                    yearMonth: selection.yearMonth
                )
            }
                .presentationDragIndicator(.visible)
        }
#endif
    }

    private func weekTimelineHourLabels(height: CGFloat) -> some View {
        let edgeInset: CGFloat = 5
#if os(macOS)
        let labelCenterX: CGFloat = 25
#else
        let labelCenterX: CGFloat = 25
#endif

        return ZStack(alignment: .topLeading) {
            ForEach(0...24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.65))
                    .frame(width: 34, alignment: .leading)
                    .position(
                        x: labelCenterX,
                        y: edgeInset
                            + max(0, height - edgeInset * 2) * CGFloat(hour) / 24
                    )
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: height,
            maxHeight: height,
            alignment: .topLeading
        )
        .allowsHitTesting(false)
    }

    private func weekTimelineView(
        dates: [CalendarGridDate],
        events: [CalendarEventRecord],
        availableWidth: CGFloat,
        height: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat
    ) -> some View {
        let yearMonth = dates.first?.yearMonth ?? model.yearMonth
#if os(iOS)
        let columnSpacing: CGFloat = 4
#else
        let columnSpacing: CGFloat = 8
#endif
        let columnWidth = max(
            0,
            (availableWidth - leadingInset - trailingInset - CGFloat(6) * columnSpacing) / 7
        )
        let laneSpacing: CGFloat = 3
        let laneAreaWidth = max(0, columnWidth - 8)
        let cacheKey = CalendarLayoutCacheKey(
            kind: .weekTimeline,
            pageDate: dates.first?.date ?? Date.distantPast,
            eventSignature: events.hashValue
        )
        let timedLayoutResult = measureCalendarRendering(
            "WeekTimelineSegments",
            details: "days=\(dates.count) events=\(events.count)"
        ) {
            calendarEventLayoutCache.timedLayouts(for: cacheKey) {
                calendarTimedEventLayouts(
                    for: dates,
                    events: events
                )
            }
        }
        let timedLayouts = timedLayoutResult.layouts

        return ZStack(alignment: .topLeading) {
            HStack(spacing: columnSpacing) {
                ForEach(Array(dates.enumerated()), id: \.element.id) { _, gridDate in
                    ZStack(alignment: .topLeading) {
                        ForEach(timedLayouts.filter { $0.segment.gridDate.id == gridDate.id }) { layout in
                            let segment = layout.segment
                            let duration = CGFloat(segment.endMinute - segment.startMinute)
                            let bandHeight = max(6, height * duration / 1440)
                            let laneWidth = max(
                                0,
                                (laneAreaWidth
                                    - CGFloat(max(0, layout.laneCount - 1)) * laneSpacing)
                                    / CGFloat(max(1, layout.laneCount))
                            )
                            let eventColor = segment.event.isRestEvent
                                ? Color.red
                                : segment.event.calendarColor?.color ?? Color.accentColor

                            Button {
#if os(macOS)
                                handleTimelineEventTap(
                                    event: segment.event,
                                    yearMonth: gridDate.yearMonth,
                                    day: gridDate.day
                                )
#else
                                handleEventBandTap(
                                    event: segment.event,
                                    yearMonth: gridDate.yearMonth,
                                    day: gridDate.day
                                )
#endif
                            } label: {
                                CalendarTimelineSegmentShape(
                                    squareTop: segment.continuesFromPreviousDay,
                                    squareBottom: segment.continuesIntoNextDay
                                )
                                .fill(eventColor.opacity(0.25))
                            }
                            .buttonStyle(.plain)
                            .frame(width: laneWidth, height: bandHeight)
                            .position(
                                x: 4
                                    + laneWidth / 2
                                    + CGFloat(layout.lane) * (laneWidth + laneSpacing),
                                y: height * CGFloat(segment.startMinute) / 1440 + bandHeight / 2
                            )
#if os(macOS)
                            .allowsHitTesting(!isBandPopoverPresented)
#endif
                        }

                        if let overflowCount = timedLayoutResult.overflowCounts[gridDate.id],
                           overflowCount > 0 {
                            Text("\(overflowCount)件")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(.background.opacity(0.8), in: Capsule())
                                .padding(3)
                                .frame(
                                    maxWidth: .infinity,
                                    maxHeight: .infinity,
                                    alignment: .topTrailing
                                )
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: columnWidth, height: height, alignment: .topLeading)
                }
            }
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
        }
        .frame(width: availableWidth, alignment: .topLeading)
    }

    private func calendarTimedEventSegments(
        for dates: [CalendarGridDate],
        events: [CalendarEventRecord]
    ) -> [CalendarTimedEventSegment] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        return dates.flatMap { (gridDate: CalendarGridDate) -> [CalendarTimedEventSegment] in
            let dayStart = calendar.startOfDay(for: gridDate.date)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                return []
            }

            return events.compactMap { event in
                // Render all-day events as full-day timeline bands so they
                // still participate in the same lane layout as timed events.
                guard let eventStart = event.startDate else {
                    return nil
                }

                let eventEnd: Date
                let eventStartDay = calendar.startOfDay(for: eventStart)
                let eventEndDay = calendar.startOfDay(
                    for: event.endDate ?? eventStart
                )
                if event.isAllDay {
                    let allDayStart = eventStartDay
                    let allDayEnd = event.endDate.flatMap { endDate in
                        calendar.date(
                            byAdding: .day,
                            value: 1,
                            to: calendar.startOfDay(for: endDate)
                        )
                    } ?? calendar.date(byAdding: .day, value: 1, to: allDayStart)
                    eventEnd = allDayEnd ?? dayEnd
                } else {
                    let fallbackEnd = calendar.date(byAdding: .hour, value: 1, to: eventStart)
                        ?? eventStart
                    eventEnd = max(event.endDate ?? fallbackEnd, eventStart)
                }
                let overlapStart = max(eventStart, dayStart)
                let overlapEnd = min(eventEnd, dayEnd)
                guard overlapStart < overlapEnd else { return nil }

                let startComponents = calendar.dateComponents(
                    [.hour, .minute],
                    from: overlapStart
                )
                let rawStartMinute = (startComponents.hour ?? 0) * 60
                    + (startComponents.minute ?? 0)
                let rawEndMinute: Int
                if calendar.isDate(overlapEnd, inSameDayAs: dayStart) {
                    let endComponents = calendar.dateComponents(
                        [.hour, .minute],
                        from: overlapEnd
                    )
                    rawEndMinute = (endComponents.hour ?? 0) * 60
                        + (endComponents.minute ?? 0)
                } else {
                    rawEndMinute = 1440
                }

                let startMinute = min(1430, max(0, (rawStartMinute / 10) * 10))
                let endMinute = min(
                    1440,
                    max(startMinute + 10, ((rawEndMinute + 9) / 10) * 10)
                )
                return CalendarTimedEventSegment(
                    event: event,
                    gridDate: gridDate,
                    startMinute: startMinute,
                    endMinute: endMinute,
                    continuesFromPreviousDay: eventStartDay < dayStart,
                    continuesIntoNextDay: eventEndDay > dayStart
                )
            }
        }
    }

    private func calendarTimedEventLayouts(
        for dates: [CalendarGridDate],
        events: [CalendarEventRecord]
    ) -> CalendarTimedEventLayoutResult {
        let segments = calendarTimedEventSegments(for: dates, events: events)
        var layouts: [CalendarTimedEventLayout] = []
        var overflowCounts: [Date: Int] = [:]

        for gridDate in dates {
            let daySegments = segments
                .filter { $0.gridDate.id == gridDate.id }
                .sorted {
                    if $0.startMinute != $1.startMinute {
                        return $0.startMinute < $1.startMinute
                    }
                    if $0.endMinute != $1.endMinute {
                        return $0.endMinute > $1.endMinute
                    }
                    return $0.event.id < $1.event.id
                }

            var cluster: [CalendarTimedEventSegment] = []
            var clusterEnd = -1

            func flushCluster() {
                guard !cluster.isEmpty else { return }

                var laneEndMinutes: [Int] = []
                var assignments: [(segment: CalendarTimedEventSegment, lane: Int)] = []

                for segment in cluster {
                    if let lane = laneEndMinutes.firstIndex(where: {
                        $0 <= segment.startMinute
                    }) {
                        laneEndMinutes[lane] = segment.endMinute
                        assignments.append((segment, lane))
                    } else {
                        laneEndMinutes.append(segment.endMinute)
                        assignments.append((segment, laneEndMinutes.count - 1))
                    }
                }

                let laneCount = laneEndMinutes.count
                let visibleLaneCount = min(3, laneCount)
                for assignment in assignments {
                    if assignment.lane < visibleLaneCount {
                        layouts.append(CalendarTimedEventLayout(
                            segment: assignment.segment,
                            lane: assignment.lane,
                            laneCount: visibleLaneCount
                        ))
                    } else {
                        overflowCounts[gridDate.id, default: 0] += 1
                    }
                }

                cluster.removeAll(keepingCapacity: true)
                clusterEnd = -1
            }

            for segment in daySegments {
                if !cluster.isEmpty, segment.startMinute >= clusterEnd {
                    flushCluster()
                }
                cluster.append(segment)
                clusterEnd = max(clusterEnd, segment.endMinute)
            }
            flushCluster()
        }

        return CalendarTimedEventLayoutResult(
            layouts: layouts,
            overflowCounts: overflowCounts
        )
    }

    private func weekCalendarPage(
        dates: [CalendarGridDate],
        events: [CalendarEventRecord],
        availableWidth: CGFloat,
        cardHeight: CGFloat,
        leadingInset: CGFloat,
        trailingInset: CGFloat
    ) -> some View {
        let yearMonth = dates.first?.yearMonth ?? model.yearMonth
        let pageDate = dates.first?.date ?? Date.distantPast
        let eventSignature = events.hashValue
        let segmentCacheKey = CalendarLayoutCacheKey(
            kind: .weekSegments,
            pageDate: pageDate,
            eventSignature: eventSignature
        )
        let displaySegments = measureCalendarRendering(
            "WeekEventSegments",
            details: "days=\(dates.count) events=\(events.count)"
        ) {
            calendarEventLayoutCache.displaySegments(for: segmentCacheKey) {
                eventDisplaySegments(events: events, gridDates: dates)
            }
        }
        let bandCacheKey = CalendarLayoutCacheKey(
            kind: .weekBands,
            pageDate: pageDate,
            eventSignature: eventSignature
        )
        let bandLayouts = measureCalendarRendering(
            "WeekEventBandLayouts",
            details: "segments=\(displaySegments.count) events=\(events.count)"
        ) {
            calendarEventLayoutCache.bandLayouts(for: bandCacheKey) {
                eventBandLayouts(
                    events: events,
                    segments: displaySegments,
                    gridDates: dates
                )
            }
        }
#if os(iOS)
        let gridSpacing: CGFloat = 0
        let columnSpacing: CGFloat = 4
#else
        let gridSpacing: CGFloat = 0
        let columnSpacing: CGFloat = 8
        let bandTitleFontSize = min(11, max(5, calendarEventBandMetrics(cardHeight: cardHeight).height * 0.9))
#endif
        let bandMetrics = calendarEventBandMetrics(cardHeight: cardHeight)
        let columnWidth = max(
            0,
            (availableWidth - leadingInset - trailingInset - CGFloat(6) * columnSpacing) / 7
        )

        return ZStack(alignment: .topLeading) {
            LazyVGrid(columns: eventCalendarColumns, spacing: gridSpacing) {
                ForEach(dates) { gridDate in
                    eventDayCell(
                        gridDate: gridDate,
                        events: events,
                        segments: displaySegments,
                        isInteractive: true,
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
                        // Use the compact cell content only when the overlay
                        // has no renderable bands. This keeps week mode useful
                        // for legacy/month-only records that cannot produce a
                        // band layout, without duplicating visible events.
                        hideEventContent: !bandLayouts.isEmpty,
                        isWeekModeCard: true,
                        dimsOutOfDisplayedMonth: false
                    )
                }
            }

            ForEach(bandLayouts.filter { $0.lane < 3 }) { layout in
                let column = layout.startDay % 7
#if os(iOS)
                let bandInset: CGFloat = 3
#else
                let bandInset: CGFloat = 6
#endif
                let cornerStyle = eventBandCornerStyle(
                    for: layout,
                    segments: displaySegments,
                    gridDates: dates
                )
                let leadingExtension = cornerStyle.squareLeading
                    ? bandInset + columnSpacing / 2
                    : 0
                let trailingExtension = cornerStyle.squareTrailing
                    ? bandInset + columnSpacing / 2
                    : 0
                let bandWidth = max(
                    0,
                    columnWidth * CGFloat(layout.spanDays)
                        + columnSpacing * CGFloat(layout.spanDays - 1)
                        - bandInset * 2
                        + leadingExtension
                        + trailingExtension
                )
                let eventColor = layout.event.isRestEvent
                    ? Color.red
                    : layout.event.calendarColor?.color ?? Color.accentColor
                let bandStartDate = dates.first { $0.slot == layout.startDay }
                let bandTitleOpacity = 1.0

                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Text(layout.event.title)
#if os(iOS)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
#else
                            .font(.system(size: bandTitleFontSize, weight: .medium))
                            .lineLimit(1)
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
                                        gridDates: dates
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
                                gridDates: dates
                            )
                        ) {
                            bandEventActionsPopover(
                                for: layout.event,
                                day: (selectedBandEventForActions ?? selectedTimelineEventForActions)?.day
                                    ?? bandStartDate?.day
                                    ?? 1,
                                yearMonth: (selectedBandEventForActions ?? selectedTimelineEventForActions)?.yearMonth
                                    ?? bandStartDate?.yearMonth
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
                                gridDates: dates,
                                dimsOutOfDisplayedMonth: false
                            )
                        )
                }
                .position(
                    x: CGFloat(column) * (columnWidth + columnSpacing)
                        + bandInset - leadingExtension + bandWidth / 2,
                    y: bandMetrics.top
                        + CGFloat(layout.lane) * bandMetrics.laneHeight
                        + bandMetrics.height / 2
                )
                .opacity(eventBandRevealOpacity(
                    for: yearMonth,
                    slot: layout.startDay,
                    gridDates: dates
                ))
                .zIndex(2)
                .allowsHitTesting(
                    !isDaySelectionMode
                        && !model.isDeleting
                        && !isBandPopoverPresented
                )
            }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
#if os(iOS)
        .padding(.vertical, 4)
#else
        .padding(.vertical, 8)
#endif
        .frame(width: availableWidth, alignment: .topLeading)
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
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.75)
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
#if os(iOS)
        monthNavigationButtons(
            buttonWidth: min(30, max(22, calendarHeaderWidth * 0.07)),
            spacing: min(8, max(0, (calendarHeaderWidth - 343) * 0.12))
        )
        .layoutPriority(-1)
#else
        monthNavigationButtons(buttonWidth: 34, spacing: 12)
#endif
    }

    private func monthNavigationButtons(buttonWidth: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Button {
                isYearMonthPickerPresented = false
                if calendarDisplayMode == .week {
                    moveWeek(by: -1)
                } else if calendarDisplayMode == .year {
                    moveYear(by: -1)
                } else {
                    moveMonth(by: -1)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: buttonWidth, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(
                locale.identifier.hasPrefix("en")
                    ? (calendarDisplayMode == .week ? "Previous week" : calendarDisplayMode == .year ? "Previous year" : "Previous month")
                    : (calendarDisplayMode == .week ? "前の週" : calendarDisplayMode == .year ? "前年" : "前の月")
            )

            Button {
                isYearMonthPickerPresented = false
                if calendarDisplayMode == .week {
                    moveWeek(by: 1)
                } else if calendarDisplayMode == .year {
                    moveYear(by: 1)
                } else {
                    moveMonth(by: 1)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .frame(width: buttonWidth, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(
                locale.identifier.hasPrefix("en")
                    ? (calendarDisplayMode == .week ? "Next week" : calendarDisplayMode == .year ? "Next year" : "Next month")
                    : (calendarDisplayMode == .week ? "次の週" : calendarDisplayMode == .year ? "次年" : "次の月")
            )
        }
    }

    private var calendarDisplayModeSelector: some View {
        CalHubSegmentedControl(
            options: calendarDisplayModeOptions,
            selection: calendarDisplayModeSelection,
            systemImages: ["12.calendar", "31.calendar", "7.calendar"]
        )
        .frame(width: calendarDisplayModeControlWidth)
        .accessibilityLabel(locale.identifier.hasPrefix("en") ? "Calendar view" : "カレンダー表示")
    }

    private var calendarDisplayModeOptions: [String] {
        locale.identifier.hasPrefix("en") ? ["Year", "Month", "Week"] : ["年", "月", "週"]
    }

    private var calendarDisplayModeControlWidth: CGFloat {
#if os(iOS)
        min(124, max(120, calendarHeaderWidth * 0.30))
#else
        108
#endif
    }

    private var calendarDisplayModeSelection: Binding<String> {
        Binding(
            get: {
                switch calendarDisplayMode {
                case .year: return calendarDisplayModeOptions[0]
                case .month: return calendarDisplayModeOptions[1]
                case .week: return calendarDisplayModeOptions[2]
                }
            },
            set: { value in
                if value == calendarDisplayModeOptions[0] {
                    setCalendarDisplayMode(.year)
                } else if value == calendarDisplayModeOptions[2] {
                    setCalendarDisplayMode(.week)
                } else {
                    setCalendarDisplayMode(.month)
                }
            }
        )
    }

    private func setCalendarDisplayMode(_ mode: CalendarDisplayMode) {
        if calendarDisplayMode == .week {
            let day = Calendar.current.component(.day, from: calendarFocusDate)
            calendarFocusDate = calendarDate(
                yearMonth: model.yearMonth,
                day: min(day, model.yearMonth.numberOfDays)
            )
        }

        if calendarDisplayMode == .year,
           mode != .year,
           let yearModeReturnFocusDate {
            calendarFocusDate = yearModeReturnFocusDate
        }

        let components = Calendar.current.dateComponents([.year, .month], from: calendarFocusDate)
        guard let year = components.year,
              let month = components.month else {
            calendarDisplayMode = mode
            return
        }

        let targetMonth = YearMonth(year: year, month: month)
        if mode == .year {
            if calendarDisplayMode != .year {
                yearModeReturnFocusDate = calendarFocusDate
            }
            selectedYear = year
            selectedMonth = month
            yearPageID = year
        } else {
            yearModeReturnFocusDate = nil
            if mode == .week {
                pendingWeekMonthAnchorDate = calendarFocusDate
            } else {
                pendingWeekMonthAnchorDate = nil
                if let pageID = pageID(for: targetMonth) {
                    monthPageID = pageID
                } else {
                    monthPageAnchor = targetMonth
                    monthPageID = Self.monthPageRadius
                }
            }

            selectedYear = targetMonth.year
            selectedMonth = targetMonth.month
            if model.yearMonth != targetMonth {
                model.updateYearMonth(targetMonth)
                model.load()
            }
        }

        calendarDisplayMode = mode
    }

    private func dateByReplacingYear(of date: Date, with year: Int) -> Date {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let month = components.month,
              let day = components.day else {
            return date
        }

        let yearMonth = YearMonth(year: year, month: month)
        return calendarDate(yearMonth: yearMonth, day: min(day, yearMonth.numberOfDays))
    }

    private func moveMonth(by offset: Int) {
        let target = model.yearMonth.addingMonths(offset)
        moveMonth(to: target, animated: true)
    }

    private func moveWeek(by offset: Int) {
        guard calendarDisplayMode == .week,
              !isRebuildingWeekPages else {
            return
        }

        let pages = calendarWeekPages(for: model.yearMonth)
        guard !pages.isEmpty else { return }

        let currentIndex = weekPageID.flatMap { pageID in
            pages.firstIndex { $0.first?.date == pageID }
        } ?? pages.firstIndex { page in
            page.contains { $0.yearMonth == model.yearMonth }
        } ?? 0
        let targetIndex = currentIndex + offset
        guard pages.indices.contains(targetIndex),
              let targetPageID = pages[targetIndex].first?.date else {
            return
        }

        // Let the normal page-change handler perform month-boundary loading.
        programmaticWeekPageID = nil
        withAnimation(.easeInOut(duration: 0.25)) {
            weekPageID = targetPageID
        }
    }

    private func jumpToToday() {
        let today = Date()
        let targetMonth = YearMonth.current
        calendarFocusDate = today
        if calendarDisplayMode == .year {
            yearModeReturnFocusDate = today
        }
        isYearMonthPickerPresented = false
        isCalendarDestinationMenuPresented = false

        if calendarDisplayMode == .year {
            withAnimation(.easeInOut(duration: 0.25)) {
                yearPageID = targetMonth.year
            }
            return
        }

        if calendarDisplayMode == .week {
            pendingWeekMonthAnchorDate = targetMonth == model.yearMonth ? nil : today

            if targetMonth == model.yearMonth {
                scheduleWeekPageRebuild(anchorDate: today)
            } else {
                moveMonth(to: targetMonth)
            }
            return
        }

        if targetMonth != model.yearMonth {
            moveMonth(to: targetMonth)
        }
    }

    private func weekModeEntryAnchorDate() -> Date? {
        calendarFocusDate
    }

    private func weekPagingDebug(_ message: String) {
        calendarWeekPagingLogger.debug("\(message, privacy: .public)")
    }

    private func weekPagingNotice(_ message: String) {
        calendarWeekPagingLogger.notice("\(message, privacy: .public)")
    }

    private func weekPagingError(_ message: String) {
        calendarWeekPagingLogger.error("\(message, privacy: .public)")
    }

    private func handleWeekPageChange(from oldPageID: Date?, to newPageID: Date?) {
        guard calendarDisplayMode == .week else { return }
        guard let oldPageID,
              let newPageID else {
            return
        }
        guard oldPageID != newPageID else { return }

        weekPagingDebug(
            "page change old=\(String(describing: oldPageID)) new=\(String(describing: newPageID)) "
                + "month=\(model.yearMonth.year)-\(model.yearMonth.month) "
                + "rebuilding=\(isRebuildingWeekPages) "
                + "pending=\(String(describing: pendingWeekMonthAnchorDate)) "
                + "programmatic=\(String(describing: programmaticWeekPageID))"
        )
        logCalendarRenderingEvent(
            "WeekPageChange",
            details: "events=\(model.events.count) rebuilding=\(isRebuildingWeekPages)"
        )

        guard !isRebuildingWeekPages else {
            weekPagingDebug("ignored page change while rebuilding pages")
            return
        }

        if let programmaticWeekPageID {
            guard newPageID == programmaticWeekPageID else {
                weekPagingError(
                    "programmatic target missed target=\(String(describing: programmaticWeekPageID)) "
                        + "received=\(String(describing: newPageID)); clearing target"
                )
                self.programmaticWeekPageID = nil
                return
            }
            weekPagingDebug("accepted programmatic page target")
            self.programmaticWeekPageID = nil
            return
        }

        // Ignore additional scroll-position notifications while the month boundary
        // transition is being committed. They can otherwise trigger multiple jumps.
        guard pendingWeekMonthAnchorDate == nil else { return }

        let weekPages = calendarWeekPages(for: model.yearMonth)
        guard let oldIndex = weekPages.firstIndex(where: {
                  $0.first?.date == oldPageID
              }),
              let newIndex = weekPages.firstIndex(where: {
                  $0.first?.date == newPageID
              }) else {
            weekPagingError(
                "page ID not found old=\(String(describing: oldPageID)) "
                    + "new=\(String(describing: newPageID)) "
                    + "available=\(weekPages.map { String(describing: $0.first?.date) }.joined(separator: ","))"
            )
            return
        }

        let visibleDates = weekPages[newIndex]
        let nextMonth = model.yearMonth.nextMonth
        let previousMonth = model.yearMonth.previousMonth
        let containsNextMonthFirstDay = visibleDates.contains {
            $0.yearMonth == nextMonth && $0.day == 1
        }
        let containsPreviousMonthLastDay = visibleDates.contains {
            $0.yearMonth == previousMonth
                && $0.day == previousMonth.numberOfDays
        }

        let isMovingForward = newIndex > oldIndex
        let isMovingBackward = newIndex < oldIndex
        let firstCurrentMonthPageIndex = weekPages.firstIndex { page in
            page.contains { $0.yearMonth == model.yearMonth }
        } ?? 0
        let lastCurrentMonthPageIndex = weekPages.lastIndex { page in
            page.contains { $0.yearMonth == model.yearMonth }
        } ?? max(0, weekPages.count - 1)

        // The boundary week may contain the first day of the next month while
        // still being the last page that contains dates from the current
        // month. Moving from Dec 28-Jan 3 to Jan 4-Jan 10 therefore needs the
        // page-range check as well; the new page no longer contains Jan 1.
        let crossedAfterMonthEnd = isMovingForward
            && newIndex > lastCurrentMonthPageIndex
        let shouldMoveToNextMonth = isMovingForward
            && (containsNextMonthFirstDay || crossedAfterMonthEnd)
        let crossedBeforeMonthStart = isMovingBackward
            && newIndex < firstCurrentMonthPageIndex
        let shouldMoveToPreviousMonth = isMovingBackward
            && (containsPreviousMonthLastDay || crossedBeforeMonthStart)

        guard shouldMoveToNextMonth || shouldMoveToPreviousMonth,
              let anchorDate = visibleDates.first?.date else {
            // Re-center near the edge, and only after confirming this is not a
            // month-boundary transition. Re-centering one page early ensures
            // the user can continue dragging before the bounded pager stops.
            if (newIndex <= 1 || newIndex >= weekPages.count - 2),
               let edgeAnchorDate = visibleDates.first?.date {
                weekPagingNotice(
                    "recenter week pages near edge index=\(newIndex) "
                        + "anchor=\(String(describing: edgeAnchorDate))"
                )
                scheduleWeekPageRebuild(
                    anchorDate: edgeAnchorDate,
                    forceRecenter: true
                )
            }
            weekPagingDebug(
                "normal week move oldIndex=\(oldIndex) newIndex=\(newIndex)"
            )
            return
        }

        let targetMonth = shouldMoveToNextMonth
            ? nextMonth
            : previousMonth
        weekPagingNotice(
            "month boundary oldIndex=\(oldIndex) newIndex=\(newIndex) "
                + "anchor=\(String(describing: anchorDate)) "
                + "target=\(targetMonth.year)-\(targetMonth.month)"
        )
        pendingWeekMonthAnchorDate = anchorDate
        moveMonth(to: targetMonth)

        // Month-boundary handling owns this page change. Re-centering before
        // this point races the model update and can replace the page set while
        // SwiftUI is still reporting the user's swipe.
        return
    }

    private func scheduleWeekPageRebuild(
        anchorDate: Date? = nil,
        forceRecenter: Bool = false
    ) {
        guard calendarDisplayMode == .week else { return }

        var targetPages = calendarWeekPages(for: model.yearMonth)
        let targetMonthStart = Calendar.current.date(from: DateComponents(
            year: model.yearMonth.year,
            month: model.yearMonth.month,
            day: 1
        ))
        let targetDate = anchorDate ?? targetMonthStart
        let recenterMonth: YearMonth = {
            guard let anchorDate else { return model.yearMonth }
            let components = Calendar.current.dateComponents(
                [.year, .month],
                from: anchorDate
            )
            guard let year = components.year, let month = components.month else {
                return model.yearMonth
            }
            return YearMonth(year: year, month: month)
        }()

        // Month-boundary paging stays on the same page set. Re-center only for
        // an explicit jump outside the bounded window so normal scrolling does
        // not rebuild the LazyHStack on every month transition.
        if forceRecenter {
            targetPages = Self.makeWeekPageTemplates(around: recenterMonth)
            weekPageTemplates = targetPages
            weekPagingNotice(
                "recenter week pages around \(recenterMonth.year)-\(recenterMonth.month) "
                    + "pageCount=\(targetPages.count)"
            )
        } else if let targetDate,
           !targetPages.contains(where: { page in
               page.contains { Calendar.current.isDate($0.date, inSameDayAs: targetDate) }
           }) {
            targetPages = Self.makeWeekPageTemplates(around: model.yearMonth)
            weekPageTemplates = targetPages
            weekPagingNotice(
                "recenter week pages month=\(model.yearMonth.year)-\(model.yearMonth.month) "
                    + "pageCount=\(targetPages.count)"
            )
        }

        let targetPage = anchorDate.flatMap { date in
            targetPages.first { page in
                page.contains {
                    Calendar.current.isDate($0.date, inSameDayAs: date)
                }
            }
        }
        let fallbackTargetPage = targetPages.first { page in
            page.contains { $0.yearMonth == model.yearMonth }
        }
        let targetPageID = targetPage?.first?.date
            ?? fallbackTargetPage?.first?.date

        // Week pages are stable across month changes. If the requested anchor
        // is already visible, changing the scroll position would only create a
        // redundant position update at the month boundary.
        if !forceRecenter, targetPageID == weekPageID {
            isRebuildingWeekPages = false
            programmaticWeekPageID = nil
            return
        }

        // Month-boundary changes normally keep the same page set. Assigning
        // the target directly avoids the asynchronous rebuild window in which
        // ScrollPosition can report an intermediate page and the next swipe is
        // lost. Keep the asynchronous path for initial week-mode entry, when
        // the horizontal scroll view may not have installed its IDs yet.
        if !forceRecenter,
           weekPageID != nil,
           let targetPageID {
            var transaction = Transaction()
            transaction.animation = nil
            programmaticWeekPageID = targetPageID
            isRebuildingWeekPages = false
            withTransaction(transaction) {
                weekPageID = targetPageID
            }
            weekPagingDebug(
                "applied stable page target=\(String(describing: targetPageID))"
            )
            return
        }

        weekPageRebuildGeneration += 1
        let rebuildGeneration = weekPageRebuildGeneration
        isRebuildingWeekPages = true
        programmaticWeekPageID = targetPageID

        weekPagingNotice(
            "schedule rebuild generation=\(rebuildGeneration) "
                + "month=\(model.yearMonth.year)-\(model.yearMonth.month) "
                + "anchor=\(String(describing: anchorDate)) "
                + "current=\(String(describing: weekPageID)) "
                + "target=\(String(describing: targetPageID))"
        )

        Task { @MainActor in
            // Let SwiftUI install the new page IDs before assigning the scroll target.
            await Task.yield()
            await Task.yield()
            guard rebuildGeneration == weekPageRebuildGeneration else {
                weekPagingDebug(
                    "discard stale rebuild generation=\(rebuildGeneration) "
                        + "current=\(weekPageRebuildGeneration)"
                )
                return
            }

            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                weekPageID = targetPageID
            }
            weekPagingDebug(
                "applied rebuild generation=\(rebuildGeneration) "
                    + "target=\(String(describing: targetPageID))"
            )

            // Give the new page set one render opportunity to settle. A single
            // reassertion is enough to absorb the transient LazyHStack update
            // without holding the UI in a timed stabilization loop.
            await Task.yield()
            guard rebuildGeneration == weekPageRebuildGeneration else {
                weekPagingDebug(
                    "skip rebuild stabilization generation=\(rebuildGeneration) "
                        + "current=\(weekPageRebuildGeneration)"
                )
                return
            }

            if weekPageID != targetPageID {
                weekPagingNotice(
                    "reassert rebuild generation=\(rebuildGeneration) "
                        + "current=\(String(describing: weekPageID)) "
                        + "target=\(String(describing: targetPageID))"
                )
                withTransaction(transaction) {
                    weekPageID = targetPageID
                }
            }

            isRebuildingWeekPages = false
            programmaticWeekPageID = nil
            weekPagingDebug(
                "finished rebuild generation=\(rebuildGeneration) "
                    + "current=\(String(describing: weekPageID))"
            )
        }
    }

    private func moveMonth(to target: YearMonth, animated: Bool = false) {
        guard let pageID = pageID(for: target) else {
            weekPagingError(
                "cannot move to month=\(target.year)-\(target.month) outside month page range"
            )
            pendingWeekMonthAnchorDate = nil
            return
        }

        if calendarDisplayMode == .week,
           pendingWeekMonthAnchorDate == nil {
            pendingWeekMonthAnchorDate = Calendar.current.date(from: DateComponents(
                year: target.year,
                month: target.month,
                day: 1
            ))
        }

        if calendarDisplayMode == .week {
            calendarFocusDate = pendingWeekMonthAnchorDate
                ?? calendarDate(yearMonth: target, day: 1)
        }

        // The month pager is not mounted while week mode is visible, so its
        // scroll-position callback cannot commit this transition. Update the
        // model directly; otherwise the week page can show a new month while
        // the footer and event source remain on the old one.
        if calendarDisplayMode == .week {
            pendingMonthPageID = nil
            model.updateYearMonth(target)
            selectedYear = target.year
            selectedMonth = target.month
            model.load()

            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                monthPageID = pageID
            }
            return
        }

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
#if os(macOS)
        guard Date() >= bandPopoverDismissalDeadline else { return }
#endif
        isCalendarDestinationMenuPresented = false
        isYearMonthPickerPresented = false
        selectedDayForActions = nil
#if os(macOS)
        selectedTimelineEventForActions = nil
#endif
        selectedWeekDayForActions = nil

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

#if os(macOS)
    private func handleTimelineEventTap(
        event: CalendarEventRecord,
        yearMonth: YearMonth,
        day: Int
    ) {
        guard Date() >= bandPopoverDismissalDeadline else { return }
        isCalendarDestinationMenuPresented = false
        isYearMonthPickerPresented = false
        selectedDayForActions = nil
        selectedBandEventForActions = nil
        selectedWeekDayForActions = nil
        selectedTimelineEventForActions = CalendarBandEventSelection(
            event: event,
            yearMonth: yearMonth,
            day: day
        )
    }
#endif

    private func presentEventActions(for event: CalendarEventRecord, day: Int) {
        let selection = CalendarBandEventSelection(
            event: event,
            yearMonth: model.yearMonth,
            day: day
        )

        selectedDayForActions = nil
        selectedEventForActions = nil
        selectedBandEventForActions = nil
#if os(macOS)
        selectedTimelineEventForActions = nil
        isDayActionsPopoverPresented = false
#endif
        Task { @MainActor in
            await Task.yield()
            selectedBandEventForActions = selection
        }
    }

    private func reloadSelectedMonth() {
        let previousDay = Calendar.current.component(.day, from: calendarFocusDate)
        calendarFocusDate = calendarDate(
            yearMonth: selectedYearMonth,
            day: min(previousDay, selectedYearMonth.numberOfDays)
        )
        guard selectedYearMonth != model.yearMonth else { return }
        pendingMonthPageID = nil
        if calendarDisplayMode == .week,
           pendingWeekMonthAnchorDate == nil {
            pendingWeekMonthAnchorDate = calendarFocusDate
        }
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

        calendarFocusDate = calendarDate(yearMonth: target, day: 1)
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
        // The reveal animation belongs to the month grid. Week mode has its
        // own page transition and must not inherit a partially revealed month
        // state when the mode is switched during the reveal.
        guard calendarDisplayMode == .month else { return 1 }
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
        let rowCount = max(6, Int(ceil(Double(monthSlotCount) / 7.0)))
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

    private func calendarWeekPages(for yearMonth: YearMonth) -> [[CalendarGridDate]] {
        weekPageTemplates
    }

    private static func makeWeekPageTemplates(around yearMonth: YearMonth) -> [[CalendarGridDate]] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        // Keep a bounded set of stable week IDs. Rebuilding a month-local
        // LazyHStack at the boundary can make ScrollPosition jump, while a
        // very large range makes SwiftUI measure too many event-band views.
        let firstMonth = yearMonth.addingMonths(-Self.weekPageMonthRadius)
        let lastMonth = yearMonth.addingMonths(Self.weekPageMonthRadius)
        guard let firstMonthStart = calendar.date(from: DateComponents(
                  year: firstMonth.year,
                  month: firstMonth.month,
                  day: 1
              )),
              let lastMonthStart = calendar.date(from: DateComponents(
                  year: lastMonth.year,
                  month: lastMonth.month,
                  day: 1
              )),
              let lastMonthEnd = calendar.date(
                  byAdding: .day,
                  value: lastMonth.numberOfDays - 1,
                  to: lastMonthStart
              ) else {
            return []
        }

        let firstGridDate = calendar.date(
            byAdding: .day,
            value: -firstMonth.leadingBlankCount - 7,
            to: firstMonthStart
        ) ?? firstMonthStart
        let lastWeekday = lastMonth.weekdayIndex(for: lastMonth.numberOfDays) ?? 7
        let trailingBlankCount = 7 - lastWeekday
        let lastGridDate = calendar.date(
            byAdding: .day,
            value: trailingBlankCount,
            to: lastMonthEnd
        ) ?? lastMonthEnd

        var pages: [[CalendarGridDate]] = []
        var pageStart = firstGridDate
        while pageStart <= lastGridDate {
            let page = (0..<7).compactMap { offset -> CalendarGridDate? in
                guard let date = calendar.date(byAdding: .day, value: offset, to: pageStart) else {
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
                    slot: offset,
                    displayedMonth: yearMonth
                )
            }
            pages.append(page)
            guard let nextPageStart = calendar.date(byAdding: .day, value: 7, to: pageStart) else {
                break
            }
            pageStart = nextPageStart
        }

        return pages
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

    private func weekPageEvents(
        for dates: [CalendarGridDate],
        events: [CalendarEventRecord]
    ) -> [CalendarEventRecord] {
        guard !dates.isEmpty else { return [] }

        let calendar = Calendar.current
        let weekStart = calendar.startOfDay(for: dates[0].date)
        let weekEnd = calendar.startOfDay(for: dates[dates.count - 1].date)

        // Keep month-only records available for eventDisplaySegments(), which
        // resolves their day using the month represented by the page. Records
        // with absolute dates can be narrowed to the visible week here.
        return events.filter { event in
            guard let startDate = event.startDate else { return true }
            let startDay = calendar.startOfDay(for: startDate)
            let endDay = calendar.startOfDay(for: event.endDate ?? startDate)
            return startDay <= weekEnd && endDay >= weekStart
        }
    }

    private func eventDisplaySegments(
        events: [CalendarEventRecord],
        gridDates: [CalendarGridDate]
    ) -> [CalendarEventDisplaySegment] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let result = events.flatMap { (event: CalendarEventRecord) -> [CalendarEventDisplaySegment] in
            let matchingSlots: [CalendarGridDate]
            if let startDate = event.startDate {
                let startDay = calendar.startOfDay(for: startDate)
                let endDay = calendar.startOfDay(for: event.endDate ?? startDate)
                matchingSlots = gridDates.filter { gridDate in
                    let date = calendar.startOfDay(for: gridDate.date)
                    return date >= startDay && date <= endDay
                }
            } else {
                // Month-only records have no absolute date. Resolve their day
                // against the month represented by each grid cell, so a week
                // that straddles two months uses the correct month per cell.
                matchingSlots = gridDates.filter { gridDate in
                    event.occurs(
                        on: gridDate.date,
                        fallbackYearMonth: gridDate.yearMonth
                    )
                }
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
        events: [CalendarEventRecord],
        segments: [CalendarEventDisplaySegment],
        gridDates: [CalendarGridDate]
    ) -> [CalendarEventDisplaySegment] {
        var result: [CalendarEventDisplaySegment] = []

        for gridDate in gridDates {
            let dayEvents = events.filter {
                $0.occurs(on: gridDate.date, fallbackYearMonth: gridDate.yearMonth)
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
        events: [CalendarEventRecord],
        segments: [CalendarEventDisplaySegment],
        gridDates: [CalendarGridDate]
    ) -> [CalendarEventBandLayout] {
        let candidates = Array(
            Dictionary(
                (segments.filter { $0.spanDays > 1 }
                    + singleDayEventBandSegments(
                        events: events,
                        segments: segments,
                        gridDates: gridDates
                    )).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ).values
        )
        .sorted {
            if calendarEventComesBefore($0.event, $1.event) {
                return true
            }
            if calendarEventComesBefore($1.event, $0.event) {
                return false
            }
            if $0.startDay != $1.startDay {
                return $0.startDay < $1.startDay
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
        let gap = min(4, max(1, 1 + (cardHeight - 52) / 22))
#endif
        let availableHeight = max(
            0,
            cardHeight - 12 - dateHeaderHeight - contentSpacing
        )
        let height = max(0, (availableHeight - gap * 2) / 3)
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
        gridDates: [CalendarGridDate],
        dimsOutOfDisplayedMonth: Bool = true
    ) -> LinearGradient {
        let baseOpacity = isDaySelectionMode ? 0.08 : 0.25
        let dimmedOpacity = baseOpacity * 0.45
        let layoutDates = gridDates.filter {
            (layout.startDay...layout.endDay).contains($0.slot)
        }
        let span = max(1, layoutDates.count)
        let leadingOutsideCount = dimsOutOfDisplayedMonth
            ? layoutDates.prefix { !$0.isInDisplayedMonth }.count
            : 0
        let trailingOutsideCount = dimsOutOfDisplayedMonth
            ? layoutDates.reversed().prefix { !$0.isInDisplayedMonth }.count
            : 0

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
                eventActionsPopover(
                    for: selection.event,
                    day: selection.day,
                    yearMonth: selection.yearMonth
                )
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
        let eventSignature = pageEvents.hashValue
        let segmentCacheKey = CalendarLayoutCacheKey(
            kind: .monthSegments,
            pageDate: gridDates.first?.date ?? Date.distantPast,
            eventSignature: eventSignature
        )
        let displaySegments = measureCalendarRendering(
            "MonthEventSegments",
            details: "days=\(gridDates.count) events=\(pageEvents.count)"
        ) {
            calendarEventLayoutCache.displaySegments(for: segmentCacheKey) {
                eventDisplaySegments(events: pageEvents, gridDates: gridDates)
            }
        }
        let bandCacheKey = CalendarLayoutCacheKey(
            kind: .monthBands,
            pageDate: gridDates.first?.date ?? Date.distantPast,
            eventSignature: eventSignature
        )
        let bandLayouts = measureCalendarRendering(
            "MonthEventBandLayouts",
            details: "segments=\(displaySegments.count) events=\(pageEvents.count)"
        ) {
            calendarEventLayoutCache.bandLayouts(for: bandCacheKey) {
                eventBandLayouts(
                    events: pageEvents,
                    segments: displaySegments,
                    gridDates: gridDates
                )
            }
        }
#if os(iOS)
        let gridSpacing: CGFloat = 5
        let columnSpacing: CGFloat = 4
        let horizontalInsets: CGFloat = 24
#else
        let gridSpacing: CGFloat = 8
        let columnSpacing: CGFloat = 8
        let horizontalInsets: CGFloat = 48
#endif
        let cardHeight = eventCalendarCardHeight(availableHeight: availableHeight)
        let bandMetrics = calendarEventBandMetrics(cardHeight: cardHeight)
#if os(macOS)
        let bandTitleFontSize = min(11, max(5, bandMetrics.height * 0.9))
#endif
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
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
#else
                                    .font(.system(size: bandTitleFontSize, weight: .medium))
                                    .lineLimit(1)
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
                                        ?? 1,
                                    yearMonth: selectedBandEventForActions?.yearMonth
                                        ?? bandStartDate?.yearMonth
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
                                && !isBandPopoverPresented
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
        .background(calendarBaseBackground)
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
        hideEventContent: Bool,
        isWeekModeCard: Bool = false,
        dimsOutOfDisplayedMonth: Bool = true
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
            selectedBandEventForActions = nil

            if !gridDate.isInDisplayedMonth && !isWeekModeCard {
                pendingDayActionsSelection = selection
                moveMonth(to: gridDate.yearMonth, animated: true)
                return
            }

            Task { @MainActor in
                await Task.yield()
                if isWeekModeCard {
                    selectedDayForActions = nil
                    selectedWeekDayForActions = selection
#if os(macOS)
                    isDayActionsPopoverPresented = true
#endif
                    return
                }
                selectedWeekDayForActions = nil
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
                    Text(String(gridDate.day))
#if os(iOS)
                        .font(.caption.weight(.semibold))
#else
                        .font(.body.weight(.semibold))
#endif
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .allowsTightening(true)
                        .background {
                            if isToday {
                                Circle()
                                    .fill(Color.red.opacity(0.35))
                                    .padding(-2)
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
                        .fill(calendarCardBackground)
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
        .opacity(
            dimsOutOfDisplayedMonth && !gridDate.isInDisplayedMonth
                ? 0.38
                : 1
        )
        .zIndex(connectsToPreviousCard ? 0 : 1)
        .disabled(model.isDeleting || !isInteractive)
#if os(macOS)
        .popover(
            isPresented: Binding(
                get: {
                    isInteractive
                        && (isWeekModeCard || gridDate.isInDisplayedMonth)
                        && !isSelectionMode
                        && isDayActionsPopoverPresented
                        && (isWeekModeCard
                            ? selectedWeekDayForActions == selection
                            : selectedDayForActions == gridDate.day)
                        && selectedBandEventForActions == nil
                },
                set: { isPresented in
                    if isWeekModeCard {
                        if !isPresented && selectedWeekDayForActions == selection {
                            isDayActionsPopoverPresented = false
                            selectedWeekDayForActions = nil
                        }
                    } else if isInteractive
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
                yearMonth: isWeekModeCard ? gridDate.yearMonth : nil,
                additionalEvents: isWeekModeCard
                    ? dayEvents + segmentsForDay.map(\.event)
                    : segmentsForDay.map(\.event)
            )
        }
#endif
    }

#if os(iOS)
    @ViewBuilder
    private func calendarDayActionsSheetContent(
        for selection: CalendarDayActionsSheet
    ) -> some View {
        switch selection {
        case .month(let day):
            dayActionsPopover(for: day)
        case .week(let selection):
            dayActionsPopover(
                for: selection.day,
                yearMonth: selection.yearMonth
            )
        }
    }
#endif

    private func dayActionsPopover(
        for day: Int,
        yearMonth: YearMonth? = nil,
        additionalEvents: [CalendarEventRecord] = []
    ) -> some View {
        let dayEvents = Array(
            Dictionary(
                (model.events(for: day, yearMonth: yearMonth) + additionalEvents).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            .values
        )
        let actionableEvents = dayEvents.filter { !$0.isReadOnly }
        let displayOnlyEvents = dayEvents.filter(\.isReadOnly)

        return CalHubDateActionSheetContainer {
            VStack(alignment: .leading, spacing: 0) {
            Text(model.dayHeader(for: day, yearMonth: yearMonth, locale: locale))
                .font(.headline)
                .padding(.bottom, 10)

            ForEach(displayOnlyEvents) { event in
                Button {
                    presentEventActions(for: event, day: day)
                } label: {
                    eventListRowContent(for: event)
                }
                .buttonStyle(.plain)
                    .padding(.top, 12)
            }

#if os(iOS)
            if actionableEvents.count == 1, let event = actionableEvents.first {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    scrollableEventInformationCard(for: event)
                        .padding(.top, 11)
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

                dateTimeEventRegistrationButton(forDay: day)
                    .padding(.top, 12)

                eventRegistrationButton(forDay: day)
                    .padding(.top, 8)
            }
#else
            if !actionableEvents.isEmpty {
                if actionableEvents.count == 1, let event = actionableEvents.first {
                    VStack(alignment: .leading, spacing: 0) {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            scrollableEventInformationCard(for: event)
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

    private func eventSummaryContent(for event: CalendarEventRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)

            let menuDetail = event.menuDetail(locale: locale)
            if !menuDetail.isEmpty {
                Text(menuDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func eventInformationCard(for event: CalendarEventRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            eventSummaryContent(for: event)
            eventMetadataDetails(for: event, showsBackground: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            .background.secondary.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

#if os(iOS) || os(macOS)
    private func scrollableEventInformationCard(for event: CalendarEventRecord) -> some View {
        ScrollView(.vertical) {
            eventInformationCard(for: event)
        }
        .scrollIndicators(.visible)
        .frame(maxHeight: 360, alignment: .topLeading)
    }
#endif

    private struct CalendarEventMetadataDisplayItem: Identifiable {
        let id: String
        let label: String
        let value: String
        let optionValues: [String]
        let optionColors: [String: String]
    }

    private func notionTagBackgroundColor(for colorName: String) -> Color {
        switch colorName.lowercased() {
        case "blue":
            return Color(red: 0.20, green: 0.47, blue: 0.66)
        case "brown":
            return Color(red: 0.56, green: 0.34, blue: 0.20)
        case "green":
            return Color(red: 0.22, green: 0.55, blue: 0.34)
        case "orange":
            return Color(red: 0.73, green: 0.42, blue: 0.16)
        case "pink":
            return Color(red: 0.72, green: 0.35, blue: 0.53)
        case "purple":
            return Color(red: 0.48, green: 0.33, blue: 0.62)
        case "red":
            return Color(red: 0.70, green: 0.25, blue: 0.25)
        case "yellow":
            return Color(red: 0.68, green: 0.54, blue: 0.16)
        case "gray", "default":
            return Color.secondary.opacity(0.55)
        default:
            return Color.secondary.opacity(0.55)
        }
    }

    private func notionTagForegroundColor(for colorName: String) -> Color {
        switch colorName.lowercased() {
        case "gray", "default", "yellow":
            return .primary
        default:
            return .white
        }
    }

    private func metadataDisplayItems(
        for event: CalendarEventRecord
    ) -> [CalendarEventMetadataDisplayItem] {
        let metadata = event.metadata.normalized
        var items: [CalendarEventMetadataDisplayItem] = []

        func append(
            _ id: String,
            label: String,
            value: String,
            optionValues: [String] = [],
            optionColors: [String: String] = [:]
        ) {
            guard !value.isEmpty else { return }
            items.append(
                CalendarEventMetadataDisplayItem(
                    id: id,
                    label: label,
                    value: value,
                    optionValues: optionValues,
                    optionColors: optionColors
                )
            )
        }

        if metadataFieldLabels.tagIsAvailable {
            let tagProperty = notionMetadataProperties.first { $0.name == notionTagProperty }
            let optionValues = metadata.tagValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            append(
                "tag",
                label: metadataFieldLabels.tag,
                value: metadata.tagValue,
                optionValues: optionValues,
                optionColors: tagProperty?.optionColors ?? [:]
            )
        }
        if metadataFieldLabels.locationIsAvailable {
            append("location", label: metadataFieldLabels.location, value: metadata.location)
        }
        if metadataFieldLabels.urlIsAvailable {
            append("url", label: metadataFieldLabels.url, value: metadata.url)
        }
        if metadataFieldLabels.notesIsAvailable {
            append("notes", label: metadataFieldLabels.notes, value: metadata.notes)
        }
        for property in metadataFieldLabels.additionalProperties {
            let value = metadata.propertyValues[property.name] ?? ""
            let isOptionProperty = ["multi_select", "select"].contains(property.type)
            let optionValues = isOptionProperty
                ? value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                : []
            append(
                property.name,
                label: property.displayName(for: locale),
                value: value,
                optionValues: optionValues,
                optionColors: isOptionProperty ? property.optionColors : [:]
            )
        }

        return items
    }

    @ViewBuilder
    private func eventMetadataDetails(
        for event: CalendarEventRecord,
        showsBackground: Bool = true
    ) -> some View {
        let items = metadataDisplayItems(for: event)
        if !items.isEmpty {
            let content = VStack(alignment: .leading, spacing: 8) {
                Divider()
                    .padding(.vertical, 4)

                Text(localized("詳細"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: item.optionValues.isEmpty ? 2 : 6) {
                        Text(item.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !item.optionValues.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(item.optionValues, id: \.self) { optionValue in
                                    let colorName = item.optionColors[optionValue] ?? "gray"
                                    Text(optionValue)
                                        .font(.body)
                                        .foregroundStyle(notionTagForegroundColor(for: colorName))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            notionTagBackgroundColor(for: colorName),
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

            if showsBackground {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        .background.secondary.opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .padding(.bottom, 12)
            } else {
                content
            }
        }
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
                    Button {
                        presentEventActions(for: event, day: day)
                    } label: {
                        eventListRowContent(for: event)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)

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
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
#else
                HStack(spacing: 8) {
                    Button {
                        presentEventActions(for: event, day: day)
                    } label: {
                        eventListRowContent(for: event)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)

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
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
#endif
            }
        }
    }

#if os(iOS)
    private func eventActionsPopover(
        for event: CalendarEventRecord,
        day: Int,
        yearMonth: YearMonth? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.dayHeader(for: day, yearMonth: yearMonth, locale: locale))
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.bottom, 10)

            Divider()

            scrollableEventInformationCard(for: event)
                .padding(.top, 12)

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
                    .padding(.top, 12)
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
                guard let selection = selectedBandEventForActions ?? selectedTimelineEventForActions,
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
                guard !isPresented else {
                    return
                }

                bandPopoverDismissalDeadline = Date().addingTimeInterval(0.5)

                if let selection = selectedBandEventForActions,
                   selection.event.id == event.id {
                    selectedBandEventForActions = nil
                }

                if let selection = selectedTimelineEventForActions,
                   selection.event.id == event.id {
                    selectedTimelineEventForActions = nil
                }
            }
        )
    }

    private func bandEventActionsPopover(
        for event: CalendarEventRecord,
        day: Int,
        yearMonth: YearMonth? = nil
    ) -> some View {
        CalHubDateActionSheetContainer {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.dayHeader(for: day, yearMonth: yearMonth, locale: locale))
                    .font(.headline)
                    .padding(.bottom, 10)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    scrollableEventInformationCard(for: event)
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
                beginEditing(event)
            } label: {
                Label(localized("編集"), systemImage: "pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(event.isReadOnly)

            Button {
                selectedEventForActions = nil
                selectedBandEventForActions = nil
#if os(macOS)
                selectedTimelineEventForActions = nil
#endif
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
                beginEditing(event)
            } label: {
                Label(localized("編集"), systemImage: "pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(event.isReadOnly)

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
#if os(macOS)
                selectedTimelineEventForActions = nil
#endif
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
        selectedWeekDayForActions = nil
        selectedBandEventForActions = nil
        pendingShiftRegistration = PendingShiftRegistration(
            day: event.day,
            event: event,
            deleteExisting: deleteExisting
        )
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            isShiftSelectionPresented = true
        }
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
        selectedWeekDayForActions = nil
        selectedBandEventForActions = nil
#if os(macOS)
        isDayActionsPopoverPresented = false
#endif
        dateTimeEventRegistrationStartDate = initialStartDate
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            isDateTimeEventRegistrationPresented = true
        }
    }

    private func presentDateTimeEventRegistration() {
        selectedDayForActions = nil
        selectedBandEventForActions = nil
        dateTimeEventRegistrationStartDate = Date()
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
        selectedWeekDayForActions = nil
        selectedBandEventForActions = nil
        pendingShiftRegistration = PendingShiftRegistration(
            day: day,
            event: nil,
            deleteExisting: deleteExisting
        )
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            isShiftSelectionPresented = true
        }
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
