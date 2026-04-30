// ScreenshotWatcher.swift — FSEvents-based directory watcher

import Foundation
import CoreServices

final class ScreenshotWatcher {
    private var stream: FSEventStreamRef?
    private let handler: (URL) -> Void
    private let queue = DispatchQueue(label: "com.akb4q.clipboard-only.watcher")

    private static let validExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tiff", "gif", "mov", "mp4"
    ]

    init(watchDir: URL, handler: @escaping (URL) -> Void) {
        self.handler = handler
        start(watchDir: watchDir)
    }

    deinit { stop() }

    // MARK: – Private

    private func start(watchDir: URL) {
        let paths = [watchDir.path] as CFArray
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: { Unmanaged<ScreenshotWatcher>.fromOpaque($0!).release() },
            copyDescription: nil
        )

        let cb: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<ScreenshotWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as! [String]

            for i in 0..<count {
                let f = flags[i]
                let isFile    = (f & UInt32(kFSEventStreamEventFlagItemIsFile))   != 0
                let isCreated = (f & UInt32(kFSEventStreamEventFlagItemCreated))  != 0
                let isRenamed = (f & UInt32(kFSEventStreamEventFlagItemRenamed))  != 0
                guard isFile, isCreated || isRenamed else { continue }

                let url = URL(fileURLWithPath: paths[i])
                guard ScreenshotWatcher.validExtensions.contains(url.pathExtension.lowercased()) else { continue }

                // Wait until the file size is stable across two consecutive
                // checks before dispatching. A fixed 200 ms delay was unreliable
                // for large multi-monitor PNGs, leaving handlers to read partial
                // files (which then decoded as nil or black images).
                me.queue.asyncAfter(deadline: .now() + 0.15) { [weak me] in
                    guard let me else { return }
                    me.dispatchWhenStable(url: url, attempts: 0)
                }
            }
        }

        stream = FSEventStreamCreate(
            nil, cb, &ctx, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagUseCFTypes
            )
        )

        if let s = stream {
            FSEventStreamSetDispatchQueue(s, queue)   // ← modern API, replaces RunLoop version
            FSEventStreamStart(s)
        }
    }

    private func dispatchWhenStable(url: URL, attempts: Int) {
        let path = url.path
        var st1 = stat()
        guard lstat(path, &st1) == 0 else { return } // file gone — give up
        let size1 = st1.st_size

        // Cap retries so a stuck/never-finished writer can't loop forever.
        let maxAttempts = 20  // ~3s total at 0.15s spacing
        if attempts >= maxAttempts {
            DispatchQueue.main.async { self.handler(url) }
            return
        }

        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            var st2 = stat()
            guard lstat(path, &st2) == 0 else { return }
            if st2.st_size == size1, size1 > 0 {
                DispatchQueue.main.async { self.handler(url) }
            } else {
                self.dispatchWhenStable(url: url, attempts: attempts + 1)
            }
        }
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
