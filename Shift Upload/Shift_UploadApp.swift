//
//  Shift_UploadApp.swift
//  Shift Upload
//
//  Created by tomoaki-d on 2026/09/08.
//

import SwiftUI

@main
struct Shift_UploadApp: App {
    var body: some Scene {
#if os(macOS)
        WindowGroup {
            ContentView()
                .handlesExternalEvents(
                    preferring: ["calhub://calendar"],
                    allowing: ["calhub://calendar"]
                )
        }
        .handlesExternalEvents(matching: ["calhub://calendar"])
#else
        WindowGroup {
            ContentView()
        }
#endif
#if os(macOS)
        WindowGroup(id: "pdf-preview", for: StoredSchedule.self) { $schedule in
            if let schedule {
                SavedSchedulePreviewView(schedule: schedule, onSelect: nil)
            }
        }
        .defaultSize(width: 1000, height: 720)

        WindowGroup(id: "pdf-viewer", for: StoredSchedule.self) { $schedule in
            if let schedule {
                SavedSchedulePreviewView(
                    schedule: schedule,
                    onSelect: nil,
                    showsScanAction: false
                )
            }
        }
        .defaultSize(width: 1000, height: 720)
#endif
    }
}
