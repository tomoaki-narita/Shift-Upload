import Foundation
import SwiftUI
import Combine
import WatchConnectivity
import WidgetKit

struct WatchSnapshot: Codable {
    let version: Int
    let localeIdentifier: String
    let updatedAt: Date
    let events: [WatchSnapshotEvent]
}

struct WatchSnapshotEvent: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let date: Date
    let startDate: Date?
    let endDate: Date?
    let isAllDay: Bool
    let isRestEvent: Bool
    let red: Double?
    let green: Double?
    let blue: Double?
}

@MainActor
final class WatchSnapshotReceiver: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSnapshotReceiver()
    private static let appGroupIdentifier = "group.net.unwraps.Shift-Hub"
    private static let snapshotFileName = "watch-calendar-snapshot.json"

    @Published private(set) var snapshot: WatchSnapshot?

    private override init() {
        snapshot = Self.loadSnapshot()
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else {
            #if DEBUG
            print("Watch sync unavailable: WCSession is not supported")
            #endif
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #if DEBUG
        print("Watch sync receiver activating state=\(session.activationState.rawValue)")
        #endif
    }

    private func receive(_ data: Data) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ),
        let snapshot = try? JSONDecoder().decode(WatchSnapshot.self, from: data) else { return }

        do {
            try data.write(
                to: container.appendingPathComponent(Self.snapshotFileName),
                options: .atomic
            )
            self.snapshot = snapshot
            WidgetCenter.shared.reloadAllTimelines()
            #if DEBUG
            print("Watch sync received events=\(snapshot.events.count)")
            #endif
        } catch {
            #if DEBUG
            print("Watch snapshot write failed: \(error.localizedDescription)")
            #endif
        }
    }

    private static func loadSnapshot() -> WatchSnapshot? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ),
        let data = try? Data(contentsOf: container.appendingPathComponent(snapshotFileName)) else {
            return nil
        }
        return try? JSONDecoder().decode(WatchSnapshot.self, from: data)
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let data = session.receivedApplicationContext["snapshot"] as? Data
        #if DEBUG
        print("Watch sync activated state=\(activationState.rawValue) contextPresent=\(data != nil) error=\(error?.localizedDescription ?? "none")")
        #endif
        guard activationState == .activated, let data else { return }
        Task { @MainActor in
            WatchSnapshotReceiver.shared.receive(data)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let data = applicationContext["snapshot"] as? Data else {
            #if DEBUG
            print("Watch sync received context without snapshot")
            #endif
            return
        }
        #if DEBUG
        print("Watch sync application context received bytes=\(data.count)")
        #endif
        Task { @MainActor in
            WatchSnapshotReceiver.shared.receive(data)
        }
    }
}
