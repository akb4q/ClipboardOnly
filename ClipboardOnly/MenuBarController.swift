// MenuBarController.swift — business logic + owns the NSStatusItem directly

import AppKit
import ServiceManagement
import UserNotifications

@MainActor
final class MenuBarController: NSObject, ObservableObject, NSMenuDelegate {

    @Published var clipboardMode: Bool {
        didSet {
            UserDefaults.standard.set(clipboardMode, forKey: "clipboardMode")
            setThumbnailVisible(!clipboardMode)
            updateButton()
            DispatchQueue.main.async { [weak self] in self?.rebuildMenu() }
        }
    }
    @Published private(set) var saveDirectory: URL

    // MARK: – Private state

    private var statusItem: NSStatusItem!
    private var hasBadge = false

    private let interceptDir: URL
    private let originalLocation: String
    private let originalTarget: String       // "clipboard", "file", "preview", etc.
    private var watcher: ScreenshotWatcher?
    private var badgeChangeCount: Int = 0     // pasteboard changeCount when badge was shown
    private var badgeTimer: Timer?
    private let shortcutArea:   String = "⌘⇧4"
    private let shortcutScreen: String = "⌘⇧3"

    private static let screencaptureDomain = "com.apple.screencapture"
    private static let interceptPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".clipboard_only/intercept")

    // MARK: – Init

    override init() {
        interceptDir     = Self.interceptPath
        originalLocation = Self.readScreenshotLocation()
        originalTarget   = UserDefaults(suiteName: Self.screencaptureDomain)?
            .string(forKey: "target") ?? "file"
        clipboardMode    = UserDefaults.standard.bool(forKey: "clipboardMode")

        let saved = originalLocation == Self.interceptPath.path
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            : URL(fileURLWithPath: originalLocation)
        saveDirectory = saved

        super.init()

        setupInterceptDir()
        setScreenshotLocation(interceptDir.path)
        setThumbnailVisible(!clipboardMode)
        setupStatusItem()

        watcher = ScreenshotWatcher(watchDir: interceptDir) { [weak self] url in
            Task { @MainActor [weak self] in self?.handleNewFile(url) }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cleanup() }
        }
    }

    // MARK: – Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateButton()
        rebuildMenu()
    }

    /// 空心 = 正常，实心 = 剪贴板里有截图
    private func updateButton() {
        let name = hasBadge ? "doc.on.clipboard.fill" : "doc.on.clipboard"
        let img  = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.isTemplate = true
        statusItem.button?.image        = img
        statusItem.button?.imageScaling = .scaleProportionallyDown
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        populateMenu(menu)
        statusItem.menu = menu
    }

    private func populateMenu(_ menu: NSMenu) {
        let toggleItem = NSMenuItem(
            title: L10n.str(.toggle),
            action: #selector(toggleMode),
            keyEquivalent: ""
        )
        toggleItem.state  = clipboardMode ? .on : .off
        toggleItem.target = self
        menu.addItem(toggleItem)

        let shortcutInfo = NSMenuItem(
            title: String(format: L10n.str(.shortcuts), shortcutArea, shortcutScreen),
            action: nil, keyEquivalent: ""
        )
        shortcutInfo.isEnabled = false
        menu.addItem(shortcutInfo)

        menu.addItem(.separator())

        // Clipboard preview section
        addClipboardPreview(to: menu)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(
            title: L10n.str(.launchAtLogin),
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.state  = isLaunchAtLoginEnabled ? .on : .off
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.str(.quit),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: – NSMenuDelegate

    /// Called on main thread by AppKit before the menu is displayed.
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menu.removeAllItems()
            self.populateMenu(menu)
        }
    }

    // MARK: – Clipboard preview

    private func addClipboardPreview(to menu: NSMenu) {
        let pb = NSPasteboard.general
        let types = pb.types ?? []

        // 1) Image
        if types.contains(.tiff) || types.contains(.png),
           let image = NSImage(pasteboard: pb) {

            let maxW: CGFloat = 240
            let maxH: CGFloat = 160
            let originalSize = image.size
            let scale = min(maxW / originalSize.width, maxH / originalSize.height, 1.0)
            let thumbW = originalSize.width * scale
            let thumbH = originalSize.height * scale

            let imageView = NSImageView(frame: NSRect(x: 12, y: 4, width: thumbW, height: thumbH))
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown

            let container = NSView(frame: NSRect(x: 0, y: 0, width: maxW + 24, height: thumbH + 8))
            container.addSubview(imageView)

            let item = NSMenuItem()
            item.view = container
            menu.addItem(item)

            let sizeLabel = NSMenuItem(
                title: "  \(Int(originalSize.width)) × \(Int(originalSize.height))",
                action: nil, keyEquivalent: ""
            )
            sizeLabel.isEnabled = false
            menu.addItem(sizeLabel)
            return
        }

        // 2) Text — fixed-size scrollable area
        if let text = pb.string(forType: .string), !text.isEmpty {
            let boxW: CGFloat = 260
            let boxH: CGFloat = 160
            let padding: CGFloat = 12
            let displayText = text.count > 2000 ? String(text.prefix(2000)) + "…" : text

            let scrollView = NSScrollView(frame: NSRect(x: padding, y: 4, width: boxW, height: boxH))
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder

            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: boxW, height: boxH))
            textView.isEditable = false
            textView.isSelectable = true
            textView.backgroundColor = .clear
            textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textColor = .labelColor
            textView.textContainerInset = NSSize(width: 4, height: 4)
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: boxW - 8, height: .greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.string = displayText

            scrollView.documentView = textView

            let container = NSView(frame: NSRect(x: 0, y: 0, width: boxW + padding * 2, height: boxH + 8))
            container.addSubview(scrollView)

            let item = NSMenuItem()
            item.view = container
            menu.addItem(item)

            let countLabel = NSMenuItem(
                title: "  " + String(format: L10n.str(.characters), text.count),
                action: nil, keyEquivalent: ""
            )
            countLabel.isEnabled = false
            menu.addItem(countLabel)
            return
        }

        // 3) Empty
        let emptyItem = NSMenuItem(
            title: "  (\(L10n.str(.clipboardEmpty)))",
            action: nil, keyEquivalent: ""
        )
        emptyItem.isEnabled = false
        menu.addItem(emptyItem)
    }

    // MARK: – Badge（截图后 → 实心图标，剪贴板内容变化 → 空心图标）

    private func showBadge() {
        hasBadge = true
        updateButton()

        // Poll pasteboard changeCount — when the user copies something new,
        // the badge disappears (screenshot no longer in clipboard).
        badgeChangeCount = NSPasteboard.general.changeCount
        badgeTimer?.invalidate()
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if NSPasteboard.general.changeCount != self.badgeChangeCount {
                timer.invalidate()
                Task { @MainActor in self.hideBadge() }
            }
        }
    }

    private func hideBadge() {
        badgeTimer?.invalidate()
        badgeTimer = nil
        hasBadge = false
        updateButton()
    }

    // MARK: – File handling

    private func handleNewFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let ext = url.pathExtension.lowercased()

        if clipboardMode {
            if ["mov", "mp4"].contains(ext) {
                let dest = saveDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.moveItem(at: url, to: dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                notify(L10n.str(.notifVideo),
                       String(format: L10n.str(.notifVideoMsg), url.lastPathComponent))
            } else {
                guard let image = NSImage(contentsOf: url) else { return }
                try? FileManager.default.removeItem(at: url)

                // Write image data eagerly (not lazily) so Universal Clipboard
                // (Handoff to iPhone/iPad) works correctly.
                let pb = NSPasteboard.general
                pb.clearContents()
                if let tiffData = image.tiffRepresentation {
                    let item = NSPasteboardItem()
                    item.setData(tiffData, forType: .tiff)
                    if let rep = NSBitmapImageRep(data: tiffData),
                       let pngData = rep.representation(using: .png, properties: [:]) {
                        item.setData(pngData, forType: .png)
                    }
                    pb.writeObjects([item])
                }

                showBadge()
                notify(L10n.str(.notifCopied), L10n.str(.notifNoFile))
            }
        } else {
            let dest = saveDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.moveItem(at: url, to: dest)
            notify(L10n.str(.notifSaved), dest.path)
        }
    }

    // MARK: – ObjC actions

    @objc private func toggleMode()   { clipboardMode.toggle() }
    @objc private func quitApp()      { quit() }
    // MARK: – Launch at Login

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch { }
        DispatchQueue.main.async { [weak self] in self?.rebuildMenu() }
    }

    // MARK: – Cleanup

    func quit() {
        cleanup()
        NSApplication.shared.terminate(nil)
    }

    private func cleanup() {
        watcher?.stop()
        NSStatusBar.system.removeStatusItem(statusItem)
        restoreLocation()
    }

    // MARK: – macOS screenshot defaults

    private func setupInterceptDir() {
        try? FileManager.default.createDirectory(
            at: interceptDir, withIntermediateDirectories: true)
    }

    private func setScreenshotLocation(_ path: String) {
        screencaptureDefaults?.set(path, forKey: "location")
        // Force file-based screenshots so our watcher can intercept them.
        // Without this, "target = clipboard" would bypass file creation entirely.
        screencaptureDefaults?.set("file", forKey: "target")
        syncScreencapturePrefs()
    }

    private func setThumbnailVisible(_ visible: Bool) {
        screencaptureDefaults?.set(visible, forKey: "show-thumbnail")
        syncScreencapturePrefs()
    }

    private func restoreLocation() {
        if originalLocation == interceptDir.path || originalLocation.isEmpty {
            screencaptureDefaults?.removeObject(forKey: "location")
        } else {
            screencaptureDefaults?.set(originalLocation, forKey: "location")
        }
        // Restore original target (e.g. "clipboard") and thumbnail visibility
        screencaptureDefaults?.set(originalTarget, forKey: "target")
        screencaptureDefaults?.set(true, forKey: "show-thumbnail")
        syncScreencapturePrefs()
    }

    private var screencaptureDefaults: UserDefaults? {
        UserDefaults(suiteName: Self.screencaptureDomain)
    }

    private func syncScreencapturePrefs() {
        screencaptureDefaults?.synchronize()
    }

    static func readScreenshotLocation() -> String {
        UserDefaults(suiteName: screencaptureDomain)?.string(forKey: "location")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop").path
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title    = L10n.str(.appName)
        content.subtitle = title
        content.body     = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString,
                                  content: content, trigger: nil))
    }
}

