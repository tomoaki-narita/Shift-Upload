//
//  ContentView.swift
//  Shift Upload
//
//  Created by tomoaki-d on 2026/09/08.
//

import Combine
import CryptoKit
import EventKit
import ImageIO
import Network
import PDFKit
import Security
import UniformTypeIdentifiers
import Vision
import AuthenticationServices
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct CalHubDateActionSheetHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct CalHubDateActionSheetContainer<Content: View>: View {
    private let content: Content
#if os(iOS)
    @State private var measuredHeight: CGFloat = 240
#endif

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
#if os(iOS)
            .padding(.horizontal, 20)
            .padding(.top, 30)
            .padding(.bottom, 20)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(
                            key: CalHubDateActionSheetHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                }
            }
            .onPreferenceChange(CalHubDateActionSheetHeightPreferenceKey.self) { height in
                guard height > 0, abs(measuredHeight - height) > 0.5 else { return }
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    measuredHeight = ceil(height)
                }
            }
            .presentationDetents([.height(measuredHeight)])
#else
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(width: 250, alignment: .leading)
#endif
    }
}

extension Notification.Name {
    static let shiftHubSettingsDidChange = Notification.Name("ShiftHubSettingsDidChange")
    static let shiftHubScanStoredSchedule = Notification.Name("ShiftHubScanStoredSchedule")
}

enum GoogleOAuthConfiguration {
#if os(iOS)
    // Native iOS OAuth clients use PKCE and must not send the macOS client secret.
    static let clientSecret: String? = nil
    static let clientID = "286738733463-lihm8melqntpfekgp9npr2i16b5dlv8p.apps.googleusercontent.com"
    static let callbackURLScheme = "com.googleusercontent.apps.286738733463-lihm8melqntpfekgp9npr2i16b5dlv8p"
#else
    static let clientSecret = GoogleOAuthSecrets.macOSClientSecret
    static let clientID = "286738733463-tr3gh0ou1akkgvkiag0j47v3pj6sk0cu.apps.googleusercontent.com"
#endif
}

@MainActor
struct ContentView: View {
    private var locale: Locale {
        Locale(identifier: appLanguage)
    }
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.japanese.rawValue
    @AppStorage("workerName") private var workerName = ""
    @AppStorage("shiftDefinitionsJSON") private var shiftDefinitionsJSON = ""
    @AppStorage("calendarDestination") private var calendarDestination = CalendarDestination.apple.rawValue
    @AppStorage("appleCalendarIdentifier") private var appleCalendarIdentifier = ""
    @AppStorage("appleCalendarName") private var appleCalendarName = ""
    @AppStorage("appleRestEventTitle") private var appleRestEventTitle = "休"
    @AppStorage("googleCalendarID") private var googleCalendarID = "primary"
    @AppStorage("googleCalendarName") private var googleCalendarName = ""
    @AppStorage("googleRestEventTitle") private var googleRestEventTitle = "休"
    @AppStorage("notionDataSourceID") private var notionDataSourceID = ""
    @AppStorage("notionDatabaseName") private var notionDatabaseName = ""
    @AppStorage("notionTitleProperty") private var notionTitleProperty = "tasks"
    @AppStorage("notionDateProperty") private var notionDateProperty = "due date"
    @AppStorage("notionTagProperty") private var notionTagProperty = "tag"
    @AppStorage("notionTagValue") private var notionTagValue = "shift"
    @AppStorage("notionRestEventTitle") private var notionRestEventTitle = "休"
    @AppStorage("storedSchedulesJSON") private var storedSchedulesJSON = ""
    @AppStorage("iCloudSyncEnabled") private var isCloudSyncEnabled = true

    @State private var isImporterPresented = false
    @State private var isSavedScheduleListPresented = false
    @State private var isPDFListPresented = false
    @State private var isRegistrationDestinationMenuPresented = false
    @State private var isSettingsPresented = false
    @State private var isShiftUploadPresented = false
    @State private var isMissingShiftSelectionPresented = false
    @State private var isRestRegistrationAlertPresented = false
    @State private var registrationPreview: RegistrationPreview?
    @State private var isRegisteringEvents = false
    @State private var selectedFileName = ""
    @State private var selectedYearMonth: YearMonth?
    @State private var recognizedItems: [RecognizedTextItem] = []
    @State private var extractedCells: [ExtractedShiftCell] = []
    @State private var workerNameDraft = ""
    @State private var shiftDefinitions: [ShiftDefinition] = []
    @State private var savedSchedules: [StoredSchedule] = []
    @State private var pendingMissingShiftTitles: [String] = []
    @State private var ignoredMissingShiftTitles: Set<String> = []
    @State private var selectedExtractedDayAction: ExtractedDayAction?
#if os(iOS)
    @State private var isExtractedShiftActionPresented = false
    @State private var selectedExtractedDirectDayAction: ExtractedDayAction?
#endif
    @State private var isExtractedShiftSelectionPresented = false
    @State private var pendingExtractedDayForEdit: Int?
    @State private var editedExtractedShiftText = ""
    @State private var isImportAlertPresented = false
    @State private var importAlertTitle = ""
    @State private var importAlertMessage = ""
    @State private var statusMessage = "文字データを持つPDFの勤務表を選択"
    @State private var isProcessing = false
    @State private var isSynchronizing = false
    @State private var displayMode: ShiftDisplayMode = .calendar
    @State private var selectedCalendarDisplayColor: CalendarDisplayColor?
    @State private var isCloudKitStateLoaded = false
#if os(macOS)
    @State private var isPDFDropTargeted = false
#endif

    private let analyzer = ShiftOCRAnalyzer()

    var body: some View {
        NavigationStack {
            homeEventManagerScreen
                .navigationDestination(isPresented: $isShiftUploadPresented) {
                    shiftUploadScreen
                }
            .navigationDestination(isPresented: $isSettingsPresented) {
                AppSettingsView(definitions: $shiftDefinitions)
            }
        }
        .environment(\.locale, Locale(identifier: appLanguage))
#if os(macOS)
        .frame(minWidth: 720, minHeight: 950)
#endif
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .alert(LocalizedStringKey(importAlertTitle), isPresented: $isImportAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(importAlertMessage))
        }
        .sheet(isPresented: $isSavedScheduleListPresented) {
            SavedScheduleListView(
                schedules: savedSchedules,
                onSelect: { schedule in
                    isSavedScheduleListPresented = false
                    analyzeSavedSchedule(schedule)
                },
                onDelete: deleteSavedSchedule
            )
        }
        .sheet(isPresented: $isPDFListPresented) {
            PDFListView(
                schedules: savedSchedules,
                onDelete: deleteSavedSchedule
            )
        }
        .onAppear {
            let sanitizedWorkerName = workerName.filter { !$0.isNumber }
            workerName = sanitizedWorkerName
            workerNameDraft = sanitizedWorkerName
            shiftDefinitions = Self.loadShiftDefinitions(from: shiftDefinitionsJSON)
            let loadedSchedules = Self.loadStoredSchedules(from: storedSchedulesJSON)
            savedSchedules = Self.removeInvalidStoredSchedules(from: loadedSchedules)
            if savedSchedules.count != loadedSchedules.count {
                statusMessage = localizedMessage("対応していない保存済みPDFを削除しました。")
            }

            if isCloudSyncEnabled {
                if let cloudSettings = ShiftHubCloudSync.loadSettings() {
                    applyCloudSettings(cloudSettings)
                }

                Task { @MainActor in
                    await synchronizeWithCloudKit()
                }
            }
        }
        .onChange(of: shiftDefinitions) {
            shiftDefinitionsJSON = Self.shiftDefinitionsJSON(from: shiftDefinitions)
        }
        .onChange(of: savedSchedules) {
            storedSchedulesJSON = Self.storedSchedulesJSON(from: savedSchedules)
            if isCloudKitStateLoaded && isCloudSyncEnabled {
                ShiftHubCloudSync.saveSchedules(savedSchedules)
            }
        }
        .onChange(of: cloudSettingsSnapshot) {
            if isCloudKitStateLoaded && isCloudSyncEnabled {
                syncCloudSettings()
            }
        }
        .onChange(of: isCloudSyncEnabled) {
            if isCloudSyncEnabled {
                Task { @MainActor in
                    await synchronizeWithCloudKit()
                }
            } else {
                isCloudKitStateLoaded = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            guard isCloudSyncEnabled else { return }
            Task { @MainActor in
                await synchronizeWithCloudKit()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shiftHubSettingsDidChange)) { _ in
            if isCloudKitStateLoaded && isCloudSyncEnabled {
                syncCloudSettings()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shiftHubScanStoredSchedule)) { notification in
            guard let schedule = notification.object as? StoredSchedule else { return }
            isSavedScheduleListPresented = false
            analyzeSavedSchedule(schedule)
        }
        .sheet(isPresented: $isMissingShiftSelectionPresented) {
            MissingShiftSelectionView(titles: pendingMissingShiftTitles) { selectedTitles, definitions in
                completeMissingShiftSelection(selectedTitles, definitions: definitions)
            }
        }
        .sheet(isPresented: $isExtractedShiftSelectionPresented) {
            ShiftSelectionView(definitions: shiftDefinitions, locale: locale) { title in
                completeExtractedShiftSelection(title)
            }
        }
        .sheet(item: $registrationPreview) { preview in
            RegistrationPreviewView(
                preview: preview,
                locale: locale,
                onRegister: confirmPendingRegistration
            )
        }
    }

    private var registrationDestinationName: String? {
        let name: String
        switch CalendarDestination(rawValue: calendarDestination) {
        case .apple:
            name = appleCalendarName
        case .google:
            name = googleCalendarName
        case .notion:
            name = notionDatabaseName
        case nil:
            return nil
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? nil : trimmedName
    }

    private func localizedMessage(_ key: String) -> String {
        ShiftHubLocalization.string(key, locale: locale)
    }

    private func localizedMessage(_ key: String, arguments: CVarArg...) -> String {
        ShiftHubLocalization.format(key, locale: locale, arguments: arguments)
    }

    private var loadedScheduleClearedMessageKey: String? {
        let key = "勤務表の読み込みを解除しました。"
        let englishValue = ShiftHubLocalization.string(key, locale: Locale(identifier: "en"))
        return statusMessage == key || statusMessage == englishValue ? key : nil
    }

    private func localizedError(_ error: Error) -> String {
        ShiftHubLocalization.localizedErrorDescription(error, locale: locale)
    }

    @ViewBuilder
    private var homeEventManagerScreen: some View {
        if let destination = CalendarDestination(rawValue: calendarDestination) {
            CalendarEventManagerView(
                destination: destination,
                initialYearMonth: selectedYearMonth,
                appleCalendarIdentifier: appleCalendarIdentifier,
                googleCalendarID: googleCalendarID,
                appleCalendarName: appleCalendarName,
                googleCalendarName: googleCalendarName,
                notionDataSourceID: notionDataSourceID,
                notionDatabaseName: notionDatabaseName,
                notionDateProperty: notionDateProperty,
                notionTitleProperty: notionTitleProperty,
                notionTagProperty: notionTagProperty,
                notionTagValue: notionTagValue,
                definitions: shiftDefinitions,
                onRegisterShift: { yearMonth, day, title, completion in
                    registerSingleShift(
                        yearMonth: yearMonth,
                        day: day,
                        title: title,
                        onComplete: completion.call
                    )
                },
                onRegisterDateTimeEvent: { title, startDate, endDate, isAllDay, completion in
                    registerDateTimeEvent(
                        title: title,
                        startDate: startDate,
                        endDate: endDate,
                        isAllDay: isAllDay,
                        onComplete: completion.call
                    )
                },
                onRegisterShifts: { selections, title, completion in
                    registerMultipleShifts(
                        selections: selections,
                        title: title,
                        onComplete: completion.call
                    )
                },
                onCalendarDestinationChange: { destination in
                    calendarDestination = destination.rawValue
                },
                onCalendarColorChange: { color in
                    selectedCalendarDisplayColor = color
                },
                onOpenShiftUpload: {
                    isShiftUploadPresented = true
                },
                onOpenPDFList: {
                    isPDFListPresented = true
                },
                onOpenSettings: {
                    isSettingsPresented = true
                },
                isSynchronizing: isSynchronizing,
                isCloudSyncEnabled: isCloudSyncEnabled,
                onSynchronize: {
                    Task { @MainActor in
                        await synchronizeWithCloudKit()
                    }
                }
            )
        }
    }

    private var shiftUploadScreen: some View {
        VStack(spacing: 0) {
#if os(iOS)
            iOSScanHeader
                .zIndex(1)
            header
#else
            header
#endif

            Divider()

            extractedRowPanel
        }
        .onTapGesture {
            if isRegistrationDestinationMenuPresented {
                isRegistrationDestinationMenuPresented = false
            }
        }
        .alert("「休」も登録しますか？", isPresented: $isRestRegistrationAlertPresented) {
            Button("休も登録") {
                registerSelectedCalendar(includeRest: true)
            }

            Button("イベントだけ登録") {
                registerSelectedCalendar(includeRest: false)
            }

            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(restRegistrationMessage)
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlayPreferenceValue(CalendarOverlayAnchorKey.self) { anchors in
            GeometryReader { geometry in
                if isRegistrationDestinationMenuPresented, let anchor = anchors.destination {
                    let destinationFrame = geometry[anchor]

                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                isRegistrationDestinationMenuPresented = false
                            }

                        CalendarDestinationPopup(
                            selection: CalendarDestination(rawValue: calendarDestination),
                            isPresented: $isRegistrationDestinationMenuPresented,
                            onSelect: { destination in
                                calendarDestination = destination.rawValue
                            }
                        )
                        .position(
                            x: destinationFrame.maxX - 90,
                            y: destinationFrame.minY + 50 + 58
                        )
                        .zIndex(1)
                    }
                }
            }
            .allowsHitTesting(isRegistrationDestinationMenuPresented)
        }
#endif
#if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
#endif
#if os(macOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    Color.accentColor.opacity(isPDFDropTargeted ? 0.9 : 0),
                    style: StrokeStyle(lineWidth: 3, dash: [8, 6])
                )
                .padding(8)
                .allowsHitTesting(false)
        }
        .onDrop(
            of: [UTType.pdf.identifier],
            isTargeted: $isPDFDropTargeted,
            perform: handlePDFDrop
        )
        .toolbar {
            if isCloudSyncEnabled {
                ToolbarItem(placement: .primaryAction) {
                    synchronizeButton
                }
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                settingsButton
            }

        }
#endif
    }

    private var header: some View {
#if os(iOS)
        mobileHeader
#else
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PDFスキャン")
                    .font(.title.bold())
            }

            scheduleSelectionControls
            scheduleStatusRow
            registrationControls

            if isRegisteringEvents {
                ProgressView("カレンダーへ登録中です...")
                    .controlSize(.small)
            }
            workerSearchField

        }
        .padding(24)
#endif
    }

#if os(macOS)
    private var registrationControls: some View {
        HStack(spacing: 12) {
            Label("登録先", systemImage: "paperplane")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            registrationDestinationMenu

            if let registrationDestinationName {
                Text(registrationDestinationName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var scheduleSelectionControls: some View {
        HStack(spacing: 8) {
            schedulePickerButton
            savedScheduleButton

            Spacer()

            if isProcessing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
#else
    private var registrationControls: some View {
        HStack(spacing: 6) {
            Label("登録先", systemImage: "paperplane")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            registrationDestinationMenu
                .padding(.vertical, 4)

            if let registrationDestinationName {
                Text(registrationDestinationName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .zIndex(1)
    }

    private var scheduleSelectionControls: some View {
        HStack(spacing: 8) {
            schedulePickerButton
            savedScheduleButton
        }
    }
#endif

    private var scheduleStatusRow: some View {
        Group {
            if !selectedFileName.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    Text(selectedFileName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    removeScheduleButton
                }
            } else if !statusMessage.isEmpty {
                Group {
                    if let key = loadedScheduleClearedMessageKey {
                        Text(LocalizedStringKey(key))
                    } else {
                        Text(verbatim: statusMessage)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var workerSearchField: some View {
#if os(macOS)
        HStack(spacing: 12) {
            workerSearchInput
            workerSearchButton

            Spacer(minLength: 8)

            registrationActionButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
#else
        HStack(spacing: 12) {
            workerSearchInput
            workerSearchButton
            registrationActionButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
#endif
    }

    private var workerSearchInput: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)

            TextField("Name...", text: $workerNameDraft)
                .textFieldStyle(.plain)
                .onSubmit {
                    performWorkerSearch()
                }
                .onChange(of: workerNameDraft) {
                    let sanitizedWorkerName = workerNameDraft.filter { !$0.isNumber }
                    if sanitizedWorkerName != workerNameDraft {
                        workerNameDraft = sanitizedWorkerName
                    }
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.25), lineWidth: 1)
        }
#if os(macOS)
        .frame(width: 260)
#else
        .frame(maxWidth: .infinity)
#endif
    }

    private var workerSearchButton: some View {
        Button {
            performWorkerSearch()
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
        }
#if os(macOS)
        .buttonStyle(ToolbarUtilityButtonStyleD())
        .help("検索")
#else
        .buttonStyle(ToolbarIconButtonStyleD())
        .accessibilityLabel("検索")
#endif
        .disabled(isProcessing || isRegisteringEvents)
    }

    private var registrationDestinationMenu: some View {
#if os(iOS)
                CalendarDestinationSelector(
                    selection: CalendarDestination(rawValue: calendarDestination),
                    showsCalendarIcon: false,
                    isPresented: $isRegistrationDestinationMenuPresented,
                    rendersOverlay: false,
                    buttonHeight: 34,
                    onOpen: {},
                    onSelect: { destination in
                        calendarDestination = destination.rawValue
            }
        )
        .anchorPreference(key: CalendarOverlayAnchorKey.self, value: .bounds) {
            CalendarOverlayAnchors(destination: $0)
        }
#else
        Menu {
            ForEach(CalendarDestination.allCases) { destination in
                Button {
                    calendarDestination = destination.rawValue
                } label: {
                    Label(destination.title, systemImage: "calendar")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(CalendarDestination(rawValue: calendarDestination)?.title ?? "カレンダー")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
            }
        }
        .buttonStyle(ToolbarSelectorButtonStyleD(buttonHeight: 34))
        .accessibilityLabel("カレンダーを変更")
#endif
    }

    private var registrationActionButton: some View {
        Button {
            prepareCalendarRegistration()
        } label: {
#if os(macOS)
            Label("登録", systemImage: "calendar.badge.plus")
#else
            Image(systemName: "calendar.badge.plus")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
#endif
        }
#if os(macOS)
        .buttonStyle(ToolbarUtilityButtonStyleD())
#else
        .buttonStyle(ToolbarIconButtonStyleD())
#endif
        .disabled(isProcessing || isRegisteringEvents)
#if os(macOS)
        .help("登録")
#else
        .accessibilityLabel("登録")
#endif
    }

    private var synchronizeButton: some View {
        Button {
            Task { @MainActor in
                await synchronizeWithCloudKit()
            }
        } label: {
            if isSynchronizing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 36, height: 36)
            } else {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.icloud")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
        }
        .buttonStyle(.plain)
        .disabled(isProcessing || isRegisteringEvents || isSynchronizing || !isCloudSyncEnabled)
        .help("今すぐ同期")
    }

    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Image(systemName: "gearshape")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .help("設定")
    }

    private var schedulePickerButton: some View {
        Button {
            isImporterPresented = true
        } label: {
            Label("勤務表を選択", systemImage: "doc.viewfinder")
        }
#if os(iOS)
        .buttonStyle(ToolbarNavigationButtonStyleD(fillsAvailableWidth: true))
#else
        .buttonStyle(ToolbarUtilityButtonStyleD())
#endif
        .disabled(isProcessing)
    }

    private var savedScheduleButton: some View {
        Button {
            isSavedScheduleListPresented = true
        } label: {
            Label(
                ShiftHubLocalization.string("PDF一覧", locale: Locale(identifier: appLanguage)),
                systemImage: "folder"
            )
        }
#if os(iOS)
        .buttonStyle(ToolbarNavigationButtonStyleD(fillsAvailableWidth: true))
#else
        .buttonStyle(ToolbarUtilityButtonStyleD())
#endif
        .disabled(isProcessing)
    }

    private var removeScheduleButton: some View {
        Button {
            resetImportedSchedule()
        } label: {
            Image(systemName: "xmark.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isProcessing || isRegisteringEvents)
        .help("読み込みを解除")
    }

#if os(iOS)
    private var mobileHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            scheduleSelectionControls
            scheduleStatusRow
            registrationControls

            if isRegisteringEvents {
                ProgressView("カレンダーへ登録中です...")
                    .controlSize(.small)
            }

            workerSearchField
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .zIndex(1)
    }

    private var iOSScanHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    isShiftUploadPresented = false
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(ToolbarIconButtonStyleD())
                .accessibilityLabel("戻る")

                if isCloudSyncEnabled {
                    Button {
                        Task { @MainActor in
                            await synchronizeWithCloudKit()
                        }
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
            }
            .fixedSize(horizontal: true, vertical: false)

            Text("PDFスキャン")
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .center)
                .layoutPriority(1)

            HStack(spacing: 8) {
                Button {
                    isSettingsPresented = true
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
#endif

    private var extractedRowPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let selectedYearMonth {
                    Text(selectedYearMonth.displayText(for: locale))
                        .font(.title3.bold())
                } else {
                    Text("勤務表")
                        .font(.title3.bold())
                }

                Spacer()

                ShiftDisplayModePicker(
                    selection: $displayMode,
                    selectedSymbolColor: selectedCalendarDisplayColor?.color ?? .accentColor
                )
                .accessibilityLabel("表示形式")

//                Text("\(extractedCells.count)件")
//                    .font(.callout)
//                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if selectedFileName.isEmpty {
                            ContentUnavailableView(
                                label: {
                                    Label(
                                        localizedMessage("勤務表を選択"),
                                        systemImage: "doc.viewfinder"
                                    )
                                },
                                description: {
                                    Text(verbatim: localizedMessage("文字データを持つPDFの勤務表を選択"))
                                }
                            )
                            .frame(maxWidth: .infinity, minHeight: 120)
                        } else if isProcessing {
                            ProgressView("勤務表を解析中です...")
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else if workerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ContentUnavailableView(
                                "名前を入力してください",
                                systemImage: "person.text.rectangle",
                                description: Text("保存された名前を含む行だけを抽出します。")
                            )
                            .frame(maxWidth: .infinity, minHeight: 120)
                        } else if extractedCells.isEmpty {
                            ContentUnavailableView(
                                "該当する行が見つかりません",
                                systemImage: "tablecells.badge.ellipsis",
                                description: Text("PDFの文字データに名前が含まれているか確認してください。")
                            )
                            .frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            switch displayMode {
                            case .timeline:
                                timelineShiftView
                            case .calendar:
                                calendarShiftView(availableHeight: geometry.size.height)
                            case .list:
                                listShiftView
                            }
                        }
                    }
                    .padding(.trailing, 8)
                }
            }
            .frame(maxHeight: .infinity)
        }
#if os(iOS)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
#else
        .padding(24)
#endif
#if os(iOS)
        .sheet(item: $selectedExtractedDirectDayAction) { action in
            if let cell = extractedCells.first(where: { Int($0.dateText) == action.day }) {
                extractedShiftActionsPopover(for: cell, day: action.day)
                    .presentationDragIndicator(.visible)
                    .onDisappear {
                        selectedExtractedDirectDayAction = nil
                    }
            }
        }
#endif
    }

    private var timelineShiftView: some View {
        let cardWidth: CGFloat = 60
        let columns = [GridItem(.adaptive(minimum: cardWidth, maximum: cardWidth), spacing: 8)]

        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(extractedCells) { cell in
                shiftCellView(for: cell, width: cardWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var listShiftView: some View {
        let days = Array(Set(
            extractedCells
                .filter { !$0.valueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .compactMap { Int($0.dateText) }
        )).sorted()

        return LazyVStack(alignment: .leading, spacing: 12) {
            if days.isEmpty {
                ContentUnavailableView(
                    localizedMessage("表示するイベントがありません"),
                    systemImage: "list.bullet",
                    description: Text(localizedMessage("読み込まれたイベントがありません。"))
                )
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ForEach(days, id: \.self) { day in
                    Section {
                        ForEach(extractedCells.filter {
                            Int($0.dateText) == day &&
                            !$0.valueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }) { cell in
                            extractedListRowView(for: cell, day: day)
                        }
                    } header: {
                        Text(dayActionHeader(for: day))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func extractedListRowView(for cell: ExtractedShiftCell, day: Int) -> some View {
        Button {
            presentExtractedDayActions(for: cell, day: day)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(cell.valueText.trimmingCharacters(in: .whitespacesAndNewlines))
                    .foregroundStyle(cell.valueText == "休" ? .red : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(savedTimeText(for: cell) ?? "-")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                .background.secondary.opacity(0.45),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
#if os(macOS)
        .popover(
            isPresented: Binding(
                get: { selectedExtractedDayAction?.day == day },
                set: { isPresented in
                    if !isPresented, selectedExtractedDayAction?.day == day {
                        selectedExtractedDayAction = nil
                    }
                }
            )
        ) {
            extractedDayActionsPopover(for: day)
                .onDisappear {
                    if selectedExtractedDayAction?.day == day {
                        selectedExtractedDayAction = nil
                    }
                }
        }
#endif
    }

    private func calendarShiftView(availableHeight: CGFloat? = nil) -> some View {
#if os(iOS)
        let columns = Array(repeating: GridItem(.flexible(minimum: 38), spacing: 4), count: 7)
#else
        let columns = Array(repeating: GridItem(.flexible(minimum: 72), spacing: 8), count: 7)
#endif
        let leadingBlankCount = selectedYearMonth?.leadingBlankCount ?? 0
#if os(iOS)
        let rowCount = max(1, Int(ceil(Double(leadingBlankCount + extractedCells.count) / 7.0)))
        let weekdayHeaderHeight: CGFloat = 28
        let cardHeight = availableHeight.map { height in
            max(52, min(78, (height - weekdayHeaderHeight - CGFloat(rowCount) * 8) / CGFloat(rowCount)))
        } ?? 78
#else
        let cardHeight: CGFloat = 96
#endif

        return VStack(spacing: 8) {
            LazyVGrid(columns: columns, spacing: 8, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(0..<leadingBlankCount, id: \.self) { _ in
                        Color.clear
                            .frame(height: cardHeight)
                    }

                    ForEach(extractedCells) { cell in
                        calendarShiftCellView(for: cell, height: cardHeight)
                    }
                } header: {
                    calendarWeekdayHeader(columns: columns)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func calendarWeekdayHeader(columns: [GridItem]) -> some View {
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

    private func shiftCellView(for cell: ExtractedShiftCell, width: CGFloat) -> some View {
        let day = Int(cell.dateText)

        return Button {
            guard let day else { return }
            presentExtractedDayActions(for: cell, day: day)
        } label: {
            VStack(spacing: 0) {
                VStack(spacing: 2) {
                    Text(dayText(for: cell))
#if os(iOS)
                        .font(.caption.weight(.semibold))
#else
                        .font(.callout.weight(.semibold))
#endif

                    Text(weekdayText(for: cell))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 5)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
#if os(iOS)
                .background(
                    colorScheme == .dark
                        ? Color.white.opacity(0.10)
                        : Color.black.opacity(0.08)
                )
#else
                .background(.background.secondary)
#endif

                Text(cell.valueText.isEmpty ? " " : cell.valueText)
#if os(iOS)
                    .font(.system(size: 11, weight: .regular))
#else
                    .font(.body)
#endif
                    .foregroundStyle(cell.valueText == "休" ? .red : .primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
            }
            .contentShape(Rectangle())
        }
        .frame(width: width, height: 100)
        .background(.background.secondary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.trailing, 6)
        .buttonStyle(CalendarDayCardButtonStyle())
#if os(macOS)
        .popover(
            isPresented: Binding(
                get: { selectedExtractedDayAction?.day == day },
                set: { isPresented in
                    if !isPresented, selectedExtractedDayAction?.day == day {
                        selectedExtractedDayAction = nil
                    }
                }
            )
        ) {
            extractedDayActionsPopover(for: day ?? 0)
                .onDisappear {
                    // 先に閉じたポップオーバーが、新しい日付の選択を解除しないようにする。
                    if selectedExtractedDayAction?.day == day {
                        selectedExtractedDayAction = nil
                    }
                }
        }
#endif
        .disabled(day == nil || isProcessing || isRegisteringEvents)
    }

    private func calendarShiftCellView(for cell: ExtractedShiftCell, height: CGFloat = 96) -> some View {
        let day = Int(cell.dateText)

        return Button {
            guard let day else { return }
            presentExtractedDayActions(for: cell, day: day)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(dayText(for: cell))
#if os(iOS)
                    .font(.caption.weight(.semibold))
#else
                    .font(.body.weight(.semibold))
#endif

                Text(cell.valueText.isEmpty ? " " : cell.valueText)
#if os(iOS)
                    .font(.system(size: 11, weight: .regular))
#else
                    .font(.body)
#endif
                    .foregroundStyle(cell.valueText == "休" ? .red : .primary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .padding(10)
#if os(iOS)
            .frame(height: height, alignment: .top)
#else
            .frame(minHeight: 96)
#endif
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.background.secondary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            .clipped()
            .contentShape(Rectangle())
        }
#if os(iOS)
        .frame(height: height)
#endif
        .buttonStyle(CalendarDayCardButtonStyle())
#if os(macOS)
        .popover(
            isPresented: Binding(
                get: { selectedExtractedDayAction?.day == day },
                set: { isPresented in
                    if !isPresented, selectedExtractedDayAction?.day == day {
                        selectedExtractedDayAction = nil
                    }
                }
            )
        ) {
            extractedDayActionsPopover(for: day ?? 0)
                .onDisappear {
                    // 先に閉じたポップオーバーが、新しい日付の選択を解除しないようにする。
                    if selectedExtractedDayAction?.day == day {
                        selectedExtractedDayAction = nil
                    }
                }
        }
#endif
        .disabled(day == nil || isProcessing || isRegisteringEvents)
    }

    @ViewBuilder
    private func extractedDayActionsPopover(for day: Int) -> some View {
#if os(macOS)
        CalHubDateActionSheetContainer {
            extractedDayActionsPopoverContent(for: day)
        }
#else
        extractedDayActionsPopoverContent(for: day)
#endif
    }

    private func extractedDayActionsPopoverContent(for day: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(dayActionHeader(for: day))
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.bottom, 10)

            Divider()

            if let cell = extractedCells.first(where: { Int($0.dateText) == day }) {
#if os(iOS)
                List {
                    Button {
                        isExtractedShiftActionPresented = true
                    } label: {
                        HStack(spacing: 0) {
                            extractedShiftListRow(for: cell)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .popover(isPresented: $isExtractedShiftActionPresented) {
                        extractedShiftActionMenu(for: cell, day: day)
                            .fixedSize(horizontal: false, vertical: true)
                            .presentationCompactAdaptation(.popover)
                    }
                    .listRowInsets(EdgeInsets())
                }
                .listStyle(.plain)
                .frame(minHeight: 72, maxHeight: 100)
#else
                TextField(localizedMessage("イベント名"), text: $editedExtractedShiftText)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.top, 12)
                    .padding(.bottom, 6)

                if let detail = savedTimeText(for: cell) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .padding(.bottom, 12)
                }

                VStack(spacing: 8) {
                    Button {
                        presentExtractedShiftSelection(for: day)
                    } label: {
                        Label(localizedMessage("イベント一覧から選択"), systemImage: "list.bullet")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        applyEditedExtractedShift(for: day)
                    } label: {
                        Label(localizedMessage("変更を適用"), systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(editedExtractedShiftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(role: .destructive) {
                        deleteExtractedShift(for: day)
                    } label: {
                        Label(localizedMessage("削除"), systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
#endif
            }
        }
#if os(iOS)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
#endif
    }

#if os(iOS)
    private func extractedShiftListRow(for cell: ExtractedShiftCell) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cell.valueText.isEmpty ? " " : cell.valueText)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)

            if let detail = extractedShiftDetail(for: cell) {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func extractedShiftActionsPopover(
        for cell: ExtractedShiftCell,
        day: Int
    ) -> some View {
        let shiftName = cell.valueText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasShift = !shiftName.isEmpty
        let buttonHeight: CGFloat = 42
        let buttonSpacing: CGFloat = 8
        let dividerPadding: CGFloat = hasShift ? 12 : 10
        let fieldBottomPadding: CGFloat = 8

        return CalHubDateActionSheetContainer {
            VStack(alignment: .leading, spacing: 0) {
            Text(dayActionHeader(for: day))
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.bottom, 10)

            Divider()

            if hasShift {
                Text(shiftName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.top, 11)

                if let detail = extractedShiftDetail(for: cell) {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }

            Divider()
                .padding(.top, dividerPadding)

            if hasShift {
                TextField(localizedMessage("イベント名"), text: $editedExtractedShiftText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.bottom, fieldBottomPadding)
            }

            VStack(spacing: buttonSpacing) {
                Button {
                    isExtractedShiftActionPresented = false
                    selectedExtractedDirectDayAction = nil
                    presentExtractedShiftSelection(for: day)
                } label: {
                    Label(localizedMessage("イベント一覧から選択"), systemImage: "list.bullet")
                        .frame(maxWidth: .infinity, minHeight: buttonHeight, maxHeight: buttonHeight, alignment: .leading)
                }

                Button {
                    isExtractedShiftActionPresented = false
                    selectedExtractedDirectDayAction = nil
                    applyEditedExtractedShift(for: day)
                } label: {
                    Label(localizedMessage("変更を適用"), systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, minHeight: buttonHeight, maxHeight: buttonHeight, alignment: .leading)
                }
                .disabled(editedExtractedShiftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(role: .destructive) {
                    isExtractedShiftActionPresented = false
                    selectedExtractedDirectDayAction = nil
                    deleteExtractedShift(for: day)
                } label: {
                    Label(localizedMessage("削除"), systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: buttonHeight, maxHeight: buttonHeight, alignment: .leading)
                }
                .disabled(!hasShift)
                .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.top, 12)
            }
        }
    }

    private func extractedShiftActionMenu(for cell: ExtractedShiftCell, day: Int) -> some View {
        let shiftName = cell.valueText.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 0) {
            Text(dayActionHeader(for: day))
                .font(.headline)
                .foregroundStyle(.primary)

            Text(shiftName)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.top, 10)

            if let detail = extractedShiftDetail(for: cell) {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            Divider()
                .padding(.vertical, 12)

            TextField(localizedMessage("イベント名"), text: $editedExtractedShiftText)
                .textFieldStyle(.roundedBorder)
                .padding(.bottom, 10)

            VStack(spacing: 8) {
                Button {
                    isExtractedShiftActionPresented = false
                    presentExtractedShiftSelection(for: day)
                } label: {
                    Label(localizedMessage("イベント一覧から選択"), systemImage: "list.bullet")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    isExtractedShiftActionPresented = false
                    applyEditedExtractedShift(for: day)
                } label: {
                    Label(localizedMessage("変更を適用"), systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(editedExtractedShiftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(role: .destructive) {
                    isExtractedShiftActionPresented = false
                    deleteExtractedShift(for: day)
                } label: {
                    Label(localizedMessage("削除"), systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(16)
        .frame(minWidth: 280, alignment: .leading)
    }

    private func extractedShiftDetail(for cell: ExtractedShiftCell) -> String? {
        savedTimeText(for: cell)
    }
#endif

    private func savedTimeText(for cell: ExtractedShiftCell) -> String? {
        let normalizedTitle = normalizedShiftTitle(cell.valueText)
        guard !normalizedTitle.isEmpty else { return nil }

        if normalizedTitle == "休" {
            return localizedMessage("終日")
        }

        return shiftDefinitions.first {
            normalizedShiftTitle($0.title) == normalizedTitle
        }?.timeRangeText
    }

    private func presentExtractedDayActions(for cell: ExtractedShiftCell, day: Int) {
#if os(iOS)
        guard selectedExtractedDayAction == nil,
              selectedExtractedDirectDayAction == nil else { return }
#endif
        isRegistrationDestinationMenuPresented = false
        editedExtractedShiftText = cell.valueText
        let action = ExtractedDayAction(day: day)
#if os(iOS)
        Task { @MainActor in
            await Task.yield()
            selectedExtractedDirectDayAction = action
        }
#else
        Task { @MainActor in
            await Task.yield()
            selectedExtractedDayAction = action
        }
#endif
    }

    private func presentExtractedShiftSelection(for day: Int) {
        selectedExtractedDayAction = nil
#if os(iOS)
        isExtractedShiftActionPresented = false
        selectedExtractedDirectDayAction = nil
#endif
        pendingExtractedDayForEdit = day
        Task { @MainActor in
            await Task.yield()
            isExtractedShiftSelectionPresented = true
        }
    }

    private func applyEditedExtractedShift(for day: Int) {
        let title = editedExtractedShiftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              let index = extractedCells.firstIndex(where: { Int($0.dateText) == day }) else {
            return
        }

        let cell = extractedCells[index]
        var updatedCells = extractedCells
        updatedCells[index] = ExtractedShiftCell(
            dateText: cell.dateText,
            valueText: title,
            pageIndex: cell.pageIndex,
            boundingBox: cell.boundingBox
        )
        extractedCells = updatedCells
        editedExtractedShiftText = title
        selectedExtractedDayAction = nil
#if os(iOS)
        isExtractedShiftActionPresented = false
        selectedExtractedDirectDayAction = nil
#endif
        queueMissingShiftPromptsAfterEditing(title: title, cells: updatedCells)
        statusMessage = localizedMessage(
            "%@日のイベント名を変更しました。カレンダーへ登録すると反映されます。",
            arguments: String(day)
        )
    }

    private func deleteExtractedShift(for day: Int) {
        guard let index = extractedCells.firstIndex(where: { Int($0.dateText) == day }) else {
            return
        }

        let cell = extractedCells[index]
        extractedCells[index] = ExtractedShiftCell(
            dateText: cell.dateText,
            valueText: "",
            pageIndex: cell.pageIndex,
            boundingBox: cell.boundingBox
        )
        editedExtractedShiftText = ""
        selectedExtractedDayAction = nil
#if os(iOS)
        selectedExtractedDirectDayAction = nil
#endif
        statusMessage = localizedMessage("イベントを削除しました。")
    }

    private func completeExtractedShiftSelection(_ title: String) {
        guard let day = pendingExtractedDayForEdit,
              let index = extractedCells.firstIndex(where: { Int($0.dateText) == day }) else {
            return
        }

        let cell = extractedCells[index]
        var updatedCells = extractedCells
        updatedCells[index] = ExtractedShiftCell(
            dateText: cell.dateText,
            valueText: title,
            pageIndex: cell.pageIndex,
            boundingBox: cell.boundingBox
        )
        extractedCells = updatedCells
        editedExtractedShiftText = title
        pendingExtractedDayForEdit = nil
        isExtractedShiftSelectionPresented = false
#if os(iOS)
        isExtractedShiftActionPresented = false
#endif
        queueMissingShiftPromptsAfterEditing(title: title, cells: updatedCells)
        statusMessage = localizedMessage(
            "%@日のイベントを変更しました。カレンダーへ登録すると反映されます。",
            arguments: String(day)
        )
    }
    private func dayActionHeader(for day: Int) -> String {
        guard let selectedYearMonth,
              let weekdayIndex = selectedYearMonth.weekdayIndex(for: day) else {
            return "\(day)日"
        }

        let weekdays = locale.identifier.hasPrefix("en")
            ? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            : ["日", "月", "火", "水", "木", "金", "土"]
        let weekday = weekdays[weekdayIndex - 1]
        return locale.identifier.hasPrefix("en")
            ? "\(day) (\(weekday))"
            : "\(day)日（\(weekday)）"
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            saveAndAnalyzeImportedFile(at: url)
        case .failure(let error):
            statusMessage = localizedMessage("ファイルを選択できませんでした: %@", arguments: localizedError(error))
        }
    }

    private func resetImportedSchedule() {
        selectedFileName = ""
        selectedYearMonth = nil
        recognizedItems = []
        extractedCells = []
        pendingMissingShiftTitles = []
        ignoredMissingShiftTitles = []
        isMissingShiftSelectionPresented = false
        selectedExtractedDayAction = nil
#if os(iOS)
        isExtractedShiftActionPresented = false
#endif
        isExtractedShiftSelectionPresented = false
        pendingExtractedDayForEdit = nil
        editedExtractedShiftText = ""
        isRestRegistrationAlertPresented = false
        statusMessage = localizedMessage("勤務表の読み込みを解除しました。")
    }

    private func saveAndAnalyzeImportedFile(
        at url: URL,
        removeAfterUse: Bool = false,
        originalFileName: String? = nil
    ) {
        guard url.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame else {
            presentImportAlert(.unsupportedFile)
            return
        }

        isProcessing = true
        statusMessage = localizedMessage("PDFを確認中です。")

        Task {
            defer {
                if removeAfterUse {
                    try? FileManager.default.removeItem(at: url)
                }
            }

            do {
                // 文字データ層を確認できたPDFだけをアプリ内へ保存する。
                _ = try await analyzer.recognizeText(in: url)

                let result = try StoredScheduleStore.importFile(
                    from: url,
                    existing: savedSchedules,
                    fileName: originalFileName
                )
                if result.isNew {
                    savedSchedules.insert(result.schedule, at: 0)
                } else if let index = savedSchedules.firstIndex(where: { $0.id == result.schedule.id }),
                          savedSchedules[index] != result.schedule {
                    savedSchedules[index] = result.schedule
                }
                analyzeFile(at: result.url, displayName: result.schedule.fileName)
            } catch {
                if let analyzerError = error as? ShiftOCRAnalyzerError {
                    presentImportAlert(analyzerError)
                } else {
                    statusMessage = localizedMessage("勤務表を保存できませんでした: %@", arguments: localizedError(error))
                }
                isProcessing = false
            }
        }
    }

#if os(macOS)
    private func handlePDFDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isProcessing,
              let provider = providers.first(where: {
                  $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
              }) else {
            return false
        }

        provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
            guard let url else {
                Task { @MainActor in
                    statusMessage = localizedMessage(
                        "PDFを読み込めませんでした: %@",
                        arguments: error.map { localizedError($0) } ?? "Unknown error"
                    )
                }
                return
            }

            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("pdf")

            do {
                try FileManager.default.copyItem(at: url, to: temporaryURL)
            } catch {
                Task { @MainActor in
                    statusMessage = localizedMessage(
                        "PDFを読み込めませんでした: %@",
                        arguments: localizedError(error)
                    )
                }
                return
            }

            let originalFileName = url.lastPathComponent
            Task { @MainActor in
                saveAndAnalyzeImportedFile(
                    at: temporaryURL,
                    removeAfterUse: true,
                    originalFileName: originalFileName
                )
            }
        }
        return true
    }
#endif

    private func analyzeSavedSchedule(_ schedule: StoredSchedule) {
        do {
            let url = try StoredScheduleStore.fileURL(for: schedule)
            guard FileManager.default.fileExists(atPath: url.path) else {
                statusMessage = localizedMessage("保存した勤務表が見つかりません。")
                return
            }
            analyzeFile(at: url, displayName: schedule.fileName)
        } catch {
            statusMessage = localizedMessage("保存した勤務表を開けませんでした: %@", arguments: localizedError(error))
        }
    }

    private func deleteSavedSchedule(_ schedule: StoredSchedule) {
        do {
            try StoredScheduleStore.deleteFile(for: schedule)
            savedSchedules.removeAll { $0.id == schedule.id }
        } catch {
            statusMessage = localizedMessage("保存した勤務表を削除できませんでした: %@", arguments: localizedError(error))
        }
    }

    private func analyzeFile(at url: URL, displayName: String? = nil) {
        guard url.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame else {
            presentImportAlert(.unsupportedFile)
            return
        }

        isProcessing = true
        selectedFileName = displayName ?? url.lastPathComponent
        selectedYearMonth = Self.yearMonth(from: url)
        recognizedItems = []
        extractedCells = []
        pendingMissingShiftTitles = []
        ignoredMissingShiftTitles = []
        isMissingShiftSelectionPresented = false
        statusMessage = localizedMessage("PDFを解析中です。")

        Task {
            do {
                let items = try await analyzer.recognizeText(in: url)
                recognizedItems = items
                selectedYearMonth = analyzer.yearMonth(from: items) ?? selectedYearMonth
                extractedCells = analyzer.extractRowItems(matching: workerName, from: items, yearMonth: selectedYearMonth)
                queueMissingShiftPrompts(for: extractedCells)
                statusMessage = items.isEmpty
                    ? localizedMessage("文字を認識できませんでした。画像が暗い、傾いている、または解像度が低い可能性があります。")
                    : ""
            } catch {
                if let analyzerError = error as? ShiftOCRAnalyzerError {
                    presentImportAlert(analyzerError)
                } else {
                    statusMessage = localizedMessage("解析に失敗しました: %@", arguments: localizedError(error))
                }
            }

            isProcessing = false
        }
    }

    private func performWorkerSearch() {
        let sanitizedWorkerName = workerNameDraft.filter { !$0.isNumber }
        workerNameDraft = sanitizedWorkerName
        workerName = sanitizedWorkerName
        extractedCells = analyzer.extractRowItems(
            matching: sanitizedWorkerName,
            from: recognizedItems,
            yearMonth: selectedYearMonth
        )
        queueMissingShiftPrompts(for: extractedCells)
    }

    private func presentImportAlert(_ error: ShiftOCRAnalyzerError) {
        switch error {
        case .unsupportedFile:
            importAlertTitle = "PDFのみ対応しています"
            importAlertMessage = "JPGやPNGではなく、文字データを持つPDFを選択してください。"
        case .missingTextLayer:
            importAlertTitle = "取得できないPDFです"
            importAlertMessage = "文字データを持つPDFではありません。文字を選択・コピーできるPDFを使用してください。"
        case .unsupportedLayout:
            importAlertTitle = "対応していないPDFです"
            importAlertMessage = "横型で文字データを持つPDFを選択してください。縦型のPDFには対応していません。"
        case .unreadableFile:
            importAlertTitle = "PDFを読み込めません"
            importAlertMessage = "PDFファイルを開けませんでした。"
        }

        isImportAlertPresented = true
    }

    private func prepareCalendarRegistration() {
        guard !extractedCells.isEmpty else {
            statusMessage = localizedMessage("勤務表を読み込んでください。")
            return
        }

        guard CalendarDestination(rawValue: calendarDestination) != nil else {
            statusMessage = localizedMessage("登録先カレンダーの設定を確認してください。")
            return
        }

        let hasRestDays = extractedCells.contains { normalizedShiftTitle($0.valueText) == "休" }
        if hasRestDays {
            isRestRegistrationAlertPresented = true
        } else {
            registerSelectedCalendar(includeRest: false)
        }
    }

    private func registerSelectedCalendar(includeRest: Bool) {
        guard let targetYearMonth = selectedYearMonth else {
            statusMessage = localizedMessage("登録する年月を選択してください。")
            return
        }

        registrationPreview = makeRegistrationPreview(
            cells: extractedCells,
            yearMonth: targetYearMonth,
            includeRest: includeRest
        )
    }

    private func confirmPendingRegistration(_ preview: RegistrationPreview) {
        registrationPreview = nil
        performSelectedCalendarRegistration(
            cells: preview.cells,
            yearMonth: preview.yearMonth,
            includeRest: preview.includeRest
        )
    }

    private func performSelectedCalendarRegistration(
        cells: [ExtractedShiftCell],
        yearMonth: YearMonth,
        includeRest: Bool
    ) {
        switch CalendarDestination(rawValue: calendarDestination) ?? .apple {
        case .apple:
            registerAppleCalendarEvents(
                cells: cells,
                yearMonth: yearMonth,
                includeRest: includeRest
            )
        case .notion:
            registerNotionPages(
                cells: cells,
                yearMonth: yearMonth,
                includeRest: includeRest
            )
        case .google:
            registerGoogleCalendarEvents(
                cells: cells,
                yearMonth: yearMonth,
                includeRest: includeRest
            )
        }
    }

    private func makeRegistrationPreview(
        cells: [ExtractedShiftCell],
        yearMonth: YearMonth,
        includeRest: Bool
    ) -> RegistrationPreview {
        let definitionByTitle = Dictionary(
            uniqueKeysWithValues: shiftDefinitions.map { (normalizedShiftTitle($0.title), $0) }
        )
        let destination = CalendarDestination(rawValue: calendarDestination) ?? .apple
        let restTitle = registrationRestTitle(for: destination)
        var events: [RegistrationPreviewEvent] = []
        var excludedEvents: [RegistrationPreviewExcludedEvent] = []
        var skippedTitles: [String] = []
        var excludedCount = 0
        var invalidItems: [String] = []

        for cell in cells {
            let parsedDay = Int(cell.dateText)
            guard let day = parsedDay, (1...yearMonth.numberOfDays).contains(day) else {
                excludedCount += 1
                excludedEvents.append(
                    RegistrationPreviewExcludedEvent(
                        yearMonth: yearMonth,
                        day: nil,
                        rawDateText: cell.dateText,
                        title: normalizedShiftTitle(cell.valueText).isEmpty
                            ? localizedMessage("タイトル未設定")
                            : normalizedShiftTitle(cell.valueText),
                        startMinutes: nil,
                        endMinutes: nil,
                        reason: .invalidDate
                    )
                )
                continue
            }

            let title = normalizedShiftTitle(cell.valueText)
            guard !title.isEmpty else {
                excludedCount += 1
                excludedEvents.append(
                    RegistrationPreviewExcludedEvent(
                        yearMonth: yearMonth,
                        day: day,
                        rawDateText: cell.dateText,
                        title: localizedMessage("タイトル未設定"),
                        startMinutes: nil,
                        endMinutes: nil,
                        reason: .emptyTitle
                    )
                )
                continue
            }

            if title == "休" {
                guard includeRest else {
                    excludedCount += 1
                    excludedEvents.append(
                        RegistrationPreviewExcludedEvent(
                            yearMonth: yearMonth,
                            day: day,
                            rawDateText: cell.dateText,
                            title: restTitle,
                            startMinutes: nil,
                            endMinutes: nil,
                            reason: .restDisabled
                        )
                    )
                    continue
                }

                events.append(
                    RegistrationPreviewEvent(
                        yearMonth: yearMonth,
                        day: day,
                        title: restTitle,
                        startMinutes: nil,
                        endMinutes: nil
                    )
                )
                continue
            }

            guard let definition = definitionByTitle[title] else {
                if !skippedTitles.contains(title) {
                    skippedTitles.append(title)
                }
                excludedCount += 1
                excludedEvents.append(
                    RegistrationPreviewExcludedEvent(
                        yearMonth: yearMonth,
                        day: day,
                        rawDateText: cell.dateText,
                        title: title,
                        startMinutes: nil,
                        endMinutes: nil,
                        reason: .missingTitle
                    )
                )
                continue
            }

            guard (0...1_439).contains(definition.startMinutes),
                  (0...1_439).contains(definition.endMinutes),
                  definition.endMinutes >= definition.startMinutes else {
                invalidItems.append(title)
                continue
            }

            events.append(
                RegistrationPreviewEvent(
                    yearMonth: yearMonth,
                    day: day,
                    title: title,
                    startMinutes: definition.startMinutes,
                    endMinutes: definition.endMinutes
                )
            )
        }

        return RegistrationPreview(
            cells: cells,
            yearMonth: yearMonth,
            includeRest: includeRest,
            destinationTitle: destination.title,
            events: events,
            excludedEvents: excludedEvents,
            skippedTitles: skippedTitles,
            excludedCount: excludedCount,
            invalidItems: invalidItems
        )
    }

    private func registrationRestTitle(for destination: CalendarDestination) -> String {
        let configuredTitle: String
        switch destination {
        case .apple:
            configuredTitle = appleRestEventTitle
        case .google:
            configuredTitle = googleRestEventTitle
        case .notion:
            configuredTitle = notionRestEventTitle
        }

        let trimmedTitle = configuredTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "休" : trimmedTitle
    }

    private var restRegistrationMessage: String {
        if locale.identifier.hasPrefix("en") {
            if CalendarDestination(rawValue: calendarDestination) == .notion {
                return "Days off will be registered with a 00:00-23:59 time range."
            }

            return "Days off will be registered as all-day events without a specified time."
        }

        if CalendarDestination(rawValue: calendarDestination) == .notion {
            return "勤務表に含まれる「休」を、00:00〜23:59の時間付きデータとして登録できます。"
        }

        return "勤務表に含まれる「休」を、時間を指定しない終日イベントとして登録できます。"
    }

    private func registerAppleCalendarEvents(
        cells: [ExtractedShiftCell]? = nil,
        yearMonth: YearMonth? = nil,
        includeRest: Bool,
        onComplete: (() -> Void)? = nil
    ) {
        guard let targetYearMonth = yearMonth ?? selectedYearMonth else {
            statusMessage = localizedMessage("登録する年月を選択してください。")
            return
        }

        isRegisteringEvents = true
        statusMessage = localizedMessage("Appleカレンダーへ登録中です。")

        let writer = AppleCalendarEventWriter()
        do {
            let result = try writer.register(
                cells: cells ?? extractedCells,
                yearMonth: targetYearMonth,
                definitions: shiftDefinitions,
                calendarIdentifier: appleCalendarIdentifier,
                restTitle: appleRestEventTitle,
                includeRest: includeRest
            )

            let skippedMessage = result.skippedTitles.isEmpty
                ? ""
                : " " + localizedMessage(
                    "未登録のイベントはスキップしました: %@",
                    arguments: result.skippedTitles.joined(separator: ", ")
                )
            statusMessage = localizedMessage(
                "%@件をAppleカレンダーへ登録しました。%@",
                arguments: String(result.savedCount), skippedMessage
            )
            onComplete?()
        } catch {
            statusMessage = localizedMessage("Appleカレンダーへの登録に失敗しました: %@", arguments: localizedError(error))
        }

        isRegisteringEvents = false
    }

    private func registerNotionPages(
        cells: [ExtractedShiftCell]? = nil,
        yearMonth: YearMonth? = nil,
        includeRest: Bool,
        onComplete: (() -> Void)? = nil
    ) {
        guard let token = KeychainStore.string(for: "notion-access-token"),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !notionDataSourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = localizedMessage("NotionのアクセストークンとデータベースIDを設定してください。")
            return
        }

        guard let targetYearMonth = yearMonth ?? selectedYearMonth else {
            statusMessage = localizedMessage("登録する年月を選択してください。")
            return
        }

        isRegisteringEvents = true
        statusMessage = localizedMessage("Notionへ登録中です。")

        let writer = NotionPageWriter()
        let cells = cells ?? extractedCells
        let definitions = shiftDefinitions
        let dataSourceID = notionDataSourceID
        let titleProperty = notionTitleProperty
        let dateProperty = notionDateProperty
        let tagProperty = notionTagProperty
        let tagValue = notionTagValue
        let restTitle = notionRestEventTitle

        Task { @MainActor in
            do {
                let result = try await writer.register(
                    cells: cells,
                    yearMonth: targetYearMonth,
                    definitions: definitions,
                    token: token,
                    dataSourceID: dataSourceID,
                    titleProperty: titleProperty,
                    dateProperty: dateProperty,
                    tagProperty: tagProperty,
                    tagValue: tagValue,
                    restTitle: restTitle,
                    includeRest: includeRest
                )

                let skippedMessage = result.skippedTitles.isEmpty
                    ? ""
                    : " " + localizedMessage(
                        "未登録のイベントはスキップしました: %@",
                        arguments: result.skippedTitles.joined(separator: ", ")
                    )
                statusMessage = localizedMessage(
                    "%@件をNotionへ登録しました。%@",
                    arguments: String(result.savedCount), skippedMessage
                )
                onComplete?()
            } catch {
                statusMessage = localizedMessage("Notionへの登録に失敗しました: %@", arguments: localizedError(error))
            }

            isRegisteringEvents = false
        }
    }

    private func registerGoogleCalendarEvents(
        cells: [ExtractedShiftCell]? = nil,
        yearMonth: YearMonth? = nil,
        includeRest: Bool,
        onComplete: (() -> Void)? = nil
    ) {
        guard GoogleTokenStore.load() != nil else {
            statusMessage = localizedMessage("Google設定でログインとカレンダー選択を完了してください。")
            return
        }

        guard !googleCalendarID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = localizedMessage("Google設定で登録先カレンダーを選択してください。")
            return
        }

        guard let targetYearMonth = yearMonth ?? selectedYearMonth else {
            statusMessage = localizedMessage("登録する年月を選択してください。")
            return
        }

        isRegisteringEvents = true
        statusMessage = localizedMessage("Googleカレンダーへ登録中です。")

        let cells = cells ?? extractedCells
        let yearMonth = targetYearMonth
        let definitions = shiftDefinitions
        let calendarID = googleCalendarID
        let restTitle = googleRestEventTitle

        Task { @MainActor in
            do {
                let writer = GoogleCalendarEventWriter(clientID: GoogleOAuthConfiguration.clientID)
                let result = try await writer.register(
                    cells: cells,
                    yearMonth: yearMonth,
                    definitions: definitions,
                    calendarID: calendarID,
                    restTitle: restTitle,
                    includeRest: includeRest
                )

                let skippedMessage = result.skippedTitles.isEmpty
                    ? ""
                    : " " + localizedMessage(
                        "未登録のイベントはスキップしました: %@",
                        arguments: result.skippedTitles.joined(separator: ", ")
                    )
                statusMessage = localizedMessage(
                    "%@件をGoogleカレンダーへ登録しました。%@",
                    arguments: String(result.savedCount), skippedMessage
                )
                onComplete?()
            } catch {
                statusMessage = localizedMessage("Googleカレンダーへの登録に失敗しました: %@", arguments: localizedError(error))
            }

            isRegisteringEvents = false
        }
    }

    private func registerSingleShift(
        yearMonth: YearMonth,
        day: Int,
        title: String,
        onComplete: (() -> Void)? = nil
    ) {
        guard (1...yearMonth.numberOfDays).contains(day) else {
            statusMessage = localizedMessage("登録する日付が正しくありません。")
            return
        }

        let cell = ExtractedShiftCell(
            dateText: String(day),
            valueText: title,
            pageIndex: 0,
            boundingBox: .zero
        )
        let includeRest = normalizedShiftTitle(title) == "休"

        switch CalendarDestination(rawValue: calendarDestination) ?? .apple {
        case .apple:
            registerAppleCalendarEvents(
                cells: [cell],
                yearMonth: yearMonth,
                includeRest: includeRest,
                onComplete: onComplete
            )
        case .notion:
            registerNotionPages(
                cells: [cell],
                yearMonth: yearMonth,
                includeRest: includeRest,
                onComplete: onComplete
            )
        case .google:
            registerGoogleCalendarEvents(
                cells: [cell],
                yearMonth: yearMonth,
                includeRest: includeRest,
                onComplete: onComplete
            )
        }
    }

    private func registerDateTimeEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        onComplete: ((String) -> Void)? = nil
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            statusMessage = localizedMessage("イベントタイトルを入力してください。")
            return
        }

        let calendar = Calendar.current
        let normalizedStartDate = isAllDay ? calendar.startOfDay(for: startDate) : startDate
        let normalizedEndDate = isAllDay ? calendar.startOfDay(for: endDate) : endDate
        guard normalizedEndDate >= normalizedStartDate else {
            statusMessage = localizedMessage("終了日時は開始日時以降にしてください。")
            return
        }

        isRegisteringEvents = true
        let destination = CalendarDestination(rawValue: calendarDestination) ?? .apple

        switch destination {
        case .apple:
            statusMessage = localizedMessage("Appleカレンダーへ登録中です。")
            do {
                let eventID = try AppleCalendarEventWriter().registerDateTimeEvent(
                    title: trimmedTitle,
                    startDate: normalizedStartDate,
                    endDate: normalizedEndDate,
                    isAllDay: isAllDay,
                    calendarIdentifier: appleCalendarIdentifier
                )
                statusMessage = localizedMessage("Appleカレンダーへイベントを登録しました。")
                onComplete?(eventID)
            } catch {
                statusMessage = localizedMessage("Appleカレンダーへの登録に失敗しました: %@", arguments: localizedError(error))
            }
            isRegisteringEvents = false

        case .google:
            guard GoogleTokenStore.load() != nil else {
                statusMessage = localizedMessage("Google設定でログインとカレンダー選択を完了してください。")
                isRegisteringEvents = false
                return
            }

            guard !googleCalendarID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                statusMessage = localizedMessage("Google設定で登録先カレンダーを選択してください。")
                isRegisteringEvents = false
                return
            }

            statusMessage = localizedMessage("Googleカレンダーへ登録中です。")
            let calendarID = googleCalendarID
            Task { @MainActor in
                do {
                    let eventID = try await GoogleCalendarAPIClient(clientID: GoogleOAuthConfiguration.clientID).createEvent(
                        calendarID: calendarID,
                        title: trimmedTitle,
                        startDate: normalizedStartDate,
                        endDate: normalizedEndDate,
                        isAllDay: isAllDay
                    )
                    statusMessage = localizedMessage("Googleカレンダーへイベントを登録しました。")
                    onComplete?(eventID)
                } catch {
                    statusMessage = localizedMessage("Googleカレンダーへの登録に失敗しました: %@", arguments: localizedError(error))
                }
                isRegisteringEvents = false
            }

        case .notion:
            guard let token = KeychainStore.string(for: "notion-access-token"),
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !notionDataSourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                statusMessage = localizedMessage("NotionのアクセストークンとデータベースIDを設定してください。")
                isRegisteringEvents = false
                return
            }

            statusMessage = localizedMessage("Notionへ登録中です。")
            let writer = NotionPageWriter()
            let dataSourceID = notionDataSourceID
            let titleProperty = notionTitleProperty
            let dateProperty = notionDateProperty
            let tagProperty = notionTagProperty
            let tagValue = notionTagValue
            Task { @MainActor in
                do {
                    let eventID = try await writer.registerDateTimeEvent(
                        title: trimmedTitle,
                        startDate: normalizedStartDate,
                        endDate: normalizedEndDate,
                        isAllDay: isAllDay,
                        token: token,
                        dataSourceID: dataSourceID,
                        titleProperty: titleProperty,
                        dateProperty: dateProperty,
                        tagProperty: tagProperty,
                        tagValue: tagValue
                    )
                    statusMessage = localizedMessage("Notionへイベントを登録しました。")
                    onComplete?(eventID)
                } catch {
                    statusMessage = localizedMessage("Notionへの登録に失敗しました: %@", arguments: localizedError(error))
                }
                isRegisteringEvents = false
            }
        }
    }

    private func registerMultipleShifts(
        selections: [CalendarDaySelection],
        title: String,
        onComplete: (() -> Void)? = nil
    ) {
        let groupedSelections = Dictionary(grouping: selections) {
            "\($0.year)-\($0.month)"
        }
        let groups = groupedSelections.values.sorted {
            guard let lhs = $0.first, let rhs = $1.first else { return false }
            if lhs.year != rhs.year { return lhs.year < rhs.year }
            return lhs.month < rhs.month
        }

        guard !groups.isEmpty else { return }

        func registerGroup(at index: Int) {
            guard index < groups.count else {
                onComplete?()
                return
            }

            guard let first = groups[index].first else {
                registerGroup(at: index + 1)
                return
            }

            let yearMonth = first.yearMonth
            let cells = groups[index].sorted { $0.day < $1.day }.map { selection in
                ExtractedShiftCell(
                    dateText: String(selection.day),
                    valueText: title,
                    pageIndex: 0,
                    boundingBox: .zero
                )
            }
            let includeRest = normalizedShiftTitle(title) == "休"
            let next = RegistrationCompletion {
                registerGroup(at: index + 1)
            }

            switch CalendarDestination(rawValue: calendarDestination) ?? .apple {
            case .apple:
                registerAppleCalendarEvents(
                    cells: cells,
                    yearMonth: yearMonth,
                    includeRest: includeRest,
                    onComplete: next.call
                )
            case .notion:
                registerNotionPages(
                    cells: cells,
                    yearMonth: yearMonth,
                    includeRest: includeRest,
                    onComplete: next.call
                )
            case .google:
                registerGoogleCalendarEvents(
                    cells: cells,
                    yearMonth: yearMonth,
                    includeRest: includeRest,
                    onComplete: next.call
                )
            }
        }

        registerGroup(at: 0)
    }

    private func queueMissingShiftPrompts(for cells: [ExtractedShiftCell]) {
        guard !cells.isEmpty else { return }

        let savedTitles = Set(shiftDefinitions.map { normalizedShiftTitle($0.title) })
        let missingTitles = cells
            .flatMap { value -> [String] in
                let fullTitle = normalizedShiftTitle(value.valueText)

                // スラッシュを含む勤務も、分割せず1つのタイトルとして照合する。
                if isSavedShiftTitle(fullTitle, in: savedTitles) || fullTitle == "" || fullTitle == "休" {
                    return []
                }

                return [fullTitle]
            }
            .map(normalizedShiftTitle)
            .filter { !$0.isEmpty && $0 != "休" }
            .filter { !isSavedShiftTitle($0, in: savedTitles) }
            .filter { !ignoredMissingShiftTitles.contains($0) }

        var uniqueTitles: [String] = []
        for title in missingTitles where !uniqueTitles.contains(title) {
            uniqueTitles.append(title)
        }

        pendingMissingShiftTitles = uniqueTitles
        isMissingShiftSelectionPresented = !uniqueTitles.isEmpty
    }

    private func queueMissingShiftPromptsAfterEditing(
        title: String,
        cells: [ExtractedShiftCell]
    ) {
        ignoredMissingShiftTitles.remove(normalizedShiftTitle(title))

        Task { @MainActor in
            await Task.yield()
            queueMissingShiftPrompts(for: cells)
        }
    }

    private func completeMissingShiftSelection(
        _ selectedTitles: Set<String>,
        definitions: [ShiftDefinition]
    ) {
        let titlesToSave = pendingMissingShiftTitles.filter { selectedTitles.contains($0) }
        let titlesToIgnore = pendingMissingShiftTitles.filter { !selectedTitles.contains($0) }
        let definitionsByTitle = Dictionary(
            uniqueKeysWithValues: definitions.map { (normalizedShiftTitle($0.title), $0) }
        )
        let newDefinitions = titlesToSave.compactMap { title -> ShiftDefinition? in
            guard let definition = definitionsByTitle[normalizedShiftTitle(title)] else { return nil }
            guard !shiftDefinitions.contains(where: {
                normalizedShiftTitle($0.title) == normalizedShiftTitle(title)
            }) else { return nil }
            return definition
        }

        shiftDefinitions.append(contentsOf: newDefinitions)
        ignoredMissingShiftTitles.formUnion(titlesToIgnore.map(normalizedShiftTitle))
        pendingMissingShiftTitles = []
        isMissingShiftSelectionPresented = false

        if !newDefinitions.isEmpty {
            statusMessage = localizedMessage(
                "%@件のイベントをイベント一覧に保存しました。時間はイベント設定から変更できます。",
                arguments: String(newDefinitions.count)
            )
        } else if !titlesToIgnore.isEmpty {
            statusMessage = localizedMessage("選択したイベントをイベント一覧に保存しませんでした。")
        }
    }

    private func normalizedShiftTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "／", with: "/")
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isSavedShiftTitle(_ title: String, in savedTitles: Set<String>) -> Bool {
        guard !title.isEmpty else { return true }
        return savedTitles.contains(title)
    }

    private func dayText(for cell: ExtractedShiftCell) -> String {
        guard let day = Int(cell.dateText) else {
            return cell.dateText.isEmpty
                ? localizedMessage("日付未判定")
                : cell.dateText
        }

        return String(day)
    }

    private func weekdayText(for cell: ExtractedShiftCell) -> String {
        guard let day = Int(cell.dateText),
              let selectedYearMonth,
              let weekdayIndex = selectedYearMonth.weekdayIndex(for: day) else {
            return ""
        }

        let weekdays = locale.identifier.hasPrefix("en")
            ? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            : ["日", "月", "火", "水", "木", "金", "土"]
        return weekdays[weekdayIndex - 1]
    }

    private static func yearMonth(from url: URL) -> YearMonth? {
        let fileName = url.deletingPathExtension().lastPathComponent
        let parts = fileName.split(separator: "-")
        guard parts.count >= 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              (1...12).contains(month) else {
            return nil
        }

        return YearMonth(year: year, month: month)
    }

    private static func loadShiftDefinitions(from json: String) -> [ShiftDefinition] {
        guard let data = json.data(using: .utf8),
              let definitions = try? JSONDecoder().decode([ShiftDefinition].self, from: data) else {
            return []
        }

        return definitions
    }

    private func syncCloudSettings() {
        guard isCloudSyncEnabled else { return }
        ShiftHubCloudSync.saveSettings(cloudSettingsSnapshot)
    }

    private var cloudSettingsSnapshot: ShiftHubCloudSettings {
        ShiftHubCloudSettings(
            appLanguage: appLanguage,
            workerName: workerName,
            shiftDefinitionsJSON: shiftDefinitionsJSON,
            calendarDestination: calendarDestination,
            appleCalendarIdentifier: appleCalendarIdentifier,
            appleRestEventTitle: appleRestEventTitle,
            googleCalendarClientID: GoogleOAuthConfiguration.clientID,
            googleCalendarID: googleCalendarID,
            googleRestEventTitle: googleRestEventTitle,
            notionDataSourceID: notionDataSourceID,
            notionTitleProperty: notionTitleProperty,
            notionDateProperty: notionDateProperty,
            notionTagProperty: notionTagProperty,
            notionTagValue: notionTagValue,
            notionRestEventTitle: notionRestEventTitle
        )
    }

    private func applyCloudSettings(_ settings: ShiftHubCloudSettings) {
        appLanguage = settings.appLanguage
        workerName = settings.workerName.filter { !$0.isNumber }
        workerNameDraft = workerName
        shiftDefinitionsJSON = settings.shiftDefinitionsJSON
        shiftDefinitions = Self.loadShiftDefinitions(from: settings.shiftDefinitionsJSON)
        calendarDestination = settings.calendarDestination
        // EventKit calendar identifiers are local to the device and must not be
        // restored from another Mac or iPhone through iCloud.
        appleRestEventTitle = settings.appleRestEventTitle
        googleCalendarID = settings.googleCalendarID
        googleRestEventTitle = settings.googleRestEventTitle
        notionDataSourceID = settings.notionDataSourceID
        notionTitleProperty = settings.notionTitleProperty
        notionDateProperty = settings.notionDateProperty
        notionTagProperty = settings.notionTagProperty
        notionTagValue = settings.notionTagValue
        notionRestEventTitle = settings.notionRestEventTitle
    }

    private func synchronizeWithCloudKit() async {
        guard isCloudSyncEnabled, !isSynchronizing else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }

        let settingsResult = await ShiftHubCloudSync.loadSettingsFromCloudKit()
        switch settingsResult {
        case .success(let settings):
            if let settings {
                applyCloudSettings(settings)
            } else {
                ShiftHubCloudSync.saveSettings(cloudSettingsSnapshot)
            }
        case .failure:
            break
        }

        let schedulesResult = await ShiftHubCloudSync.synchronizeSchedulesFromCloudKit(
            with: savedSchedules
        )
        if case .success(let schedules) = schedulesResult {
            savedSchedules = Self.removeInvalidStoredSchedules(from: schedules)
        }

        isCloudKitStateLoaded = true
    }

    private static func shiftDefinitionsJSON(from definitions: [ShiftDefinition]) -> String {
        guard let data = try? JSONEncoder().encode(definitions),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return json
    }

    private static func loadStoredSchedules(from json: String) -> [StoredSchedule] {
        guard let data = json.data(using: .utf8),
              let schedules = try? JSONDecoder().decode([StoredSchedule].self, from: data) else {
            return []
        }

        return schedules.sorted { $0.importedAt > $1.importedAt }
    }

    private static func removeInvalidStoredSchedules(from schedules: [StoredSchedule]) -> [StoredSchedule] {
        schedules.filter { schedule in
            guard URL(fileURLWithPath: schedule.fileName).pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame else {
                try? StoredScheduleStore.deleteFile(for: schedule)
                return false
            }

            guard let url = try? StoredScheduleStore.fileURL(for: schedule),
                  FileManager.default.fileExists(atPath: url.path) else {
                return true
            }

            guard let document = PDFDocument(url: url), document.pageCount > 0 else {
                try? StoredScheduleStore.deleteFile(for: schedule)
                return false
            }

            let hasTextLayer = (0..<document.pageCount).contains { pageIndex in
                guard let pageText = document.page(at: pageIndex)?.string else {
                    return false
                }
                return !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let isHorizontal = ShiftOCRAnalyzer.supportsHorizontalTextLayout(document)

            if !hasTextLayer || !isHorizontal {
                try? StoredScheduleStore.deleteFile(for: schedule)
            }
            return hasTextLayer && isHorizontal
        }
    }

    private static func storedSchedulesJSON(from schedules: [StoredSchedule]) -> String {
        guard let data = try? JSONEncoder().encode(schedules),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return json
    }
}

struct SavedScheduleRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        configuration.label
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 62, alignment: .leading)
            .background(
                .white.opacity(configuration.isPressed ? 0.12 : 0.055),
                in: shape
            )
            .overlay {
                shape.stroke(.white.opacity(configuration.isPressed ? 0.25 : 0.1), lineWidth: 1)
            }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct ShiftSelectionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                .background.secondary.opacity(configuration.isPressed ? 0.82 : 0.48),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(configuration.isPressed ? 0.22 : 0.08), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct PendingShiftRegistration {
    let day: Int
    let event: CalendarEventRecord?
    let deleteExisting: Bool
}

final class RegistrationCompletion {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func call() {
        action()
    }
}

final class DateTimeEventRegistrationCompletion {
    private let action: (String) -> Void

    init(action: @escaping (String) -> Void) {
        self.action = action
    }

    func call(eventID: String) {
        action(eventID)
    }
}

struct ToolbarSelectorButtonStyleD: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let fillsAvailableWidth: Bool
    let buttonHeight: CGFloat

    init(fillsAvailableWidth: Bool = false, buttonHeight: CGFloat = 40) {
        self.fillsAvailableWidth = fillsAvailableWidth
        self.buttonHeight = buttonHeight
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 1 : 0.9))
            .padding(.horizontal, 13)
            .frame(
                minWidth: 36,
                maxWidth: fillsAvailableWidth ? .infinity : nil,
                minHeight: buttonHeight,
                maxHeight: buttonHeight
            )
            .background(.white.opacity(configuration.isPressed ? 0.16 : 0.07), in: shape)
            .overlay {
                shape.stroke(.white.opacity(configuration.isPressed ? 0.34 : 0.14), lineWidth: 1)
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct ToolbarNavigationButtonStyleD: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let accented: Bool
    let fillsAvailableWidth: Bool

    init(accented: Bool = false, fillsAvailableWidth: Bool = false) {
        self.accented = accented
        self.fillsAvailableWidth = fillsAvailableWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 1 : 0.9))
#if os(iOS)
            .fixedSize(horizontal: !fillsAvailableWidth, vertical: false)
            .padding(.horizontal, 8)
            .frame(
                minWidth: 0,
                maxWidth: fillsAvailableWidth ? .infinity : nil,
                minHeight: 40,
                maxHeight: 40,
                alignment: .center
            )
#else
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .frame(minWidth: 150, minHeight: 44, maxHeight: 44, alignment: .center)
#endif
            .background(
                accented
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.23 : 0.13)
                    : Color.white.opacity(configuration.isPressed ? 0.13 : 0.055),
                in: shape
            )
            .overlay {
                shape.stroke(
                    accented
                        ? Color.accentColor.opacity(configuration.isPressed ? 0.8 : 0.42)
                        : Color.white.opacity(configuration.isPressed ? 0.3 : 0.12),
                    lineWidth: 1
                )
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct ToolbarUtilityButtonStyleD: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 1 : 0.76))
            .padding(.horizontal, 10)
            .frame(minWidth: 36, minHeight: 32, maxHeight: 32)
            .background(.white.opacity(configuration.isPressed ? 0.12 : 0.035), in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct ToolbarIconButtonStyleD: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = Circle()

        configuration.label
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 1 : 0.86))
            .background(.white.opacity(configuration.isPressed ? 0.14 : 0.06), in: shape)
            .overlay {
                shape
                    .stroke(.white.opacity(configuration.isPressed ? 0.3 : 0.1), lineWidth: 1)
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct CalendarDayCardButtonStyle: ButtonStyle {
    let accent: Color
    let isSelectionMode: Bool

    init(accent: Color = .accentColor, isSelectionMode: Bool = false) {
        self.accent = accent
        self.isSelectionMode = isSelectionMode
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isSelectionMode ? 1 : (configuration.isPressed ? 0.97 : 1))
            .opacity(isSelectionMode ? 1 : (configuration.isPressed ? 0.68 : 1))
            .overlay {
                if !isSelectionMode {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(accent.opacity(configuration.isPressed ? 1 : 0), lineWidth: 2)
                }
            }
            .animation(isSelectionMode ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct ShiftDefinitionRowView: View {
    @Binding var definition: ShiftDefinition
    let editAction: () -> Void
    let deleteAction: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
#if os(iOS)
        iOSRow
#else
        macOSRow
#endif
    }

#if os(iOS)
    private var iOSRow: some View {
        HStack(spacing: 6) {
            Text(definition.title)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(definition.timeRangeText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

#else
    private var macOSRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 18)

            Text(definition.title)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(definition.timeRangeText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 90, alignment: .leading)

            Button(action: editAction) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .frame(width: 24)
            .accessibilityLabel(ShiftHubLocalization.string("編集", locale: locale))
            .help(ShiftHubLocalization.string("編集", locale: locale))

            Button(role: .destructive, action: deleteAction) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .frame(width: 24)
            .accessibilityLabel("削除")
            .help("削除")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
    }
#endif
}

private struct ExtractedDayAction: Identifiable, Equatable {
    let day: Int

    var id: Int { day }
}
