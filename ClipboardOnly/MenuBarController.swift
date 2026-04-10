// MenuBarController.swift — business logic + owns the NSStatusItem directly

import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications
import Vision

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
    @Published var autoOCREnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoOCREnabled, forKey: "autoOCREnabled")
            if !autoOCREnabled { resetOCRState() }
            dismissManualOCRPanel()
            DispatchQueue.main.async { [weak self] in self?.rebuildMenu() }
        }
    }
    @Published private(set) var saveDirectory: URL

    // MARK: – Private state

    private var statusItem: NSStatusItem!

    private let interceptDir: URL
    private let originalLocation: String
    private let originalTarget: String       // "clipboard", "file", "preview", etc.
    private var watcher: ScreenshotWatcher?
    private var clipboardPollTimer: Timer?
    private var lastChangeCount: Int = 0
    private var clipboardChangedSinceLaunch = false
    private var lastOCRText: String?
    private var ocrChangeCount: Int = 0
    private var ocrInFlightChangeCount: Int?
    private var manualOCRImage: NSImage?
    private var manualOCRChangeCount: Int?
    private var manualOCRPanelController: OCRQuickActionPanelController?
    private var pasteEventMonitor: Any?
    private var manualOCRClickMonitor: Any?
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
        autoOCREnabled   = UserDefaults.standard.object(forKey: "autoOCREnabled") as? Bool ?? true

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

        startClipboardPoll()
        startPasteEventMonitor()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cleanup() }
        }
    }

    deinit {
        if let pasteEventMonitor {
            NSEvent.removeMonitor(pasteEventMonitor)
        }
        if let manualOCRClickMonitor {
            NSEvent.removeMonitor(manualOCRClickMonitor)
        }
    }

    // MARK: – Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateButton()
        rebuildMenu()
    }

    private func updateButton() {
        let img = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
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

        let autoOCRItem = NSMenuItem(
            title: L10n.str(.autoOCR),
            action: #selector(toggleAutoOCR),
            keyEquivalent: ""
        )
        autoOCRItem.state = autoOCREnabled ? .on : .off
        autoOCRItem.target = self
        menu.addItem(autoOCRItem)

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
        guard clipboardChangedSinceLaunch else {
            let emptyItem = NSMenuItem(
                title: "  (\(L10n.str(.clipboardEmpty)))",
                action: nil, keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

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

            let currentCC = pb.changeCount
            if autoOCREnabled {
                menu.addItem(.separator())

                if ocrInFlightChangeCount == currentCC && lastOCRText == nil {
                    let loadingItem = NSMenuItem(
                        title: "  " + L10n.str(.ocrRecognizing),
                        action: nil,
                        keyEquivalent: ""
                    )
                    loadingItem.isEnabled = false
                    menu.addItem(loadingItem)
                } else if ocrChangeCount == currentCC {
                    if let ocrText = lastOCRText, !ocrText.isEmpty {
                        let ocrHeader = NSMenuItem(
                            title: "  📝 " + L10n.str(.ocrCopyHint),
                            action: #selector(copyOCRText),
                            keyEquivalent: ""
                        )
                        ocrHeader.target = self
                        menu.addItem(ocrHeader)

                        let preview = ocrText.count > 200 ? String(ocrText.prefix(200)) + "…" : ocrText
                        let lines = preview.components(separatedBy: .newlines).prefix(4)
                        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                            let lineItem = NSMenuItem(title: "    " + line, action: nil, keyEquivalent: "")
                            lineItem.isEnabled = false
                            menu.addItem(lineItem)
                        }
                    } else {
                        let emptyOCRItem = NSMenuItem(
                            title: "  " + L10n.str(.ocrEmpty),
                            action: nil,
                            keyEquivalent: ""
                        )
                        emptyOCRItem.isEnabled = false
                        menu.addItem(emptyOCRItem)
                    }
                }
            }
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

    // MARK: – Clipboard bounce（剪贴板变化 → 图标 bounce 动画）

    private func startClipboardPoll() {
        lastChangeCount = NSPasteboard.general.changeCount
        clipboardPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let current = NSPasteboard.general.changeCount
                if current != self.lastChangeCount {
                    self.lastChangeCount = current
                    self.clipboardChangedSinceLaunch = true
                    if self.ocrInFlightChangeCount != current && self.ocrChangeCount != current {
                        self.resetOCRState()
                    }
                    if self.manualOCRChangeCount != current {
                        self.dismissManualOCRPanel()
                    }
                    self.bounceIcon()
                }
            }
        }
    }

    private func startPasteEventMonitor() {
        pasteEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isPasteShortcut =
                event.modifierFlags.contains(.command) &&
                (event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v")
            guard isPasteShortcut else { return }

            Task { @MainActor [weak self] in
                guard let self, self.manualOCRPanelController != nil else { return }
                self.dismissManualOCRPanel()
            }
        }

        manualOCRClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.manualOCRPanelController != nil else { return }
                self.dismissManualOCRPanel()
            }
        }
    }

    // MARK: – OCR (Vision framework)

    private func performOCR(on image: NSImage, completion: @escaping (String?) -> Void) {
        guard let tiffData = image.tiffRepresentation,
              let cgImage = NSBitmapImageRep(data: tiffData)?.cgImage else {
            completion(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation] else {
                    completion(nil)
                    return
                }
                let text = observations.compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                completion(text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    private func refreshMenuDisplay() {
        guard let menu = statusItem.menu else {
            rebuildMenu()
            return
        }

        menu.removeAllItems()
        populateMenu(menu)
    }

    private func resetOCRState() {
        lastOCRText = nil
        ocrChangeCount = 0
        ocrInFlightChangeCount = nil
    }

    private func writeImageToClipboard(_ image: NSImage, recognizedText: String? = nil) -> Int? {
        guard let tiffData = image.tiffRepresentation else { return nil }

        let item = NSPasteboardItem()
        item.setData(tiffData, forType: .tiff)
        if let rep = NSBitmapImageRep(data: tiffData),
           let pngData = rep.representation(using: .png, properties: [:]) {
            item.setData(pngData, forType: .png)
        }
        if let recognizedText, !recognizedText.isEmpty {
            item.setString(recognizedText, forType: .string)
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.writeObjects([item]) else { return nil }
        return pb.changeCount
    }

    private func writeTextToClipboard(_ text: String) -> Int? {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string) else { return nil }
        return pb.changeCount
    }

    private func showManualOCRPanel(for image: NSImage, changeCount: Int) {
        manualOCRImage = image
        manualOCRChangeCount = changeCount

        if manualOCRPanelController == nil {
            manualOCRPanelController = OCRQuickActionPanelController(controller: self)
        }
        manualOCRPanelController?.show()
    }

    private func dismissManualOCRPanel() {
        manualOCRImage = nil
        manualOCRChangeCount = nil
        manualOCRPanelController?.close()
        manualOCRPanelController = nil
    }

    fileprivate var manualOCRThumbnail: NSImage? { manualOCRImage }

    fileprivate func manualOCRButtonTitle() -> String {
        if let current = manualOCRChangeCount, current == ocrInFlightChangeCount {
            return L10n.str(.ocrQuickActionBusy)
        }
        if let current = manualOCRChangeCount, current == ocrChangeCount, lastOCRText != nil {
            return L10n.str(.ocrQuickActionDone)
        }
        return L10n.str(.ocrQuickAction)
    }

    fileprivate func manualOCRPreviewText() -> String? {
        guard let current = manualOCRChangeCount,
              current == ocrChangeCount,
              let lastOCRText,
              !lastOCRText.isEmpty else { return nil }

        let collapsed = lastOCRText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "  ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 54 ? String(collapsed.prefix(54)) + "…" : collapsed
    }

    fileprivate func triggerManualOCR() {
        guard let image = manualOCRImage, let changeCount = manualOCRChangeCount else { return }
        guard ocrInFlightChangeCount != changeCount else { return }

        lastOCRText = nil
        ocrInFlightChangeCount = changeCount
        manualOCRPanelController?.refresh()
        refreshMenuDisplay()

        performOCR(on: image) { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                guard self.ocrInFlightChangeCount == changeCount else { return }

                let normalizedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.ocrInFlightChangeCount = nil

                let pb = NSPasteboard.general
                guard pb.changeCount == changeCount else {
                    self.resetOCRState()
                    self.dismissManualOCRPanel()
                    self.refreshMenuDisplay()
                    return
                }

                if let normalizedText, !normalizedText.isEmpty,
                   let newChangeCount = self.writeTextToClipboard(normalizedText) {
                    self.lastChangeCount = newChangeCount
                    self.ocrChangeCount = newChangeCount
                    self.lastOCRText = normalizedText
                    self.manualOCRChangeCount = newChangeCount
                    self.manualOCRPanelController?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                        self?.dismissManualOCRPanel()
                    }
                } else {
                    self.ocrChangeCount = changeCount
                    self.lastOCRText = nil
                    self.manualOCRPanelController?.refresh()
                }

                self.refreshMenuDisplay()
            }
        }
    }

    private func startOCRForClipboardImage(_ image: NSImage, sourceChangeCount: Int) {
        guard autoOCREnabled else { return }

        lastOCRText = nil
        ocrInFlightChangeCount = sourceChangeCount
        refreshMenuDisplay()

        performOCR(on: image) { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                guard self.ocrInFlightChangeCount == sourceChangeCount else { return }

                let normalizedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.ocrInFlightChangeCount = nil

                let pb = NSPasteboard.general
                guard pb.changeCount == sourceChangeCount else {
                    self.resetOCRState()
                    self.refreshMenuDisplay()
                    return
                }

                if let normalizedText, !normalizedText.isEmpty,
                   let newChangeCount = self.writeTextToClipboard(normalizedText) {
                    self.lastChangeCount = newChangeCount
                    self.ocrChangeCount = newChangeCount
                    self.lastOCRText = normalizedText
                } else {
                    self.ocrChangeCount = sourceChangeCount
                    self.lastOCRText = nil
                }

                self.refreshMenuDisplay()
            }
        }
    }

    @objc private func copyOCRText() {
        guard let text = lastOCRText, !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func bounceIcon() {
        // Animation removed; icon stays static.
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
                guard let newChangeCount = writeImageToClipboard(image) else {
                    notify(L10n.str(.notifError), L10n.str(.notifNoFile))
                    return
                }

                try? FileManager.default.removeItem(at: url)

                clipboardChangedSinceLaunch = true
                lastChangeCount = newChangeCount
                if autoOCREnabled {
                    dismissManualOCRPanel()
                    startOCRForClipboardImage(image, sourceChangeCount: newChangeCount)
                } else {
                    resetOCRState()
                    showManualOCRPanel(for: image, changeCount: newChangeCount)
                    refreshMenuDisplay()
                }

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
    @objc private func toggleAutoOCR() { autoOCREnabled.toggle() }
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
        clipboardPollTimer?.invalidate()
        if let pasteEventMonitor {
            NSEvent.removeMonitor(pasteEventMonitor)
            self.pasteEventMonitor = nil
        }
        if let manualOCRClickMonitor {
            NSEvent.removeMonitor(manualOCRClickMonitor)
            self.manualOCRClickMonitor = nil
        }
        dismissManualOCRPanel()
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


private final class OCRQuickActionPanelController: NSObject {
    private let controller: MenuBarController
    private let panel: NSPanel
    private let hostingView: NSHostingView<OCRQuickActionView>

    init(controller: MenuBarController) {
        self.controller = controller
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 154),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.hostingView = NSHostingView(rootView: OCRQuickActionView(controller: controller))
        super.init()

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = hostingView
    }

    func show() {
        refresh()
        positionPanel()
        panel.orderFrontRegardless()
    }

    func refresh() {
        hostingView.rootView = OCRQuickActionView(controller: controller)
    }

    func close() {
        panel.orderOut(nil)
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.maxX - size.width - 28
        let y = frame.minY + 28
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct OCRQuickActionView: View {
    let controller: MenuBarController

    var body: some View {
        Button(action: controller.triggerManualOCR) {
            ZStack(alignment: .bottomTrailing) {
                if let preview = controller.manualOCRPreviewText() {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.10), radius: 10, y: 4)

                        Text(preview)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.82))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                    .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 74)
                }

                Image(systemName: "text.viewfinder")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .padding(14)
            .frame(width: 250)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial)
                    if let thumbnail = controller.manualOCRThumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 160, height: 90)
                            .cornerRadius(8)
                            .opacity(0.35)
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(controller.manualOCRButtonTitle() == L10n.str(.ocrQuickActionBusy))
    }
}
