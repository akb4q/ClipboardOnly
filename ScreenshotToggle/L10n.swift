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

    enum Key: String {
        case appName, toggle, saveLocation, quit, launchAtLogin
        case shortcuts
        case notifCopied, notifNoFile, notifSaved
        case notifVideo, notifVideoMsg, notifError
    }

    private static let strings: [String: [Key: String]] = [
        "zh": [
            .appName:        "截图助手",
            .toggle:         "仅复制到剪贴板（不保存文件）",
            .saveLocation:   "保存位置: %@",
            .launchAtLogin:  "开机自启动",
            .shortcuts:      "截图快捷键：%@  /  %@",
            .quit:           "退出",
            .notifCopied:  "截图已复制到剪贴板",
            .notifNoFile:  "文件未保存",
            .notifSaved:   "截图已保存",
            .notifVideo:   "屏幕录像已保存",
            .notifVideoMsg:"视频无法复制到剪贴板，已保存到: %@",
            .notifError:   "截图处理出错",
        ],
        "en": [
            .appName:        "Screenshot Toggle",
            .toggle:         "Clipboard Only (don't save file)",
            .saveLocation:   "Save to: %@",
            .launchAtLogin:  "Launch at Login",
            .shortcuts:      "Shortcuts: %@  /  %@",
            .quit:           "Quit",
            .notifCopied:  "Screenshot copied to clipboard",
            .notifNoFile:  "No file was saved",
            .notifSaved:   "Screenshot saved",
            .notifVideo:   "Screen recording saved",
            .notifVideoMsg:"Video saved to: %@",
            .notifError:   "Screenshot processing error",
        ],
    ]
}
