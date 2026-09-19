import CryptoKit
import Foundation

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

    static func importFile(
        from sourceURL: URL,
        existing: [StoredSchedule],
        fileName: String? = nil
    ) throws -> StoredScheduleImportResult {
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

            let displayFileName: String
            if let fileName,
               URL(fileURLWithPath: existingSchedule.fileName)
                   .deletingPathExtension()
                   .lastPathComponent
                   .caseInsensitiveCompare(existingSchedule.id.uuidString) == .orderedSame {
                displayFileName = fileName
            } else {
                displayFileName = existingSchedule.fileName
            }

            let schedule = displayFileName == existingSchedule.fileName
                ? existingSchedule
                : StoredSchedule(
                    id: existingSchedule.id,
                    fileName: displayFileName,
                    storedFileName: existingSchedule.storedFileName,
                    checksum: existingSchedule.checksum,
                    importedAt: existingSchedule.importedAt
                )
            return StoredScheduleImportResult(
                schedule: schedule,
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
            fileName: fileName ?? sourceURL.lastPathComponent,
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
