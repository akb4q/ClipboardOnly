// ClipboardOnlyApp.swift — entry point
// NSStatusItem is created and owned by MenuBarController directly.

import SwiftUI
import AppKit
import Darwin

@main
struct ClipboardOnlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Strong reference ensures the status item is created and stays alive.
    private var controller: MenuBarController?
    private var singleInstanceLockFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstanceLock() else {
            NSApplication.shared.terminate(nil)
            return
        }
        // Drop any cached path-mode image left over from a previous run.
        ClipboardImageCache.clear()
        // Create after launch so NSStatusBar is fully ready.
        controller = MenuBarController()
    }

    private func acquireSingleInstanceLock() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)

        do {
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            return false
        }

        let lockPath = dir.appendingPathComponent("app.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }

        singleInstanceLockFD = fd
        return true
    }
}
