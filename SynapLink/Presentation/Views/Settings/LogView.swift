//
//  LogView.swift
//  SynapLink
//
//  In-app log viewer (Settings → Diagnostics → Logs). Reads LogStore so
//  on-device issues can be inspected and shared without an Xcode console.
//

import SwiftUI

struct LogView: View {
    @State private var entries: [LogEntry] = []
    @State private var minLevel: LogLevel = .debug
    @State private var autoRefresh = true

    private let levels: [(String, LogLevel)] = [
        ("All", .debug), ("Info", .info), ("Warn", .warning), ("Errors", .error)
    ]

    var body: some View {
        VStack(spacing: 0) {
            Picker("Level", selection: $minLevel) {
                ForEach(levels, id: \.1) { Text($0.0).tag($0.1) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 6)
            .onChange(of: minLevel) { refresh() }

            if entries.isEmpty {
                ContentUnavailableView("No logs yet", systemImage: "text.alignleft",
                                       description: Text("Activity will appear here as you use the app."))
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.level.emoji)
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(entry.category)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.message)
                            .font(.caption.monospaced())
                            .foregroundStyle(color(for: entry.level))
                            .textSelection(.enabled)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
                .listStyle(.plain)
                .scrollIndicators(.hidden)
                .synapTabBarInset()
            }
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: LogStore.shared.exportText()) {
                        Label("Share Logs", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        LogStore.shared.clear()
                        refresh()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            while autoRefresh, !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        entries = LogStore.shared.snapshot(minLevel: minLevel)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .notice: return .primary
        default: return .secondary
        }
    }
}

#Preview {
    NavigationStack { LogView() }
}
