// ScreenshotWatcher.swift — FSEvents-based directory watcher

import Foundation
import CoreServices

final class ScreenshotWatcher {
    private var stream: FSEventStreamRef?
    private let handler: (URL) -> Void
    private let queue = DispatchQueue(label: "com.akb4q.screenshot-toggle.watcher")

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

                // Brief delay so macOS finishes writing the file
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    me.handler(url)
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

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
