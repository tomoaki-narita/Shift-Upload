//
//  ContentView.swift
//  CalHubWatch Watch App
//
//  Created by tomoaki-d on 2026/10/02.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var receiver = WatchSnapshotReceiver.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cal Hub")
                .font(.headline)
            if let snapshot = receiver.snapshot {
                Text(snapshot.events.count == 1 ? "1 event synced" : "\(snapshot.events.count) events synced")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let next = snapshot.events
                    .filter({ !$0.isAllDay && ($0.startDate ?? $0.date) > .now })
                    .sorted(by: { ($0.startDate ?? $0.date) < ($1.startDate ?? $1.date) })
                    .first {
                    Text(next.title)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .lineLimit(2)
                    Text(next.startDate ?? next.date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Open Cal Hub on iPhone to sync events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear { receiver.activate() }
    }
}
