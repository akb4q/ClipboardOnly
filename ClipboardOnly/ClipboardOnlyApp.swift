// ClipboardOnlyApp.swift — entry point
// NSStatusItem is created and owned by MenuBarController directly.

import SwiftUI
import AppKit

@main
struct ClipboardOnlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = MenuBarController()

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        terminatePreviousInstances()
    }

    private func terminatePreviousInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        others.forEach { $0.terminate() }
    }
}
