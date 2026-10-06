//
//  Shift_UploadApp.swift
//  Shift Upload
//
//  Created by tomoaki-d on 2026/09/08.
//

import SwiftUI
import CloudKit

#if os(iOS)
import UIKit
#else
import AppKit
#endif

final class ShiftHubApplicationDelegate: NSObject {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Shift Hub: applicationDidFinishLaunching")
#if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
#endif
    }
}

#if os(iOS)
extension ShiftHubApplicationDelegate: UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NSLog("Shift Hub: iOS didFinishLaunching")
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let handled = ShiftHubCloudSync.handleRemoteNotification(userInfo)
        completionHandler(handled ? .newData : .noData)
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NSLog("Shift Hub: iOS APNs registration succeeded tokenBytes=%ld", deviceToken.count)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("Shift Hub: iOS APNs registration failed error=%@", String(describing: error))
    }
}
#else
extension ShiftHubApplicationDelegate: NSApplicationDelegate {
    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NSLog("Shift Hub: macOS APNs registration succeeded tokenBytes=%ld", deviceToken.count)
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("Shift Hub: macOS APNs registration failed error=%@", String(describing: error))
    }

    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        let converted = Dictionary(uniqueKeysWithValues: userInfo.map { (AnyHashable($0.key), $0.value) })
        _ = ShiftHubCloudSync.handleRemoteNotification(converted)
    }
}
#endif

@main
struct Shift_UploadApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(ShiftHubApplicationDelegate.self) private var appDelegate
#else
    @NSApplicationDelegateAdaptor(ShiftHubApplicationDelegate.self) private var appDelegate
#endif

    init() {
        Task {
            await ShiftHubCloudSync.ensureSettingsSubscription()
        }
#if os(iOS)
        CalHubWatchSyncManager.shared.activate()
#endif
    }

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
