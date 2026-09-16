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

private struct CalHubDateActionSheetHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CalHubDateActionSheetContainer<Content: View>: View {
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

private extension Notification.Name {
    static let shiftHubSettingsDidChange = Notification.Name("ShiftHubSettingsDidChange")
    static let shiftHubScanStoredSchedule = Notification.Name("ShiftHubScanStoredSchedule")
}

private enum GoogleOAuthConfiguration {
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

private enum ShiftHubLocalization {
    static func string(_ key: String, locale: Locale) -> String {
        let language = locale.identifier.hasPrefix("en") ? "en" : "ja"
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }

        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, locale: Locale, arguments: CVarArg...) -> String {
        String(format: string(key, locale: locale), arguments: arguments)
    }

    static func isEnglish(_ locale: Locale) -> Bool {
        locale.identifier.hasPrefix("en")
    }

    static func yearText(_ year: Int, locale: Locale) -> String {
        String(year)
    }

    static func monthText(_ month: Int, locale: Locale) -> String {
        String(format: "%02d", month)
    }

    static func localizedErrorDescription(_ error: Error, locale: Locale) -> String {
        let description = error.localizedDescription
        let exactKeys = [
            "カレンダーへのアクセスが許可されていません。",
            "登録先カレンダーが見つかりません。",
            "カレンダーから無効な応答が返されました。",
            "イベントの日付を作成できませんでした。",
            "Googleログイン画面を開けませんでした。",
            "Googleログインがキャンセルされました。",
            "Google認証の確認に失敗しました。もう一度ログインしてください。",
            "Googleから無効な応答が返されました。",
            "先にGoogleへログインしてください。",
            "勤務表の年月を取得できませんでした。",
            "Notionの設定を確認してください。",
            "Notionから無効な応答が返されました。",
            "Googleの認証設定を確認してください。",
            "NotionのアクセストークンとデータベースIDを設定してください。",
            "Notionのアクセストークンを設定してください。",
            "不明なエラー"
        ]
        if exactKeys.contains(description) {
            return string(description, locale: locale)
        }

        let prefixes = [
            "Google Calendar APIエラー: ": "Google Calendar APIエラー: %@",
            "Notion APIエラー（": "Notion APIエラー（%@）: %@",
            "日付を作成できませんでした: ": "日付を作成できませんでした: %@",
            "認証トークンを更新できませんでした (HTTP ": "認証トークンを更新できませんでした (HTTP %@): %@"
        ]
        for (prefix, key) in prefixes where description.hasPrefix(prefix) {
            if prefix == "Google Calendar APIエラー: " {
                return format(key, locale: locale, arguments: String(description.dropFirst(prefix.count)))
            }

            if prefix == "日付を作成できませんでした: " {
                return format(key, locale: locale, arguments: String(description.dropFirst(prefix.count)))
            }

            if prefix == "認証トークンを更新できませんでした (HTTP " {
                let remainder = String(description.dropFirst(prefix.count))
                guard let separator = remainder.range(of: "):")?.lowerBound else { break }
                let status = String(remainder[..<separator])
                let message = String(remainder[remainder.index(separator, offsetBy: 2)...])
                return format(key, locale: locale, arguments: status, message)
            }

            let remainder = String(description.dropFirst(prefix.count))
            guard let separator = remainder.firstIndex(of: "）") else { break }
            let status = String(remainder[..<separator])
            let messageStart = remainder.index(after: separator)
            let message = String(remainder[messageStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return format(key, locale: locale, arguments: status, message)
        }

        return description
    }
}

@MainActor
struct ContentView: View {
    @Environment(\.locale) private var locale
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
    @State private var isRegisteringEvents = false
    @State private var selectedFileName = ""
    @State private var selectedYearMonth: YearMonth?
    @State private var recognizedItems: [RecognizedTextItem] = []
    @State private var extractedCells: [ExtractedShiftCell] = []
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
    @State private var isCloudKitStateLoaded = false

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
            MissingShiftSelectionView(titles: pendingMissingShiftTitles) { selectedTitles in
                completeMissingShiftSelection(selectedTitles)
            }
        }
        .sheet(isPresented: $isExtractedShiftSelectionPresented) {
            ShiftSelectionView(definitions: shiftDefinitions, locale: locale) { title in
                completeExtractedShiftSelection(title)
            }
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
            header
                .zIndex(1)
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
        .navigationTitle("PDFスキャン")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("PDFスキャン")
                    .font(.headline)
            }

            if isCloudSyncEnabled {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { @MainActor in
                            await synchronizeWithCloudKit()
                        }
                    } label: {
                        if isSynchronizing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.icloud")
                        }
                    }
                    .accessibilityLabel("今すぐ同期")
                    .disabled(isSynchronizing)
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                registrationActionButton
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("設定")
            }
        }
#endif
#if os(macOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

            Spacer(minLength: 8)

            registrationActionButton
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
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Name...", text: $workerName)
                .textFieldStyle(.plain)
                .onChange(of: workerName) {
                    extractedCells = analyzer.extractRowItems(
                        matching: workerName,
                        from: recognizedItems,
                        yearMonth: selectedYearMonth
                    )
                    queueMissingShiftPrompts(for: extractedCells)
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

                Picker("表示", selection: $displayMode) {
                    ForEach(ShiftDisplayMode.allCases) { mode in
                        Image(systemName: mode.systemImage)
                            .help(mode.title)
                            .accessibilityLabel(mode.title)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 92)
                .accessibilityLabel("表示形式")
                .labelsHidden()

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
        VStack(alignment: .leading, spacing: 0) {
            Text(dayActionHeader(for: day))
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.bottom, 14)

            Divider()
                .padding(.bottom, 6)

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
                TextField("イベント名", text: $editedExtractedShiftText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                VStack(spacing: 8) {
                    Button {
                        presentExtractedShiftSelection(for: day)
                    } label: {
                        Label("イベント一覧から選択", systemImage: "list.bullet")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        applyEditedExtractedShift(for: day)
                    } label: {
                        Label("変更を適用", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(editedExtractedShiftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(role: .destructive) {
                        deleteExtractedShift(for: day)
                    } label: {
                        Label("削除", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
#endif
            }
        }
#if os(iOS)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
#else
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 250, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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
                TextField("イベント名", text: $editedExtractedShiftText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.bottom, fieldBottomPadding)
            }

            VStack(spacing: buttonSpacing) {
                Button {
                    isExtractedShiftActionPresented = false
                    selectedExtractedDirectDayAction = nil
                    presentExtractedShiftSelection(for: day)
                } label: {
                    Label("イベント一覧から選択", systemImage: "list.bullet")
                        .frame(maxWidth: .infinity, minHeight: buttonHeight, maxHeight: buttonHeight, alignment: .leading)
                }

                Button {
                    isExtractedShiftActionPresented = false
                    selectedExtractedDirectDayAction = nil
                    applyEditedExtractedShift(for: day)
                } label: {
                    Label("変更を適用", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, minHeight: buttonHeight, maxHeight: buttonHeight, alignment: .leading)
                }
                .disabled(editedExtractedShiftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(role: .destructive) {
                    isExtractedShiftActionPresented = false
                    selectedExtractedDirectDayAction = nil
                    deleteExtractedShift(for: day)
                } label: {
                    Label("削除", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: buttonHeight, maxHeight: buttonHeight, alignment: .leading)
                }
                .disabled(!hasShift)
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

            TextField("イベント名", text: $editedExtractedShiftText)
                .textFieldStyle(.roundedBorder)
                .padding(.bottom, 10)

            VStack(spacing: 8) {
                Button {
                    isExtractedShiftActionPresented = false
                    presentExtractedShiftSelection(for: day)
                } label: {
                    Label("イベント一覧から選択", systemImage: "list.bullet")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    isExtractedShiftActionPresented = false
                    applyEditedExtractedShift(for: day)
                } label: {
                    Label("変更を適用", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(editedExtractedShiftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(role: .destructive) {
                    isExtractedShiftActionPresented = false
                    deleteExtractedShift(for: day)
                } label: {
                    Label("削除", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(16)
        .frame(minWidth: 280, alignment: .leading)
    }

    private func extractedShiftDetail(for cell: ExtractedShiftCell) -> String? {
        let normalizedTitle = cell.valueText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedShiftTitle(normalizedTitle) == "休" {
            return localizedMessage("終日")
        }

        return shiftDefinitions.first(where: { $0.title == normalizedTitle })?.timeRangeText
    }
#endif

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
        extractedCells[index] = ExtractedShiftCell(
            dateText: cell.dateText,
            valueText: title,
            pageIndex: cell.pageIndex,
            boundingBox: cell.boundingBox
        )
        editedExtractedShiftText = title
        selectedExtractedDayAction = nil
#if os(iOS)
        isExtractedShiftActionPresented = false
        selectedExtractedDirectDayAction = nil
#endif
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
        extractedCells[index] = ExtractedShiftCell(
            dateText: cell.dateText,
            valueText: title,
            pageIndex: cell.pageIndex,
            boundingBox: cell.boundingBox
        )
        editedExtractedShiftText = title
        pendingExtractedDayForEdit = nil
        isExtractedShiftSelectionPresented = false
#if os(iOS)
        isExtractedShiftActionPresented = false
#endif
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

    private func saveAndAnalyzeImportedFile(at url: URL) {
        guard url.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame else {
            presentImportAlert(.unsupportedFile)
            return
        }

        isProcessing = true
        statusMessage = localizedMessage("PDFを確認中です。")

        Task {
            do {
                // 文字データ層を確認できたPDFだけをアプリ内へ保存する。
                _ = try await analyzer.recognizeText(in: url)

                let result = try StoredScheduleStore.importFile(from: url, existing: savedSchedules)
                if result.isNew {
                    savedSchedules.insert(result.schedule, at: 0)
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
        switch CalendarDestination(rawValue: calendarDestination) ?? .apple {
        case .apple:
            registerAppleCalendarEvents(includeRest: includeRest)
        case .notion:
            registerNotionPages(includeRest: includeRest)
        case .google:
            registerGoogleCalendarEvents(includeRest: includeRest)
        }
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

    private func completeMissingShiftSelection(_ selectedTitles: Set<String>) {
        let titlesToSave = pendingMissingShiftTitles.filter { selectedTitles.contains($0) }
        let titlesToIgnore = pendingMissingShiftTitles.filter { !selectedTitles.contains($0) }
        let newTitles = titlesToSave.filter { title in
            !shiftDefinitions.contains { normalizedShiftTitle($0.title) == normalizedShiftTitle(title) }
        }

        shiftDefinitions.append(contentsOf: newTitles.map {
            ShiftDefinition(title: $0, startMinutes: 510, endMinutes: 1000)
        })
        ignoredMissingShiftTitles.formUnion(titlesToIgnore.map(normalizedShiftTitle))
        pendingMissingShiftTitles = []
        isMissingShiftSelectionPresented = false

        if !newTitles.isEmpty {
            statusMessage = localizedMessage(
                "%@件のイベントをイベント一覧に保存しました。時間はイベント設定から変更できます。",
                arguments: String(newTitles.count)
            )
        } else if !titlesToIgnore.isEmpty {
            statusMessage = localizedMessage("選択したイベントをイベント一覧に保存しませんでした。")
        }
    }

    private func normalizedShiftTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "／", with: "/")
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "*", with: "")
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
        workerName = settings.workerName
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

struct StoredSchedule: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let fileName: String
    let storedFileName: String
    let checksum: String
    let importedAt: Date
}

struct StoredScheduleImportResult {
    let schedule: StoredSchedule
    let url: URL
    let isNew: Bool
}

enum StoredScheduleStore {
    private static let directoryName = "SavedSchedules"

    static func loadSchedules() -> [StoredSchedule] {
        guard let json = UserDefaults.standard.string(forKey: "storedSchedulesJSON"),
              let data = json.data(using: .utf8),
              let schedules = try? JSONDecoder().decode([StoredSchedule].self, from: data) else {
            return []
        }

        return schedules.sorted { $0.importedAt > $1.importedAt }
    }

    static func importFile(from sourceURL: URL, existing: [StoredSchedule]) throws -> StoredScheduleImportResult {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: sourceURL)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directoryURL = try directoryURL()

        if let existingSchedule = existing.first(where: { $0.checksum == checksum }) {
            let existingURL = directoryURL.appendingPathComponent(existingSchedule.storedFileName)
            if !FileManager.default.fileExists(atPath: existingURL.path) {
                try data.write(to: existingURL, options: .atomic)
            }
            return StoredScheduleImportResult(
                schedule: existingSchedule,
                url: existingURL,
                isNew: false
            )
        }

        let id = UUID()
        let pathExtension = sourceURL.pathExtension.isEmpty ? "" : ".\(sourceURL.pathExtension)"
        let storedFileName = "\(id.uuidString)\(pathExtension)"
        let storedURL = directoryURL.appendingPathComponent(storedFileName)
        try data.write(to: storedURL, options: .atomic)

        let schedule = StoredSchedule(
            id: id,
            fileName: sourceURL.lastPathComponent,
            storedFileName: storedFileName,
            checksum: checksum,
            importedAt: Date()
        )
        ShiftHubCloudSync.mirrorPDF(from: storedURL, named: storedFileName)
        return StoredScheduleImportResult(schedule: schedule, url: storedURL, isNew: true)
    }

    static func fileURL(for schedule: StoredSchedule) throws -> URL {
        try directoryURL().appendingPathComponent(schedule.storedFileName)
    }

    static func deleteFile(for schedule: StoredSchedule) throws {
        let url = try fileURL(for: schedule)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        ShiftHubCloudSync.removePDF(named: schedule.storedFileName)
    }

    private static func directoryURL() throws -> URL {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = applicationSupportURL.appendingPathComponent(
            "Shift Upload/\(directoryName)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }
}

private struct SavedScheduleListView: View {
    let schedules: [StoredSchedule]
    let onSelect: (StoredSchedule) -> Void
    let onDelete: (StoredSchedule) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.japanese.rawValue
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#else
    @State private var previewSchedule: StoredSchedule?
#endif

    private var displayLocale: Locale {
        Locale(identifier: appLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ShiftHubLocalization.string("PDF一覧", locale: displayLocale))
                        .font(.title2.bold())

                    Text(ShiftHubLocalization.string("保存した勤務表を選択して解析します。", locale: displayLocale))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 10) {
                    Text("\(schedules.count)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button(ShiftHubLocalization.string("完了", locale: displayLocale)) {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)

            if schedules.isEmpty {
                ContentUnavailableView(
                    ShiftHubLocalization.string("保存した勤務表がありません", locale: displayLocale),
                    systemImage: "folder",
                    description: Text(
                        ShiftHubLocalization.string("勤務表を選択すると、ここに保存されます。", locale: displayLocale)
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(schedules) { schedule in
                        HStack(spacing: 8) {
                            Button {
                                onSelect(schedule)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text.fill")
                                        .font(.title3)
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 38, height: 38)
                                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(schedule.fileName)
                                            .font(.body.weight(.semibold))
                                            .lineLimit(1)

                                        Text(schedule.importedAt, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 4)
                                }
                            }
                            .buttonStyle(SavedScheduleRowButtonStyle())

                            Button {
#if os(macOS)
                                openWindow(id: "pdf-preview", value: schedule)
#else
                                previewSchedule = schedule
#endif
                            } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("保存したPDFを表示")
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                onDelete(schedule)
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
#if os(iOS)
        .sheet(item: $previewSchedule) { schedule in
            SavedSchedulePreviewView(
                schedule: schedule,
                onSelect: { selectedSchedule in
                    previewSchedule = nil
                    onSelect(selectedSchedule)
                }
            )
        }
#endif
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        .frame(width: 540, height: 440)
#endif
    }
}

private struct PDFListView: View {
    let schedules: [StoredSchedule]
    let onDelete: (StoredSchedule) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.japanese.rawValue
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#else
    @State private var previewSchedule: StoredSchedule?
#endif

    private var displayLocale: Locale {
        Locale(identifier: appLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ShiftHubLocalization.string("PDF一覧", locale: displayLocale))
                        .font(.title2.bold())

                    Text(ShiftHubLocalization.string("保存したPDFを表示または削除できます。", locale: displayLocale))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 10) {
                    Text("\(schedules.count)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button(ShiftHubLocalization.string("完了", locale: displayLocale)) {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)

            if schedules.isEmpty {
                ContentUnavailableView(
                    ShiftHubLocalization.string("保存したPDFがありません", locale: displayLocale),
                    systemImage: "folder",
                    description: Text(
                        ShiftHubLocalization.string("PDFを読み込むと、ここに保存されます。", locale: displayLocale)
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(schedules) { schedule in
                        HStack(spacing: 8) {
                            Button {
#if os(macOS)
                                openWindow(id: "pdf-viewer", value: schedule)
#else
                                previewSchedule = schedule
#endif
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text.fill")
                                        .font(.title3)
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 38, height: 38)
                                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(schedule.fileName)
                                            .font(.body.weight(.semibold))
                                            .lineLimit(1)

                                        Text(schedule.importedAt, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 4)
                                }
                            }
                            .buttonStyle(SavedScheduleRowButtonStyle())

                            Button(role: .destructive) {
                                onDelete(schedule)
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(ShiftHubLocalization.string("削除", locale: displayLocale))
                        }
                        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
#if os(iOS)
        .sheet(item: $previewSchedule) { schedule in
            SavedSchedulePreviewView(
                schedule: schedule,
                onSelect: nil,
                showsScanAction: false
            )
        }
#endif
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        .frame(width: 540, height: 440)
#endif
    }
}

struct SavedSchedulePreviewView: View {
    let onSelect: ((StoredSchedule) -> Void)?
    let showsScanAction: Bool

    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.japanese.rawValue
#if os(macOS)
    @StateObject private var primaryController = PDFPreviewController()
    @StateObject private var secondaryController = PDFPreviewController()
#else
    @StateObject private var controller = PDFPreviewController()
#endif
    @State private var displayedSchedule: StoredSchedule
    @State private var document: PDFDocument?
#if os(macOS)
    @State private var secondaryDocument: PDFDocument?
    @State private var showingSecondaryDocument = false
    @State private var hasVisibleDocument = false
    @State private var loadingDocumentSlot: MacPDFDocumentSlot?
#endif
    @State private var loadError = false
    @State private var availableSchedules: [StoredSchedule] = []
    @State private var isLoadingDocument = false
    @State private var loadingScheduleID: UUID?

    init(
        schedule: StoredSchedule,
        onSelect: ((StoredSchedule) -> Void)?,
        showsScanAction: Bool = true
    ) {
        self.onSelect = onSelect
        self.showsScanAction = showsScanAction
        _displayedSchedule = State(initialValue: schedule)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(Color.accentColor)

                Text(displayedSchedule.fileName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button {
                    showPreviousSchedule()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("前のPDF")
                .accessibilityLabel("前のPDF")
                .disabled(isLoadingDocument || !canShowPreviousSchedule)

                Button {
                    showNextSchedule()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .help("次のPDF")
                .accessibilityLabel("次のPDF")
                .disabled(isLoadingDocument || !canShowNextSchedule)

                Button {
                    activePreviewController.zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("縮小")
                .accessibilityLabel("縮小")

                Button {
                    activePreviewController.zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("拡大")
                .accessibilityLabel("拡大")

                Button {
                    activePreviewController.fitToPage()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("ページに合わせる")
                .accessibilityLabel("ページに合わせる")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if let document {
#if os(macOS)
                ZStack {
                    macPDFDocumentView
                        .opacity(hasVisibleDocument ? 1 : 0)

                    if !hasVisibleDocument {
                        ProgressView()
                    }
                }
#else
                PDFDocumentView(document: document, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
            } else if loadError {
                ContentUnavailableView(
                    "PDFを表示できません",
                    systemImage: "exclamationmark.triangle",
                    description: Text("保存したPDFを開けませんでした。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
#if os(macOS)
            Divider()
            previewActionBar
#endif
        }
#if os(iOS)
        .safeAreaInset(edge: .bottom) {
            previewActionBar
        }
#endif
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        .frame(minWidth: 760, minHeight: 560)
#endif
        .onAppear {
            availableSchedules = StoredScheduleStore.loadSchedules()
            loadDisplayedSchedule()
        }
    }

    private func loadDisplayedSchedule() {
        loadSchedule(displayedSchedule)
    }

    private var activePreviewController: PDFPreviewController {
#if os(macOS)
        showingSecondaryDocument ? secondaryController : primaryController
#else
        controller
#endif
    }

#if os(macOS)
    private var macPDFDocumentView: some View {
        ZStack {
            if let document {
                PDFDocumentView(
                    document: document,
                    controller: primaryController,
                    onFirstRender: {
                        finishRenderingDocument(in: .primary)
                    }
                )
                .id(ObjectIdentifier(document))
                .opacity(showingSecondaryDocument ? 0 : 1)
            }

            if let secondaryDocument {
                PDFDocumentView(
                    document: secondaryDocument,
                    controller: secondaryController,
                    onFirstRender: {
                        finishRenderingDocument(in: .secondary)
                    }
                )
                .id(ObjectIdentifier(secondaryDocument))
                .opacity(showingSecondaryDocument ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func finishRenderingDocument(in slot: MacPDFDocumentSlot) {
        guard loadingDocumentSlot == slot else { return }

        showingSecondaryDocument = slot == .secondary
        hasVisibleDocument = true
        loadingDocumentSlot = nil
        loadingScheduleID = nil
        isLoadingDocument = false
    }
#endif

    private func loadSchedule(_ schedule: StoredSchedule) {
        guard !isLoadingDocument else { return }

        let scheduleID = schedule.id
        isLoadingDocument = true
        loadingScheduleID = scheduleID
        loadError = false

        Task { @MainActor in
            do {
                let url = try StoredScheduleStore.fileURL(for: schedule)
                guard FileManager.default.fileExists(atPath: url.path),
                      let loadedDocument = PDFDocument(url: url),
                      loadedDocument.pageCount > 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }

                guard loadingScheduleID == scheduleID else { return }
#if os(macOS)
                displayedSchedule = schedule

                if document == nil {
                    document = loadedDocument
                    loadingDocumentSlot = .primary
                } else if showingSecondaryDocument {
                    document = loadedDocument
                    loadingDocumentSlot = .primary
                } else {
                    secondaryDocument = loadedDocument
                    loadingDocumentSlot = .secondary
                }
#else
                document = loadedDocument
                displayedSchedule = schedule
#endif
            } catch {
                guard loadingScheduleID == scheduleID else { return }
#if os(macOS)
                if !hasVisibleDocument {
                    loadError = true
                }
                loadingDocumentSlot = nil
                loadingScheduleID = nil
                isLoadingDocument = false
#else
                if document == nil {
                    loadError = true
                }
#endif
            }

#if os(iOS)
            loadingScheduleID = nil
            isLoadingDocument = false
#endif
        }
    }

    private var displayedScheduleIndex: Int? {
        availableSchedules.firstIndex { $0.id == displayedSchedule.id }
    }

    private var canShowPreviousSchedule: Bool {
        guard let index = displayedScheduleIndex else { return false }
        return index > 0
    }

    private var canShowNextSchedule: Bool {
        guard let index = displayedScheduleIndex else { return false }
        return index + 1 < availableSchedules.count
    }

    private func showPreviousSchedule() {
        guard let index = displayedScheduleIndex, index > 0 else { return }
        loadSchedule(availableSchedules[index - 1])
    }

    private func showNextSchedule() {
        guard let index = displayedScheduleIndex,
              index + 1 < availableSchedules.count else { return }
        loadSchedule(availableSchedules[index + 1])
    }

    private var previewActionBar: some View {
        HStack {
            Button("閉じる") {
                dismiss()
            }
            .buttonStyle(.bordered)

            Spacer()

#if os(macOS)
            if showsScanAction {
                Button(
                    ShiftHubLocalization.string("このPDFをスキャン", locale: Locale(identifier: appLanguage))
                ) {
                    NotificationCenter.default.post(
                        name: .shiftHubScanStoredSchedule,
                        object: displayedSchedule
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(document == nil || isLoadingDocument)
            }
#else
            if showsScanAction, let onSelect {
                Button(
                    ShiftHubLocalization.string("このPDFをスキャン", locale: Locale(identifier: appLanguage))
                ) {
                    dismiss()
                    onSelect(displayedSchedule)
                }
                .buttonStyle(.borderedProminent)
                .disabled(document == nil || isLoadingDocument)
            }
#endif
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

private final class PDFPreviewController: ObservableObject {
    weak var pdfView: PDFView?

    func zoomIn() {
        guard let pdfView else { return }
        pdfView.scaleFactor = min(pdfView.scaleFactor * 1.25, pdfView.maxScaleFactor)
    }

    func zoomOut() {
        guard let pdfView else { return }
        pdfView.scaleFactor = max(pdfView.scaleFactor / 1.25, pdfView.minScaleFactor)
    }

    func fitToPage() {
        pdfView?.autoScales = true
    }
}

#if os(macOS)
private enum MacPDFDocumentSlot {
    case primary
    case secondary
}
#endif

private struct PDFDocumentView: View {
    let document: PDFDocument
    let controller: PDFPreviewController
    let onFirstRender: (() -> Void)?

    init(
        document: PDFDocument,
        controller: PDFPreviewController,
        onFirstRender: (() -> Void)? = nil
    ) {
        self.document = document
        self.controller = controller
        self.onFirstRender = onFirstRender
    }

    var body: some View {
#if os(iOS)
        PDFKitRepresentable(document: document, controller: controller)
#else
        PDFKitRepresentable(
            document: document,
            controller: controller,
            onFirstRender: onFirstRender
        )
#endif
    }
}

#if os(iOS)
private final class IOSPDFPreviewView: PDFView {
    private var shouldFitPageToWidth = true
    private var pendingDocument: PDFDocument?

    override func layoutSubviews() {
        super.layoutSubviews()
        applyInitialPageWidthFitIfNeeded()
        applyPageCornerRadius()
    }

    func prepareForInitialWidthFit() {
        shouldFitPageToWidth = true
        setNeedsLayout()
    }

    func setDocumentWhenReady(_ document: PDFDocument) {
        guard self.document !== document else { return }

        pendingDocument = document
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingDocument === document else { return }

            pendingDocument = nil
            prepareForInitialWidthFit()
            self.document = document
        }
    }

    private func applyInitialPageWidthFitIfNeeded() {
        guard shouldFitPageToWidth,
              bounds.width > 0,
              let page = document?.page(at: 0) else { return }

        let pageWidth = page.bounds(for: displayBox).width
        guard pageWidth > 0 else { return }

        // Mark the fit as complete before changing PDFView layout state to avoid reentrant layout.
        shouldFitPageToWidth = false
        autoScales = false
        scaleFactor = min(max(bounds.width / pageWidth, minScaleFactor), maxScaleFactor)
    }

    private func applyPageCornerRadius() {
        documentView?.layer.cornerRadius = 15
        documentView?.layer.masksToBounds = true
    }
}

private struct PDFKitRepresentable: UIViewRepresentable {
    let document: PDFDocument
    let controller: PDFPreviewController

    func makeUIView(context: Context) -> IOSPDFPreviewView {
        let pdfView = IOSPDFPreviewView()
        configure(pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: IOSPDFPreviewView, context: Context) {
        pdfView.setDocumentWhenReady(document)
        controller.pdfView = pdfView
    }

    private func configure(_ pdfView: IOSPDFPreviewView) {
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = .zero
        pdfView.minScaleFactor = 0.75
        pdfView.maxScaleFactor = 5.0
        pdfView.autoScales = false
        pdfView.prepareForInitialWidthFit()
        pdfView.document = document
        controller.pdfView = pdfView
    }
}
#else
private final class MacPDFPreviewView: PDFView {
    var onFirstRender: (() -> Void)?
    private var didReportFirstRender = false

    override func layout() {
        super.layout()
        applyPageCornerRadius()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !didReportFirstRender, document?.pageCount ?? 0 > 0 else { return }
        didReportFirstRender = true

        DispatchQueue.main.async { [weak self] in
            self?.onFirstRender?()
        }
    }

    private func applyPageCornerRadius() {
        documentView?.wantsLayer = true
        documentView?.layer?.cornerRadius = 15
        documentView?.layer?.masksToBounds = true
    }
}

private struct PDFKitRepresentable: NSViewRepresentable {
    let document: PDFDocument
    let controller: PDFPreviewController
    let onFirstRender: (() -> Void)?

    func makeNSView(context: Context) -> MacPDFPreviewView {
        let pdfView = MacPDFPreviewView()
        pdfView.onFirstRender = onFirstRender
        configure(pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: MacPDFPreviewView, context: Context) {
        pdfView.onFirstRender = onFirstRender
        controller.pdfView = pdfView
    }

    private func configure(_ pdfView: PDFView) {
        pdfView.document = document
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = false
        pdfView.minScaleFactor = 0.75
        pdfView.maxScaleFactor = 5.0
        pdfView.autoScales = true
        controller.pdfView = pdfView
    }
}
#endif

private struct SavedScheduleRowButtonStyle: ButtonStyle {
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

private struct SingleShiftRegistrationView: View {
    let definitions: [ShiftDefinition]
    let onRegister: (YearMonth, Int, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var selectedYear: Int
    @State private var selectedMonth: Int
    @State private var selectedDay: Int
    @State private var selectedTitle: String

    init(
        initialYearMonth: YearMonth?,
        definitions: [ShiftDefinition],
        onRegister: @escaping (YearMonth, Int, String) -> Void
    ) {
        let initial = initialYearMonth ?? .current
        self.definitions = definitions.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        self.onRegister = onRegister
        _selectedYear = State(initialValue: initial.year)
        _selectedMonth = State(initialValue: initial.month)
        _selectedDay = State(initialValue: 1)
        _selectedTitle = State(initialValue: definitions.first(where: {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.title ?? "休")
    }

    private var selectedYearMonth: YearMonth {
        YearMonth(year: selectedYear, month: selectedMonth)
    }

    private var yearOptions: [Int] {
        let currentYear = YearMonth.current.year
        let range = Array((currentYear - 10)...(currentYear + 10))
        return Array(Set(range + [selectedYear])).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("日付ごとに登録")
                        .font(.title.bold())

                    Text("登録する日付とイベントを選択します。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("キャンセル") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("登録") {
                    onRegister(selectedYearMonth, selectedDay, selectedTitle)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)

            Divider()

            Form {
                HStack {
                    Picker("年", selection: $selectedYear) {
                        ForEach(yearOptions, id: \.self) { year in
                            Text(ShiftHubLocalization.yearText(year, locale: locale)).tag(year)
                        }
                    }

                    Picker("月", selection: $selectedMonth) {
                        ForEach(1...12, id: \.self) { month in
                            Text(ShiftHubLocalization.monthText(month, locale: locale)).tag(month)
                        }
                    }
                }

                Picker("日付", selection: $selectedDay) {
                    ForEach(1...selectedYearMonth.numberOfDays, id: \.self) { day in
                        Text("\(selectedMonth)/\(day)")
                            .tag(day)
                    }
                }

                Picker("イベント", selection: $selectedTitle) {
                    Text("休（終日）")
                        .tag("休")

                    ForEach(definitions) { definition in
                        Text("\(definition.title)  \(definition.timeRangeText)")
                            .tag(definition.title)
                    }
                }

                if selectedTitle == "休" {
                    Text("終日イベントとして登録します。")
                        .foregroundStyle(.secondary)
                } else if let definition = definitions.first(where: { $0.title == selectedTitle }) {
                    Text("登録時間: \(definition.timeRangeText)")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(24)
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        .frame(width: 520, height: 360)
#endif
        .onChange(of: selectedYear) {
            selectedDay = min(selectedDay, selectedYearMonth.numberOfDays)
        }
        .onChange(of: selectedMonth) {
            selectedDay = min(selectedDay, selectedYearMonth.numberOfDays)
        }
    }
}

private struct DateTimeEventRegistrationView: View {
    let initialStartDate: Date
    let locale: Locale
    let onRegister: (String, Date, Date, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
#if os(iOS)
    @Environment(\.colorScheme) private var colorScheme
#endif
    @State private var title = ""
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var isAllDay = false
    @State private var isInvalidDateAlertPresented = false

    init(
        initialStartDate: Date,
        locale: Locale,
        onRegister: @escaping (String, Date, Date, Bool) -> Void
    ) {
        self.initialStartDate = initialStartDate
        self.locale = locale
        self.onRegister = onRegister
        _startDate = State(initialValue: initialStartDate)
        _endDate = State(initialValue: Calendar.current.date(byAdding: .hour, value: 1, to: initialStartDate) ?? initialStartDate)
    }

    private var canRegisterTitleOnly: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func registerEvent() {
        guard endDate >= startDate else {
            isInvalidDateAlertPresented = true
            return
        }

        let calendar = Calendar.current
        let normalizedStartDate = isAllDay ? calendar.startOfDay(for: startDate) : startDate
        let normalizedEndDate = isAllDay ? calendar.startOfDay(for: endDate) : endDate
        onRegister(
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedStartDate,
            normalizedEndDate,
            isAllDay
        )
        dismiss()
    }

    private func localized(_ key: String) -> String {
        ShiftHubLocalization.string(key, locale: locale)
    }

    private var timePickerLocale: Locale {
        locale.identifier.hasPrefix("ja")
            ? Locale(identifier: "ja_JP")
            : Locale(identifier: "en_GB")
    }

#if os(iOS)
    private var registrationScreenBackground: Color {
        colorScheme == .dark
            ? Color(uiColor: .secondarySystemBackground)
            : Color(uiColor: .systemGroupedBackground)
    }

    private var registrationSectionBackground: Color {
        colorScheme == .dark
            ? Color(uiColor: .tertiarySystemBackground)
            : Color(uiColor: .secondarySystemGroupedBackground)
    }
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized("イベントを登録"))
                        .font(.title.bold())

                    Text(localized("タイトルと日時を指定して登録します。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(localized("キャンセル")) {
                    dismiss()
                }
                .buttonStyle(.bordered)

#if os(macOS)
                Button(localized("登録")) {
                    registerEvent()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRegisterTitleOnly)
#endif
            }
            .padding(24)

            Divider()

#if os(macOS)
            VStack(alignment: .leading, spacing: 12) {
                Text(localized("イベントタイトル"))
                    .font(.headline)

                TextField(localized("タイトル"), text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }

                Text(localized("日時"))
                    .font(.headline)
                    .padding(.top, 8)

                Toggle(localized("終日"), isOn: $isAllDay)

                HStack(alignment: .center, spacing: 8) {
                    DatePicker(
                        localized("開始"),
                        selection: $startDate,
                        displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                    .environment(\.locale, timePickerLocale)
                    Text("-")
                        .foregroundStyle(.secondary)
                    DatePicker(
                        localized("終了"),
                        selection: $endDate,
                        displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                    .environment(\.locale, timePickerLocale)
                }

                if endDate < startDate {
                    Text(localized("終了日時は開始日時以降にしてください。"))
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
#else
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(localized("イベントタイトル"))
                            .font(.headline)

                        TextField(localized("タイトル"), text: $title, axis: .vertical)
                            .lineLimit(1...5)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                Color(uiColor: .tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                    }
                    .padding(16)
                    .background(
                        registrationSectionBackground,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(localized("日時"))
                            .font(.headline)

                        Toggle(localized("終日"), isOn: $isAllDay)

                        Divider()

                        DatePicker(
                            localized("開始"),
                            selection: $startDate,
                            displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                        )
                        .environment(\.locale, timePickerLocale)

                        DatePicker(
                            localized("終了"),
                            selection: $endDate,
                            displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                        )
                        .environment(\.locale, timePickerLocale)

                        if endDate < startDate {
                            Text(localized("終了日時は開始日時以降にしてください。"))
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(16)
                    .background(
                        registrationSectionBackground,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    VStack {
                        Button {
                            registerEvent()
                        } label: {
                            Text(localized("登録"))
                                .foregroundStyle(Color.accentColor)
                                .frame(maxWidth: .infinity, minHeight: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canRegisterTitleOnly)
                    }
                    .padding(16)
                    .background(
                        registrationSectionBackground,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(24)
#endif

        }
        .alert(
            Text(localized("保存できません")),
            isPresented: $isInvalidDateAlertPresented
        ) {
            Button(localized("OK"), role: .cancel) {}
        } message: {
            Text(localized("終了日時は開始日時以降にしてください。"))
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        .frame(width: 560, height: 420)
#endif
#if os(iOS)
        .background(
            registrationScreenBackground,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
#endif
        .environment(\.locale, locale)
        .onChange(of: startDate) {
            if endDate < startDate {
                endDate = Calendar.current.date(byAdding: .hour, value: 1, to: startDate) ?? startDate
            }
        }
        .onChange(of: endDate) {
            if endDate < startDate {
                endDate = startDate
            }
        }
        .onChange(of: isAllDay) {
            let calendar = Calendar.current
            if isAllDay {
                startDate = calendar.startOfDay(for: startDate)
                endDate = calendar.startOfDay(for: endDate)
                if endDate < startDate {
                    endDate = startDate
                }
            }
        }
    }
}

private struct CalendarDisplayColor: Hashable {
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

private struct CalendarEventRecord: Identifiable, Hashable {
    let id: String
    let day: Int
    let title: String
    let detail: String
    let isAllDay: Bool
    let startDate: Date?
    let endDate: Date?
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

    var confirmationText: String {
        let displayedDetail = menuDetail(locale: Locale(identifier: "ja"))
        return displayedDetail.isEmpty ? "\(day)日の「\(title)」" : "\(day)日の「\(title)」\n\(displayedDetail)"
    }
}

private struct CalendarEventDisplaySegment: Identifiable, Hashable {
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

private struct CalendarBandEventSelection: Identifiable {
    let event: CalendarEventRecord
    let day: Int

    var id: String {
        "\(event.id)-\(day)"
    }
}

private struct CalendarEventBandLayout: Identifiable, Hashable {
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

private struct CalendarEventBandMetrics {
    let top: CGFloat
    let contentSpacing: CGFloat
    let gap: CGFloat
    let height: CGFloat
    let laneHeight: CGFloat
}

private struct CalendarEventBandShape: Shape {
    let squareLeading: Bool
    let squareTrailing: Bool

    func path(in rect: CGRect) -> Path {
        let radius = min(6, min(rect.width, rect.height) / 2)
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

private func calendarEventComesBefore(
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

private struct CalendarDaySelection: Hashable {
    let year: Int
    let month: Int
    let day: Int

    var yearMonth: YearMonth {
        YearMonth(year: year, month: month)
    }
}

private struct ShiftSelectionView: View {
    let definitions: [ShiftDefinition]
    let tint: Color
    let locale: Locale
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        definitions: [ShiftDefinition],
        tint: Color = .accentColor,
        locale: Locale,
        onSelect: @escaping (String) -> Void
    ) {
        self.definitions = definitions
        self.tint = tint
        self.locale = locale
        self.onSelect = onSelect
    }

    private func localized(_ key: String) -> String {
        ShiftHubLocalization.string(key, locale: locale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized("イベントを選択"))
                        .font(.title2.bold())

                    Text(localized("登録するイベントをイベント設定から選択します。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(localized("キャンセル")) {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(24)

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    shiftSelectionRow(
                        title: "休",
                        detail: localized("終日"),
                        symbol: "moon.zzz.fill",
                        tint: .red
                    )

                    ForEach(definitions) { definition in
                        shiftSelectionRow(
                            title: definition.title,
                            detail: definition.timeRangeText,
                            symbol: "clock.fill",
                            tint: tint
                        )
                    }
                }
                .padding(20)
            }
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        .frame(width: 460, height: 430)
#endif
    }

    private func shiftSelectionRow(
        title: String,
        detail: String,
        symbol: String,
        tint: Color
    ) -> some View {
        Button {
            onSelect(title)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.14), in: Circle())

                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 10)

                Text(detail)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.background.secondary.opacity(0.7), in: Capsule())

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: 52)
        }
        .buttonStyle(ShiftSelectionRowButtonStyle())
    }
}

private struct ShiftSelectionRowButtonStyle: ButtonStyle {
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

private struct PendingShiftRegistration {
    let day: Int
    let event: CalendarEventRecord?
    let deleteExisting: Bool
}

private final class RegistrationCompletion {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func call() {
        action()
    }
}

private final class DateTimeEventRegistrationCompletion {
    private let action: (String) -> Void

    init(action: @escaping (String) -> Void) {
        self.action = action
    }

    func call(eventID: String) {
        action(eventID)
    }
}

private struct ToolbarSelectorButtonStyleD: ButtonStyle {
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

private struct ToolbarNavigationButtonStyleD: ButtonStyle {
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

private struct ToolbarUtilityButtonStyleD: ButtonStyle {
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

private struct ToolbarIconButtonStyleD: ButtonStyle {
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

private struct CalendarDayCardButtonStyle: ButtonStyle {
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

private struct CalendarOverlayAnchors {
    var monthTitle: Anchor<CGRect>?
    var destination: Anchor<CGRect>?

    init(monthTitle: Anchor<CGRect>? = nil, destination: Anchor<CGRect>? = nil) {
        self.monthTitle = monthTitle
        self.destination = destination
    }
}

private struct CalendarOverlayAnchorKey: PreferenceKey {
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

private struct CalendarDestinationPopup: View {
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

private struct CalendarDestinationSelector: View {
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

private struct CalendarEventManagerView: View {
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
    @State private var isDaySelectionMode = false
    @State private var selectedCalendarDays: Set<CalendarDaySelection> = []
    @State private var selectedEventForActions: CalendarEventRecord?
    @State private var selectedBandEventForActions: CalendarBandEventSelection?
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
            guard !didLoadInitialMonth else { return }
            didLoadInitialMonth = true
            model.setLocaleIdentifier(locale.identifier)
            model.load()
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

#if os(iOS)
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
#endif

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
        guard let pageID = pageID(for: target) else { return }

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            monthPageID = pageID
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

    private func eventBandRevealOpacity(for yearMonth: YearMonth, day: Int) -> Double {
        guard yearMonth == model.yearMonth, !model.events.isEmpty else { return 1 }
        return day <= eventBandRevealThroughDay ? 1 : 0
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

    private func eventDisplaySegments(
        for yearMonth: YearMonth,
        events: [CalendarEventRecord]
    ) -> [CalendarEventDisplaySegment] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let result = events.flatMap { (event: CalendarEventRecord) -> [CalendarEventDisplaySegment] in
            guard event.spansMultipleDays,
                  let startDate = event.startDate,
                  let endDate = event.endDate,
                  let monthStart = calendar.date(from: DateComponents(
                      year: yearMonth.year,
                      month: yearMonth.month,
                      day: 1
                  )),
                  let nextMonthStart = calendar.date(
                      byAdding: .month,
                      value: 1,
                      to: monthStart
                  ) else {
                return []
            }

            guard startDate < nextMonthStart, endDate > monthStart else {
                return []
            }

            let startDay = startDate < monthStart
                ? 1
                : calendar.component(.day, from: startDate)
            let endDay: Int
            if endDate >= nextMonthStart {
                endDay = yearMonth.numberOfDays
            } else {
                endDay = calendar.component(.day, from: endDate)
            }

            guard (1...yearMonth.numberOfDays).contains(startDay),
                  (1...yearMonth.numberOfDays).contains(endDay),
                  endDay >= startDay else {
                return []
            }

            var segments: [CalendarEventDisplaySegment] = []
            var segmentStartDay = startDay
            while segmentStartDay <= endDay {
                let weekdayColumn = (
                    yearMonth.leadingBlankCount + segmentStartDay - 1
                ) % 7
                let segmentEndDay = min(
                    endDay,
                    segmentStartDay + (6 - weekdayColumn)
                )
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
        segments: [CalendarEventDisplaySegment]
    ) -> [CalendarEventDisplaySegment] {
        var result: [CalendarEventDisplaySegment] = []

        for day in 1...yearMonth.numberOfDays {
            let dayEvents = events.filter { $0.starts(on: day, in: yearMonth) }
            let segmentsForDay = segments.filter { $0.contains(day: day) }
            let segmentStartEvents = segmentsForDay
                .filter { $0.startDay == day }
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
                    $0.event.id == event.id && $0.startDay == day && $0.spanDays > 1
                }
            }
            .sorted(by: calendarEventComesBefore)
            .prefix(3)

            for event in displayEvents {
                result.append(CalendarEventDisplaySegment(
                    event: event,
                    startDay: day,
                    endDay: day
                ))
            }
        }

        return result
    }

    private func eventBandLayouts(
        for yearMonth: YearMonth,
        events: [CalendarEventRecord],
        segments: [CalendarEventDisplaySegment]
    ) -> [CalendarEventBandLayout] {
        let candidates = Array(
            Dictionary(
                (segments.filter { $0.spanDays > 1 }
                    + singleDayEventBandSegments(
                        for: yearMonth,
                        events: events,
                        segments: segments
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
            let startSlot = yearMonth.leadingBlankCount + segment.startDay - 1
            let row = startSlot / 7
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
        yearMonth: YearMonth,
        segments: [CalendarEventDisplaySegment]
    ) -> (squareLeading: Bool, squareTrailing: Bool) {
        let hasPreviousSegment = segments.contains {
            $0.event.id == layout.event.id && $0.endDay == layout.startDay - 1
        }
        let hasNextSegment = segments.contains {
            $0.event.id == layout.event.id && $0.startDay == layout.endDay + 1
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let monthStart = calendar.date(from: DateComponents(
            year: yearMonth.year,
            month: yearMonth.month,
            day: 1
        ))
        let nextMonthStart = monthStart.flatMap {
            calendar.date(byAdding: .month, value: 1, to: $0)
        }
        let continuesFromPreviousMonth = monthStart.map { monthStart in
            layout.event.startDate.map { $0 < monthStart } ?? false
        } ?? false
        let continuesIntoNextMonth = nextMonthStart.map { nextMonthStart in
            layout.event.endDate.map { $0 >= nextMonthStart } ?? false
        } ?? false

        return (
            squareLeading: hasPreviousSegment || continuesFromPreviousMonth,
            squareTrailing: hasNextSegment || continuesIntoNextMonth
        )
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
        let leadingBlankCount = yearMonth.leadingBlankCount
        let totalSlots = leadingBlankCount + yearMonth.numberOfDays
        let slots = Swift.Array<Int>(0..<totalSlots)
        let isCurrentMonth = yearMonth == model.yearMonth
        let displaySegments = eventDisplaySegments(for: yearMonth, events: events)
        let bandLayouts = eventBandLayouts(
            for: yearMonth,
            events: events,
            segments: displaySegments
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
                    ForEach(slots, id: \.self) { slot in
                        if slot < leadingBlankCount {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: cardHeight)
                        } else {
                            eventDayCell(
                                day: slot - leadingBlankCount + 1,
                                yearMonth: yearMonth,
                                events: events,
                                segments: displaySegments,
                                isInteractive: isCurrentMonth,
                                isSelectionMode: isDaySelectionMode,
                                isSelected: selectedCalendarDays.contains(
                                    CalendarDaySelection(
                                        year: yearMonth.year,
                                        month: yearMonth.month,
                                        day: slot - leadingBlankCount + 1
                                    )
                                ),
                                cardHeight: cardHeight,
                                bandMetrics: bandMetrics,
                                bandLayouts: bandLayouts,
                                hideEventContent: renderEventBandsInOverlay
                            )
                        }
                    }
                }

                if renderEventBandsInOverlay {
                    ForEach(bandLayouts.filter { $0.lane < 3 }) { layout in
                        let startSlot = leadingBlankCount + layout.startDay - 1
                        let row = startSlot / 7
                        let column = startSlot % 7
                        #if os(iOS)
                        let bandInset: CGFloat = 3
                        #else
                        let bandInset: CGFloat = 6
                        #endif
                        let bandWidth = max(0, columnWidth * CGFloat(layout.spanDays)
                            + columnSpacing * CGFloat(layout.spanDays - 1)
                            - bandInset * 2)
                        let eventColor = layout.event.isRestEvent
                            ? Color.red
                            : layout.event.calendarColor?.color ?? Color.accentColor
                        let cornerStyle = eventBandCornerStyle(
                            for: layout,
                            yearMonth: yearMonth,
                            segments: displaySegments
                        )

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
                                    .padding(.horizontal, 6)

                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .allowsHitTesting(false)

                            Button {
                                isCalendarDestinationMenuPresented = false
                                isYearMonthPickerPresented = false
                                selectedDayForActions = nil
                                selectedBandEventForActions = CalendarBandEventSelection(
                                    event: layout.event,
                                    day: layout.startDay
                                )
                            } label: {
                                Rectangle()
                                    .fill(.clear)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .contentShape(Rectangle())
                                    .accessibilityLabel(layout.event.title)
                            }
                            .buttonStyle(.plain)
#if os(macOS)
                            .popover(
                                isPresented: bandEventPopoverBinding(
                                    for: layout.event,
                                    day: layout.startDay
                                )
                            ) {
                                bandEventActionsPopover(
                                    for: layout.event,
                                    day: layout.startDay
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
                                .fill(eventColor.opacity(isDaySelectionMode ? 0.08 : 0.18))
                        }
                        .position(
                            x: CGFloat(column) * (columnWidth + columnSpacing)
                                + bandInset + bandWidth / 2,
                            y: CGFloat(row) * (cardHeight + gridSpacing)
                                + bandMetrics.top
                                + CGFloat(layout.lane) * bandMetrics.laneHeight
                                + bandMetrics.height / 2
                        )
                        .opacity(eventBandRevealOpacity(
                            for: yearMonth,
                            day: layout.startDay
                        ))
                        .zIndex(2)
                        .allowsHitTesting(isCurrentMonth && !isDaySelectionMode && !model.isDeleting)
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
        day: Int,
        yearMonth: YearMonth,
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
        let dayEvents = events.filter { $0.starts(on: day, in: yearMonth) }
        let segmentsForDay = segments.filter { $0.contains(day: day) }
        let segmentStartEvents = segmentsForDay
            .filter { $0.startDay == day }
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
                $0.event.id == event.id && $0.startDay == day && $0.spanDays > 1
            }
        }
            .sorted(by: calendarEventComesBefore)
            .prefix(3)
        let displayEvents = hideEventContent ? [] : allDisplayEvents
        let overflowCount = bandLayouts.filter {
            $0.lane >= 3 && $0.contains(day: day)
        }.count
        let weekdayColumn = (yearMonth.leadingBlankCount + day - 1) % 7
        let connectsToPreviousCard = weekdayColumn > 0 && segmentsForDay.contains {
            $0.startDay < day
        }
        let selection = CalendarDaySelection(year: yearMonth.year, month: yearMonth.month, day: day)
        let isToday = Calendar.current.date(
            from: DateComponents(year: yearMonth.year, month: yearMonth.month, day: day)
        ).map(Calendar.current.isDateInToday) ?? false
#if os(iOS)
        let dateHeaderHeight: CGFloat = 14
#else
        let dateHeaderHeight: CGFloat = 18
#endif
        return Button {
            guard isInteractive else { return }

            if isSelectionMode {
                if selectedCalendarDays.contains(selection) {
                    selectedCalendarDays.remove(selection)
                } else {
                    selectedCalendarDays.insert(selection)
                }
                return
            }

            isCalendarDestinationMenuPresented = false
            isYearMonthPickerPresented = false
            Task { @MainActor in
                await Task.yield()
                selectedDayForActions = day
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
                    Text("\(day)")
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
        .zIndex(connectsToPreviousCard ? 0 : 1)
        .disabled(model.isDeleting || !isInteractive)
#if os(iOS)
        .sheet(
            isPresented: Binding(
                get: { isInteractive && !isSelectionMode && selectedDayForActions == day },
                set: { isPresented in
                    if isInteractive && !isPresented && selectedDayForActions == day {
                        selectedDayForActions = nil
                    }
                }
            )
        ) {
            dayActionsPopover(
                for: day,
                additionalEvents: segmentsForDay.map(\.event)
            )
                .presentationDragIndicator(.visible)
        }
#else
        .popover(
            isPresented: Binding(
                get: {
                    isInteractive
                        && !isSelectionMode
                        && isDayActionsPopoverPresented
                        && selectedDayForActions == day
                        && selectedBandEventForActions == nil
                },
                set: { isPresented in
                    if isInteractive && !isPresented && selectedDayForActions == day {
                        isDayActionsPopoverPresented = false
                        selectedDayForActions = nil
                    }
                }
            )
        ) {
            dayActionsPopover(
                for: day,
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
            if !actionableEvents.isEmpty {
                Text(localized("イベントを選択"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                    .padding(.bottom, 6)

                eventSelectionList(for: day, events: actionableEvents)
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

#if os(iOS)
            eventRegistrationButton(forDay: day)
                .padding(.top, 12)

            dateTimeEventRegistrationButton(forDay: day)
                .padding(.top, 8)
#else
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

            Text(event.title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.top, 10)

            let menuDetail = event.menuDetail(locale: locale)
            if !menuDetail.isEmpty {
                Text(menuDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            Divider()
                .padding(.vertical, 12)

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
        day: Int
    ) -> Binding<Bool> {
        Binding(
            get: {
                selectedBandEventForActions?.event.id == event.id
                    && selectedBandEventForActions?.day == day
            },
            set: { isPresented in
                guard !isPresented,
                      selectedBandEventForActions?.event.id == event.id,
                      selectedBandEventForActions?.day == day else {
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

private enum AppLanguage: String, CaseIterable, Identifiable {
    case japanese = "ja"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .japanese:
            return "日本語"
        case .english:
            return "English"
        }
    }
}

#if os(macOS)
private enum ShiftHubMacSettingsPane: String, CaseIterable, Identifiable {
    case general
    case shifts
    case calendars
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "一般"
        case .shifts:
            return "イベント管理"
        case .calendars:
            return "カレンダー設定"
        case .about:
            return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            return "言語とiCloud同期を設定"
        case .shifts:
            return "イベントタイトルと開始・終了時刻を管理"
        case .calendars:
            return "カレンダー接続と登録先を設定"
        case .about:
            return "アプリ情報・プライバシー・著作権"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .shifts:
            return "clock.badge.checkmark"
        case .calendars:
            return "calendar.badge.clock"
        case .about:
            return "info.circle"
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .general:
            return ["General", "Language", "言語", "iCloud", "同期"]
        case .shifts:
            return ["Shifts", "Shift", "勤務", "タイトル", "時間"]
        case .calendars:
            return ["Calendar", "Apple", "Google", "Notion", "カレンダー"]
        case .about:
            return ["About", "Privacy", "Copyright", "情報", "プライバシー", "著作権"]
        }
    }
}

private struct ShiftHubMacSettingsView: View {
    @Binding var definitions: [ShiftDefinition]
    @Binding var appLanguage: String
    @Binding var isCloudSyncEnabled: Bool

    @State private var selectedPane: ShiftHubMacSettingsPane = .general
    @State private var sidebarSearchText = ""
    @State private var isShiftSettingsPresented = false
    @State private var isCalendarSettingsPresented = false

    private var locale: Locale {
        Locale(identifier: appLanguage)
    }

    private func localized(_ key: String) -> String {
        ShiftHubLocalization.string(key, locale: locale)
    }

    private var filteredPanes: [ShiftHubMacSettingsPane] {
        let query = sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ShiftHubMacSettingsPane.allCases
        }

        return ShiftHubMacSettingsPane.allCases.filter { pane in
            pane.title.localizedCaseInsensitiveContains(query)
                || pane.subtitle.localizedCaseInsensitiveContains(query)
                || pane.searchKeywords.contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: 220)

            Divider()

            settingsDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isShiftSettingsPresented) {
            ShiftDefinitionSettingsView(definitions: $definitions)
                .environment(\.locale, Locale(identifier: appLanguage))
        }
        .sheet(isPresented: $isCalendarSettingsPresented) {
            CalendarSettingsView()
                .environment(\.locale, Locale(identifier: appLanguage))
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("検索", text: $sidebarSearchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.top, 18)

            VStack(spacing: 2) {
                ForEach(filteredPanes) { pane in
                    Button {
                        selectedPane = pane
                    } label: {
                        ShiftHubMacSettingsSidebarRow(
                            title: localized(pane.title),
                            systemImage: pane.systemImage,
                            isSelected: selectedPane == pane
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)

            Spacer()
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var settingsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHero(for: selectedPane)
                settingsContent(for: selectedPane)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func settingsHero(for pane: ShiftHubMacSettingsPane) -> some View {
        VStack(spacing: 8) {
            ShiftHubMacSettingsHeroIcon(systemImage: pane.systemImage)

            Text(localized(pane.title))
                .font(.title2.weight(.semibold))

            Text(localized(pane.subtitle))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
        .background(ShiftHubMacSettingsCardBackground())
    }

    @ViewBuilder
    private func settingsContent(for pane: ShiftHubMacSettingsPane) -> some View {
        switch pane {
        case .general:
            generalSettings
        case .shifts:
            detailActionCard(
                title: localized("イベント管理"),
                subtitle: localized("イベントタイトルと開始・終了時刻を管理"),
                systemImage: "clock.badge.checkmark"
            ) {
                isShiftSettingsPresented = true
            }
        case .calendars:
            detailActionCard(
                title: localized("カレンダー設定"),
                subtitle: localized("Apple・Google・Notionの接続先を管理"),
                systemImage: "calendar.badge.clock"
            ) {
                isCalendarSettingsPresented = true
            }
        case .about:
            aboutSettings
        }
    }

    private var generalSettings: some View {
        ShiftHubMacSettingsSectionCard {
            ShiftHubMacSettingsRow(
                title: localized("言語"),
                subtitle: localized("アプリの表示言語"),
                systemImage: "globe"
            ) {
                Picker("言語", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title)
                            .tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Divider()

            ShiftHubMacSettingsRow(
                title: localized("iCloud同期"),
                subtitle: localized("設定とPDFをiCloudで同期します。"),
                systemImage: "icloud"
            ) {
                Toggle("", isOn: $isCloudSyncEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private func detailActionCard(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        ShiftHubMacSettingsSectionCard {
            Button(action: action) {
                HStack(spacing: 12) {
                    ShiftHubMacSettingsRowIcon(systemImage: systemImage)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.callout.weight(.medium))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 16)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            ShiftHubMacSettingsSectionCard {
                HStack(spacing: 14) {
                    Image("CalHubIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Cal Hub")
                            .font(.title3.weight(.semibold))
                        Text(shiftHubAppVersion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(shiftHubCopyrightText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            ShiftHubMacSettingsSectionCard {
                Text(localized("このアプリについて"))
                    .font(.headline)
                Text(localized("イベント設定に保存したイベントを、Appleカレンダー、Googleカレンダー、Notionデータベースへ登録・変更・削除できるアプリです。勤務表のPDFを読み込み、日付ごとのイベントを抽出して登録できます。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            ShiftHubMacSettingsSectionCard {
                Text(localized("主な機能"))
                    .font(.headline)

                ShiftHubMacAboutFeatureRow(
                    title: localized("PDFスキャン"),
                    detail: localized("文字データを持つ横向きPDFから、保存した名前に一致する行を抽出します。抽出結果はカレンダー表示と横並び表示を切り替えられ、日付ごとのイベント名を編集・削除できます。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("保存済みPDF"),
                    detail: localized("読み込んだPDFをアプリ内に保存し、一覧から再解析・削除できます。同じ内容のPDFは重複保存しません。保存したPDFのプレビュー、ページ移動、拡大縮小にも対応します。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("カレンダー登録"),
                    detail: localized("Appleカレンダー、Googleカレンダー、Notionデータベースを登録先として選択できます。保存済みイベントの一覧から登録できるほか、トップ画面ではタイトルと開始・終了日時を指定したイベントを登録できます。PDFスキャンと複数選択は同日登録に対応します。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("イベント管理"),
                    detail: localized("月を移動し、日付ごとの通常イベントを確認、変更、削除できます。空の日付への新規登録、既存イベントの置き換えにも対応します。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("複数選択"),
                    detail: localized("複数の日付を選択し、保存済みのイベントをまとめて登録できます。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("祝日表示"),
                    detail: localized("Googleカレンダーの「日本の祝日」を登録先と一緒に表示できます。祝日は表示専用で、イベント件数には含まれません。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("イベント設定"),
                    detail: localized("イベントタイトルと開始・終了時刻を保存、編集、並べ替え、削除できます。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("iCloud同期"),
                    detail: localized("設定と保存済みPDFをiCloudで同期できます。カレンダー上のイベントと認証情報は同期しません。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("カレンダーキャッシュ"),
                    detail: localized("表示中の月を中心に前後12か月をキャッシュし、月移動時はキャッシュを先に表示します。表示範囲外の月は破棄し、手動更新、iCloud同期完了、接続先設定の変更後に再取得します。Mac版ではアプリの再アクティブ化だけでは再取得しません。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("言語切替"),
                    detail: localized("設定から日本語と英語を切り替えられます。")
                )
            }

            ShiftHubMacSettingsSectionCard {
                Text(localized("対応形式と注意点"))
                    .font(.headline)

                ShiftHubMacAboutFeatureRow(
                    title: localized("PDF入力条件"),
                    detail: localized("PDFのみ対応しています。文字を選択・コピーできる文字データ層を持つ横向きの勤務表を使用してください。画像だけのスキャンPDFや縦向きPDFには対応していません。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("年月の判定"),
                    detail: localized("PDFから年月を取得できない場合は、ファイル名を「2026-01.pdf」のようなYYYY-MM形式にしてください。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("イベント名の照合"),
                    detail: localized("PDFから抽出した勤務名がイベント設定にない場合は、登録前に保存するか、登録時にスキップされます。新しく保存したイベントの初期時間は8:30-16:40です。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("休の登録"),
                    detail: localized("「休」は登録時に含めるか選択できます。AppleカレンダーとGoogleカレンダーでは終日、Notionでは00:00-23:59の時間付きデータとして登録します。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("日付カードの表示"),
                    detail: localized("日付カードには時間順に最大3件を表示します。3件以上の場合、カード内の時間は省略され、日付メニューで全件を確認できます。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("日をまたぐイベント"),
                    detail: localized("トップ画面から開始日時と終了日時を指定して登録できます。日付をまたぐイベントは開始日から終了日まで帯で表示し、週や月の境界では帯を分割します。日付メニューでは開始日・終了日を含む範囲を表示します。PDFスキャンと複数選択からは登録できません。")
                )
            }

            ShiftHubMacSettingsSectionCard {
                Text(localized("接続の準備"))
                    .font(.headline)

                ShiftHubMacAboutFeatureRow(
                    title: localized("Appleカレンダー"),
                    detail: localized("用意するもの: Apple IDでiCloudにサインインし、カレンダーを有効にした端末。クライアントIDやトークンは不要です。\n設定方法: 端末のカレンダーへのアクセスを許可し、カレンダー設定で「カレンダー一覧を取得」から登録先カレンダーを選択します。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("Googleカレンダー"),
                    detail: localized("用意するもの: Googleアカウント。\n設定方法: Googleログインを選択し、カレンダーへのアクセスを許可して登録先を選択してください。OAuthクライアントの設定はアプリ側で管理します。")
                )
                Divider()
                ShiftHubMacAboutFeatureRow(
                    title: localized("Notion DB"),
                    detail: localized("用意するもの: Notionの内部インテグレーション、アクセストークン、対象データベースのID。データベースにはタイトル型・日付型・複数選択型のプロパティが必要です。\n設定方法: NotionのMy integrationsで内部インテグレーションを作成してトークンを取得し、対象データベースの接続にそのインテグレーションを追加します。データベースURLからIDを確認して入力し、列を取得後にタイトル列・日付列・タグ列・タグ値を選択してください。")
                )
            }

            ShiftHubMacSettingsSectionCard {
                Text(localized("プライバシーポリシー"))
                    .font(.headline)
                Text(localized("このアプリは、ユーザーが選択したPDFと、カレンダー登録に必要な設定を使用します。"))
                Text(localized("Appleカレンダーを使用する場合、カレンダーへのアクセスはイベントの読み取りと登録のためにのみ使用します。"))
                Text(localized("GoogleカレンダーとNotionを使用する場合、入力された認証情報は登録先との通信に使用されます。"))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var shiftHubAppVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (.some(version), .some(build)) where !build.isEmpty:
            return "\(version) (\(build))"
        case let (.some(version), _):
            return version
        default:
            return "Unknown"
        }
    }

    private var shiftHubCopyrightText: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 Tomoaki Narita. All rights reserved."
    }
}

private struct ShiftHubMacSettingsSidebarRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            ShiftHubMacSettingsRowIcon(systemImage: systemImage, isSelected: isSelected)

            Text(title)
                .font(.callout.weight(isSelected ? .semibold : .medium))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 30)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        }
    }
}

private struct ShiftHubMacSettingsHeroIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 34, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 58, height: 58)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            }
    }
}

private struct ShiftHubMacSettingsCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            }
    }
}

private struct ShiftHubMacSettingsSectionCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShiftHubMacSettingsCardBackground())
    }
}

private struct ShiftHubMacSettingsRow<Control: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            ShiftHubMacSettingsRowIcon(systemImage: systemImage)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
            control
        }
        .frame(minHeight: 44)
        .padding(.vertical, 3)
    }
}

private struct ShiftHubMacSettingsRowIcon: View {
    let systemImage: String
    var isSelected = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 22, height: 22)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.18) : Color.secondary.opacity(0.12))
            }
    }
}

private struct ShiftHubMacAboutFeatureRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.callout.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }
}
#endif

private struct AppSettingsView: View {
    @Binding var definitions: [ShiftDefinition]

    @AppStorage("appLanguage") private var appLanguage = AppLanguage.japanese.rawValue
    @AppStorage("iCloudSyncEnabled") private var isCloudSyncEnabled = true

    var body: some View {
#if os(macOS)
        ShiftHubMacSettingsView(
            definitions: $definitions,
            appLanguage: $appLanguage,
            isCloudSyncEnabled: $isCloudSyncEnabled
        )
        .environment(\.locale, Locale(identifier: appLanguage))
        .navigationTitle("設定")
        .frame(
            minWidth: 720,
            idealWidth: 760,
            maxWidth: .infinity,
            minHeight: 560,
            idealHeight: 620,
            maxHeight: .infinity,
            alignment: .topLeading
        )
#else
        Form {
            Section("一般") {
                Picker("言語", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title)
                            .tag(language.rawValue)
                    }
                }

                Toggle(isOn: $isCloudSyncEnabled) {
                    Label("iCloud同期", systemImage: "icloud")
                }

                Text("設定とPDFをiCloudで同期します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("イベント") {
                NavigationLink {
                    ShiftDefinitionSettingsView(definitions: $definitions)
                } label: {
                    Label("イベント管理", systemImage: "clock.badge.checkmark")
                }
                    Text("イベントタイトルと開始・終了時刻を管理")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("カレンダー") {
                NavigationLink {
                    CalendarSettingsView()
                } label: {
                    Label("カレンダー設定", systemImage: "calendar.badge.clock")
                }
                Text("Apple・Google・Notionの接続先を管理")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                NavigationLink {
                    ShiftHubAboutView()
                } label: {
                            Label("Cal Hubについて", systemImage: "info.circle")
                }
            }
        }
        .environment(\.locale, Locale(identifier: appLanguage))
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

private struct ShiftHubAboutView: View {
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (.some(version), .some(build)) where !build.isEmpty:
            return "\(version) (\(build))"
        case let (.some(version), _):
            return version
        default:
            return "Unknown"
        }
    }

    private var copyrightText: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Copyright © 2026 Tomoaki Narita. All rights reserved."
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image("CalHubIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cal Hub")
                            .font(.title3.weight(.semibold))
                        Text(appVersion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(copyrightText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("このアプリについて") {
                Text("イベント設定に保存したイベントを、Appleカレンダー、Googleカレンダー、Notionデータベースへ登録・変更・削除できるアプリです。勤務表のPDFを読み込み、日付ごとのイベントを抽出して登録できます。")
            }

            Section("主な機能") {
                ShiftHubAboutRow(
                    title: "PDFスキャン",
                    detail: "文字データを持つ横向きPDFから、保存した名前に一致する行を抽出します。抽出結果はカレンダー表示と横並び表示を切り替えられ、日付ごとのイベント名を編集・削除できます。"
                )
                ShiftHubAboutRow(
                    title: "保存済みPDF",
                    detail: "読み込んだPDFをアプリ内に保存し、一覧から再解析・削除できます。同じ内容のPDFは重複保存しません。保存したPDFのプレビュー、ページ移動、拡大縮小にも対応します。"
                )
                ShiftHubAboutRow(
                    title: "カレンダー登録",
                    detail: "Appleカレンダー、Googleカレンダー、Notionデータベースを登録先として選択できます。保存済みイベントの一覧から登録できるほか、トップ画面ではタイトルと開始・終了日時を指定したイベントを登録できます。PDFスキャンと複数選択は同日登録に対応します。"
                )
                ShiftHubAboutRow(
                    title: "イベント管理",
                    detail: "月を移動し、日付ごとの通常イベントを確認、変更、削除できます。空の日付への新規登録、既存イベントの置き換えにも対応します。"
                )
                ShiftHubAboutRow(
                    title: "複数選択",
                    detail: "複数の日付を選択し、保存済みのイベントをまとめて登録できます。"
                )
                ShiftHubAboutRow(
                    title: "祝日表示",
                    detail: "Googleカレンダーの「日本の祝日」を登録先と一緒に表示できます。祝日は表示専用で、イベント件数には含まれません。"
                )
                ShiftHubAboutRow(
                    title: "イベント設定",
                    detail: "イベントタイトルと開始・終了時刻を保存、編集、並べ替え、削除できます。"
                )
                ShiftHubAboutRow(
                    title: "iCloud同期",
                    detail: "設定と保存済みPDFをiCloudで同期できます。カレンダー上のイベントと認証情報は同期しません。"
                )
                ShiftHubAboutRow(
                    title: "カレンダーキャッシュ",
                    detail: "表示中の月を中心に前後12か月をキャッシュし、月移動時はキャッシュを先に表示します。表示範囲外の月は破棄し、手動更新、バックグラウンドからの復帰、iCloud同期完了、接続先設定の変更後に再取得します。"
                )
                ShiftHubAboutRow(
                    title: "言語切替",
                    detail: "設定から日本語と英語を切り替えられます。"
                )
            }

            Section("対応形式と注意点") {
                ShiftHubAboutRow(
                    title: "PDF入力条件",
                    detail: "PDFのみ対応しています。文字を選択・コピーできる文字データ層を持つ横向きの勤務表を使用してください。画像だけのスキャンPDFや縦向きPDFには対応していません。"
                )
                ShiftHubAboutRow(
                    title: "年月の判定",
                    detail: "PDFから年月を取得できない場合は、ファイル名を「2026-01.pdf」のようなYYYY-MM形式にしてください。"
                )
                ShiftHubAboutRow(
                    title: "イベント名の照合",
                    detail: "PDFから抽出した勤務名がイベント設定にない場合は、登録前に保存するか、登録時にスキップされます。新しく保存したイベントの初期時間は8:30-16:40です。"
                )
                ShiftHubAboutRow(
                    title: "休の登録",
                    detail: "「休」は登録時に含めるか選択できます。AppleカレンダーとGoogleカレンダーでは終日、Notionでは00:00-23:59の時間付きデータとして登録します。"
                )
                ShiftHubAboutRow(
                    title: "日付カードの表示",
                    detail: "日付カードには時間順に最大3件を表示します。3件以上の場合、カード内の時間は省略され、日付メニューで全件を確認できます。"
                )
                ShiftHubAboutRow(
                    title: "日をまたぐイベント",
                    detail: "トップ画面から開始日時と終了日時を指定して登録できます。日付をまたぐイベントは開始日から終了日まで帯で表示し、週や月の境界では帯を分割します。日付メニューでは開始日・終了日を含む範囲を表示します。PDFスキャンと複数選択からは登録できません。"
                )
            }

            Section("接続の準備") {
                ShiftHubAboutRow(
                    title: "Appleカレンダー",
                    detail: "用意するもの: Apple IDでiCloudにサインインし、カレンダーを有効にした端末。クライアントIDやトークンは不要です。\n設定方法: 端末のカレンダーへのアクセスを許可し、カレンダー設定で「カレンダー一覧を取得」から登録先カレンダーを選択します。"
                )
                ShiftHubAboutRow(
                    title: "Googleカレンダー",
                    detail: "用意するもの: Googleアカウント。\n設定方法: Googleログインを選択し、カレンダーへのアクセスを許可して登録先を選択してください。OAuthクライアントの設定はアプリ側で管理します。"
                )
                ShiftHubAboutRow(
                    title: "Notion DB",
                    detail: "用意するもの: Notionの内部インテグレーション、アクセストークン、対象データベースのID。データベースにはタイトル型・日付型・複数選択型のプロパティが必要です。\n設定方法: NotionのMy integrationsで内部インテグレーションを作成してトークンを取得し、対象データベースの接続にそのインテグレーションを追加します。データベースURLからIDを確認して入力し、列を取得後にタイトル列・日付列・タグ列・タグ値を選択してください。"
                )
            }

            Section("プライバシーポリシー") {
                Text("勤務表、イベント設定、登録先の設定は、この端末に保存されます。iCloud同期を有効にした場合は、同期対象の設定と保存済みPDFがユーザー専用のiCloud領域に保存されます。")
                Text("Appleカレンダー、Googleカレンダー、Notionの情報は、ユーザーが接続・取得・登録を実行した場合にのみ、それぞれのサービスへ送信されます。Notionのアクセストークンなどの認証情報は端末の安全な保存領域で管理されます。")
                Text("このアプリは、ユーザーが選択した勤務表やカレンダーの内容を広告目的で利用しません。各サービスの利用やデータ保存については、それぞれのサービスのポリシーも適用されます。")
            }

            Section("著作権") {
                Text(copyrightText)
                Text("Cal Hubの名称、画面、ソフトウェアおよび関連資料の著作権は、別途記載がある場合を除き、Tomoaki Naritaに帰属します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("サポート") {
                Link(destination: URL(string: "https://github.com/tomoaki-narita/Shift-Upload")!) {
                    Label("サポート・ソースコード", systemImage: "link")
                }
            }
        }
        .navigationTitle("About")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

private struct ShiftHubAboutRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct MissingShiftSelectionView: View {
    let titles: [String]
    let onComplete: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTitles: Set<String>

    init(titles: [String], onComplete: @escaping (Set<String>) -> Void) {
        self.titles = titles
        self.onComplete = onComplete
        _selectedTitles = State(initialValue: [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("イベント一覧にありません")
                        .font(.title2.bold())

                    Text("保存するイベントを選択してください。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("保存") {
                    onComplete(selectedTitles)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)

                Button("閉じる") {
                    onComplete([])
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(24)

            Divider()

            List(titles, id: \.self) { title in
                Toggle(isOn: selectionBinding(for: title)) {
                    Text(title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
#if os(macOS)
                .toggleStyle(.checkbox)
#endif
            }
            .listStyle(.inset)
            .frame(minWidth: 360, minHeight: 220)
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        .frame(width: 420, height: 330)
#endif
    }

    private func selectionBinding(for title: String) -> Binding<Bool> {
        Binding(
            get: { selectedTitles.contains(title) },
            set: { isSelected in
                if isSelected {
                    selectedTitles.insert(title)
                } else {
                    selectedTitles.remove(title)
                }
            }
        )
    }
}

#if os(macOS)
private extension NSImage {
    var cgImageForOCR: CGImage? {
        var proposedRect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}
#elseif os(iOS)
private extension UIImage {
    var cgImageForOCR: CGImage? {
        cgImage
    }
}
#endif

private struct ShiftDefinitionRegistrationView: View {
    let locale: Locale
    let onSave: (String, Int, Int) -> Void

    @Environment(\.dismiss) private var dismiss
#if os(iOS)
    @Environment(\.colorScheme) private var colorScheme
#endif
    @State private var title = ""
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var isInvalidTimeAlertPresented = false

    init(locale: Locale, onSave: @escaping (String, Int, Int) -> Void) {
        self.locale = locale
        self.onSave = onSave
        _startDate = State(initialValue: Self.date(from: 510))
        _endDate = State(initialValue: Self.date(from: 1000))
    }

    private func localized(_ key: String) -> String {
        ShiftHubLocalization.string(key, locale: locale)
    }

    private var timePickerLocale: Locale {
        locale.identifier.hasPrefix("ja")
            ? Locale(identifier: "ja_JP")
            : Locale(identifier: "en_GB")
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

#if os(iOS)
    private var registrationScreenBackground: Color {
        colorScheme == .dark
            ? Color(uiColor: .secondarySystemBackground)
            : Color(uiColor: .systemGroupedBackground)
    }

    private var registrationSectionBackground: Color {
        colorScheme == .dark
            ? Color(uiColor: .tertiarySystemBackground)
            : Color(uiColor: .secondarySystemGroupedBackground)
    }
#endif

    private func saveDefinition() {
        let startMinutes = Self.minutes(from: startDate)
        let endMinutes = Self.minutes(from: endDate)
        guard endMinutes >= startMinutes else {
            isInvalidTimeAlertPresented = true
            return
        }

        onSave(
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            startMinutes,
            endMinutes
        )
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized("イベントを登録"))
                        .font(.title.bold())

                    Text(localized("イベントタイトルと時間を保存します。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(localized("キャンセル")) {
                    dismiss()
                }
                .buttonStyle(.bordered)

#if os(macOS)
                Button(localized("保存")) {
                    saveDefinition()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
#endif
            }
            .padding(24)

            Divider()

#if os(macOS)
            VStack(alignment: .leading, spacing: 12) {
                Text(localized("イベントタイトル"))
                    .font(.headline)

                TextField(localized("タイトル"), text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }

                Text(localized("日時"))
                    .font(.headline)
                    .padding(.top, 8)

                HStack(spacing: 8) {
                    DatePicker(
                        localized("開始"),
                        selection: $startDate,
                        displayedComponents: .hourAndMinute
                    )
                    .environment(\.locale, timePickerLocale)

                    Text("-")
                        .foregroundStyle(.secondary)

                    DatePicker(
                        localized("終了"),
                        selection: $endDate,
                        displayedComponents: .hourAndMinute
                    )
                    .environment(\.locale, timePickerLocale)
                }
            }
            .padding(24)
#else
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(localized("イベントタイトル"))
                            .font(.headline)

                        TextField(localized("タイトル"), text: $title, axis: .vertical)
                            .lineLimit(1...5)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                Color(uiColor: .tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )

                    }
                    .padding(16)
                    .background(
                        registrationSectionBackground,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(localized("日時"))
                            .font(.headline)

                        HStack {
                            Text(localized("開始"))
                            Spacer()
                            DatePicker(
                                "",
                                selection: $startDate,
                                displayedComponents: .hourAndMinute
                            )
                            .labelsHidden()
                            .environment(\.locale, timePickerLocale)
                        }

                        Divider()

                        HStack {
                            Text(localized("終了"))
                            Spacer()
                            DatePicker(
                                "",
                                selection: $endDate,
                                displayedComponents: .hourAndMinute
                            )
                            .labelsHidden()
                            .environment(\.locale, timePickerLocale)
                        }
                    }
                    .padding(16)
                    .background(
                        registrationSectionBackground,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    VStack {
                        Button {
                            saveDefinition()
                        } label: {
                            Text(localized("保存"))
                                .foregroundStyle(Color.accentColor)
                                .frame(maxWidth: .infinity, minHeight: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSave)
                    }
                    .padding(16)
                    .background(
                        registrationSectionBackground,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(24)
#endif
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
#else
        .frame(width: 520, height: 360)
#endif
#if os(iOS)
        .background(
            registrationScreenBackground,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
#endif
        .environment(\.locale, locale)
        .alert(
            Text(localized("保存できません")),
            isPresented: $isInvalidTimeAlertPresented
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(localized("終了時刻は開始時刻以降にしてください。"))
        }
    }

    private static func date(from minutes: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(
            from: DateComponents(
                year: 2000,
                month: 1,
                day: 1,
                hour: minutes / 60,
                minute: minutes % 60
            )
        ) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    private static func minutes(from date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

struct ShiftDefinitionSettingsView: View {
    @Binding var definitions: [ShiftDefinition]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var isRegistrationPresented = false
    @State private var isInvalidTimeAlertPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
#if os(macOS)
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("イベント管理")
                        .font(.title.bold())

//                    Text("勤務タイトルと時間を保存します。")
//                        .font(.callout)
//                        .foregroundStyle(.secondary)
                }

                Spacer()

#if os(macOS)
                Button("完了") {
                    if definitions.contains(where: { $0.endMinutes < $0.startMinutes }) {
                        isInvalidTimeAlertPresented = true
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
#endif
            }
            .padding(24)

            Divider()
#endif

            VStack(alignment: .leading, spacing: 12) {
                if definitions.isEmpty {
                    ContentUnavailableView(
                        "イベント設定がありません",
                        systemImage: "clock.badge.questionmark",
                        description: Text("追加ボタンからイベントタイトルと時間を登録してください。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    List {
                        ForEach($definitions) { $definition in
                            ShiftDefinitionRowView(
                                definition: $definition,
                                deleteAction: {
                                    definitions.removeAll { $0.id == definition.id }
                                }
                            )
#if os(iOS)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    definitions.removeAll { $0.id == definition.id }
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
#else
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowSeparator(.hidden)
#endif
                        }
                        .onMove(perform: moveDefinitions)
                    }
                    .listStyle(.plain)
                }
            }
#if os(iOS)
            .padding(.horizontal, 0)
#else
            .padding(24)
#endif

            Divider()

            HStack {
                Button {
                    isRegistrationPresented = true
                } label: {
                    Label("追加", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)

                Spacer()
            }
#if os(iOS)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
#else
            .padding(24)
#endif
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("イベント管理")
        .navigationBarTitleDisplayMode(.inline)
#else
        .frame(minWidth: 680, minHeight: 460)
#endif
        .sheet(isPresented: $isRegistrationPresented) {
            ShiftDefinitionRegistrationView(locale: locale) { title, startMinutes, endMinutes in
                definitions.append(
                    ShiftDefinition(
                        title: title,
                        startMinutes: startMinutes,
                        endMinutes: endMinutes
                    )
                )
            }
        }
        .alert("保存できません", isPresented: $isInvalidTimeAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("終了時刻は開始時刻以降にしてください。")
        }
    }

    private func moveDefinitions(from source: IndexSet, to destination: Int) {
        definitions.move(fromOffsets: source, toOffset: destination)
    }
}

struct CalendarSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @AppStorage("calendarDestination") private var calendarDestination = CalendarDestination.apple.rawValue
    @AppStorage("appleCalendarIdentifier") private var appleCalendarIdentifier = ""
    @AppStorage("appleCalendarName") private var appleCalendarName = ""
    @AppStorage("appleRestEventTitle") private var appleRestEventTitle = "休"
    @AppStorage("googleCalendarID") private var googleCalendarID = "primary"
    @AppStorage("googleCalendarName") private var googleCalendarName = ""
    @AppStorage("googleRestEventTitle") private var googleRestEventTitle = "休"
    @AppStorage("googleShowJapaneseHolidays") private var googleShowJapaneseHolidays = false
    @AppStorage("notionDataSourceID") private var notionDataSourceID = ""
    @AppStorage("notionDatabaseName") private var notionDatabaseName = ""
    @AppStorage("notionTitleProperty") private var notionTitleProperty = "tasks"
    @AppStorage("notionDateProperty") private var notionDateProperty = "due date"
    @AppStorage("notionTagProperty") private var notionTagProperty = "tag"
    @AppStorage("notionTagValue") private var notionTagValue = "shift"
    @AppStorage("notionRestEventTitle") private var notionRestEventTitle = "休"
    @StateObject private var appleCalendarProvider = AppleCalendarProvider()
    @StateObject private var googleCalendarProvider = GoogleCalendarProvider()
    @State private var notionToken = ""
    @State private var notionProperties: [NotionPropertyOption] = []
    @State private var notionPropertyMessage = ""
    @State private var isLoadingNotionProperties = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
#if os(macOS)
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("カレンダー設定")
                        .font(.title.bold())

                    Text("イベント情報の登録先を設定します。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

#if os(macOS)
                Button("完了") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
#endif
            }
            .padding(24)

            Divider()
#endif

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    calendarSection("登録先カレンダー", systemImage: "paperplane") {
                        Picker("登録先", selection: $calendarDestination) {
                            ForEach(CalendarDestination.allCases) { destination in
                                Text(destination.title)
                                    .tag(destination.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text("ここで選択したカレンダーを、イベントの登録先として使用します。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    switch CalendarDestination(rawValue: calendarDestination) ?? .apple {
                    case .apple:
                        calendarSection("Appleカレンダー", systemImage: "apple.logo") {
                            Button {
                                appleCalendarProvider.loadCalendars()
                            } label: {
                                Label("カレンダー一覧を取得", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .disabled(appleCalendarProvider.isLoading)

                            if appleCalendarProvider.isLoading {
                                ProgressView("取得中です...")
                                    .controlSize(.small)
                            }

                            if !appleCalendarProvider.calendars.isEmpty {
                                Picker("登録先カレンダー", selection: $appleCalendarIdentifier) {
                                    Text("デフォルトカレンダー")
                                        .tag("")

                                    ForEach(appleCalendarProvider.calendars) { calendar in
                                        Text(calendar.displayName(for: locale))
                                        .tag(calendar.id)
                                    }
                                }

                            }

                            if appleCalendarIdentifier.isEmpty {
                                Text("現在の登録先: デフォルトカレンダー")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else if let selectedCalendar = appleCalendarProvider.calendars.first(where: { $0.id == appleCalendarIdentifier }) {
                                Text("現在の登録先: \(selectedCalendar.displayName(for: locale))")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("保存されている登録先カレンダーを確認できません。もう一度一覧を取得してください。")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                            }

                            if !appleCalendarProvider.message.isEmpty {
                                Text(appleCalendarProvider.message)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }

                    case .google:
                        calendarSection("Googleカレンダー", systemImage: "g.circle") {
                            HStack(spacing: 10) {
                                Button {
                                    googleCalendarProvider.signIn()
                                } label: {
                                    Label(
                                        googleCalendarProvider.isAuthorized ? "Googleに再ログイン" : "Googleにログイン",
                                        systemImage: "person.crop.circle.badge.checkmark"
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(googleCalendarProvider.isAuthorizing)

                                if googleCalendarProvider.isAuthorized {
                                    Label("接続済み", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }

                            if googleCalendarProvider.isAuthorizing {
                                ProgressView("ブラウザでGoogleログインを待っています...")
                                    .controlSize(.small)
                            }

                            if googleCalendarProvider.isAuthorized {
                                Button {
                                    googleCalendarProvider.loadCalendars()
                                } label: {
                                    Label("カレンダー一覧を取得", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                                .disabled(googleCalendarProvider.isLoading)
                            }

                            if googleCalendarProvider.isLoading {
                                ProgressView("取得中です...")
                                    .controlSize(.small)
                            }

                            if !googleCalendarProvider.calendars.isEmpty {
                                Picker("登録先カレンダー", selection: $googleCalendarID) {
                                    ForEach(googleCalendarProvider.calendars) { calendar in
                                        Text(calendar.displayName(for: locale))
                                            .tag(calendar.id)
                                    }
                                }
                            }

                            if let selectedCalendar = googleCalendarProvider.calendars.first(where: {
                                $0.id == googleCalendarID
                            }) {
                                Text("現在の登録先: \(selectedCalendar.displayName(for: locale))")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else if googleCalendarProvider.isAuthorized {
                                Text("カレンダー一覧を取得して登録先を選択してください。")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }

                            if googleCalendarProvider.japaneseHolidayCalendarID != nil {
                                VStack(alignment: .leading, spacing: 4) {
                                    Toggle("日本の祝日を表示", isOn: $googleShowJapaneseHolidays)
                                    Text("Googleカレンダーの「日本の祝日」を、登録先と一緒に表示します。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if !googleCalendarProvider.message.isEmpty {
                                Text(googleCalendarProvider.message)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }

                            Text("Googleにログインしてカレンダーへのアクセスを許可し、登録先を選択します。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                    case .notion:
                        calendarSection("Notion DB", systemImage: "square.grid.2x2") {
                            HStack(spacing: 8) {
                                Text("Bearer")
                                    .foregroundStyle(.secondary)

                                SecureField("ntn_から始まるトークン", text: $notionToken)
                                    .textFieldStyle(.roundedBorder)
                            }

                            TextField("データベースID", text: $notionDataSourceID)
                                .textFieldStyle(.roundedBorder)

                            if !notionDatabaseName.isEmpty {
                                Label("接続先: \(notionDatabaseName)", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }

                            if isLoadingNotionProperties {
                                ProgressView("Notionの列を取得中です...")
                                    .controlSize(.small)
                            }

                            if !notionProperties.isEmpty {
                                Text("取得した列から選択")
                                    .font(.callout.weight(.semibold))

                                if !notionProperties.filter({ $0.type == "title" }).isEmpty {
                                    Picker("タイトル列", selection: $notionTitleProperty) {
                                        ForEach(notionProperties.filter { $0.type == "title" }) { property in
                                            Text(property.displayName(for: locale))
                                                .tag(property.name)
                                        }
                                    }
                                }

                                if !notionProperties.filter({ $0.type == "date" }).isEmpty {
                                    Picker("日付列", selection: $notionDateProperty) {
                                        ForEach(notionProperties.filter { $0.type == "date" }) { property in
                                            Text(property.displayName(for: locale))
                                                .tag(property.name)
                                        }
                                    }
                                }

                                if !notionProperties.filter({ $0.type == "multi_select" }).isEmpty {
                                    Picker("タグ列", selection: $notionTagProperty) {
                                        ForEach(notionProperties.filter { $0.type == "multi_select" }) { property in
                                            Text(property.displayName(for: locale))
                                                .tag(property.name)
                                        }
                                    }

                                    if let selectedTagProperty = notionProperties.first(where: {
                                        $0.name == notionTagProperty && $0.type == "multi_select"
                                    }), !selectedTagProperty.options.isEmpty {
                                        Picker("タグ値を選択", selection: $notionTagValue) {
                                            ForEach(selectedTagProperty.options, id: \.self) { option in
                                                Text(option)
                                                    .tag(option)
                                            }
                                        }
                                    }
                                }
                            }

                            if !notionPropertyMessage.isEmpty {
                                Text(notionPropertyMessage)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }

                            Text("データベースID、列名、タグ値はNotion側の設定に合わせて入力してください。Bearer、プロパティの種類、JSON構造はアプリが補完します。対象データベースをNotionの接続に共有し、ページ追加権限を付与してください。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    calendarSection("休の登録名", systemImage: "textformat") {
                        switch CalendarDestination(rawValue: calendarDestination) ?? .apple {
                        case .apple:
                            restEventTitleField($appleRestEventTitle)
                        case .google:
                            restEventTitleField($googleRestEventTitle)
                        case .notion:
                            restEventTitleField($notionRestEventTitle)
                        }
                    }

                    calendarSection("登録ルール", systemImage: "checklist") {
                        switch CalendarDestination(rawValue: calendarDestination) ?? .apple {
                        case .apple:
                            ruleRow("休", "時間を指定しない終日イベントとして登録")
                            ruleRow("イベント", "開始・終了時刻を指定して登録")
                            ruleRow("複合イベント", "登録済みのイベント情報から時間を参照")
                            ruleRow("日をまたぐイベント", "トップ画面から開始日時と終了日時を指定して登録")
                        case .notion:
                            ruleRow("休", "00:00〜23:59の時間付きデータとして登録")
                            ruleRow("イベント", "日付プロパティに開始・終了時刻を登録")
                            ruleRow("複合イベント", "登録済みのイベント情報から時間を参照")
                            ruleRow("日をまたぐイベント", "トップ画面から開始日時と終了日時を指定して登録")
                        case .google:
                            ruleRow("休", "時間を指定しない終日イベントとして登録")
                            ruleRow("イベント", "開始・終了時刻を指定して登録")
                            ruleRow("複合イベント", "登録済みのイベント情報から時間を参照")
                            ruleRow("日をまたぐイベント", "トップ画面から開始日時と終了日時を指定して登録")
                        }
                    }
                }
                .padding(24)
            }
        }
#if os(iOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("カレンダー設定")
        .navigationBarTitleDisplayMode(.inline)
#else
        .frame(minWidth: 680, minHeight: 620)
#endif
        .onAppear {
            appleCalendarProvider.setLocaleIdentifier(locale.identifier)
            googleCalendarProvider.setLocaleIdentifier(locale.identifier)
            appleCalendarProvider.loadCalendarsIfAuthorized()
            googleCalendarProvider.loadSavedState()
            updateAppleCalendarName()
            updateGoogleCalendarName()
            if googleCalendarProvider.isAuthorized {
                googleCalendarProvider.loadCalendars()
            }
            notionToken = KeychainStore.string(for: "notion-access-token") ?? ""

            if notionTitleProperty == "Name" {
                notionTitleProperty = "tasks"
            }
            if notionDateProperty == "Date" {
                notionDateProperty = "due date"
            }
        }
        .onChange(of: calendarDestination) {
            if calendarDestination == CalendarDestination.apple.rawValue {
                appleCalendarProvider.loadCalendarsIfAuthorized()
            }
            if calendarDestination == CalendarDestination.google.rawValue {
                googleCalendarProvider.loadSavedState()
            }
        }
        .onChange(of: locale.identifier) {
            appleCalendarProvider.setLocaleIdentifier(locale.identifier)
            googleCalendarProvider.setLocaleIdentifier(locale.identifier)
        }
        .onChange(of: appleCalendarIdentifier) {
            updateAppleCalendarName()
        }
        .onChange(of: appleCalendarProvider.calendars) {
            reconcileAppleCalendarSelection()
            updateAppleCalendarName()
        }
        .onChange(of: googleCalendarID) {
            updateGoogleCalendarName()
        }
        .onChange(of: googleCalendarProvider.calendars) {
            updateGoogleCalendarName()
        }
        .onChange(of: notionToken) {
            KeychainStore.set(notionToken, for: "notion-access-token")
        }
        .onChange(of: calendarSettingsSyncKey) {
            NotificationCenter.default.post(name: .shiftHubSettingsDidChange, object: nil)
        }
        .task(id: notionDiscoveryKey) {
            await discoverNotionProperties()
        }
        .onDisappear {
            NotificationCenter.default.post(name: .shiftHubSettingsDidChange, object: nil)
        }
    }

    private func restEventTitleField(_ title: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text("休 →")
                .foregroundStyle(.secondary)
            TextField("登録名（例: off）", text: title)
                .textFieldStyle(.roundedBorder)
        }
        .help("勤務表の「休」を、この名前で登録します。")
    }

    private func calendarSection<Content: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            VStack(alignment: .leading, spacing: 10, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.background.secondary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ruleRow(_ name: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.body.weight(.semibold))

            Text(detail)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }

    private func updateAppleCalendarName() {
        let name: String
        if appleCalendarIdentifier.isEmpty {
            name = appleCalendarProvider.defaultCalendarName
        } else {
            name = appleCalendarProvider.calendars.first(where: {
                $0.id == appleCalendarIdentifier
            })?.displayName(for: locale) ?? ""
        }

        appleCalendarName = name
    }

    private func reconcileAppleCalendarSelection() {
        guard !appleCalendarIdentifier.isEmpty,
              !appleCalendarProvider.isLoading,
              !appleCalendarProvider.calendars.isEmpty,
              !appleCalendarProvider.calendars.contains(where: {
                  $0.id == appleCalendarIdentifier
              }) else {
            return
        }

        appleCalendarIdentifier = ""
        updateAppleCalendarName()
    }

    private func updateGoogleCalendarName() {
        googleCalendarName = googleCalendarProvider.calendars.first(where: {
            $0.id == googleCalendarID
        })?.displayName(for: locale) ?? ""
    }

    private var notionDiscoveryKey: String {
        "\(notionToken)|\(notionDataSourceID)"
    }

    private var calendarSettingsSyncKey: [String] {
        [
            calendarDestination,
            appleCalendarIdentifier,
            appleRestEventTitle,
            googleCalendarID,
            googleRestEventTitle,
            notionDataSourceID,
            notionTitleProperty,
            notionDateProperty,
            notionTagProperty,
            notionTagValue,
            notionRestEventTitle
        ]
    }

    private func discoverNotionProperties() async {
        let token = notionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let databaseID = notionDataSourceID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard token.count >= 8, databaseID.count >= 8 else {
            notionDatabaseName = ""
            notionProperties = []
            notionPropertyMessage = ShiftHubLocalization.string(
                "トークンとデータベースIDを入力すると、列を自動取得します。",
                locale: locale
            )
            return
        }

        isLoadingNotionProperties = true
        notionDatabaseName = ""
        notionPropertyMessage = ""

        do {
            try await Task.sleep(for: .milliseconds(600))
            try Task.checkCancellation()
            let schema = try await NotionSchemaClient().fetchSchema(
                token: token,
                databaseID: databaseID,
                localeIdentifier: locale.identifier
            )
            try Task.checkCancellation()
            notionDatabaseName = schema.title
            notionProperties = schema.properties
            notionPropertyMessage = schema.properties.isEmpty
                ? ShiftHubLocalization.string(
                    "取得できる列がありませんでした。Notionの接続権限を確認してください。",
                    locale: locale
                )
                : ShiftHubLocalization.format(
                    "%@個の列を取得しました。",
                    locale: locale,
                    arguments: String(schema.properties.count)
                )
        } catch is CancellationError {
            return
        } catch {
            notionProperties = []
            notionPropertyMessage = ShiftHubLocalization.format(
                "列を取得できませんでした: %@",
                locale: locale,
                arguments: ShiftHubLocalization.localizedErrorDescription(error, locale: locale)
            )
        }

        isLoadingNotionProperties = false
    }
}

private struct NotionRegistrationResult {
    let savedCount: Int
    let skippedTitles: [String]
}

private struct NotionPropertyOption: Identifiable, Hashable {
    let name: String
    let type: String
    let options: [String]

    var id: String { "\(name)|\(type)" }

    var displayName: String {
        "\(name)（\(type)）"
    }

    func displayName(for locale: Locale) -> String {
        ShiftHubLocalization.isEnglish(locale) ? "\(name) (\(type))" : displayName
    }
}

private struct NotionDatabaseSchema {
    let title: String
    let properties: [NotionPropertyOption]
}

private struct NotionSchemaClient {
    func fetchSchema(
        token: String,
        databaseID: String,
        localeIdentifier: String
    ) async throws -> NotionDatabaseSchema {
        guard let url = URL(string: "https://api.notion.com/v1/databases/\(databaseID)") else {
            throw NotionAPIError.invalidSettings
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NotionAPIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = responseObject?["message"] as? String ?? "不明なエラー"
            throw NotionAPIError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        guard let responseObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = responseObject["properties"] as? [String: Any] else {
            throw NotionAPIError.invalidResponse
        }

        let title = (responseObject["title"] as? [[String: Any]] ?? [])
            .compactMap { richText in
                if let plainText = richText["plain_text"] as? String {
                    return plainText
                }

                let text = richText["text"] as? [String: Any]
                return text?["content"] as? String
            }
            .joined()

        let propertyOptions: [NotionPropertyOption] = properties.compactMap { name, value in
            guard let property = value as? [String: Any],
                  let type = property["type"] as? String else {
                return nil
            }

            let options: [String]
            if type == "multi_select",
               let configuration = property["multi_select"] as? [String: Any],
               let rawOptions = configuration["options"] as? [[String: Any]] {
                options = rawOptions.compactMap { $0["name"] as? String }
            } else {
                options = []
            }

            return NotionPropertyOption(name: name, type: type, options: options)
        }
        .sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return NotionDatabaseSchema(
            title: title.isEmpty
                ? (ShiftHubLocalization.isEnglish(Locale(identifier: localeIdentifier))
                    ? "Untitled Notion database"
                    : "名称未設定のNotion DB")
                : title,
            properties: propertyOptions
        )
    }
}

private enum NotionAPIError: LocalizedError {
    case invalidSettings
    case invalidDate(String)
    case requestFailed(statusCode: Int, message: String)
    case invalidResponse

    var statusCode: Int? {
        if case .requestFailed(let statusCode, _) = self {
            return statusCode
        }

        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            return "Notionの設定を確認してください。"
        case .invalidDate(let day):
            return "日付を作成できませんでした: \(day)"
        case .requestFailed(let statusCode, let message):
            return "Notion APIエラー（\(statusCode)）: \(message)"
        case .invalidResponse:
            return "Notionから無効な応答が返されました。"
        }
    }
}

@MainActor
private final class NotionPageWriter {
    private let endpoint = URL(string: "https://api.notion.com/v1/pages")!

    func register(
        cells: [ExtractedShiftCell],
        yearMonth: YearMonth?,
        definitions: [ShiftDefinition],
        token: String,
        dataSourceID: String,
        titleProperty: String,
        dateProperty: String,
        tagProperty: String,
        tagValue: String,
        restTitle: String,
        includeRest: Bool
    ) async throws -> NotionRegistrationResult {
        guard let yearMonth,
              !dataSourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !titleProperty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !dateProperty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !tagProperty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !tagValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotionAPIError.invalidSettings
        }

        let definitionByTitle = Dictionary(
            uniqueKeysWithValues: definitions.map { (normalizedTitle($0.title), $0) }
        )
        let registeredRestTitle = restTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "休"
            : restTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var skippedTitles: [String] = []
        var savedCount = 0

        for cell in cells {
            guard let day = Int(cell.dateText), (1...yearMonth.numberOfDays).contains(day) else {
                continue
            }

            let title = normalizedTitle(cell.valueText)
            guard !title.isEmpty else { continue }

            if title == "休" {
                guard includeRest else { continue }
                try await createPage(
                    title: registeredRestTitle,
                    yearMonth: yearMonth,
                    dayText: cell.dateText,
                    startMinutes: 0,
                    endMinutes: 1439,
                    token: token,
                    dataSourceID: dataSourceID,
                    titleProperty: titleProperty,
                    dateProperty: dateProperty,
                    tagProperty: tagProperty,
                    tagValue: tagValue
                )
                savedCount += 1
                continue
            }

            guard let definition = definitionByTitle[title] else {
                if !skippedTitles.contains(title) {
                    skippedTitles.append(title)
                }
                continue
            }

            try await createPage(
                title: title,
                yearMonth: yearMonth,
                dayText: cell.dateText,
                startMinutes: definition.startMinutes,
                endMinutes: definition.endMinutes,
                token: token,
                dataSourceID: dataSourceID,
                titleProperty: titleProperty,
                dateProperty: dateProperty,
                tagProperty: tagProperty,
                tagValue: tagValue
            )
            savedCount += 1
        }

        return NotionRegistrationResult(savedCount: savedCount, skippedTitles: skippedTitles)
    }

    private func createPage(
        title: String,
        yearMonth: YearMonth,
        dayText: String,
        startMinutes: Int?,
        endMinutes: Int?,
        token: String,
        dataSourceID: String,
        titleProperty: String,
        dateProperty: String,
        tagProperty: String,
        tagValue: String
    ) async throws {
        guard let day = Int(dayText), (1...yearMonth.numberOfDays).contains(day) else {
            throw NotionAPIError.invalidDate(dayText)
        }

        var dateValue: [String: Any] = [:]
        if let startMinutes, let endMinutes,
           let startDate = date(yearMonth: yearMonth, day: day, minutes: startMinutes),
           let endDate = date(yearMonth: yearMonth, day: day, minutes: endMinutes) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            formatter.timeZone = TimeZone.current
            dateValue["start"] = formatter.string(from: startDate)
            dateValue["end"] = formatter.string(from: endDate)
        } else if startMinutes == nil && endMinutes == nil {
            dateValue["start"] = String(format: "%04d-%02d-%02d", yearMonth.year, yearMonth.month, day)
        } else {
            throw NotionAPIError.invalidDate(dayText)
        }

        let properties: [String: Any] = [
            titleProperty: [
                "title": [[
                    "type": "text",
                    "text": ["content": title]
                ]]
            ],
            dateProperty: ["date": dateValue],
            tagProperty: [
                "multi_select": [["name": tagValue]]
            ]
        ]

        _ = try await sendCreatePageRequest(
            parent: ["database_id": dataSourceID],
            properties: properties,
            token: token
        )
    }

    func registerDateTimeEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        token: String,
        dataSourceID: String,
        titleProperty: String,
        dateProperty: String,
        tagProperty: String,
        tagValue: String
    ) async throws -> String {
        guard !dataSourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !titleProperty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !dateProperty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !tagProperty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !tagValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotionAPIError.invalidSettings
        }

        var dateValue: [String: Any]
        if isAllDay {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"

            let calendar = Calendar.current
            let normalizedStartDate = calendar.startOfDay(for: startDate)
            let normalizedEndDate = calendar.startOfDay(for: endDate)
            dateValue = ["start": formatter.string(from: normalizedStartDate)]
            if normalizedEndDate > normalizedStartDate {
                dateValue["end"] = formatter.string(from: normalizedEndDate)
            }
        } else {
            guard endDate >= startDate else {
                throw NotionAPIError.invalidDate("終了日時")
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            formatter.timeZone = .current
            dateValue = [
                "start": formatter.string(from: startDate),
                "end": formatter.string(from: endDate)
            ]
        }

        let properties: [String: Any] = [
            titleProperty: [
                "title": [[
                    "type": "text",
                    "text": ["content": title]
                ]]
            ],
            dateProperty: ["date": dateValue],
            tagProperty: [
                "multi_select": [["name": tagValue]]
            ]
        ]

        return try await sendCreatePageRequest(
            parent: ["database_id": dataSourceID],
            properties: properties,
            token: token
        )
    }

    private func sendCreatePageRequest(
        parent: [String: Any],
        properties: [String: Any],
        token: String
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "parent": parent,
            "properties": properties
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NotionAPIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = responseObject?["message"] as? String ?? "不明なエラー"
            throw NotionAPIError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        guard let responseObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identifier = responseObject["id"] as? String else {
            throw NotionAPIError.invalidResponse
        }

        return identifier
    }

    private func date(yearMonth: YearMonth, day: Int, minutes: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: yearMonth.year,
                month: yearMonth.month,
                day: day,
                hour: minutes / 60,
                minute: minutes % 60
            )
        )
    }

    private func normalizedTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "／", with: "/")
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
private final class CalendarEventManagerModel: ObservableObject {
    private struct MonthCacheEntry {
        let events: [CalendarEventRecord]
        let calendarColor: CalendarDisplayColor?
    }

    @Published private(set) var events: [CalendarEventRecord] = []
    @Published private(set) var loadedDays: Set<Int> = []
    @Published private(set) var calendarColor: CalendarDisplayColor? = nil
    @Published private(set) var isLoading = false
    @Published private(set) var isDeleting = false
    @Published var isDeleteConfirmationPresented = false
    @Published private(set) var pendingDeletion: CalendarEventRecord?
    @Published private(set) var message = ""
    @Published private(set) var shouldAnimateEventBandReveal = false

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
        notionTagValue: String
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
        notionTagValue: String
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

        self.destination = destination
        self.appleCalendarIdentifier = appleCalendarIdentifier
        self.googleCalendarID = googleCalendarID
        self.googleShowJapaneseHolidays = googleShowJapaneseHolidays
        self.notionDataSourceID = notionDataSourceID
        self.notionDateProperty = notionDateProperty
        self.notionTitleProperty = notionTitleProperty
        self.notionTagProperty = notionTagProperty
        self.notionTagValue = notionTagValue

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

    func events(for day: Int) -> [CalendarEventRecord] {
        events
            .filter { $0.starts(on: day, in: yearMonth) }
            .sorted(by: calendarEventComesBefore)
    }

    func applyRegisteredDateTimeEvent(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let startComponents = calendar.dateComponents([.year, .month, .day], from: startDate)
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
            title: title,
            detail: isAllDay
                ? ShiftHubLocalization.string("終日", locale: displayLocale)
                : registeredTimeRangeText(start: startDate, end: endDate),
            isAllDay: isAllDay,
            startDate: startDate,
            endDate: endDate,
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
                tagValue: notionTagValue
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

private enum CalendarEventManagementError: LocalizedError {
    case invalidSettings(String)
    case accessDenied
    case calendarNotFound
    case invalidResponse
    case requestFailed(String)
    case invalidDate

    var errorDescription: String? {
        switch self {
        case .invalidSettings(let message):
            return message
        case .accessDenied:
            return "カレンダーへのアクセスが許可されていません。"
        case .calendarNotFound:
            return "登録先カレンダーが見つかりません。"
        case .invalidResponse:
            return "カレンダーから無効な応答が返されました。"
        case .requestFailed(let message):
            return message
        case .invalidDate:
            return "イベントの日付を作成できませんでした。"
        }
    }
}

nonisolated private final class AppleCalendarEventClient {
    private let eventStore = EKEventStore()
    private let calendarIdentifier: String

    init(calendarIdentifier: String) {
        self.calendarIdentifier = calendarIdentifier
    }

    func fetch(yearMonth: YearMonth) throws -> [CalendarEventRecord] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarEventManagementError.accessDenied
        }

        guard let calendar = selectedCalendar() else {
            throw CalendarEventManagementError.calendarNotFound
        }
        let calendarColor = CalendarDisplayColor(cgColor: calendar.cgColor)

        guard let startDate = monthStart(yearMonth),
              let endDate = Calendar.current.date(byAdding: .month, value: 1, to: startDate) else {
            throw CalendarEventManagementError.invalidDate
        }

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: [calendar]
        )

        return eventStore.events(matching: predicate).compactMap { event in
            guard let identifier = event.eventIdentifier,
                  let day = Calendar.current.dateComponents([.day], from: event.startDate).day else {
                return nil
            }

            return CalendarEventRecord(
                id: identifier,
                day: day,
                title: event.title?.isEmpty == false ? event.title! : "無題",
                detail: event.isAllDay ? "終日" : timeRangeText(start: event.startDate, end: event.endDate),
                isAllDay: event.isAllDay,
                startDate: event.startDate,
                endDate: event.isAllDay ? nil : event.endDate,
                calendarColor: calendarColor
            )
        }
    }

    func fetchCalendarColor() throws -> CalendarDisplayColor? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarEventManagementError.accessDenied
        }

        guard let calendar = selectedCalendar() else {
            throw CalendarEventManagementError.calendarNotFound
        }

        return CalendarDisplayColor(cgColor: calendar.cgColor)
    }

    func deleteEvent(identifier: String) throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarEventManagementError.accessDenied
        }

        guard let event = eventStore.event(withIdentifier: identifier) else {
            throw CalendarEventManagementError.invalidResponse
        }

        try eventStore.remove(event, span: .thisEvent, commit: true)
    }

    private func selectedCalendar() -> EKCalendar? {
        if calendarIdentifier.isEmpty {
            return eventStore.defaultCalendarForNewEvents
        }

        return eventStore.calendar(withIdentifier: calendarIdentifier)
    }

    private func monthStart(_ yearMonth: YearMonth) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: yearMonth.year, month: yearMonth.month, day: 1))
    }

    private func timeRangeText(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = .current
        formatter.dateFormat = "H:mm"
        return "\(formatter.string(from: start))-\(formatter.string(from: end))"
    }
}

private struct NotionCalendarEventClient {
    let token: String
    let dataSourceID: String
    let dateProperty: String
    let titleProperty: String
    let tagProperty: String
    let tagValue: String

    func fetchEvents(yearMonth: YearMonth) async throws -> [CalendarEventRecord] {
        var cursor: String?
        var records: [CalendarEventRecord] = []
        var seenPageIDs = Set<String>()
        var requestedCursors = Set<String>()
        var pageCount = 0

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let monthStart = calendar.date(from: DateComponents(
            year: yearMonth.year,
            month: yearMonth.month,
            day: 1
        )),
        let queryStart = calendar.date(
            byAdding: .month,
            value: -1,
            to: monthStart
        ),
        let nextMonthStart = calendar.date(
            byAdding: .month,
            value: 1,
            to: monthStart
        ) else {
            throw CalendarEventManagementError.invalidResponse
        }

        repeat {
            if let cursor, !requestedCursors.insert(cursor).inserted {
                break
            }
            pageCount += 1
            guard pageCount <= 100 else { break }

            var body: [String: Any] = [
                "page_size": 100,
                "filter": [
                    "and": [
                        [
                            "property": dateProperty,
                            "date": [
                                "on_or_after": dateText(from: queryStart),
                                "before": dateText(yearMonth: yearMonth.nextMonth, day: 1)
                            ]
                        ],
                        [
                            "property": tagProperty,
                            "multi_select": ["contains": tagValue]
                        ]
                    ]
                ]
            ]
            if let cursor {
                body["start_cursor"] = cursor
            }

            let payload = try await sendRequest(
                url: URL(string: "https://api.notion.com/v1/databases/\(dataSourceID)/query")!,
                method: "POST",
                body: body
            )

            guard let results = payload["results"] as? [[String: Any]] else {
                throw CalendarEventManagementError.invalidResponse
            }

            for page in results {
                let isTrashed = (page["in_trash"] as? Bool) == true
                    || (page["archived"] as? Bool) == true

                guard let identifier = page["id"] as? String,
                      seenPageIDs.insert(identifier).inserted,
                      !isTrashed,
                      let properties = page["properties"] as? [String: Any],
                      let dateData = properties[dateProperty] as? [String: Any],
                      let dateValue = dateData["date"] as? [String: Any],
                      let start = dateValue["start"] as? String,
                      hasConfiguredTag(in: properties[tagProperty]) else {
                    continue
                }

                let title = title(from: properties[titleProperty])
                let isAllDay = !start.contains("T")
                let startDate = isAllDay ? dateOnlyDate(from: start) : parseISO8601Date(start)
                guard let startDate else { continue }
                let detail: String
                let endDate: Date?
                if start.contains("T"),
                   let end = dateValue["end"] as? String,
                   end.contains("T") {
                    detail = timeRangeText(start: start, end: end)
                    endDate = parseISO8601Date(end)
                } else {
                    detail = isAllDay ? "終日" : timeText(from: start)
                    endDate = isAllDay
                        ? (dateValue["end"] as? String).flatMap { dateOnlyDate(from: $0) }
                        : nil
                }

                let startsInMonth = startDate >= monthStart && startDate < nextMonthStart
                let continuesIntoMonth = startDate < monthStart
                    && (endDate.map { $0 > monthStart } ?? false)
                guard startsInMonth || continuesIntoMonth else { continue }

                let day = startsInMonth
                    ? (dayInSelectedMonth(from: start, yearMonth: yearMonth) ?? 1)
                    : 1
                records.append(CalendarEventRecord(
                    id: identifier,
                    day: day,
                    title: title.isEmpty ? "無題" : title,
                    detail: detail,
                    isAllDay: isAllDay,
                    startDate: startDate,
                    endDate: endDate,
                    calendarColor: nil
                ))
            }

            cursor = payload["has_more"] as? Bool == true
                ? payload["next_cursor"] as? String
                : nil
        } while cursor != nil

        return records
    }

    func deletePage(identifier: String) async throws {
        let payload = try await sendRequest(
            url: URL(string: "https://api.notion.com/v1/pages/\(identifier)")!,
            method: "PATCH",
            body: ["in_trash": true],
            notionVersion: "2026-03-11"
        )

        guard (payload["in_trash"] as? Bool) == true else {
            throw CalendarEventManagementError.invalidResponse
        }
    }

    private func sendRequest(
        url: URL,
        method: String,
        body: [String: Any]? = nil,
        notionVersion: String = "2022-06-28"
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CalendarEventManagementError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = responseObject?["message"] as? String ?? "Notion APIエラー"
            throw CalendarEventManagementError.requestFailed(message)
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return payload
    }

    private func title(from property: Any?) -> String {
        guard let property = property as? [String: Any],
              let values = property["title"] as? [[String: Any]] else {
            return ""
        }

        return values.compactMap { value in
            (value["plain_text"] as? String) ?? ((value["text"] as? [String: Any])?["content"] as? String)
        }
        .joined()
    }

    private func timeText(from value: String) -> String {
        if let date = parseISO8601Date(value) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ja_JP")
            formatter.timeZone = .current
            formatter.dateFormat = "H:mm"
            return formatter.string(from: date)
        }

        let time = value.split(separator: "T").dropFirst().first.map(String.init) ?? value
        return String(time.prefix(5))
    }

    private func timeRangeText(start: String, end: String) -> String {
        guard let startDate = parseISO8601Date(start),
              let endDate = parseISO8601Date(end) else {
            return timeText(from: start)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = .current
        formatter.dateFormat = "H:mm"
        return "\(formatter.string(from: startDate))-\(formatter.string(from: endDate))"
    }

    private func dayInSelectedMonth(from value: String, yearMonth: YearMonth) -> Int? {
        if value.contains("T"), let date = parseISO8601Date(value) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let components = calendar.dateComponents([.year, .month, .day], from: date)

            guard components.year == yearMonth.year,
                  components.month == yearMonth.month,
                  let day = components.day,
                  (1...yearMonth.numberOfDays).contains(day) else {
                return nil
            }

            return day
        }

        let dateText = String(value.prefix(10))
        let components = dateText.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3,
              components[0] == yearMonth.year,
              components[1] == yearMonth.month,
              (1...yearMonth.numberOfDays).contains(components[2]) else {
            return nil
        }

        return components[2]
    }

    private func parseISO8601Date(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func dateOnlyDate(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(value.prefix(10)))
    }

    private func hasConfiguredTag(in property: Any?) -> Bool {
        let expected = tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty,
              let property = property as? [String: Any] else {
            return false
        }

        if let values = property["multi_select"] as? [[String: Any]] {
            return values.contains { ($0["name"] as? String) == expected }
        }

        if let value = property["select"] as? [String: Any] {
            return (value["name"] as? String) == expected
        }

        if let values = property["rich_text"] as? [[String: Any]] {
            return values.contains { textValue(from: $0) == expected }
        }

        return false
    }

    private func textValue(from value: [String: Any]) -> String {
        (value["plain_text"] as? String)
            ?? ((value["text"] as? [String: Any])?["content"] as? String)
            ?? ""
    }

    private func dateText(yearMonth: YearMonth, day: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let date = calendar.date(from: DateComponents(year: yearMonth.year, month: yearMonth.month, day: day)) else {
            return String(format: "%04d-%02d-%02d", yearMonth.year, yearMonth.month, day)
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func dateText(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct GoogleCalendarOption: Identifiable, Hashable {
    let id: String
    let title: String
    let isPrimary: Bool

    var displayName: String {
        isPrimary ? "\(title)（メイン）" : title
    }

    func displayName(for locale: Locale) -> String {
        isPrimary && ShiftHubLocalization.isEnglish(locale) ? "\(title) (Primary)" : displayName
    }
}

private struct GoogleOAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

private enum GoogleTokenStore {
    private static let account = "google-calendar-oauth-tokens"

    static func load() -> GoogleOAuthTokens? {
        guard let value = KeychainStore.string(for: account),
              let data = value.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(GoogleOAuthTokens.self, from: data)
    }

    static func save(_ tokens: GoogleOAuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens),
              let value = String(data: data, encoding: .utf8) else {
            return
        }

        KeychainStore.set(value, for: account)
    }

    static func clear() {
        KeychainStore.set("", for: account)
    }
}

@MainActor
private final class GoogleCalendarProvider: ObservableObject {
    @Published private(set) var calendars: [GoogleCalendarOption] = []
    @Published private(set) var japaneseHolidayCalendarID: String?
    @Published private(set) var message = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isAuthorizing = false
    @Published private(set) var isAuthorized = false
    private var localeIdentifier = "ja"

    func setLocaleIdentifier(_ identifier: String) {
        localeIdentifier = identifier
    }

    func loadSavedState() {
        isAuthorized = GoogleTokenStore.load() != nil
    }

    func signIn() {
        isAuthorizing = true
        message = ""

        Task { @MainActor [weak self] in
            do {
                let tokens = try await GoogleOAuthClient.authorize(
                    localeIdentifier: self?.localeIdentifier ?? "ja"
                )
                GoogleTokenStore.save(tokens)
                self?.isAuthorized = true
                self?.calendars = []
                self?.japaneseHolidayCalendarID = nil
                self?.message = ShiftHubLocalization.string(
                    "Googleアカウントに接続しました。カレンダー一覧を取得してください。",
                    locale: Locale(identifier: self?.localeIdentifier ?? "ja")
                )
            } catch {
                self?.message = ShiftHubLocalization.format(
                    "Googleログインに失敗しました: %@",
                    locale: Locale(identifier: self?.localeIdentifier ?? "ja"),
                    arguments: ShiftHubLocalization.localizedErrorDescription(
                        error,
                        locale: Locale(identifier: self?.localeIdentifier ?? "ja")
                    )
                )
            }

            self?.isAuthorizing = false
        }
    }

    func loadCalendars() {
        isLoading = true
        message = ""

        Task { @MainActor [weak self] in
            do {
                let client = GoogleCalendarAPIClient(
                    clientID: GoogleOAuthConfiguration.clientID
                )
                let calendars = try await client.fetchCalendars()
                let holidayCalendarID = try await client.fetchJapaneseHolidayCalendarID()
                self?.calendars = calendars
                self?.japaneseHolidayCalendarID = holidayCalendarID
                self?.isAuthorized = true
                self?.message = calendars.isEmpty
                    ? ShiftHubLocalization.string(
                        "利用できるカレンダーが見つかりませんでした。",
                        locale: Locale(identifier: self?.localeIdentifier ?? "ja")
                    )
                    : ShiftHubLocalization.format(
                        "%@件のカレンダーを取得しました。",
                        locale: Locale(identifier: self?.localeIdentifier ?? "ja"),
                        arguments: String(calendars.count)
                    )
            } catch {
                self?.message = ShiftHubLocalization.format(
                    "カレンダー一覧を取得できませんでした: %@",
                    locale: Locale(identifier: self?.localeIdentifier ?? "ja"),
                    arguments: error.localizedDescription
                )
            }

            self?.isLoading = false
        }
    }
}

private struct GoogleOAuthCallback: Sendable {
    let code: String
    let state: String
}

private enum GoogleOAuthClient {
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let scopes = [
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    ]

    static func authorize(localeIdentifier: String) async throws -> GoogleOAuthTokens {
        let clientID = GoogleOAuthConfiguration.clientID
        let state = randomString(length: 32)
        let codeVerifier = randomString(length: 64)
        let codeChallenge = base64URL(SHA256.hash(data: Data(codeVerifier.utf8)))
#if os(iOS)
        let redirectURI = "\(GoogleOAuthConfiguration.callbackURLScheme):/oauthredirect"
#else
        let server = GoogleOAuthLoopbackServer(localeIdentifier: localeIdentifier)
        let redirectURI = try await server.start()
        defer { server.stop() }
#endif

        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authorizationURL = components?.url else {
            throw GoogleCalendarError.browserUnavailable
        }

#if os(macOS)
        guard NSWorkspace.shared.open(authorizationURL) else {
            throw GoogleCalendarError.browserUnavailable
        }
#endif

#if os(iOS)
        let callbackURL = try await GoogleOAuthWebAuthenticationSession.authenticate(
            authorizationURL: authorizationURL,
            callbackURLScheme: GoogleOAuthConfiguration.callbackURLScheme
        )
        guard let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value,
              let callbackState = callbackComponents.queryItems?.first(where: { $0.name == "state" })?.value else {
            throw GoogleCalendarError.invalidResponse
        }
        let callback = GoogleOAuthCallback(code: code, state: callbackState)
#else
        let callback = try await server.waitForCallback()
#endif
        guard callback.state == state else {
            throw GoogleCalendarError.invalidOAuthState
        }

        return try await exchangeCode(
            callback.code,
            clientID: clientID,
            redirectURI: redirectURI,
            codeVerifier: codeVerifier
        )
    }

    private static func exchangeCode(
        _ code: String,
        clientID: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> GoogleOAuthTokens {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var values = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]
        if let clientSecret = GoogleOAuthConfiguration.clientSecret, !clientSecret.isEmpty {
            values["client_secret"] = clientSecret
        }
        request.httpBody = formBody(values)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleCalendarError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GoogleCalendarError.requestFailed(message: "HTTP \(httpResponse.statusCode): \(responseMessage(from: data))")
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = payload["access_token"] as? String,
              let refreshToken = payload["refresh_token"] as? String,
              let expiresIn = payload["expires_in"] as? Double else {
            throw GoogleCalendarError.invalidResponse
        }

        return GoogleOAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    private static func formBody(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private static func randomString(length: Int) -> String {
        let bytes = (0..<length).map { _ in UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URL(_ digest: SHA256.Digest) -> String {
        base64URL(Data(digest))
    }

    private static func responseMessage(from data: Data) -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return body?.isEmpty == false ? body! : "不明なエラー"
        }

        if let error = payload["error"] as? [String: Any] {
            let code = error["status"] as? String
                ?? (error["code"] as? Int).map(String.init)
            let reason = error["reason"] as? String
                ?? (error["errors"] as? [[String: Any]])?.compactMap { $0["reason"] as? String }.first
            let message = error["message"] as? String
            let details = [code, reason, message]
                .compactMap { $0 }
            return details.isEmpty ? "不明なエラー" : details.joined(separator: ": ")
        }

        if let error = payload["error"] as? String {
            let description = payload["error_description"] as? String
            return [error, description]
                .compactMap { $0 }
                .joined(separator: ": ")
        }

        return payload["message"] as? String ?? "不明なエラー"
    }
}

#if os(iOS)
@MainActor
private final class GoogleOAuthWebAuthenticationSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    static func authenticate(authorizationURL: URL, callbackURLScheme: String) async throws -> URL {
        let coordinator = GoogleOAuthWebAuthenticationSession()
        return try await coordinator.start(
            authorizationURL: authorizationURL,
            callbackURLScheme: callbackURLScheme
        )
    }

    private func start(authorizationURL: URL, callbackURLScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: callbackURLScheme
            ) { [weak self] callbackURL, error in
                guard let self else { return }
                self.session = nil

                if let callbackURL {
                    self.finish(.success(callbackURL))
                } else if let error {
                    self.finish(.failure(error))
                } else {
                    self.finish(.failure(GoogleCalendarError.authorizationCancelled))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            guard session.start() else {
                self.session = nil
                self.finish(.failure(GoogleCalendarError.browserUnavailable))
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })
            ?? UIWindow(frame: UIScreen.main.bounds)
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
#endif

private final class GoogleOAuthLoopbackServer: @unchecked Sendable {
    private let localeIdentifier: String
    private let queue = DispatchQueue(label: "net.unwraps.Shift-Upload.google-oauth")
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<String, Error>?
    private var callbackContinuation: CheckedContinuation<GoogleOAuthCallback, Error>?
    private var pendingCallback: GoogleOAuthCallback?

    init(localeIdentifier: String) {
        self.localeIdentifier = localeIdentifier
    }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return }
                self.startContinuation = continuation

                do {
                    let listener = try NWListener(using: .tcp, on: .any)
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = listener?.port else {
                                self.failStart(GoogleCalendarError.invalidResponse)
                                return
                            }
                            self.finishStart("http://127.0.0.1:\(port.rawValue)/oauth2callback")
                        case .failed(let error):
                            self.failStart(error)
                        case .cancelled:
                            self.failStart(GoogleCalendarError.authorizationCancelled)
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        connection.start(queue: self?.queue ?? .global())
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, _, _ in
                            guard let self, let data else { return }
                            self.handle(data: data, connection: connection)
                        }
                    }
                    self.listener = listener
                    listener.start(queue: self.queue)
                } catch {
                    self.failStart(error)
                }
            }
        }
    }

    func waitForCallback() async throws -> GoogleOAuthCallback {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return }
                if let pendingCallback = self.pendingCallback {
                    self.pendingCallback = nil
                    continuation.resume(returning: pendingCallback)
                } else {
                    self.callbackContinuation = continuation
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
        }
    }

    private func finishStart(_ redirectURI: String) {
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(returning: redirectURI)
    }

    private func failStart(_ error: Error) {
        let continuation = startContinuation
        startContinuation = nil
        listener?.cancel()
        listener = nil
        continuation?.resume(throwing: error)
    }

    private func handle(data: Data, connection: NWConnection?) {
        guard let request = String(data: data, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let state = components.queryItems?.first(where: { $0.name == "state" })?.value else {
            sendResponse(
                to: connection,
                body: ShiftHubLocalization.string(
                    "認証情報を受け取れませんでした。Cal Hubに戻ってください。",
                    locale: Locale(identifier: localeIdentifier)
                )
            )
            return
        }

        sendResponse(
            to: connection,
            body: ShiftHubLocalization.string(
                "Googleログインが完了しました。このページを閉じてCal Hubに戻ってください。",
                locale: Locale(identifier: localeIdentifier)
            )
        )
        listener?.cancel()
        listener = nil

        let callback = GoogleOAuthCallback(code: code, state: state)
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(returning: callback)
        } else {
            pendingCallback = callback
        }
    }

    private func sendResponse(to connection: NWConnection?, body: String) {
        guard let connection else { return }
        let bodyData = Data(body.utf8)
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private struct GoogleCalendarAPIClient {
    let clientID: String
    let clientSecret: String? = GoogleOAuthConfiguration.clientSecret

    func fetchCalendars() async throws -> [GoogleCalendarOption] {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        components.queryItems = [
            URLQueryItem(name: "minAccessRole", value: "writer")
        ]

        let data = try await sendRequest(url: components.url!, method: "GET")
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = payload["items"] as? [[String: Any]] else {
            throw GoogleCalendarError.invalidResponse
        }

        let options: [GoogleCalendarOption] = items.compactMap { (item: [String: Any]) -> GoogleCalendarOption? in
            guard let rawID = item["id"] as? String,
                  let accessRole = item["accessRole"] as? String,
                  accessRole == "owner" || accessRole == "writer" else {
                return nil
            }

            let isPrimary = item["primary"] as? Bool ?? false
            let id = isPrimary ? "primary" : rawID
            let title = (item["summaryOverride"] as? String)
                ?? (item["summary"] as? String)
                ?? "名称未設定"
            return GoogleCalendarOption(id: id, title: title, isPrimary: isPrimary)
        }

        return options
        .reduce(into: [GoogleCalendarOption]()) { (result: inout [GoogleCalendarOption], calendar: GoogleCalendarOption) in
            guard !result.contains(where: { $0.id == calendar.id }) else { return }
            result.append(calendar)
        }
        .sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary {
                return lhs.isPrimary
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    func fetchJapaneseHolidayCalendarID() async throws -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        components.queryItems = [
            URLQueryItem(name: "minAccessRole", value: "reader")
        ]

        let data = try await sendRequest(url: components.url!, method: "GET")
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = payload["items"] as? [[String: Any]] else {
            throw GoogleCalendarError.invalidResponse
        }

        return items.compactMap { (item: [String: Any]) -> String? in
            guard let id = item["id"] as? String else { return nil }
            let title = ((item["summaryOverride"] as? String) ?? (item["summary"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let normalizedID = id.lowercased()
            guard title.contains("日本の祝日")
                    || title.contains("japanese holidays")
                    || title.contains("japanese holiday")
                    || normalizedID.contains("japanese#holiday") else {
                return nil
            }
            return id
        }.first
    }

    func createEvent(
        calendarID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool
    ) async throws -> String {
        guard endDate >= startDate else {
            throw GoogleCalendarError.invalidDate
        }

        let start: [String: Any]
        let end: [String: Any]
        if isAllDay {
            let calendar = Calendar.current
            let normalizedStartDate = calendar.startOfDay(for: startDate)
            let normalizedEndDate = calendar.startOfDay(for: endDate)
            guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: normalizedEndDate) else {
                throw GoogleCalendarError.invalidDate
            }

            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            start = ["date": formatter.string(from: normalizedStartDate)]
            end = ["date": formatter.string(from: endExclusive)]
        } else {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            formatter.timeZone = .current
            start = [
                "dateTime": formatter.string(from: startDate),
                "timeZone": TimeZone.current.identifier
            ]
            end = [
                "dateTime": formatter.string(from: endDate),
                "timeZone": TimeZone.current.identifier
            ]
        }

        let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events")!
        let body: [String: Any] = [
            "summary": title,
            "start": start,
            "end": end
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let responseData = try await sendRequest(url: url, method: "POST", body: bodyData)
        guard let responseObject = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let identifier = responseObject["id"] as? String else {
            throw GoogleCalendarError.invalidResponse
        }

        return identifier
    }

    func createEvent(
        calendarID: String,
        title: String,
        yearMonth: YearMonth,
        day: Int,
        startMinutes: Int?,
        endMinutes: Int?
    ) async throws {
        let start: [String: Any]
        let end: [String: Any]
        if let startMinutes, let endMinutes {
            guard let startDate = date(yearMonth: yearMonth, day: day, minutes: startMinutes),
                  let endDate = date(yearMonth: yearMonth, day: day, minutes: endMinutes) else {
                throw GoogleCalendarError.invalidDate
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            formatter.timeZone = .current
            start = [
                "dateTime": formatter.string(from: startDate),
                "timeZone": TimeZone.current.identifier
            ]
            end = [
                "dateTime": formatter.string(from: endDate),
                "timeZone": TimeZone.current.identifier
            ]
        } else {
            guard let date = date(yearMonth: yearMonth, day: day, minutes: 0),
                  let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: date) else {
                throw GoogleCalendarError.invalidDate
            }

            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            start = ["date": formatter.string(from: date)]
            end = ["date": formatter.string(from: nextDay)]
        }

        let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events")!
        let body: [String: Any] = [
            "summary": title,
            "start": start,
            "end": end
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await sendRequest(url: url, method: "POST", body: bodyData)
    }

    func fetchEvents(
        yearMonth: YearMonth,
        calendarID: String,
        isReadOnly: Bool = false
    ) async throws -> [CalendarEventRecord] {
        guard let startDate = monthStart(yearMonth),
              let endDate = Calendar.current.date(byAdding: .month, value: 1, to: startDate) else {
            throw CalendarEventManagementError.invalidDate
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        // URLクエリ内の「+09:00」は一部のHTTPサーバーで空白として解釈されるため、UTCのZ形式で送る。
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID(calendarID))/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: startDate)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: endDate)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "showDeleted", value: "false"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "2500")
        ]

        let data = try await sendRequest(url: components.url!, method: "GET")
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = payload["items"] as? [[String: Any]] else {
            throw CalendarEventManagementError.invalidResponse
        }
        let calendarColor = try? await fetchCalendarColor(calendarID: calendarID)

        return items.compactMap { (item: [String: Any]) -> CalendarEventRecord? in
            guard let identifier = item["id"] as? String,
                  let start = item["start"] as? [String: Any] else {
                return nil
            }

            let title = (item["summary"] as? String)?.isEmpty == false
                ? (item["summary"] as? String ?? "")
                : "無題"
            if let dateText = start["date"] as? String,
               let day = Int(dateText.split(separator: "-").last ?? ""),
               let startDate = dateOnlyDate(from: dateText) {
                let endDate = ((item["end"] as? [String: Any])?["date"] as? String)
                    .flatMap { dateOnlyDate(from: $0) }
                return CalendarEventRecord(
                    id: identifier,
                    day: day,
                    title: title,
                    detail: "終日",
                    isAllDay: true,
                    startDate: startDate,
                    endDate: endDate.map { date in
                        Calendar.current.date(byAdding: .day, value: -1, to: date)
                    } ?? nil,
                    calendarColor: calendarColor ?? nil,
                    isReadOnly: isReadOnly
                )
            }

            guard let dateTimeText = start["dateTime"] as? String,
                  let dateTime = ISO8601DateFormatter().date(from: dateTimeText),
                  let day = Calendar.current.dateComponents([.day], from: dateTime).day else {
                return nil
            }

            let endText = (item["end"] as? [String: Any])?["dateTime"] as? String
            let endDate = endText.flatMap { ISO8601DateFormatter().date(from: $0) } ?? dateTime
            return CalendarEventRecord(
                id: identifier,
                day: day,
                title: title,
                detail: timeRangeText(start: dateTime, end: endDate),
                isAllDay: false,
                startDate: dateTime,
                endDate: endDate,
                calendarColor: calendarColor ?? nil,
                isReadOnly: isReadOnly
            )
        }
    }

    func fetchJapaneseHolidayEvents(yearMonth: YearMonth) async throws -> [CalendarEventRecord] {
        guard let calendarID = try await fetchJapaneseHolidayCalendarID() else {
            return []
        }

        return try await fetchEvents(
            yearMonth: yearMonth,
            calendarID: calendarID,
            isReadOnly: true
        )
    }

    func fetchCalendarColor(calendarID: String) async throws -> CalendarDisplayColor? {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList/\(encodedCalendarID(calendarID))")!
        let data = try await sendRequest(url: url, method: "GET")
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CalendarEventManagementError.invalidResponse
        }

        return (payload["backgroundColor"] as? String).flatMap(CalendarDisplayColor.init(hex:))
    }

    func deleteEvent(calendarID: String, eventID: String) async throws {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID(calendarID))/events/\(eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID)")!
        _ = try await sendRequest(url: url, method: "DELETE")
    }

    private func monthStart(_ yearMonth: YearMonth) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: yearMonth.year, month: yearMonth.month, day: 1))
    }

    private func encodedCalendarID(_ calendarID: String) -> String {
        calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
    }

    private func timeRangeText(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = .current
        formatter.dateFormat = "H:mm"
        return "\(formatter.string(from: start))-\(formatter.string(from: end))"
    }

    private func dateOnlyDate(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private func sendRequest(url: URL, method: String, body: Data? = nil) async throws -> Data {
        guard let storedTokens = GoogleTokenStore.load() else {
            throw GoogleCalendarError.notAuthenticated
        }

        var tokens = storedTokens
        if tokens.expiresAt.timeIntervalSinceNow < 60 {
            tokens = try await refresh(tokens: tokens)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleCalendarError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            let refreshedTokens = try await refresh(tokens: tokens)
            var retryRequest = request
            retryRequest.setValue("Bearer \(refreshedTokens.accessToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
            guard let retryHTTPResponse = retryResponse as? HTTPURLResponse else {
                throw GoogleCalendarError.invalidResponse
            }
            guard (200..<300).contains(retryHTTPResponse.statusCode) else {
                throw GoogleCalendarError.requestFailed(message: "HTTP \(retryHTTPResponse.statusCode): \(responseMessage(from: retryData))")
            }
            return retryData
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GoogleCalendarError.requestFailed(message: "HTTP \(httpResponse.statusCode): \(responseMessage(from: data))")
        }
        return data
    }

    private func refresh(tokens: GoogleOAuthTokens) async throws -> GoogleOAuthTokens {
        var request = URLRequest(url: GoogleOAuthClient.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        var queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "refresh_token", value: tokens.refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        if let clientSecret, !clientSecret.isEmpty {
            queryItems.append(URLQueryItem(name: "client_secret", value: clientSecret))
        }
        components.queryItems = queryItems
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleCalendarError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = payload["access_token"] as? String,
              let expiresIn = payload["expires_in"] as? Double else {
            throw GoogleCalendarError.requestFailed(message: "認証トークンを更新できませんでした (HTTP \(httpResponse.statusCode)): \(responseMessage(from: data))")
        }

        let refreshedTokens = GoogleOAuthTokens(
            accessToken: accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
        GoogleTokenStore.save(refreshedTokens)
        return refreshedTokens
    }

    private func date(yearMonth: YearMonth, day: Int, minutes: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: yearMonth.year,
                month: yearMonth.month,
                day: day,
                hour: minutes / 60,
                minute: minutes % 60
            )
        )
    }

    private func responseMessage(from data: Data) -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return body?.isEmpty == false ? body! : "不明なエラー"
        }

        if let error = payload["error"] as? [String: Any] {
            let code = error["status"] as? String
                ?? (error["code"] as? Int).map(String.init)
            let reason = error["reason"] as? String
                ?? (error["errors"] as? [[String: Any]])?.compactMap { $0["reason"] as? String }.first
            let message = error["message"] as? String
            let details = [code, reason, message]
                .compactMap { $0 }
            return details.isEmpty ? "不明なエラー" : details.joined(separator: ": ")
        }

        if let error = payload["error"] as? String {
            let description = payload["error_description"] as? String
            return [error, description]
                .compactMap { $0 }
                .joined(separator: ": ")
        }

        return payload["message"] as? String ?? "不明なエラー"
    }
}

private struct GoogleCalendarRegistrationResult {
    let savedCount: Int
    let skippedTitles: [String]
}

private struct GoogleCalendarEventWriter {
    let clientID: String

    func register(
        cells: [ExtractedShiftCell],
        yearMonth: YearMonth?,
        definitions: [ShiftDefinition],
        calendarID: String,
        restTitle: String,
        includeRest: Bool
    ) async throws -> GoogleCalendarRegistrationResult {
        guard let yearMonth else {
            throw GoogleCalendarError.missingYearMonth
        }

        let client = GoogleCalendarAPIClient(clientID: clientID)
        let definitionByTitle = Dictionary(
            uniqueKeysWithValues: definitions.map { (normalizedTitle($0.title), $0) }
        )
        let registeredRestTitle = restTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "休"
            : restTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var skippedTitles: [String] = []
        var savedCount = 0

        for cell in cells {
            guard let day = Int(cell.dateText), (1...yearMonth.numberOfDays).contains(day) else {
                continue
            }

            let title = normalizedTitle(cell.valueText)
            guard !title.isEmpty else { continue }

            if title == "休" {
                guard includeRest else { continue }
                try await client.createEvent(
                    calendarID: calendarID,
                    title: registeredRestTitle,
                    yearMonth: yearMonth,
                    day: day,
                    startMinutes: nil,
                    endMinutes: nil
                )
                savedCount += 1
                continue
            }

            guard let definition = definitionByTitle[title] else {
                if !skippedTitles.contains(title) {
                    skippedTitles.append(title)
                }
                continue
            }

            try await client.createEvent(
                calendarID: calendarID,
                title: title,
                yearMonth: yearMonth,
                day: day,
                startMinutes: definition.startMinutes,
                endMinutes: definition.endMinutes
            )
            savedCount += 1
        }

        return GoogleCalendarRegistrationResult(savedCount: savedCount, skippedTitles: skippedTitles)
    }

    private func normalizedTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "／", with: "/")
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum GoogleCalendarError: LocalizedError {
    case browserUnavailable
    case authorizationCancelled
    case invalidOAuthState
    case invalidResponse
    case requestFailed(message: String)
    case notAuthenticated
    case invalidDate
    case missingYearMonth

    var errorDescription: String? {
        switch self {
        case .browserUnavailable:
            return "Googleログイン画面を開けませんでした。"
        case .authorizationCancelled:
            return "Googleログインがキャンセルされました。"
        case .invalidOAuthState:
            return "Google認証の確認に失敗しました。もう一度ログインしてください。"
        case .invalidResponse:
            return "Googleから無効な応答が返されました。"
        case .requestFailed(let message):
            return "Google Calendar APIエラー: \(message)"
        case .notAuthenticated:
            return "先にGoogleへログインしてください。"
        case .invalidDate:
            return "イベントの日付を作成できませんでした。"
        case .missingYearMonth:
            return "勤務表の年月を取得できませんでした。"
        }
    }
}

private struct AppleCalendarOption: Identifiable, Hashable {
    let id: String
    let title: String
    let sourceTitle: String

    var displayName: String {
        sourceTitle.isEmpty ? title : "\(title)（\(sourceTitle)）"
    }

    func displayName(for locale: Locale) -> String {
        sourceTitle.isEmpty ? title : "\(title) (\(sourceTitle))"
    }
}

@MainActor
private final class AppleCalendarProvider: ObservableObject {
    @Published private(set) var calendars: [AppleCalendarOption] = []
    @Published private(set) var message = ""
    @Published private(set) var isLoading = false
    private var localeIdentifier = "ja"

    func setLocaleIdentifier(_ identifier: String) {
        localeIdentifier = identifier
    }

    private let eventStore = EKEventStore()

    var defaultCalendarName: String {
        eventStore.defaultCalendarForNewEvents?.title ?? ""
    }

    func loadCalendarsIfAuthorized() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        refreshCalendars()
    }

    func loadCalendars() {
        isLoading = true
        message = ""

        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            refreshCalendars()
        case .notDetermined:
            eventStore.requestFullAccessToEvents { [weak self] granted, error in
                let provider = self
                Task { @MainActor in
                    guard let provider else { return }
                    if granted {
                        provider.refreshCalendars()
                    } else {
                        provider.isLoading = false
                        provider.message = error.map {
                            ShiftHubLocalization.localizedErrorDescription(
                                $0,
                                locale: Locale(identifier: provider.localeIdentifier)
                            )
                        }
                            ?? ShiftHubLocalization.string(
                                "カレンダーへのアクセスが許可されませんでした。",
                                locale: Locale(identifier: provider.localeIdentifier)
                            )
                    }
                }
            }
        case .denied, .restricted, .writeOnly:
            isLoading = false
            message = ShiftHubLocalization.string(
                "カレンダーへのアクセスが許可されていません。システム設定でアクセスを許可してください。",
                locale: Locale(identifier: localeIdentifier)
            )
        @unknown default:
            isLoading = false
            message = ShiftHubLocalization.string(
                "カレンダーへのアクセス状態を確認できませんでした。",
                locale: Locale(identifier: localeIdentifier)
            )
        }
    }

    private func refreshCalendars() {
        calendars = eventStore
            .calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map { AppleCalendarOption(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source?.title ?? "") }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        isLoading = false

        if calendars.isEmpty {
            message = ShiftHubLocalization.string(
                "利用できるカレンダーが見つかりませんでした。",
                locale: Locale(identifier: localeIdentifier)
            )
        } else {
            message = ""
        }
    }
}

private struct AppleCalendarRegistrationResult {
    let savedCount: Int
    let skippedTitles: [String]
}

@MainActor
private final class AppleCalendarEventWriter {
    private let eventStore = EKEventStore()

    func register(
        cells: [ExtractedShiftCell],
        yearMonth: YearMonth?,
        definitions: [ShiftDefinition],
        calendarIdentifier: String,
        restTitle: String,
        includeRest: Bool
    ) throws -> AppleCalendarRegistrationResult {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw AppleCalendarRegistrationError.accessDenied
        }

        guard let yearMonth else {
            throw AppleCalendarRegistrationError.missingYearMonth
        }

        let calendar: EKCalendar?
        if calendarIdentifier.isEmpty {
            calendar = eventStore.defaultCalendarForNewEvents
        } else {
            calendar = eventStore.calendar(withIdentifier: calendarIdentifier)
        }

        guard let calendar, calendar.allowsContentModifications else {
            throw AppleCalendarRegistrationError.calendarNotFound
        }

        let definitionByTitle = Dictionary(
            uniqueKeysWithValues: definitions.map { (normalizedTitle($0.title), $0) }
        )
        let registeredRestTitle = restTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "休"
            : restTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var skippedTitles: [String] = []
        var savedCount = 0

        for cell in cells {
            let title = normalizedTitle(cell.valueText)
            guard !title.isEmpty else { continue }

            if title == "休" {
                guard includeRest else { continue }
                try saveAllDayEvent(title: registeredRestTitle, yearMonth: yearMonth, dayText: cell.dateText, calendar: calendar)
                savedCount += 1
                continue
            }

            guard let definition = definitionByTitle[title] else {
                if !skippedTitles.contains(title) {
                    skippedTitles.append(title)
                }
                continue
            }

            try saveTimedEvent(
                title: title,
                yearMonth: yearMonth,
                dayText: cell.dateText,
                startMinutes: definition.startMinutes,
                endMinutes: definition.endMinutes,
                calendar: calendar
            )
            savedCount += 1
        }

        if savedCount > 0 {
            try eventStore.commit()
        }

        return AppleCalendarRegistrationResult(savedCount: savedCount, skippedTitles: skippedTitles)
    }

    func registerDateTimeEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        calendarIdentifier: String
    ) throws -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw AppleCalendarRegistrationError.accessDenied
        }

        let calendar: EKCalendar?
        if calendarIdentifier.isEmpty {
            calendar = eventStore.defaultCalendarForNewEvents
        } else {
            calendar = eventStore.calendar(withIdentifier: calendarIdentifier)
        }

        guard let calendar, calendar.allowsContentModifications else {
            throw AppleCalendarRegistrationError.calendarNotFound
        }

        guard endDate >= startDate else {
            throw AppleCalendarRegistrationError.invalidDate("終了日時")
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.calendar = calendar
        event.isAllDay = isAllDay

        if isAllDay {
            let calendar = Calendar.current
            let normalizedStartDate = calendar.startOfDay(for: startDate)
            let normalizedEndDate = calendar.startOfDay(for: endDate)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: normalizedEndDate),
                  let inclusiveEndDate = calendar.date(byAdding: .second, value: -1, to: nextDay) else {
                throw AppleCalendarRegistrationError.invalidDate("終了日時")
            }
            event.startDate = normalizedStartDate
            event.endDate = inclusiveEndDate
        } else {
            event.startDate = startDate
            event.endDate = endDate
        }

        try eventStore.save(event, span: .thisEvent, commit: true)
        guard let identifier = event.eventIdentifier else {
            throw AppleCalendarRegistrationError.invalidResponse
        }

        return identifier
    }

    private func saveAllDayEvent(title: String, yearMonth: YearMonth, dayText: String, calendar: EKCalendar) throws {
        guard let eventDate = date(yearMonth: yearMonth, dayText: dayText, minutes: 0),
              let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: eventDate),
              let endDate = Calendar.current.date(byAdding: .second, value: -1, to: nextDay) else {
            throw AppleCalendarRegistrationError.invalidDate(dayText)
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.calendar = calendar
        event.isAllDay = true
        event.startDate = eventDate
        event.endDate = endDate
        try eventStore.save(event, span: .thisEvent, commit: false)
    }

    private func saveTimedEvent(
        title: String,
        yearMonth: YearMonth,
        dayText: String,
        startMinutes: Int,
        endMinutes: Int,
        calendar: EKCalendar
    ) throws {
        guard let startDate = date(yearMonth: yearMonth, dayText: dayText, minutes: startMinutes),
              let endDate = date(yearMonth: yearMonth, dayText: dayText, minutes: endMinutes) else {
            throw AppleCalendarRegistrationError.invalidDate(dayText)
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.calendar = calendar
        event.startDate = startDate
        event.endDate = endDate
        try eventStore.save(event, span: .thisEvent, commit: false)
    }

    private func date(yearMonth: YearMonth, dayText: String, minutes: Int) -> Date? {
        guard let day = Int(dayText) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: yearMonth.year,
                month: yearMonth.month,
                day: day,
                hour: minutes / 60,
                minute: minutes % 60
            )
        )
    }

    private func normalizedTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "／", with: "/")
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum AppleCalendarRegistrationError: LocalizedError {
    case accessDenied
    case calendarNotFound
    case missingYearMonth
    case invalidDate(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "カレンダーへのアクセスが許可されていません。カレンダー一覧を取得してください。"
        case .calendarNotFound:
            return "登録先のAppleカレンダーが見つからないか、書き込みできません。"
        case .missingYearMonth:
            return "勤務表の年月を取得できませんでした。"
        case .invalidDate(let day):
            return "日付を作成できませんでした: \(day)"
        case .invalidResponse:
            return "Appleカレンダーから無効な応答が返されました。"
        }
    }
}

private enum CalendarDestination: String, CaseIterable, Identifiable, Equatable {
    case apple
    case google
    case notion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple:
            return "Apple"
        case .google:
            return "Google"
        case .notion:
            return "Notion DB"
        }
    }

    var registrationTitleKey: LocalizedStringKey {
        switch self {
        case .apple:
            return "Appleカレンダーへ登録"
        case .google:
            return "Googleカレンダーへ登録"
        case .notion:
            return "Notion DBへ登録"
        }
    }
}

private enum KeychainStore {
    private static let service = "net.unwraps.Shift-Upload"

    static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        guard !value.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8)
        ]

        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

struct ShiftDefinitionRowView: View {
    @Binding var definition: ShiftDefinition
    let deleteAction: () -> Void

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
            TextField("タイトル", text: $definition.title)
                .textFieldStyle(.roundedBorder)
                .font(.callout)

            Text(definition.timeRangeText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

            TextField("タイトル", text: $definition.title)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

            Text(definition.timeRangeText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 90, alignment: .leading)

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

struct ShiftDefinition: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var startMinutes: Int
    var endMinutes: Int

    var timeRangeText: String {
        "\(Self.timeText(from: startMinutes))-\(Self.timeText(from: endMinutes))"
    }

    init(id: UUID = UUID(), title: String, startMinutes: Int, endMinutes: Int) {
        self.id = id
        self.title = title
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""

        if let startMinutes = try container.decodeIfPresent(Int.self, forKey: .startMinutes),
           let endMinutes = try container.decodeIfPresent(Int.self, forKey: .endMinutes) {
            self.startMinutes = startMinutes
            self.endMinutes = endMinutes
            return
        }

        let oldTimeRange = try container.decodeIfPresent(String.self, forKey: .timeRange) ?? ""
        let parsedMinutes = Self.minutes(from: oldTimeRange)
        startMinutes = parsedMinutes?.start ?? 510
        endMinutes = parsedMinutes?.end ?? 1000
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(startMinutes, forKey: .startMinutes)
        try container.encode(endMinutes, forKey: .endMinutes)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case timeRange
        case startMinutes
        case endMinutes
    }

    private static func timeText(from minutes: Int) -> String {
        let clampedMinutes = min(max(minutes, 0), 1_439)
        return String(format: "%d:%02d", clampedMinutes / 60, clampedMinutes % 60)
    }

    private static func minutes(from timeRange: String) -> (start: Int, end: Int)? {
        let parts = timeRange.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let start = minutes(fromTimeText: parts[0]),
              let end = minutes(fromTimeText: parts[1]) else {
            return nil
        }

        return (start, end)
    }

    private static func minutes(fromTimeText text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }

        return hour * 60 + minute
    }
}

struct YearMonth: Hashable {
    let year: Int
    let month: Int

    static var current: YearMonth {
        let components = Calendar.current.dateComponents([.year, .month], from: Date())
        return YearMonth(year: components.year ?? 2026, month: components.month ?? 1)
    }

    var displayText: String {
        "\(year)年\(month)月"
    }

    func displayText(for locale: Locale) -> String {
        guard locale.identifier.hasPrefix("en") else {
            return displayText
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
            return "\(year)-\(month)"
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    var nextMonth: YearMonth {
        addingMonths(1)
    }

    var previousMonth: YearMonth {
        addingMonths(-1)
    }

    func addingMonths(_ offset: Int) -> YearMonth {
        let absoluteMonth = year * 12 + (month - 1) + offset
        return YearMonth(
            year: absoluteMonth / 12,
            month: absoluteMonth % 12 + 1
        )
    }

    var leadingBlankCount: Int {
        guard let weekdayIndex = weekdayIndex(for: 1) else {
            return 0
        }

        return weekdayIndex - 1
    }

    func weekdayIndex(for day: Int) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }

        return calendar.component(.weekday, from: date)
    }

    var numberOfDays: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        guard let date = calendar.date(from: DateComponents(year: year, month: month)),
              let range = calendar.range(of: .day, in: .month, for: date) else {
            return 31
        }

        return range.count
    }
}

enum ShiftDisplayMode: String, CaseIterable, Identifiable {
    case calendar
    case timeline

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .timeline:
            return "横並び"
        case .calendar:
            return "カレンダー"
        }
    }

    var systemImage: String {
        switch self {
        case .timeline:
            return "rectangle"
        case .calendar:
            return "calendar"
        }
    }
}

struct RecognizedTextItem: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let boundingBox: CGRect
    let pageIndex: Int
    let rawPageText: String?

    var positionDescription: String {
        let x = String(format: "%.2f", boundingBox.midX)
        let y = String(format: "%.2f", boundingBox.midY)
        return "Page \(pageIndex + 1) / x \(x) / y \(y)"
    }
}

struct ExtractedShiftCell: Identifiable, Equatable {
    let id = UUID()
    let dateText: String
    let valueText: String
    let pageIndex: Int
    let boundingBox: CGRect
}

private struct ExtractedDayAction: Identifiable, Equatable {
    let day: Int

    var id: Int { day }
}

struct DateColumn: Equatable {
    let day: Int
    let centerX: CGFloat
    let pageIndex: Int
}

final class ShiftOCRAnalyzer {
    func yearMonth(from items: [RecognizedTextItem]) -> YearMonth? {
        for item in items {
            if let yearMonth = yearMonth(from: item.rawPageText ?? item.text) {
                return yearMonth
            }
        }

        return nil
    }

    func recognizeText(in url: URL) async throws -> [RecognizedTextItem] {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard url.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame else {
            throw ShiftOCRAnalyzerError.unsupportedFile
        }

        guard let document = PDFDocument(url: url) else {
            throw ShiftOCRAnalyzerError.unreadableFile
        }

        let textLayerItems = textLayerItems(from: document)
        guard !textLayerItems.isEmpty else {
            throw ShiftOCRAnalyzerError.missingTextLayer
        }
        guard Self.supportsHorizontalTextLayout(document) else {
            throw ShiftOCRAnalyzerError.unsupportedLayout
        }

        return sortedItems(textLayerItems)
    }

    static func supportsHorizontalTextLayout(_ document: PDFDocument) -> Bool {
        guard document.pageCount > 0 else { return false }

        return (0..<document.pageCount).allSatisfy { pageIndex in
            guard let page = document.page(at: pageIndex) else {
                return false
            }

            let dateTokens = dateSequence(in: textLayerTokens(from: page))
            guard dateTokens.count >= 20 else {
                return false
            }

            let xValues = dateTokens.map { $0.bounds.midX }
            let yValues = dateTokens.map { $0.bounds.midY }
            guard let minX = xValues.min(), let maxX = xValues.max(),
                  let minY = yValues.min(), let maxY = yValues.max() else {
                return false
            }

            let xSpan = maxX - minX
            let ySpan = maxY - minY
            let increasingXCount = zip(dateTokens.dropFirst(), dateTokens).filter { current, previous in
                current.bounds.midX > previous.bounds.midX
            }.count

            return xSpan > ySpan * 2 && increasingXCount >= dateTokens.count - 2
        }
    }

    private struct TextLayerToken {
        let text: String
        let bounds: CGRect
    }

    private static func textLayerTokens(from page: PDFPage) -> [TextLayerToken] {
        guard let pageText = page.string else {
            return []
        }

        let text = pageText as NSString
        var tokens: [TextLayerToken] = []
        var tokenText = ""
        var tokenBounds = CGRect.null

        func appendToken() {
            let trimmedText = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty, !tokenBounds.isNull, tokenBounds.width > 0, tokenBounds.height > 0 else {
                tokenText = ""
                tokenBounds = .null
                return
            }

            tokens.append(TextLayerToken(text: trimmedText, bounds: tokenBounds))
            tokenText = ""
            tokenBounds = .null
        }

        for index in 0..<min(page.numberOfCharacters, text.length) {
            let character = text.substring(with: NSRange(location: index, length: 1))
            if character.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                appendToken()
                continue
            }

            let bounds = page.characterBounds(at: index)
            tokenText.append(character)
            tokenBounds = tokenBounds.isNull ? bounds : tokenBounds.union(bounds)
        }
        appendToken()

        return tokens
    }

    private static func dateSequence(in tokens: [TextLayerToken]) -> [TextLayerToken] {
        var bestSequence: [TextLayerToken] = []

        for startIndex in tokens.indices {
            guard normalizedText(tokens[startIndex].text) == "1" else {
                continue
            }

            var expectedDay = 1
            var sequence: [TextLayerToken] = []
            for token in tokens[startIndex...] {
                guard normalizedText(token.text) == String(expectedDay) else {
                    continue
                }

                sequence.append(token)
                expectedDay += 1
                if expectedDay > 31 {
                    break
                }
            }

            if sequence.count > bestSequence.count {
                bestSequence = sequence
            }
        }

        return bestSequence
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sortedItems(_ items: [RecognizedTextItem]) -> [RecognizedTextItem] {
        items.sorted { lhs, rhs in
            if lhs.pageIndex != rhs.pageIndex {
                return lhs.pageIndex < rhs.pageIndex
            }
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.02 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
    }

    func extractRowItems(matching name: String, from items: [RecognizedTextItem], yearMonth: YearMonth?) -> [ExtractedShiftCell] {
        let normalizedName = normalize(name)
        guard !normalizedName.isEmpty else { return [] }

        return directTextCells(matching: normalizedName, from: items, yearMonth: yearMonth) ?? []
    }

    private func fallbackCells(from rowItems: [RecognizedTextItem], excludingNameBounds nameBounds: CGRect?) -> [ExtractedShiftCell] {
        shiftValueItems(in: rowItems, excludingNameBounds: nameBounds)
            .map { item in
                ExtractedShiftCell(
                    dateText: "",
                    valueText: normalizedShiftText(item.text),
                    pageIndex: item.pageIndex,
                    boundingBox: item.boundingBox
                )
            }
    }

    private func directTextCells(matching normalizedName: String, from items: [RecognizedTextItem], yearMonth: YearMonth?) -> [ExtractedShiftCell]? {
        let dayCount = yearMonth?.numberOfDays ?? 31

        for item in items where item.rawPageText != nil {
            guard let rawPageText = item.rawPageText else { continue }
            let tokens = rawPageText.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let valueStartIndex = indexAfterName(in: tokens, matching: normalizedName) else {
                continue
            }

            let values = shiftValues(from: Array(tokens[valueStartIndex...]), dayCount: dayCount)
            guard !values.isEmpty else { continue }
            let adjustedValues = adjustedWrappedRestSuffixes(in: values)

            return (1...dayCount).map { day in
                ExtractedShiftCell(
                    dateText: String(day),
                    valueText: day <= adjustedValues.count ? normalizedShiftText(adjustedValues[day - 1]) : "",
                    pageIndex: item.pageIndex,
                    boundingBox: CGRect(x: CGFloat(day) / CGFloat(max(dayCount, 1)), y: 0, width: 0, height: 0)
                )
            }
        }

        return nil
    }

    private func indexAfterName(in tokens: [String], matching normalizedName: String) -> Int? {
        // まずは、スペースで分かれたフルネームを優先して探す。
        for startIndex in tokens.indices {
            var combinedText = ""

            for endIndex in startIndex..<min(tokens.count, startIndex + 5) {
                combinedText += normalize(tokens[endIndex])

                if combinedText == normalizedName {
                    return tokens.index(after: endIndex)
                }

                if !normalizedName.hasPrefix(combinedText) {
                    break
                }
            }
        }

        // PDFのテキスト層では、スペースのないフルネームが1トークンに
        // まとまることがある。名字だけ入力された場合も、そのトークン
        // 全体を名前として消費して、直後から勤務値を読み取る。
        for (index, token) in tokens.enumerated() {
            let normalizedToken = normalize(token)
            if normalizedToken != normalizedName,
               normalizedToken.hasPrefix(normalizedName) {
                return tokens.index(after: index)
            }
        }

        return nil
    }

    private func shiftValues(from tokens: [String], dayCount: Int) -> [String] {
        var values: [String] = []

        for rawToken in tokens {
            for token in splitYearSuffixes(in: rawToken) {
                let normalizedToken = normalizedShiftText(token)
                guard !normalizedToken.isEmpty else { continue }

                if values.count >= dayCount || isSummaryToken(normalizedToken) {
                    return values
                }

                if values.last?.hasSuffix("/") == true {
                    values[values.count - 1] += normalizedToken
                    continue
                }

                if isContinuationToken(normalizedToken), !values.isEmpty {
                    values[values.count - 1] += normalizedToken
                    continue
                }

                guard isShiftValueStart(normalizedToken) else {
                    continue
                }

                values.append(normalizedToken)
            }
        }

        return values
    }

    private func splitYearSuffixes(in token: String) -> [String] {
        let normalizedToken = normalizedShiftText(token)
        guard normalizedToken.contains("年") else { return [normalizedToken] }

        var parts: [String] = []
        var current = ""

        for character in normalizedToken {
            if character == "年" {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
                parts.append("年")
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            parts.append(current)
        }

        return parts
    }

    private func adjustedWrappedRestSuffixes(in values: [String]) -> [String] {
        var adjustedValues = values

        for index in adjustedValues.indices.dropLast() {
            guard adjustedValues[index].hasSuffix("/休") else {
                continue
            }

            let baseValue = String(adjustedValues[index].dropLast(2))
            if !baseValue.isEmpty, adjustedValues[index + 1] == baseValue {
                adjustedValues[index] = baseValue
                adjustedValues[index + 1] = "\(baseValue)/休"
            }
        }

        return adjustedValues
    }

    private func isSummaryToken(_ token: String) -> Bool {
        token.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil
    }

    private func isContinuationToken(_ token: String) -> Bool {
        token.hasPrefix("/") || !isShiftValueStart(token)
    }

    private func isShiftValueStart(_ token: String) -> Bool {
        token.range(of: #"[休年△□①②③④⑤⑥⑦⑧⑨]|\d|\*"#, options: .regularExpression) != nil
    }

    private func yearMonth(from text: String) -> YearMonth? {
        let patterns = [
            #"(\d{4})\s*/\s*(\d{1,2})"#,
            #"(\d{4})\s*年\s*(\d{1,2})\s*月"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges >= 3,
                  let yearRange = Range(match.range(at: 1), in: text),
                  let monthRange = Range(match.range(at: 2), in: text),
                  let year = Int(text[yearRange]),
                  let month = Int(text[monthRange]),
                  (1...12).contains(month) else {
                continue
            }

            return YearMonth(year: year, month: month)
        }

        return nil
    }

    private func rowGroups(from items: [RecognizedTextItem]) -> [[RecognizedTextItem]] {
        let sortedItems = items.sorted {
            if $0.pageIndex != $1.pageIndex {
                return $0.pageIndex < $1.pageIndex
            }
            return $0.boundingBox.midY > $1.boundingBox.midY
        }

        return sortedItems.reduce(into: [[RecognizedTextItem]]()) { rows, item in
            let tolerance = max(item.boundingBox.height * 1.35, 0.013)
            if let index = rows.firstIndex(where: { row in
                guard let firstItem = row.first else { return false }
                return firstItem.pageIndex == item.pageIndex
                    && abs(firstItem.boundingBox.midY - item.boundingBox.midY) <= tolerance
            }) {
                rows[index].append(item)
            } else {
                rows.append([item])
            }
        }
    }

    private func nameBounds(in rowItems: [RecognizedTextItem], matching normalizedName: String) -> CGRect? {
        var combinedText = ""
        var nameItems: [RecognizedTextItem] = []

        for item in rowItems {
            let itemText = normalize(item.text)
            guard !itemText.isEmpty else { continue }

            if normalizedName.hasPrefix(combinedText + itemText) {
                combinedText += itemText
                nameItems.append(item)

                if combinedText == normalizedName {
                    return unionBounds(of: nameItems)
                }
            } else if normalizedName.hasPrefix(itemText) {
                combinedText = itemText
                nameItems = [item]
            } else {
                combinedText = ""
                nameItems = []
            }
        }

        return rowItems.first { item in
            normalize(item.text).contains(normalizedName)
        }?.boundingBox
    }

    private func logicalRowItems(
        containing targetRow: [RecognizedTextItem],
        nameBounds: CGRect?,
        from items: [RecognizedTextItem]
    ) -> [RecognizedTextItem] {
        guard let targetItem = targetRow.first,
              let targetNameBounds = nameBounds else {
            return targetRow.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        }

        let rows = rowGroups(from: items).filter { row in
            row.first?.pageIndex == targetItem.pageIndex
        }
        let targetCenterY = targetNameBounds.midY
        let targetNameX = targetNameBounds.minX
        let anchorTolerance = max(targetNameBounds.width * 0.75, 0.012)
        let nameAnchors = rows.filter { row in
            guard let leftmostItem = row.min(by: { $0.boundingBox.minX < $1.boundingBox.minX }) else {
                return false
            }

            return abs(leftmostItem.boundingBox.minX - targetNameX) <= anchorTolerance
        }

        let nearestAbove = nameAnchors
            .map { $0.map(\.boundingBox.midY).reduce(0, +) / CGFloat($0.count) }
            .filter { $0 > targetCenterY }
            .min()
        let nearestBelow = nameAnchors
            .map { $0.map(\.boundingBox.midY).reduce(0, +) / CGFloat($0.count) }
            .filter { $0 < targetCenterY }
            .max()

        let upperBound = nearestAbove.map { (targetCenterY + $0) / 2 } ?? .greatestFiniteMagnitude
        let lowerBound = nearestBelow.map { (targetCenterY + $0) / 2 } ?? -.greatestFiniteMagnitude

        let mergedItems = rows
            .filter { row in
                let rowCenterY = row.map(\.boundingBox.midY).reduce(0, +) / CGFloat(row.count)
                return rowCenterY <= upperBound && rowCenterY >= lowerBound
            }
            .flatMap { $0 }

        return (mergedItems.isEmpty ? targetRow : mergedItems)
            .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
    }

    private func refinedRowItems(around nameBounds: CGRect?, from items: [RecognizedTextItem], fallback: [RecognizedTextItem]) -> [RecognizedTextItem] {
        guard let nameBounds, let pageIndex = fallback.first?.pageIndex else {
            return fallback
        }

        let rowCenterY = nameBounds.midY
        let tolerance = max(nameBounds.height * 3.0, 0.024)
        let rowItems = items.filter { item in
            item.pageIndex == pageIndex
                && abs(item.boundingBox.midY - rowCenterY) <= tolerance
        }

        return rowItems.isEmpty ? fallback : rowItems.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
    }

    private func shiftValueItems(in rowItems: [RecognizedTextItem], excludingNameBounds nameBounds: CGRect?) -> [RecognizedTextItem] {
        rowItems.filter { item in
            let trimmedText = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return false }

            if let nameBounds {
                return item.boundingBox.minX > nameBounds.maxX
            }

            return true
        }
    }

    private func dateHeaderItems(above rowItems: [RecognizedTextItem], from items: [RecognizedTextItem]) -> [RecognizedTextItem] {
        guard let firstRowItem = rowItems.first else { return [] }
        let dateCandidates = items.filter { item in
            item.pageIndex == firstRowItem.pageIndex
                && item.boundingBox.midY > firstRowItem.boundingBox.midY
                && dateNumber(from: item.text) != nil
        }

        guard !dateCandidates.isEmpty else { return [] }

        let rows = rowGroups(from: dateCandidates)
        return rows
            .max { lhs, rhs in lhs.count < rhs.count }?
            .sorted { $0.boundingBox.minX < $1.boundingBox.minX } ?? []
    }

    private func inferredDateColumns(above rowItems: [RecognizedTextItem], from items: [RecognizedTextItem], dayCount: Int) -> [DateColumn] {
        let headerItems = dateHeaderItems(above: rowItems, from: items)
        let knownColumns = headerItems.compactMap { item -> DateColumn? in
            guard let day = dateNumber(from: item.text), (1...dayCount).contains(day) else {
                return nil
            }

            return DateColumn(day: day, centerX: item.boundingBox.midX, pageIndex: item.pageIndex)
        }

        guard !knownColumns.isEmpty else { return [] }

        if let first = knownColumns.first(where: { $0.day == 1 }),
           let last = knownColumns.first(where: { $0.day == dayCount }),
           first.centerX < last.centerX {
            let step = (last.centerX - first.centerX) / CGFloat(dayCount - 1)
            return (1...dayCount).map { day in
                DateColumn(day: day, centerX: first.centerX + CGFloat(day - 1) * step, pageIndex: first.pageIndex)
            }
        }

        let step = estimatedDateColumnStep(from: knownColumns)
        guard step > 0 else {
            return knownColumns.sorted { $0.day < $1.day }
        }

        let anchor = knownColumns.sorted { $0.day < $1.day }[knownColumns.count / 2]
        return (1...dayCount).map { day in
            DateColumn(day: day, centerX: anchor.centerX + CGFloat(day - anchor.day) * step, pageIndex: anchor.pageIndex)
        }
    }

    private func estimatedDateColumnStep(from columns: [DateColumn]) -> CGFloat {
        let sortedColumns = columns.sorted { $0.day < $1.day }
        let steps = zip(sortedColumns.dropFirst(), sortedColumns).compactMap { current, previous -> CGFloat? in
            let dayDistance = current.day - previous.day
            guard dayDistance > 0 else { return nil }

            return (current.centerX - previous.centerX) / CGFloat(dayDistance)
        }
        .filter { $0 > 0 }
        .sorted()

        guard !steps.isEmpty else { return 0 }
        return steps[steps.count / 2]
    }

    private func dateColumnRange(from columns: [DateColumn]) -> ClosedRange<CGFloat> {
        let centers = columns.map(\.centerX).sorted()
        guard centers.count >= 2 else {
            let center = centers.first ?? 0
            return (center - 0.03)...(center + 0.03)
        }

        let averageStep = zip(centers.dropFirst(), centers).map(-).reduce(0, +) / CGFloat(centers.count - 1)
        let padding = max(averageStep * 0.55, 0.02)
        return (centers[0] - padding)...(centers[centers.count - 1] + padding)
    }

    private func nearestDateColumn(for item: RecognizedTextItem, in columns: [DateColumn]) -> DateColumn? {
        columns.min { lhs, rhs in
            abs(lhs.centerX - item.boundingBox.midX) < abs(rhs.centerX - item.boundingBox.midX)
        }
    }

    private func pageImages(from url: URL) throws -> [(index: Int, image: CGImage)] {
        if url.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame {
            guard let document = PDFDocument(url: url) else {
                throw ShiftOCRAnalyzerError.unreadableFile
            }

            return try (0..<document.pageCount).map { pageIndex in
                guard let page = document.page(at: pageIndex) else {
                    throw ShiftOCRAnalyzerError.unreadableFile
                }

                let pageBounds = page.bounds(for: .mediaBox)
                let targetWidth: CGFloat = 2400
                let scale = max(targetWidth / max(pageBounds.width, 1), 1)
                let imageSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
                let image = page.thumbnail(of: imageSize, for: .mediaBox)

                guard let cgImage = image.cgImageForOCR else {
                    throw ShiftOCRAnalyzerError.unreadableFile
                }

                return (pageIndex, cgImage)
            }
        }

        guard let cgImage = CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }),
              let normalizedImage = normalizedImageForOCR(cgImage) else {
            throw ShiftOCRAnalyzerError.unreadableFile
        }

        return [(0, normalizedImage)]
    }

    private func textLayerItems(from document: PDFDocument) -> [RecognizedTextItem] {
        (0..<document.pageCount).flatMap { pageIndex -> [RecognizedTextItem] in
            guard let page = document.page(at: pageIndex),
                  let pageText = page.string,
                  !pageText.isEmpty else {
                return []
            }

            return [
                RecognizedTextItem(
                    text: pageText,
                    boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                    pageIndex: pageIndex,
                    rawPageText: pageText
                )
            ]
        }
    }

    private func recognizeText(in image: CGImage, pageIndex: Int) throws -> [RecognizedTextItem] {
        let regions = recognitionRegions(for: image)
        let items = try regions.flatMap { region in
            try recognizeText(in: image, pageIndex: pageIndex, regionOfInterest: region)
        }

        return deduplicatedItems(items)
    }

    private func recognizeText(
        in image: CGImage,
        pageIndex: Int,
        regionOfInterest: CGRect
    ) throws -> [RecognizedTextItem] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.002
        request.regionOfInterest = regionOfInterest

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else {
                return nil
            }

            return RecognizedTextItem(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                boundingBox: observation.boundingBox,
                pageIndex: pageIndex,
                rawPageText: nil
            )
        }
        .filter { !$0.text.isEmpty }
    }

    private func recognitionRegions(for image: CGImage) -> [CGRect] {
        // 表の高さは月ごとに変わるため、画像全体を相対的な帯に分けてOCRする。
        let bandCount = max(6, min(10, Int(ceil(Double(image.height) / Double(max(image.width, 1)) * 12))))
        let bandHeight = 1 / CGFloat(bandCount)
        let overlap = bandHeight * 0.2

        return (0..<bandCount).map { index in
            let minY = max(0, CGFloat(index) * bandHeight - overlap)
            let maxY = min(1, CGFloat(index + 1) * bandHeight + overlap)
            return CGRect(x: 0, y: minY, width: 1, height: maxY - minY)
        }
    }

    private func deduplicatedItems(_ items: [RecognizedTextItem]) -> [RecognizedTextItem] {
        var result: [RecognizedTextItem] = []

        for item in items {
            guard let duplicateIndex = result.firstIndex(where: { existing in
                existing.pageIndex == item.pageIndex
                    && existing.boundingBox.intersection(item.boundingBox).isNull == false
                    && rectArea(existing.boundingBox.intersection(item.boundingBox))
                        >= min(rectArea(existing.boundingBox), rectArea(item.boundingBox)) * 0.45
            }) else {
                result.append(item)
                continue
            }

            if item.text.count > result[duplicateIndex].text.count {
                result[duplicateIndex] = item
            }
        }

        return result
    }

    private func rectArea(_ rect: CGRect) -> CGFloat {
        max(0, rect.width) * max(0, rect.height)
    }

    private func normalizedImageForOCR(_ image: CGImage) -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        // JPG/PNGの色空間やアルファ有無によるVision OCRの結果差を抑える。
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: imageSize))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: imageSize))
        return context.makeImage()
    }

    private func nearestDateHeaderText(for item: RecognizedTextItem, in headers: [RecognizedTextItem]) -> String {
        headers
            .min { lhs, rhs in
                abs(lhs.boundingBox.midX - item.boundingBox.midX) < abs(rhs.boundingBox.midX - item.boundingBox.midX)
            }?
            .text ?? ""
    }

    private func dateNumber(from text: String) -> Int? {
        let normalized = normalize(text)
        guard let value = Int(normalized), (1...31).contains(value) else {
            return nil
        }

        return value
    }

    private func normalizedShiftText(_ text: String) -> String {
        var normalized = text
            .replacingOccurrences(of: "体", with: "休")
            .replacingOccurrences(of: "口", with: "□")
            .replacingOccurrences(of: "ロ", with: "□")
            .replacingOccurrences(of: "A", with: "△")
            .replacingOccurrences(of: "▲", with: "△")
            .replacingOccurrences(of: "*", with: "")

        if normalized == "祝" {
            normalized = ""
        }

        return normalized
    }

    private func unionBounds(of items: [RecognizedTextItem]) -> CGRect? {
        items.map(\.boundingBox).reduce(nil) { result, rect in
            result?.union(rect) ?? rect
        }
    }

    private func normalize(_ text: String) -> String {
        text
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ShiftOCRAnalyzerError: LocalizedError {
    case unsupportedFile
    case missingTextLayer
    case unsupportedLayout
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "PDFのみ対応しています"
        case .missingTextLayer:
            return "文字データを持つPDFではありません"
        case .unsupportedLayout:
            return "横型のPDFのみ対応しています"
        case .unreadableFile:
            return "PDFファイルを開けませんでした。"
        }
    }
}
