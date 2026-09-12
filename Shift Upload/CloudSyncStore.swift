import Foundation
import CloudKit

struct ShiftHubCloudSettings: Codable, Equatable {
    var appLanguage: String
    var workerName: String
    var shiftDefinitionsJSON: String
    var calendarDestination: String
    var appleCalendarIdentifier: String
    var appleRestEventTitle: String
    var googleCalendarClientID: String
    var googleCalendarID: String
    var googleRestEventTitle: String
    var notionDataSourceID: String
    var notionTitleProperty: String
    var notionDateProperty: String
    var notionTagProperty: String
    var notionTagValue: String
    var notionRestEventTitle: String
}

enum ShiftHubCloudSync {
    static let containerIdentifier = "iCloud.net.unwraps.Shift-Hub"

    private static let settingsKey = "shiftHub.settings.v1"
    private static let schedulesKey = "shiftHub.schedules.v1"
    private static let settingsRecordType = "ShiftHubSettings"
    private static let scheduleRecordType = "ShiftHubSchedule"
    private static let settingsRecordName = "settings"
    private static let settingsPayloadField = "payload"
    private static let schedulePayloadField = "scheduleJSON"
    private static let schedulePDFField = "pdf"

    private enum CloudSyncError: Error {
        case invalidRecord
    }

    private static var privateDatabase: CKDatabase {
        CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    private static var keyValueStore: NSUbiquitousKeyValueStore {
        .default
    }

    static func saveSettings(_ settings: ShiftHubCloudSettings) {
        cacheSettings(settings)
        Task {
            await saveSettingsToCloudKit(settings)
        }
    }

    static func loadSettings() -> ShiftHubCloudSettings? {
        guard let data = keyValueStore.data(forKey: settingsKey) else { return nil }
        return try? JSONDecoder().decode(ShiftHubCloudSettings.self, from: data)
    }

    static func saveSchedules(_ schedules: [StoredSchedule]) {
        guard let data = try? JSONEncoder().encode(schedules) else { return }
        keyValueStore.set(data, forKey: schedulesKey)
        keyValueStore.synchronize()
        Task {
            await saveSchedulesToCloudKit(schedules)
        }
    }

    static func loadSchedules() -> [StoredSchedule] {
        guard let data = keyValueStore.data(forKey: schedulesKey),
              let schedules = try? JSONDecoder().decode([StoredSchedule].self, from: data) else {
            return []
        }

        return schedules.sorted { $0.importedAt > $1.importedAt }
    }

    static func loadSettingsFromCloudKit() async -> Result<ShiftHubCloudSettings?, Error> {
        let recordID = CKRecord.ID(recordName: settingsRecordName)

        do {
            let results = try await privateDatabase.records(
                for: [recordID],
                desiredKeys: [settingsPayloadField]
            )
            guard let recordResult = results[recordID] else {
                return .success(nil)
            }

            let record: CKRecord
            do {
                record = try recordResult.get()
            } catch let error as CKError where error.code == .unknownItem {
                return .success(nil)
            } catch {
                return .failure(error)
            }

            guard let payload = record[settingsPayloadField] as? String,
                  let data = payload.data(using: .utf8),
                  let settings = try? JSONDecoder().decode(ShiftHubCloudSettings.self, from: data) else {
                return .failure(CloudSyncError.invalidRecord)
            }

            cacheSettings(settings)
            return .success(settings)
        } catch {
            return .failure(error)
        }
    }

    static func synchronizeSchedulesFromCloudKit(with localSchedules: [StoredSchedule]) async -> Result<[StoredSchedule], Error> {
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

    private static func cacheSettings(_ settings: ShiftHubCloudSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        keyValueStore.set(data, forKey: settingsKey)
        keyValueStore.synchronize()
    }

    private static func saveSettingsToCloudKit(_ settings: ShiftHubCloudSettings) async {
        guard let data = try? JSONEncoder().encode(settings),
              let payload = String(data: data, encoding: .utf8) else {
            return
        }

        let recordID = CKRecord.ID(recordName: settingsRecordName)
        let record: CKRecord

        if let results = try? await privateDatabase.records(for: [recordID]),
           let existingResult = results[recordID],
           let existingRecord = try? existingResult.get() {
            record = existingRecord
        } else {
            record = CKRecord(recordType: settingsRecordType, recordID: recordID)
        }

        record[settingsPayloadField] = payload as NSString
        do {
            _ = try await privateDatabase.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .changedKeys,
                atomically: true
            )
        } catch {
            return
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
