#if os(iOS)
import Foundation
import WatchConnectivity

private struct CalHubWatchTransferEvent: Codable {
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

    init(_ event: CalHubWidgetEvent) {
        id = event.id
        title = event.title
        date = event.date
        startDate = event.startDate
        endDate = event.endDate
        isAllDay = event.isAllDay
        isRestEvent = event.isRestEvent
        red = event.red
        green = event.green
        blue = event.blue
    }
}

private struct CalHubWatchTransferSnapshot: Codable {
    let version: Int
    let localeIdentifier: String
    let updatedAt: Date
    let events: [CalHubWatchTransferEvent]
}

@MainActor
final class CalHubWatchSyncManager: NSObject, WCSessionDelegate {
    static let shared = CalHubWatchSyncManager()

    private var latestContext: [String: Any]?

    private override init() {
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
        print("Watch sync activating paired=\(session.isPaired) installed=\(session.isWatchAppInstalled) state=\(session.activationState.rawValue)")
        #endif
    }

    func publish(_ snapshot: CalHubWidgetSnapshot) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let endOfTomorrow = calendar.date(byAdding: .day, value: 2, to: today) ?? today
        let relevantEvents = snapshot.events.filter { event in
            let start = event.startDate ?? event.date
            let end = event.endDate ?? start
            return end >= today && start < endOfTomorrow
        }
        guard let data = try? JSONEncoder().encode(CalHubWatchTransferSnapshot(
            version: 1,
            localeIdentifier: snapshot.localeIdentifier,
            updatedAt: .now,
            events: relevantEvents.map(CalHubWatchTransferEvent.init)
        )) else { return }
        latestContext = ["snapshot": data]
        #if DEBUG
        print("Watch sync snapshot prepared events=\(relevantEvents.count) bytes=\(data.count)")
        #endif
        sendLatestContext()
    }

    private func sendLatestContext() {
        guard WCSession.isSupported() else { return }
        guard let latestContext else {
            #if DEBUG
            print("Watch sync pending: no snapshot prepared")
            #endif
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            #if DEBUG
            print("Watch sync pending: session state=\(session.activationState.rawValue)")
            #endif
            return
        }
        guard session.isPaired, session.isWatchAppInstalled else {
            #if DEBUG
            print("Watch sync pending: paired=\(session.isPaired) installed=\(session.isWatchAppInstalled)")
            #endif
            return
        }
        do {
            try session.updateApplicationContext(latestContext)
            #if DEBUG
            print("Watch sync context sent reachable=\(session.isReachable)")
            #endif
        } catch {
            #if DEBUG
            print("Watch snapshot transfer failed: \(error.localizedDescription)")
            #endif
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let errorDescription = error?.localizedDescription ?? "none"
        Task { @MainActor in
            #if DEBUG
            print("Watch sync activated state=\(activationState.rawValue) error=\(errorDescription)")
            #endif
            CalHubWatchSyncManager.shared.sendLatestContext()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        Task { @MainActor in
            #if DEBUG
            print("Watch sync watch state changed paired=\(paired) installed=\(installed)")
            #endif
            CalHubWatchSyncManager.shared.sendLatestContext()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
#endif
