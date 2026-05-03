// MenuBarController.swift — business logic + owns the NSStatusItem directly

import AppKit
import ImageIO
import ServiceManagement
import SwiftUI
import UserNotifications
import UniformTypeIdentifiers
import Vision

private final class ClickableMenuItemView: NSView {
    weak var target: AnyObject?
    var action: Selector?

    override func mouseDown(with event: NSEvent) {
        guard let target, let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
}

@MainActor
final class MenuBarController: NSObject, ObservableObject, NSMenuDelegate {

    @Published var clipboardMode: Bool {
        didSet {
            UserDefaults.standard.set(clipboardMode, forKey: "clipboardMode")
            setThumbnailVisible(false)
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
    @Published var privacyFilterEnabled: Bool {
        didSet {
            UserDefaults.standard.set(privacyFilterEnabled, forKey: "privacyFilterEnabled")
            if !suppressMenuRebuild {
                DispatchQueue.main.async { [weak self] in self?.rebuildMenu() }
            }
        }
    }
    @Published var pasteAsPathEnabled: Bool {
        didSet {
            UserDefaults.standard.set(pasteAsPathEnabled, forKey: "pasteAsPathEnabled")
            if !pasteAsPathEnabled { ClipboardImageCache.clear() }
            DispatchQueue.main.async { [weak self] in self?.rebuildMenu() }
        }
    }
    @Published private(set) var saveDirectory: URL

    // MARK: – Private state

    private var statusItem: NSStatusItem!
    private var privacyFilter: PrivacyFilter = .loadFromDefaults()
    private var masker: ImagePrivacyMasker = ImagePrivacyMasker()
    private var suppressMenuRebuild = false
    private var privacyFilterExpanded = false

    private let interceptDir: URL
    private let originalLocation: String
    private let originalTarget: String       // "clipboard", "file", "preview", etc.
    private let originalShowThumbnail: Bool?
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

    private struct LoadedScreenshotImage {
        let cgImage: CGImage
        let retainedData: Data
    }

    private static let screencaptureDomain = "com.apple.screencapture"
    private static let interceptPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".clipboard_only/intercept")

    // MARK: – Init

    override init() {
        interceptDir     = Self.interceptPath

        // Read current screencapture defaults, but ignore them if they already
        // point at our intercept dir / "file" — that would mean a previous
        // instance crashed before restoring, and re-reading would permanently
        // overwrite the user's real preferences. Prefer our own persisted copy.
        let liveLocation = Self.readScreenshotLocation()
        let liveTarget   = UserDefaults(suiteName: Self.screencaptureDomain)?
            .string(forKey: "target") ?? "file"
        let liveShowThumbnail = UserDefaults(suiteName: Self.screencaptureDomain)?
            .object(forKey: "show-thumbnail") as? Bool
        let savedLocation = UserDefaults.standard.string(forKey: "originalLocation")
        let savedTarget   = UserDefaults.standard.string(forKey: "originalTarget")
        let savedShowThumbnailWasSet = UserDefaults.standard.object(forKey: "originalShowThumbnailWasSet") as? Bool
        let savedShowThumbnail = UserDefaults.standard.object(forKey: "originalShowThumbnail") as? Bool

        if liveLocation == Self.interceptPath.path, let s = savedLocation {
            originalLocation = s
        } else {
            originalLocation = liveLocation
            UserDefaults.standard.set(liveLocation, forKey: "originalLocation")
        }

        // If liveTarget is "file", we can't tell whether the user originally
        // wanted "file" or whether our previous instance set it — fall back to
        // saved value if we have one.
        if let s = savedTarget, liveTarget == "file" {
            originalTarget = s
        } else {
            originalTarget = liveTarget
            UserDefaults.standard.set(liveTarget, forKey: "originalTarget")
        }

        if liveLocation == Self.interceptPath.path, let wasSet = savedShowThumbnailWasSet {
            originalShowThumbnail = wasSet ? savedShowThumbnail : nil
        } else {
            originalShowThumbnail = liveShowThumbnail
            if let liveShowThumbnail {
                UserDefaults.standard.set(true, forKey: "originalShowThumbnailWasSet")
                UserDefaults.standard.set(liveShowThumbnail, forKey: "originalShowThumbnail")
            } else {
                UserDefaults.standard.set(false, forKey: "originalShowThumbnailWasSet")
                UserDefaults.standard.removeObject(forKey: "originalShowThumbnail")
            }
        }

        clipboardMode          = UserDefaults.standard.bool(forKey: "clipboardMode")
        autoOCREnabled         = UserDefaults.standard.object(forKey: "autoOCREnabled") as? Bool ?? true
        privacyFilterEnabled   = UserDefaults.standard.object(forKey: "privacyFilterEnabled") as? Bool ?? true
        pasteAsPathEnabled     = UserDefaults.standard.bool(forKey: "pasteAsPathEnabled")

        let saved = originalLocation == Self.interceptPath.path
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            : URL(fileURLWithPath: originalLocation)
        saveDirectory = saved

        super.init()

        privacyFilter = .loadFromDefaults()
        masker = ImagePrivacyMasker(filter: privacyFilter)

        setupInterceptDir()
        setScreenshotLocation(interceptDir.path)
        setThumbnailVisible(false)
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

        let pathItem = NSMenuItem(
            title: L10n.str(.pasteAsPath),
            action: #selector(togglePasteAsPath),
            keyEquivalent: ""
        )
        pathItem.state = pasteAsPathEnabled ? .on : .off
        pathItem.target = self
        pathItem.toolTip = L10n.str(.pasteAsPathHint)
        menu.addItem(pathItem)

        menu.addItem(makePrivacyDisclosureItem())
        if privacyFilterExpanded {
            menu.addItem(makePrivacyEnabledItem())
            menu.addItem(makePrivacySubItem(.privacyFilterAPIKey,     type: .apiKey))
            menu.addItem(makePrivacySubItem(.privacyFilterCreditCard, type: .creditCard))
            menu.addItem(makePrivacySubItem(.privacyFilterEmail,      type: .email))
            menu.addItem(makePrivacySubItem(.privacyFilterPhone,      type: .phone))
            menu.addItem(makePrivacySubItem(.privacyFilterIDCard,     type: .idCard))
            menu.addItem(makePrivacySubItem(.privacyFilterIP,         type: .ipAddress))
            menu.addItem(makePrivacySubItem(.privacyFilterPassword,   type: .password))
        }

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
                    // External clipboard write — the cached image (if any) is
                    // no longer referenced, drop it from disk immediately.
                    ClipboardImageCache.clear()
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

    private func performOCR(
        on cgImage: CGImage,
        retainedData: Data? = nil,
        completion: @escaping (String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [retainedData] in
            autoreleasepool {
                withExtendedLifetime(retainedData) {
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

    /// Anthropic / most multimodal LLMs resize the long edge to 1568 px before
    /// scoring, so anything larger pays upload bandwidth + 5 MB hard-cap risk
    /// for zero benefit. Pre-resizing to this exact threshold matches what the
    /// server would do anyway — no additional quality loss vs sending the
    /// original — and slashes token cost (cost is proportional to pixel count).
    /// Skipped for images already within the cap.
    private static let llmMaxLongEdge: CGFloat = 1568

    private static func resizedForLLM(_ cgImage: CGImage) -> CGImage {
        return autoreleasepool {
            resized(cgImage, maxLongEdge: llmMaxLongEdge) ?? cgImage
        }
    }

    private static func loadedScreenshotImage(from url: URL) -> LoadedScreenshotImage? {
        return autoreleasepool {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
            return LoadedScreenshotImage(cgImage: cgImage, retainedData: data)
        }
    }

    private static func resized(_ cgImage: CGImage, maxLongEdge: CGFloat) -> CGImage? {
        let pxW = CGFloat(cgImage.width)
        let pxH = CGFloat(cgImage.height)
        let longEdge = max(pxW, pxH)
        guard longEdge > maxLongEdge else { return cgImage }

        let scale = maxLongEdge / longEdge
        let newW = Int((pxW * scale).rounded())
        let newH = Int((pxH * scale).rounded())

        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: newW, height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }

    private static func pngData(from cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func thumbnailImage(from cgImage: CGImage) -> NSImage {
        return autoreleasepool {
            let thumbCG = resized(cgImage, maxLongEdge: 250) ?? cgImage
            return NSImage(
                cgImage: thumbCG,
                size: NSSize(width: thumbCG.width, height: thumbCG.height)
            )
        }
    }

    private func currentClipboardCGImage() -> CGImage? {
        guard let pngData = NSPasteboard.general.data(forType: .png) else { return nil }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
    }

    private func writeImageToClipboard(
        _ cgImage: CGImage,
        retainedData: Data? = nil,
        recognizedText: String? = nil
    ) -> Int? {
        return withExtendedLifetime(retainedData) {
            autoreleasepool {
                // Resize down to LLM-friendly dimensions before any encoding. Privacy
                // mask already ran on the full-resolution image (best OCR), so OCR-text
                // accuracy is preserved; only the bytes that hit the clipboard / cache
                // file are smaller.
                let outImage = Self.resizedForLLM(cgImage)
                guard let pngData = Self.pngData(from: outImage) else { return nil }

                // Roll the on-disk cache for "paste as path" mode. Always clear the
                // previous file first; only re-create it when path mode is on.
                ClipboardImageCache.clear()

                let item = NSPasteboardItem()
                item.setData(pngData, forType: .png)

                if pasteAsPathEnabled, let cachedURL = ClipboardImageCache.write(pngData) {
                    // Path mode wins over OCR text for the plain-text slot — terminals
                    // need an absolute path on Cmd+V. OCR text is still kept in
                    // lastOCRText and surfaced via the menu preview.
                    item.setString(cachedURL.absoluteString, forType: .fileURL)
                    item.setString(cachedURL.path, forType: .string)
                } else if let recognizedText, !recognizedText.isEmpty {
                    item.setString(recognizedText, forType: .string)
                }

                let pb = NSPasteboard.general
                pb.clearContents()
                guard pb.writeObjects([item]) else { return nil }
                return pb.changeCount
            }
        }
    }

    private func writeTextToClipboard(_ text: String) -> Int? {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string) else { return nil }
        return pb.changeCount
    }

    private func showManualOCRPanel(for image: CGImage, retainedData: Data? = nil, changeCount: Int) {
        manualOCRImage = withExtendedLifetime(retainedData) {
            Self.thumbnailImage(from: image)
        }
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
        guard let changeCount = manualOCRChangeCount,
              let image = currentClipboardCGImage() else { return }
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

                if let normalizedText, !normalizedText.isEmpty {
                    let finalText = self.privacyFilterEnabled
                        ? self.privacyFilter.filter(normalizedText).output
                        : normalizedText
                    if self.pasteAsPathEnabled {
                        // Keep the path on the clipboard; expose OCR text only
                        // through the menu (click-to-copy).
                        self.lastOCRText = finalText
                        self.ocrChangeCount = changeCount
                        self.manualOCRChangeCount = changeCount
                        self.manualOCRPanelController?.refresh()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                            self?.dismissManualOCRPanel()
                        }
                    } else if let newChangeCount = self.writeTextToClipboard(finalText) {
                        self.lastChangeCount = newChangeCount
                        self.ocrChangeCount = newChangeCount
                        self.lastOCRText = finalText
                        self.manualOCRChangeCount = newChangeCount
                        self.manualOCRPanelController?.refresh()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                            self?.dismissManualOCRPanel()
                        }
                    }
                } else {
                    self.ocrChangeCount = changeCount
                    self.lastOCRText = nil
                    self.manualOCRPanelController?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                        self?.dismissManualOCRPanel()
                    }
                }

                self.refreshMenuDisplay()
            }
        }
    }

    private func startOCRForClipboardImage(
        _ image: CGImage,
        retainedData: Data? = nil,
        sourceChangeCount: Int
    ) {
        guard autoOCREnabled else { return }

        lastOCRText = nil
        ocrInFlightChangeCount = sourceChangeCount
        refreshMenuDisplay()

        performOCR(on: image, retainedData: retainedData) { [weak self] text in
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

                if let normalizedText, !normalizedText.isEmpty {
                    let finalText = self.privacyFilterEnabled
                        ? self.privacyFilter.filter(normalizedText).output
                        : normalizedText
                    if self.pasteAsPathEnabled {
                        self.lastOCRText = finalText
                        self.ocrChangeCount = sourceChangeCount
                    } else if let newChangeCount = self.writeTextToClipboard(finalText) {
                        self.lastChangeCount = newChangeCount
                        self.ocrChangeCount = newChangeCount
                        self.lastOCRText = finalText
                    }
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

        // Reject symlinks and anything that isn't a regular file.
        // Without this, an attacker could plant ~/.clipboard_only/intercept/x.png
        // as a symlink to ~/.ssh/id_rsa and we'd move/read the target.
        var st = stat()
        guard lstat(url.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG else { return }

        // Resolve and verify the file is still inside the intercept directory.
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let interceptRoot = interceptDir.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(interceptRoot + "/") else { return }

        let ext = url.pathExtension.lowercased()

        if clipboardMode {
            if ["mov", "mp4"].contains(ext) {
                let dest = saveDirectory.appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.moveItem(at: url, to: dest)
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                    notify(L10n.str(.notifVideo),
                           String(format: L10n.str(.notifVideoMsg), url.lastPathComponent))
                } catch {
                    notify(L10n.str(.notifError), error.localizedDescription)
                }
            } else {
                guard let image = Self.loadedScreenshotImage(from: url) else { return }
                try? FileManager.default.removeItem(at: url)

                if privacyFilterEnabled {
                    masker.mask(
                        image.cgImage,
                        retainedData: image.retainedData,
                        maxOutputLongEdge: Self.llmMaxLongEdge
                    ) { [weak self] maskedImage in
                        autoreleasepool {
                            guard let self else { return }
                            guard let maskedImage else {
                                // Fail closed: do NOT fall back to the unmasked image,
                                // since that would defeat the privacy guarantee.
                                self.notify(L10n.str(.notifError), L10n.str(.notifNoFile))
                                return
                            }
                            self.writeAndHandleImage(
                                maskedImage,
                                ocrImage: image.cgImage,
                                ocrRetainedData: image.retainedData
                            )
                        }
                    }
                } else {
                    writeAndHandleImage(image.cgImage, retainedData: image.retainedData)
                }
            }
        } else {
            let dest = saveDirectory.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: url, to: dest)
                notify(L10n.str(.notifSaved), dest.path)
            } catch {
                notify(L10n.str(.notifError), error.localizedDescription)
            }
        }
    }

    private func writeAndHandleImage(
        _ image: CGImage,
        retainedData: Data? = nil,
        ocrImage: CGImage? = nil,
        ocrRetainedData: Data? = nil
    ) {
        guard let newChangeCount = writeImageToClipboard(image, retainedData: retainedData) else {
            notify(L10n.str(.notifError), L10n.str(.notifNoFile))
            return
        }
        clipboardChangedSinceLaunch = true
        lastChangeCount = newChangeCount
        if autoOCREnabled {
            dismissManualOCRPanel()
            startOCRForClipboardImage(
                ocrImage ?? image,
                retainedData: ocrRetainedData ?? retainedData,
                sourceChangeCount: newChangeCount
            )
        } else {
            resetOCRState()
            showManualOCRPanel(for: image, retainedData: retainedData, changeCount: newChangeCount)
            refreshMenuDisplay()
        }
        notify(L10n.str(.notifCopied), L10n.str(.notifNoFile))
    }

    // MARK: – ObjC actions

    @objc private func toggleMode()          { clipboardMode.toggle() }
    @objc private func toggleAutoOCR()       { autoOCREnabled.toggle() }
    @objc private func togglePrivacyFilter() { privacyFilterEnabled.toggle() }
    @objc private func togglePasteAsPath()   { pasteAsPathEnabled.toggle() }
    @objc private func quitApp()             { quit() }

    @objc private func togglePrivacyFilterButton(_ sender: NSButton) {
        suppressMenuRebuild = true
        privacyFilterEnabled = sender.state == .on
        suppressMenuRebuild = false
    }

    @objc private func togglePrivacyFilterExpanded(_ sender: Any) {
        privacyFilterExpanded.toggle()
        refreshMenuDisplay()
    }

    @objc private func togglePrivacyFilterTypeButton(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let type = PrivacyFilterType(rawValue: raw) else { return }
        if privacyFilter.enabledTypes.contains(type) {
            privacyFilter.enabledTypes.remove(type)
        } else {
            privacyFilter.enabledTypes.insert(type)
        }
        privacyFilter.saveToDefaults()
        masker.filter = privacyFilter
        if let swatchView = sender.superview?.subviews.compactMap({ $0 as? NSImageView }).first {
            swatchView.image = Self.makePrivacySwatch(
                color: type.redactionColor,
                filled: privacyFilter.enabledTypes.contains(type)
            )
        }
    }

    // MARK: – Menu item builders

    private func makePrivacyDisclosureItem() -> NSMenuItem {
        let arrowView = NSImageView(frame: NSRect(x: 8, y: 12, width: 8, height: 8))
        arrowView.image = Self.makeDisclosureArrow(expanded: privacyFilterExpanded)
        arrowView.imageScaling = .scaleNone

        let titleLabel = NSTextField(labelWithString: L10n.str(.privacyFilter))
        titleLabel.frame = NSRect(x: 22, y: 4, width: 218, height: 20)
        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor

        let container = ClickableMenuItemView(frame: NSRect(x: 0, y: 0, width: 252, height: 28))
        container.target = self
        container.action = #selector(togglePrivacyFilterExpanded(_:))
        container.addSubview(arrowView)
        container.addSubview(titleLabel)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private static func makeDisclosureArrow(expanded: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()

        let path = NSBezierPath()
        if expanded {
            path.move(to: NSPoint(x: 1, y: 5.5))
            path.line(to: NSPoint(x: 7, y: 5.5))
            path.line(to: NSPoint(x: 4, y: 2))
        } else {
            path.move(to: NSPoint(x: 2, y: 1))
            path.line(to: NSPoint(x: 2, y: 7))
            path.line(to: NSPoint(x: 5.5, y: 4))
        }
        path.close()
        NSColor.secondaryLabelColor.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    private func makePrivacyEnabledItem() -> NSMenuItem {
        let button = NSButton(checkboxWithTitle: L10n.str(.privacyFilterEnabled), target: self, action: #selector(togglePrivacyFilterButton(_:)))
        button.frame = NSRect(x: 28, y: 2, width: 212, height: 22)
        button.state = privacyFilterEnabled ? .on : .off
        button.font = NSFont.menuFont(ofSize: 0)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 252, height: 26))
        container.addSubview(button)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func makePrivacySubItem(_ titleKey: L10n.Key, type: PrivacyFilterType) -> NSMenuItem {
        let isEnabled = privacyFilter.enabledTypes.contains(type)
        let swatchView = NSImageView(frame: NSRect(x: 30, y: 6, width: 14, height: 14))
        swatchView.image = Self.makePrivacySwatch(color: type.redactionColor, filled: isEnabled)

        let button = NSButton(title: L10n.str(titleKey), target: self, action: #selector(togglePrivacyFilterTypeButton(_:)))
        button.frame = NSRect(x: 48, y: 2, width: 192, height: 22)
        button.identifier = NSUserInterfaceItemIdentifier(type.rawValue)
        button.isBordered = false
        button.alignment = .left
        button.font = NSFont.menuFont(ofSize: 0)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 252, height: 26))
        container.addSubview(swatchView)
        container.addSubview(button)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private static func makePrivacySwatch(color: NSColor, filled: Bool) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(x: 2.5, y: 2.5, width: 9, height: 9)
        let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
        (filled ? color : NSColor.windowBackgroundColor).setFill()
        path.fill()

        color.setStroke()
        path.lineWidth = 1.6
        path.stroke()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

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
        // Don't leave a screenshot on disk after the app quits — the user's
        // mental model is "ClipboardOnly = no leftover files".
        ClipboardImageCache.clear()
    }

    // MARK: – macOS screenshot defaults

    private func setupInterceptDir() {
        let fm = FileManager.default
        let path = interceptDir.path

        // Reject symlinks at either path component to defeat pre-launch redirection.
        // lstat does NOT follow symlinks, so we can detect a planted link.
        let parent = interceptDir.deletingLastPathComponent().path
        for p in [parent, path] {
            var st = stat()
            if lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                try? fm.removeItem(atPath: p)
            }
        }

        try? fm.createDirectory(
            at: interceptDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Tighten permissions even if the directory already existed.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
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
        if let originalShowThumbnail {
            screencaptureDefaults?.set(originalShowThumbnail, forKey: "show-thumbnail")
        } else {
            screencaptureDefaults?.removeObject(forKey: "show-thumbnail")
        }
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


@MainActor
private final class OCRQuickActionPanelController: NSObject {
    private let controller: MenuBarController
    private let panel: NSPanel
    private let contentView: OCRThumbnailView

    init(controller: MenuBarController) {
        self.controller = controller
        self.contentView = OCRThumbnailView()
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 154),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = contentView
        contentView.onTap = { [weak controller] in controller?.triggerManualOCR() }
    }

    func show() {
        let img = controller.manualOCRThumbnail
        contentView.setImage(img)
        contentView.setOCRIconHidden(controller.pasteAsPathEnabled)

        // Compute panel size from image, capping at maxW×maxH, never upscaling
        let maxW: CGFloat = 250
        let maxH: CGFloat = 200
        let panelSize: NSSize
        if let img, img.size.width > 0 {
            let scale = min(maxW / img.size.width, maxH / img.size.height, 1.0)
            panelSize = NSSize(width: img.size.width * scale, height: img.size.height * scale)
        } else {
            panelSize = NSSize(width: maxW, height: 141)
        }
        panel.setContentSize(panelSize)
        contentView.frame = NSRect(origin: .zero, size: panelSize)

        positionPanel()
        let targetFrame = panel.frame
        var startFrame = targetFrame
        startFrame.origin.x += targetFrame.width + 40
        panel.setFrame(startFrame, display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel.animator().setFrame(targetFrame, display: true)
        }
    }

    func refresh() {
        contentView.setImage(controller.manualOCRThumbnail)
        contentView.setOCRIconHidden(controller.pasteAsPathEnabled)
    }

    func close() {
        let currentFrame = panel.frame
        var endFrame = currentFrame
        endFrame.origin.x += currentFrame.width + 40
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.panel.animator().setFrame(endFrame, display: true)
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.setFrame(currentFrame, display: false)
        })
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 28, y: frame.minY + 28))
    }
}

/// Pure-AppKit thumbnail view — no SwiftUI, no constraint conflicts.
private final class OCRThumbnailView: NSView {
    var onTap: (() -> Void)?

    private let imageView = NSImageView()
    private let iconView = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleNone
        iconView.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.55)
            s.shadowBlurRadius = 4
            s.shadowOffset = .zero
            return s
        }()
        iconView.autoresizingMask = [.minXMargin, .maxYMargin]
        addSubview(iconView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: NSImage?) {
        imageView.image = image
    }

    func setOCRIconHidden(_ hidden: Bool) {
        iconView.isHidden = hidden
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        let iconSize: CGFloat = 28
        let margin: CGFloat = 8
        iconView.frame = NSRect(
            x: bounds.maxX - iconSize - margin,
            y: bounds.minY + margin,
            width: iconSize, height: iconSize
        )
    }

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }
}
