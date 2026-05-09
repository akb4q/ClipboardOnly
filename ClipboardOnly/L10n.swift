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
        // Privacy filter
        case privacyFilter, privacyFilterRedacted
        case privacyFilterEnabled
        case privacyFilterAPIKey, privacyFilterCreditCard, privacyFilterEmail
        case privacyFilterPhone, privacyFilterIDCard, privacyFilterIP
        case privacyFilterPassword
        case pasteAsPath, pasteAsPathHint
        case obsidianSend, obsidianChooseVault, obsidianVault, obsidianOpenAfterSave
        case obsidianSaved, obsidianUnsupported, obsidianNoVault
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
            .privacyFilter:       "隐私过滤",
            .privacyFilterRedacted: "已过滤 %d 处敏感内容",
            .privacyFilterEnabled:  "启用",
            .privacyFilterAPIKey:    "API Key",
            .privacyFilterCreditCard:"信用卡号",
            .privacyFilterEmail:     "邮箱地址",
            .privacyFilterPhone:     "手机/电话",
            .privacyFilterIDCard:    "身份证号",
            .privacyFilterIP:        "IP 地址",
            .privacyFilterPassword:  "密码/凭据",
            .pasteAsPath:     "粘贴为文件路径（用于 CLI）",
            .pasteAsPathHint: "截图额外缓存为文件，剪贴板同时携带绝对路径，方便 Claude Code 等终端工具读取",
            .obsidianSend:    "发送剪贴板到 Obsidian",
            .obsidianChooseVault: "选择 Obsidian Vault…",
            .obsidianVault:   "Obsidian Vault: %@",
            .obsidianOpenAfterSave: "写入后打开 Obsidian",
            .obsidianSaved:   "已写入 Obsidian",
            .obsidianUnsupported: "剪贴板没有可写入的文字或图片",
            .obsidianNoVault: "请先选择 Obsidian Vault",
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
            .privacyFilter:       "Privacy Filter",
            .privacyFilterRedacted: "%d sensitive item(s) redacted",
            .privacyFilterEnabled:  "Enabled",
            .privacyFilterAPIKey:    "API Keys",
            .privacyFilterCreditCard:"Credit Card Numbers",
            .privacyFilterEmail:     "Email Addresses",
            .privacyFilterPhone:     "Phone Numbers",
            .privacyFilterIDCard:    "ID Card Numbers",
            .privacyFilterIP:        "IP Addresses",
            .privacyFilterPassword:  "Passwords",
            .pasteAsPath:     "Paste as File Path (for CLI)",
            .pasteAsPathHint: "Caches the screenshot to a file and adds its absolute path to the clipboard, so terminals like Claude Code can read it.",
            .obsidianSend:    "Send Clipboard to Obsidian",
            .obsidianChooseVault: "Choose Obsidian Vault…",
            .obsidianVault:   "Obsidian Vault: %@",
            .obsidianOpenAfterSave: "Open in Obsidian after save",
            .obsidianSaved:   "Saved to Obsidian",
            .obsidianUnsupported: "Clipboard has no supported text or image",
            .obsidianNoVault: "Choose an Obsidian Vault first",
        ],
    ]
}
