#if os(iOS)
import Foundation
import WatchConnectivity

private struct CalHubWatchTransferEvent: Codable {
    let id: String
    let title: String
    let detail: String
    let metadata: [String: String]
    let optionColors: [String: [String: String]]
    let date: Date
    let startDate: Date?
    let endDate: Date?
    let isAllDay: Bool
    let isRestEvent: Bool
    let red: Double?
    let green: Double?
    let blue: Double?
    let alpha: Double?

    init(
        _ event: CalHubWidgetEvent,
        resolvedColor: CalendarDisplayColor? = nil,
        optionColors: [String: [String: String]] = [:]
    ) {
        id = event.id
        title = event.title
        detail = event.detail
        metadata = event.metadata
        self.optionColors = optionColors
        date = event.date
        startDate = event.startDate
        endDate = event.endDate
        isAllDay = event.isAllDay
        isRestEvent = event.isRestEvent
        red = resolvedColor?.red ?? event.red
        green = resolvedColor?.green ?? event.green
        blue = resolvedColor?.blue ?? event.blue
        alpha = resolvedColor?.alpha ?? 1
    }
}

private struct CalHubWatchTransferSnapshot: Codable {
    let version: Int
    let localeIdentifier: String
    let updatedAt: Date
    let inlineTimeEnabled: Bool
    let inlineStartTimeEnabled: Bool
    let inlineEndTimeEnabled: Bool
    let cornerTimeEnabled: Bool
    let cornerStartTimeEnabled: Bool
    let cornerEndTimeEnabled: Bool
    let rectangularTimeEnabled: Bool
    let rectangularStartTimeEnabled: Bool
    let rectangularEndTimeEnabled: Bool
    let sundayInRedEnabled: Bool
    let sourceRed: Double
    let sourceGreen: Double
    let sourceBlue: Double
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

    func publishLatestSnapshot() {
        guard let snapshot = CalHubWidgetSharedData.load() else { return }
        publish(snapshot)
    }

    func publish(_ snapshot: CalHubWidgetSnapshot) {
        let defaults = UserDefaults(suiteName: CalHubWidgetSharedData.appGroupIdentifier)
        func preference(_ key: String, default defaultValue: Bool) -> Bool {
            defaults?.object(forKey: key) as? Bool ?? defaultValue
        }
        // Keep the full snapshot so the Watch app can navigate to any synced date.
        let relevantEvents = snapshot.events
        let titleColorRules: [CalendarTitleColorRule] = {
            guard let data = (UserDefaults.standard.string(forKey: "calendarTitleColorRulesJSON") ?? "[]")
                .data(using: .utf8),
                  let rules = try? JSONDecoder().decode([CalendarTitleColorRule].self, from: data) else {
                return []
            }
            return rules
        }()
        func resolvedEventColor(_ event: CalHubWidgetEvent) -> CalendarDisplayColor? {
            if let rule = titleColorRules.first(where: { $0.title == event.title }) {
                return rule.color
            }
            guard let red = event.red,
                  let green = event.green,
                  let blue = event.blue else {
                return nil
            }
            return CalendarDisplayColor(red: red, green: green, blue: blue, alpha: 1)
        }
        guard let data = try? JSONEncoder().encode(CalHubWatchTransferSnapshot(
            version: 1,
            localeIdentifier: snapshot.localeIdentifier,
            updatedAt: .now,
            inlineTimeEnabled: preference(CalHubWidgetSharedData.inlineTimeEnabledPreferenceKey, default: true),
            inlineStartTimeEnabled: preference(CalHubWidgetSharedData.inlineStartTimeEnabledPreferenceKey, default: true),
            inlineEndTimeEnabled: preference(CalHubWidgetSharedData.inlineEndTimeEnabledPreferenceKey, default: false),
            cornerTimeEnabled: preference(CalHubWidgetSharedData.cornerTimeEnabledPreferenceKey, default: true),
            cornerStartTimeEnabled: preference(CalHubWidgetSharedData.cornerStartTimeEnabledPreferenceKey, default: true),
            cornerEndTimeEnabled: preference(CalHubWidgetSharedData.cornerEndTimeEnabledPreferenceKey, default: false),
            rectangularTimeEnabled: preference(CalHubWidgetSharedData.rectangularTimeEnabledPreferenceKey, default: true),
            rectangularStartTimeEnabled: preference(CalHubWidgetSharedData.rectangularStartTimeEnabledPreferenceKey, default: true),
            rectangularEndTimeEnabled: preference(CalHubWidgetSharedData.rectangularEndTimeEnabledPreferenceKey, default: false),
            sundayInRedEnabled: preference(CalHubWidgetSharedData.sundayInRedPreferenceKey, default: false),
            sourceRed: snapshot.sourceRed ?? 0.25,
            sourceGreen: snapshot.sourceGreen ?? 0.58,
            sourceBlue: snapshot.sourceBlue ?? 0.95,
            events: relevantEvents.map { event in
                CalHubWatchTransferEvent(
                    event,
                    resolvedColor: resolvedEventColor(event),
                    optionColors: snapshot.metadataOptionColors ?? [:]
                )
            }
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
            session.transferUserInfo(latestContext)
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
            CalHubWatchSyncManager.shared.publishLatestSnapshot()
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
