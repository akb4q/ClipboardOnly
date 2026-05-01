// ClipboardImageCache.swift — single-file rolling cache for "paste as path" mode.
// Holds at most one PNG (clip-current.png) under ~/Library/Caches/<bundle>/.
// Cleared on the next screenshot, on any external clipboard write, on quit,
// and at launch.
//
// Security model: a screenshot may contain sensitive content (terminals,
// password fields, private docs). The on-disk copy lives longer than the
// in-memory pasteboard image, so we
//   * reject symlinks at both the directory and file paths (lstat) before
//     writing — defeats a planted symlink redirecting writes/reads to
//     attacker-chosen targets such as ~/.ssh/id_rsa,
//   * force 0700 on the directory and 0600 on the file so other users on
//     the machine can't read it,
//   * write atomically (tmp + rename) so partial writes can't be observed.

import Foundation

enum ClipboardImageCache {
    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundle = Bundle.main.bundleIdentifier ?? "ClipboardOnly"
        return base.appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("clip-current.png")
    }()

    @discardableResult
    static func write(_ pngData: Data) -> URL? {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()

        // Drop any planted symlink at the directory before (re)creating it.
        var st = stat()
        if lstat(dir.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
            try? fm.removeItem(at: dir)
        }
        do {
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Tighten perms even if the directory already existed.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            return nil
        }

        // Drop anything (symlink, regular file, dir) at the target before
        // writing — atomic rename would replace a symlink safely, but explicit
        // unlink keeps the threat model obvious.
        try? fm.removeItem(at: fileURL)

        do {
            try pngData.write(to: fileURL, options: [.atomic])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return fileURL
        } catch {
            return nil
        }
    }

    static func clear() {
        // removeItem unlinks the symlink itself, never the target.
        try? FileManager.default.removeItem(at: fileURL)
    }
}
