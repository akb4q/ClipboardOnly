// L10n.swift — compile-time localization, auto-detects system language

import Foundation

enum L10n {
    static let lang: String = {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? "zh" : "en"
    }()

    static func str(_ key: Key) -> String {
        strings[lang]?[key] ?? strings["en"]![key] ?? key.rawValue
    }

    static var isZH: Bool { lang == "zh" }

    enum Key: String {
        case appName, toggle, saveLocation, quit, launchAtLogin
        case shortcuts
        case autoOCR, ocrSection, ocrCopyHint, ocrRecognizing, ocrEmpty
        case ocrQuickAction, ocrQuickActionBusy, ocrQuickActionDone
        case notifCopied, notifNoFile, notifSaved
        case notifVideo, notifVideoMsg, notifError
        case clipboardEmpty, characters
    }

    private static let strings: [String: [Key: String]] = [
        "zh": [
            .appName:        "ClipboardOnly",
            .toggle:         "仅复制到剪贴板（不保存文件）",
            .saveLocation:   "保存位置: %@",
            .launchAtLogin:  "开机自启动",
            .shortcuts:      "截图快捷键：%@  /  %@",
            .autoOCR:        "自动 OCR 识别截图并复制文字",
            .ocrSection:     "识别文字",
            .ocrCopyHint:    "识别文字（点击复制）",
            .ocrRecognizing: "正在识别图片文字…",
            .ocrEmpty:       "未识别到文字",
            .ocrQuickAction: "OCR 当前截图",
            .ocrQuickActionBusy: "正在 OCR…",
            .ocrQuickActionDone: "已复制文字",
            .quit:           "退出",
            .notifCopied:  "截图已复制到剪贴板",
            .notifNoFile:  "文件未保存",
            .notifSaved:   "截图已保存",
            .notifVideo:   "屏幕录像已保存",
            .notifVideoMsg:"视频无法复制到剪贴板，已保存到: %@",
            .notifError:   "截图处理出错",
            .clipboardEmpty: "剪贴板为空",
            .characters:   "%d 个字符",
        ],
        "en": [
            .appName:        "ClipboardOnly",
            .toggle:         "Clipboard Only (don't save file)",
            .saveLocation:   "Save to: %@",
            .launchAtLogin:  "Launch at Login",
            .shortcuts:      "Shortcuts: %@  /  %@",
            .autoOCR:        "Auto OCR for screenshots && copy",
            .ocrSection:     "OCR Text",
            .ocrCopyHint:    "OCR Text (click to copy)",
            .ocrRecognizing: "Recognizing text from image…",
            .ocrEmpty:       "No text detected",
            .ocrQuickAction: "OCR This Screenshot",
            .ocrQuickActionBusy: "Running OCR…",
            .ocrQuickActionDone: "Text copied",
            .quit:           "Quit",
            .notifCopied:  "Screenshot copied to clipboard",
            .notifNoFile:  "No file was saved",
            .notifSaved:   "Screenshot saved",
            .notifVideo:   "Screen recording saved",
            .notifVideoMsg:"Video saved to: %@",
            .notifError:   "Screenshot processing error",
            .clipboardEmpty: "Clipboard empty",
            .characters:   "%d characters",
        ],
    ]
}
