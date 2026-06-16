//
//  SynapLinkApp.swift
//  SynapLink
//

import SwiftUI

@main
struct SynapLinkApp: App {
    init() {
        let gb = RuntimeProfile.physicalMemoryGB
        slog("SynapLink launch — \(String(format: "%.1f", gb)) GB RAM, "
            + "model \(ModelDownloadManager.shared.selectedConfig.rawValue)", .notice)
    }

    var body: some Scene {
        WindowGroup {
            // CI runs the headless benchmark harness directly (see
            // scripts/simulator-smoketest.sh); users get the chat app.
            if ProcessInfo.processInfo.arguments.contains("--auto-benchmark") {
                NavigationStack { SmokeTestView() }
            } else {
                RootTabView()
            }
        }
    }
}
