//
//  SynapLinkApp.swift
//  SynapLink
//

import SwiftUI

@main
struct SynapLinkApp: App {
    var body: some Scene {
        WindowGroup {
            // CI runs the headless benchmark harness directly (see
            // scripts/simulator-smoketest.sh); users get the chat app.
            if ProcessInfo.processInfo.arguments.contains("--auto-benchmark") {
                NavigationStack { SmokeTestView() }
            } else {
                ChatListView()
            }
        }
    }
}
