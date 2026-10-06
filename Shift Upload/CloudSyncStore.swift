import Foundation
import CloudKit
import CryptoKit

struct PDFTextConversionRule: Codable, Equatable, Identifiable {
    static let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var id: UUID
    var source: String
    var appleDestination: String
    var googleDestination: String
    var notionDestination: String

    init(
        id: UUID = UUID(),
        source: String = "",
        appleDestination: String = "",
        googleDestination: String = "",
        notionDestination: String = ""
    ) {
        self.id = id
        self.source = source
        self.appleDestination = appleDestination
        self.googleDestination = googleDestination
        self.notionDestination = notionDestination
    }

    func destination(for calendar: CalendarDestination) -> String {
        switch calendar {
        case .apple:
            return appleDestination
        case .google:
            return googleDestination
        case .notion:
            return notionDestination
        }
    }
}

struct ShiftHubCloudSettings: Codable, Equatable {
    var appLanguage: String
    var workerName: String
    var shiftDefinitionsJSON: String
    var calendarDestination: String
    var appleCalendarIdentifier: String
    var restEventSourceTitle: String
    var appleRestEventTitle: String
    var calendarTitleColorRulesJSON: String
    var appleNotesEnabled: Bool
    var appleLocationEnabled: Bool
    var appleURLEnabled: Bool
    var googleCalendarClientID: String
    var googleCalendarID: String
    var googleRestEventTitle: String
    var googleShowJapaneseHolidays: Bool
    var googleNotesEnabled: Bool
    var googleLocationEnabled: Bool
    var googleURLEnabled: Bool
    var notionDataSourceID: String
    var notionDatabaseName: String
    var notionTitleProperty: String
    var notionDateProperty: String
    var notionTagProperty: String
    var notionTagValue: String
    var notionNotesProperty: String
    var notionLocationProperty: String
    var notionURLProperty: String
    var notionMetadataMappingVersion: Int
    var notionFetchedPropertiesJSON: String
    var notionEnabledPropertyNamesJSON: String
    var notionDefaultPropertyValuesJSON: String
    var notionRestEventTitle: String

    init(
        appLanguage: String,
        workerName: String,
        shiftDefinitionsJSON: String,
        calendarDestination: String,
        appleCalendarIdentifier: String,
        appleRestEventTitle: String,
        googleCalendarClientID: String,
        googleCalendarID: String,
        googleRestEventTitle: String,
        googleShowJapaneseHolidays: Bool = false,
        notionDataSourceID: String,
        notionDatabaseName: String = "",
        notionTitleProperty: String,
        notionDateProperty: String,
        notionTagProperty: String,
        notionTagValue: String,
        notionNotesProperty: String = "",
        notionLocationProperty: String = "",
        notionURLProperty: String = "",
        notionRestEventTitle: String,
        restEventSourceTitle: String = "",
        notionMetadataMappingVersion: Int = 0,
        notionFetchedPropertiesJSON: String = "",
        notionEnabledPropertyNamesJSON: String = "",
        notionDefaultPropertyValuesJSON: String = "",
        appleNotesEnabled: Bool = true,
        appleLocationEnabled: Bool = true,
        appleURLEnabled: Bool = true,
        googleNotesEnabled: Bool = true,
        googleLocationEnabled: Bool = true,
        googleURLEnabled: Bool = true,
        calendarTitleColorRulesJSON: String = "[]"
    ) {
        self.appLanguage = appLanguage
        self.workerName = workerName
        self.shiftDefinitionsJSON = shiftDefinitionsJSON
        self.calendarDestination = calendarDestination
        self.appleCalendarIdentifier = appleCalendarIdentifier
        self.restEventSourceTitle = restEventSourceTitle
        self.appleRestEventTitle = appleRestEventTitle
        self.calendarTitleColorRulesJSON = calendarTitleColorRulesJSON
        self.appleNotesEnabled = appleNotesEnabled
        self.appleLocationEnabled = appleLocationEnabled
        self.appleURLEnabled = appleURLEnabled
        self.googleCalendarClientID = googleCalendarClientID
        self.googleCalendarID = googleCalendarID
        self.googleRestEventTitle = googleRestEventTitle
        self.googleShowJapaneseHolidays = googleShowJapaneseHolidays
        self.googleNotesEnabled = googleNotesEnabled
        self.googleLocationEnabled = googleLocationEnabled
        self.googleURLEnabled = googleURLEnabled
        self.notionDataSourceID = notionDataSourceID
        self.notionDatabaseName = notionDatabaseName
        self.notionTitleProperty = notionTitleProperty
        self.notionDateProperty = notionDateProperty
        self.notionTagProperty = notionTagProperty
        self.notionTagValue = notionTagValue
        self.notionNotesProperty = notionNotesProperty
        self.notionLocationProperty = notionLocationProperty
        self.notionURLProperty = notionURLProperty
        self.notionMetadataMappingVersion = notionMetadataMappingVersion
        self.notionFetchedPropertiesJSON = notionFetchedPropertiesJSON
        self.notionEnabledPropertyNamesJSON = notionEnabledPropertyNamesJSON
        self.notionDefaultPropertyValuesJSON = notionDefaultPropertyValuesJSON
        self.notionRestEventTitle = notionRestEventTitle
    }

    private enum CodingKeys: String, CodingKey {
        case appLanguage, workerName, shiftDefinitionsJSON, calendarDestination
        case appleCalendarIdentifier, restEventSourceTitle, appleRestEventTitle
        case calendarTitleColorRulesJSON
        case appleNotesEnabled, appleLocationEnabled, appleURLEnabled, googleCalendarClientID
        case googleCalendarID, googleRestEventTitle, googleShowJapaneseHolidays
        case googleNotesEnabled, googleLocationEnabled, googleURLEnabled
        case notionDataSourceID, notionDatabaseName
        case notionTitleProperty, notionDateProperty, notionTagProperty, notionTagValue
        case notionNotesProperty, notionLocationProperty, notionURLProperty
        case notionMetadataMappingVersion, notionFetchedPropertiesJSON
        case notionEnabledPropertyNamesJSON, notionDefaultPropertyValuesJSON
        case notionRestEventTitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            appLanguage: try container.decode(String.self, forKey: .appLanguage),
            workerName: try container.decode(String.self, forKey: .workerName),
            shiftDefinitionsJSON: try container.decode(String.self, forKey: .shiftDefinitionsJSON),
            calendarDestination: try container.decode(String.self, forKey: .calendarDestination),
            appleCalendarIdentifier: try container.decode(String.self, forKey: .appleCalendarIdentifier),
            appleRestEventTitle: try container.decode(String.self, forKey: .appleRestEventTitle),
            googleCalendarClientID: try container.decode(String.self, forKey: .googleCalendarClientID),
            googleCalendarID: try container.decode(String.self, forKey: .googleCalendarID),
            googleRestEventTitle: try container.decode(String.self, forKey: .googleRestEventTitle),
            googleShowJapaneseHolidays: try container.decodeIfPresent(Bool.self, forKey: .googleShowJapaneseHolidays) ?? false,
            notionDataSourceID: try container.decode(String.self, forKey: .notionDataSourceID),
            notionDatabaseName: try container.decodeIfPresent(String.self, forKey: .notionDatabaseName) ?? "",
            notionTitleProperty: try container.decode(String.self, forKey: .notionTitleProperty),
            notionDateProperty: try container.decode(String.self, forKey: .notionDateProperty),
            notionTagProperty: try container.decode(String.self, forKey: .notionTagProperty),
            notionTagValue: try container.decode(String.self, forKey: .notionTagValue),
            notionNotesProperty: try container.decodeIfPresent(String.self, forKey: .notionNotesProperty) ?? "",
            notionLocationProperty: try container.decodeIfPresent(String.self, forKey: .notionLocationProperty) ?? "",
            notionURLProperty: try container.decodeIfPresent(String.self, forKey: .notionURLProperty) ?? "",
            notionRestEventTitle: try container.decode(String.self, forKey: .notionRestEventTitle),
            restEventSourceTitle: try container.decodeIfPresent(String.self, forKey: .restEventSourceTitle) ?? "",
            notionMetadataMappingVersion: try container.decodeIfPresent(Int.self, forKey: .notionMetadataMappingVersion) ?? 0,
            notionFetchedPropertiesJSON: try container.decodeIfPresent(String.self, forKey: .notionFetchedPropertiesJSON) ?? "",
            notionEnabledPropertyNamesJSON: try container.decodeIfPresent(String.self, forKey: .notionEnabledPropertyNamesJSON) ?? "",
            notionDefaultPropertyValuesJSON: try container.decodeIfPresent(String.self, forKey: .notionDefaultPropertyValuesJSON) ?? "",
            appleNotesEnabled: try container.decodeIfPresent(Bool.self, forKey: .appleNotesEnabled) ?? true,
            appleLocationEnabled: try container.decodeIfPresent(Bool.self, forKey: .appleLocationEnabled) ?? true,
            appleURLEnabled: try container.decodeIfPresent(Bool.self, forKey: .appleURLEnabled) ?? true,
            googleNotesEnabled: try container.decodeIfPresent(Bool.self, forKey: .googleNotesEnabled) ?? true,
            googleLocationEnabled: try container.decodeIfPresent(Bool.self, forKey: .googleLocationEnabled) ?? true,
            googleURLEnabled: try container.decodeIfPresent(Bool.self, forKey: .googleURLEnabled) ?? true,
            calendarTitleColorRulesJSON: try container.decodeIfPresent(String.self, forKey: .calendarTitleColorRulesJSON) ?? "[]"
        )
    }
}

enum ShiftHubSettingsChangeScope: String, CaseIterable {
    case eventDefinitions
    case colorRules
    case general
}

@MainActor
private final class ShiftHubCloudSettingsSaveQueue {
    static let shared = ShiftHubCloudSettingsSaveQueue()

    private var generation = 0
    private var worker: Task<Void, Never>?

    func requestSave() {
        generation += 1
        guard worker == nil else { return }
        worker = Task { await saveAfterQuietPeriod() }
    }

    func flush() async {
        if let worker {
            await worker.value
        }
    }

    private func saveAfterQuietPeriod() async {
        while true {
            let requestedGeneration = generation
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard requestedGeneration == generation else { continue }

            guard let settings = ShiftHubCloudSync.loadSettings() else {
                worker = nil
                return
            }

            await ShiftHubCloudSync.saveSettingsToCloudKit(settings)
            guard requestedGeneration == generation else { continue }
            worker = nil
            return
        }
    }
}

enum ShiftHubCloudSync {
    static let containerIdentifier = "iCloud.net.unwraps.Shift-Hub"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "iCloudSyncEnabled") as? Bool ?? true
    }

    static let settingsKey = "shiftHub.settings.v1"
    static let schedulesKey = "shiftHub.schedules.v1"
    private static let settingsRecordType = "ShiftHubSettings"
    private static let scheduleRecordType = "ShiftHubSchedule"
    private static let settingsRecordName = "settings"
    private static let settingsPayloadField = "payload"
    private static let settingsSubscriptionID = "ShiftHubSettings.settings.v1"
    private static let schedulePayloadField = "scheduleJSON"
    private static let schedulePDFField = "pdf"
    private static let scheduleSubscriptionID = "ShiftHubSchedule.v1"

    private enum CloudSyncError: Error {
        case invalidRecord
    }

    private static var privateDatabase: CKDatabase {
        CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    private static var keyValueStore: NSUbiquitousKeyValueStore {
        .default
    }

    /// Registers the Development/private-database subscriptions used as the
    /// primary cross-device change signal. KVS remains a cache/fallback.
    static func ensureSettingsSubscription() async {
        guard isEnabled else { return }
        NSLog("Shift Hub: CloudKit settings subscription check begin id=%@", settingsSubscriptionID)

        do {
            let existing = try await privateDatabase.allSubscriptions()
            await ensureSubscription(
                id: settingsSubscriptionID,
                recordType: settingsRecordType,
                existingSubscriptions: existing
            )
            await ensureSubscription(
                id: scheduleSubscriptionID,
                recordType: scheduleRecordType,
                existingSubscriptions: existing
            )
        } catch {
            NSLog("Shift Hub: failed to register CloudKit settings subscription: %@", String(describing: error))
        }
    }

    private static func ensureSubscription(
        id: String,
        recordType: String,
        existingSubscriptions: [CKSubscription]
    ) async {
        guard !existingSubscriptions.contains(where: { $0.subscriptionID == id }) else {
            NSLog("Shift Hub: CloudKit subscription already registered id=%@", id)
            return
        }

        let subscription = CKQuerySubscription(
            recordType: recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: id,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        do {
            _ = try await privateDatabase.save(subscription)
            NSLog("Shift Hub: CloudKit subscription registered id=%@", id)
        } catch {
            NSLog("Shift Hub: failed to register CloudKit subscription id=%@ error=%@", id, String(describing: error))
        }
    }

    @discardableResult
    static func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              let subscriptionID = notification.subscriptionID else {
            return false
        }

        switch subscriptionID {
        case settingsSubscriptionID:
            NSLog("Shift Hub: CloudKit settings remote notification received subscription=%@", subscriptionID)
            NotificationCenter.default.post(name: .shiftHubCloudKitSettingsDidChange, object: nil)
            return true
        case scheduleSubscriptionID:
            NSLog("Shift Hub: CloudKit schedules remote notification received subscription=%@", subscriptionID)
            NotificationCenter.default.post(name: .shiftHubCloudKitSchedulesDidChange, object: nil)
            return true
        default:
            return false
        }
    }

    private static func colorRulesDiagnostic(_ settings: ShiftHubCloudSettings) -> String {
        let data = Data(settings.calendarTitleColorRulesJSON.utf8)
        let digest = SHA256.hash(data: data)
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        return "colorBytes=\(data.count) colorDigest=\(digest)"
    }

    static func saveSettings(
        _ settings: ShiftHubCloudSettings,
        changedScopes: Set<ShiftHubSettingsChangeScope> = Set(ShiftHubSettingsChangeScope.allCases)
    ) {
        guard isEnabled else {
            NSLog("Shift Hub: settings save skipped because iCloud sync is disabled")
            return
        }
        NSLog("Shift Hub: settings save requested %@", colorRulesDiagnostic(settings))
        cacheSettings(settings, changedScopes: changedScopes)
        Task { @MainActor in
            ShiftHubCloudSettingsSaveQueue.shared.requestSave()
        }
    }

    static func flushPendingSettingsSave() async {
        await ShiftHubCloudSettingsSaveQueue.shared.flush()
    }

    static func loadSettings() -> ShiftHubCloudSettings? {
        guard isEnabled else { return nil }
        guard let data = keyValueStore.data(forKey: settingsKey) else { return nil }
        return try? JSONDecoder().decode(ShiftHubCloudSettings.self, from: data)
    }

    static func loadSettingsChangeScopes() -> Set<ShiftHubSettingsChangeScope>? {
        guard let value = keyValueStore.string(forKey: "\(settingsKey).changedScopes") else {
            return nil
        }
        let scopes = Set(value.split(separator: ",").compactMap {
            ShiftHubSettingsChangeScope(rawValue: String($0))
        })
        return scopes.isEmpty ? nil : scopes
    }

    static func saveSchedules(_ schedules: [StoredSchedule]) {
        guard isEnabled else { return }
        guard let data = try? JSONEncoder().encode(schedules) else { return }
        keyValueStore.set(data, forKey: schedulesKey)
        keyValueStore.synchronize()
        Task {
            await saveSchedulesToCloudKit(schedules)
        }
    }

    static func loadSchedules() -> [StoredSchedule] {
        guard isEnabled else { return [] }
        guard let data = keyValueStore.data(forKey: schedulesKey),
              let schedules = try? JSONDecoder().decode([StoredSchedule].self, from: data) else {
            return []
        }

        return schedules.sorted { $0.importedAt > $1.importedAt }
    }

    private static func cloudAccountDiagnostic() async -> String {
        let container = CKContainer(identifier: containerIdentifier)
        let accountStatus = await withCheckedContinuation { continuation in
            container.accountStatus { status, _ in
                continuation.resume(returning: status)
            }
        }
        let userRecordName = await withCheckedContinuation { continuation in
            container.fetchUserRecordID { recordID, _ in
                continuation.resume(returning: recordID?.recordName ?? "none")
            }
        }
        let userDigest = SHA256.hash(data: Data(userRecordName.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        let ubiquityIdentityPresent = FileManager.default.ubiquityIdentityToken != nil
        return "accountStatus=\(accountStatus.rawValue) userDigest=\(userDigest) ubiquityIdentityPresent=\(ubiquityIdentityPresent)"
    }

    static func loadSettingsFromCloudKit() async -> Result<ShiftHubCloudSettings?, Error> {
        guard isEnabled else { return .success(nil) }
        let recordID = CKRecord.ID(recordName: settingsRecordName)
        NSLog("Shift Hub: CloudKit account %@", await cloudAccountDiagnostic())
        NSLog("Shift Hub: CloudKit settings fetch begin container=%@ recordType=%@ recordName=%@", containerIdentifier, settingsRecordType, settingsRecordName)

        do {
            let results = try await privateDatabase.records(
                for: [recordID],
                desiredKeys: [settingsPayloadField]
            )
            guard let recordResult = results[recordID] else {
                NSLog("Shift Hub: CloudKit settings fetch returned no result")
                return .success(nil)
            }

            let record: CKRecord
            do {
                record = try recordResult.get()
            } catch let error as CKError where error.code == .unknownItem {
                NSLog("Shift Hub: CloudKit settings record is absent")
                return .success(nil)
            } catch {
                NSLog("Shift Hub: failed to load iCloud settings record: %@", String(describing: error))
                return .failure(error)
            }

            guard let payload = record[settingsPayloadField] as? String,
                  let data = payload.data(using: .utf8),
                  let settings = try? JSONDecoder().decode(ShiftHubCloudSettings.self, from: data) else {
                return .failure(CloudSyncError.invalidRecord)
            }

            NSLog("Shift Hub: CloudKit settings fetch succeeded %@", colorRulesDiagnostic(settings))
            return .success(settings)
        } catch {
            NSLog("Shift Hub: failed to load iCloud settings: %@", String(describing: error))
            return .failure(error)
        }
    }

    static func synchronizeSchedulesFromCloudKit(with localSchedules: [StoredSchedule]) async -> Result<[StoredSchedule], Error> {
        guard isEnabled else { return .success(localSchedules) }
        let cloudSchedules: [(StoredSchedule, URL)]
        do {
            cloudSchedules = try await fetchCloudSchedules().get()
        } catch {
            return .failure(error)
        }

        if cloudSchedules.isEmpty {
            if !localSchedules.isEmpty {
                await saveSchedulesToCloudKit(localSchedules)
            }
            return .success(localSchedules)
        }

        var schedulesByChecksum = Dictionary(uniqueKeysWithValues: localSchedules.map { ($0.checksum, $0) })
        for (cloudSchedule, assetURL) in cloudSchedules {
            guard let localURL = try? StoredScheduleStore.fileURL(for: cloudSchedule) else {
                continue
            }

            if !FileManager.default.fileExists(atPath: localURL.path) {
                try? FileManager.default.copyItem(at: assetURL, to: localURL)
            }
            schedulesByChecksum[cloudSchedule.checksum] = cloudSchedule
        }

        return .success(schedulesByChecksum.values.sorted { $0.importedAt > $1.importedAt })
    }

    static func mirrorPDF(from localURL: URL, named fileName: String) {
        guard isEnabled else { return }
        guard let cloudURL = cloudDirectoryURL()?.appendingPathComponent(fileName) else { return }

        do {
            try FileManager.default.createDirectory(
                at: cloudURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if FileManager.default.fileExists(atPath: cloudURL.path) {
                try FileManager.default.removeItem(at: cloudURL)
            }

            try FileManager.default.copyItem(at: localURL, to: cloudURL)
        } catch {
            // iCloud may be unavailable during the first launch; the local copy remains valid.
        }
    }

    static func removePDF(named fileName: String) {
        guard isEnabled else { return }
        guard let cloudURL = cloudDirectoryURL()?.appendingPathComponent(fileName) else { return }
        try? FileManager.default.removeItem(at: cloudURL)
    }

    static func synchronizeSchedules(with localSchedules: [StoredSchedule]) -> [StoredSchedule] {
        var schedulesByChecksum = Dictionary(uniqueKeysWithValues: localSchedules.map { ($0.checksum, $0) })

        for cloudSchedule in loadSchedules() {
            guard let cloudURL = cloudDirectoryURL()?.appendingPathComponent(cloudSchedule.storedFileName) else {
                continue
            }

            if !FileManager.default.fileExists(atPath: cloudURL.path) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: cloudURL)
                schedulesByChecksum[cloudSchedule.checksum] = cloudSchedule
                continue
            }

            let localURL = try? StoredScheduleStore.fileURL(for: cloudSchedule)
            if let localURL, !FileManager.default.fileExists(atPath: localURL.path) {
                try? FileManager.default.copyItem(at: cloudURL, to: localURL)
            }

            if schedulesByChecksum[cloudSchedule.checksum] == nil {
                schedulesByChecksum[cloudSchedule.checksum] = cloudSchedule
            }
        }

        let schedules = schedulesByChecksum.values.sorted { $0.importedAt > $1.importedAt }
        for schedule in schedules {
            guard let localURL = try? StoredScheduleStore.fileURL(for: schedule),
                  FileManager.default.fileExists(atPath: localURL.path) else {
                continue
            }
            mirrorPDF(from: localURL, named: schedule.storedFileName)
        }
        saveSchedules(schedules)
        return schedules
    }

    private static func cloudDirectoryURL() -> URL? {
        guard let containerURL = FileManager.default.url(
            forUbiquityContainerIdentifier: containerIdentifier
        ) else {
            return nil
        }

        let directoryURL = containerURL
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("SavedSchedules", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }

    static func cacheSettings(
        _ settings: ShiftHubCloudSettings,
        changedScopes: Set<ShiftHubSettingsChangeScope>? = nil
    ) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        keyValueStore.set(data, forKey: settingsKey)
        if let changedScopes {
            let scopeValue = changedScopes.map(\.rawValue).sorted().joined(separator: ",")
            keyValueStore.set(scopeValue, forKey: "\(settingsKey).changedScopes")
        }
        let didSynchronize = keyValueStore.synchronize()
        NSLog("Shift Hub: KVS settings cached key=%@ bytes=%ld synchronize=%@ %@", settingsKey, data.count, String(describing: didSynchronize), colorRulesDiagnostic(settings))
    }

    fileprivate static func saveSettingsToCloudKit(_ settings: ShiftHubCloudSettings) async {
        guard let data = try? JSONEncoder().encode(settings),
              let payload = String(data: data, encoding: .utf8) else {
            NSLog("Shift Hub: failed to encode iCloud settings")
            return
        }

        let recordID = CKRecord.ID(recordName: settingsRecordName)
        let record: CKRecord

        do {
            let results = try await privateDatabase.records(for: [recordID])
            if let existingResult = results[recordID] {
                do {
                    record = try existingResult.get()
                } catch let error as CKError where error.code == .unknownItem {
                    record = CKRecord(recordType: settingsRecordType, recordID: recordID)
                } catch {
                    NSLog("Shift Hub: failed to read existing iCloud settings record before save: %@", String(describing: error))
                    return
                }
            } else {
                record = CKRecord(recordType: settingsRecordType, recordID: recordID)
            }
        } catch {
            NSLog("Shift Hub: failed to read iCloud settings record before save: %@", String(describing: error))
            return
        }

        record[settingsPayloadField] = payload as NSString
        NSLog("Shift Hub: CloudKit settings save begin recordType=%@ recordName=%@ %@", settingsRecordType, settingsRecordName, colorRulesDiagnostic(settings))
        do {
            _ = try await privateDatabase.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .changedKeys,
                atomically: true
            )
            NSLog("Shift Hub: CloudKit settings save succeeded %@", colorRulesDiagnostic(settings))
        } catch {
            NSLog("Shift Hub: failed to save iCloud settings: %@", String(describing: error))
        }
    }

    private static func fetchCloudSchedules() async -> Result<[(StoredSchedule, URL)], Error> {
        let query = CKQuery(
            recordType: scheduleRecordType,
            predicate: NSPredicate(value: true)
        )

        do {
            let result = try await privateDatabase.records(
                matching: query,
                desiredKeys: [schedulePayloadField, schedulePDFField],
                resultsLimit: 100
            )
            var schedules: [(StoredSchedule, URL)] = []

            for (_, recordResult) in result.matchResults {
                guard let record = try? recordResult.get(),
                      let payload = record[schedulePayloadField] as? String,
                      let data = payload.data(using: .utf8),
                      let schedule = try? JSONDecoder().decode(StoredSchedule.self, from: data),
                      let asset = record[schedulePDFField] as? CKAsset,
                      let assetURL = asset.fileURL else {
                    continue
                }
                schedules.append((schedule, assetURL))
            }

            return .success(schedules)
        } catch {
            return .failure(error)
        }
    }

    private static func saveSchedulesToCloudKit(_ schedules: [StoredSchedule]) async {
        guard let existingRecords = await fetchAllScheduleRecords() else {
            return
        }

        let desiredRecordNames = Set(schedules.map { scheduleRecordName(for: $0) })
        var recordsToSave: [CKRecord] = []

        for schedule in schedules {
            guard let localURL = try? StoredScheduleStore.fileURL(for: schedule),
                  FileManager.default.fileExists(atPath: localURL.path),
                  let data = try? JSONEncoder().encode(schedule),
                  let payload = String(data: data, encoding: .utf8) else {
                continue
            }

            let recordID = CKRecord.ID(recordName: scheduleRecordName(for: schedule))
            let record = existingRecords.first(where: { $0.recordID == recordID })
                ?? CKRecord(recordType: scheduleRecordType, recordID: recordID)
            record[schedulePayloadField] = payload as NSString
            record[schedulePDFField] = CKAsset(fileURL: localURL)
            recordsToSave.append(record)
        }

        let recordsToDelete = existingRecords
            .filter { !desiredRecordNames.contains($0.recordID.recordName) }
            .map(\.recordID)

        guard !recordsToSave.isEmpty || !recordsToDelete.isEmpty else {
            return
        }

        do {
            _ = try await privateDatabase.modifyRecords(
                saving: recordsToSave,
                deleting: recordsToDelete,
                savePolicy: .changedKeys,
                atomically: false
            )
        } catch {
            return
        }
    }

    private static func fetchAllScheduleRecords() async -> [CKRecord]? {
        let query = CKQuery(
            recordType: scheduleRecordType,
            predicate: NSPredicate(value: true)
        )

        do {
            let result = try await privateDatabase.records(
                matching: query,
                desiredKeys: [schedulePayloadField, schedulePDFField],
                resultsLimit: 100
            )
            return result.matchResults.compactMap { try? $0.1.get() }
        } catch {
            return nil
        }
    }

    private static func scheduleRecordName(for schedule: StoredSchedule) -> String {
        "schedule.\(schedule.id.uuidString)"
    }
}
