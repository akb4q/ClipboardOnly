// PrivacyFilter.swift — regex-based sensitive text detection and replacement

import Foundation

// MARK: – Filter types

enum PrivacyFilterType: String, CaseIterable, Codable {
    case apiKey      = "apiKey"
    case creditCard  = "creditCard"
    case email       = "email"
    case phone       = "phone"
    case idCard      = "idCard"
    case ipAddress   = "ipAddress"
    case password    = "password"

    var placeholder: String {
        switch self {
        case .apiKey:     return "[API_KEY]"
        case .creditCard: return "[CREDIT_CARD]"
        case .email:      return "[EMAIL]"
        case .phone:      return "[PHONE]"
        case .idCard:     return "[ID_CARD]"
        case .ipAddress:  return "[IP_ADDRESS]"
        case .password:   return "[PASSWORD]"
        }
    }
}

// MARK: – Filter result

struct FilterMatch {
    let type: PrivacyFilterType
    /// Range in the *original* input string (UTF-16 NSRange semantics).
    let nsRange: NSRange
    let original: String
}

struct FilterResult {
    let output: String
    let matches: [FilterMatch]
    var didMatch: Bool { !matches.isEmpty }
    var summary: [PrivacyFilterType: Int] {
        matches.reduce(into: [:]) { $0[$1.type, default: 0] += 1 }
    }
}

// MARK: – PrivacyFilter

struct PrivacyFilter {

    var enabledTypes: Set<PrivacyFilterType>

    init(enabledTypes: Set<PrivacyFilterType> = Set(PrivacyFilterType.allCases)) {
        self.enabledTypes = enabledTypes
    }

    func filter(_ text: String) -> FilterResult {
        // 1) Collect all candidate matches from every enabled regex.
        var candidates: [(nsRange: NSRange, type: PrivacyFilterType)] = []
        let fullRange = NSRange(text.startIndex..., in: text)

        for type in PrivacyFilterType.allCases {
            guard enabledTypes.contains(type) else { continue }
            guard let pattern = Self.patterns[type] else { continue }
            for m in pattern.matches(in: text, range: fullRange) {
                guard m.range.location != NSNotFound, m.range.length > 0 else { continue }
                candidates.append((m.range, type))
            }
        }

        // 2) Resolve overlaps with longest-match priority.
        //    Sort by length DESC, then by start ASC — longer wins; ties go to earlier.
        candidates.sort {
            if $0.nsRange.length != $1.nsRange.length {
                return $0.nsRange.length > $1.nsRange.length
            }
            return $0.nsRange.location < $1.nsRange.location
        }

        var accepted: [(nsRange: NSRange, type: PrivacyFilterType)] = []
        for c in candidates {
            let overlaps = accepted.contains { NSIntersectionRange(c.nsRange, $0.nsRange).length > 0 }
            if !overlaps { accepted.append(c) }
        }

        // 3) Apply replacements right-to-left on an NSMutableString so earlier
        //    UTF-16 offsets remain valid. NSRange/NSMutableString avoids any
        //    String.Index aliasing across mutations.
        accepted.sort { $0.nsRange.location > $1.nsRange.location }

        let mutable = NSMutableString(string: text)
        var matches: [FilterMatch] = []
        for item in accepted {
            let original = mutable.substring(with: item.nsRange)
            matches.append(FilterMatch(type: item.type, nsRange: item.nsRange, original: original))
            mutable.replaceCharacters(in: item.nsRange, with: item.type.placeholder)
        }

        // Return matches in ascending original-string order (more useful for callers).
        matches.sort { $0.nsRange.location < $1.nsRange.location }

        return FilterResult(output: mutable as String, matches: matches)
    }

    // MARK: – Regex patterns

    private static let patterns: [PrivacyFilterType: NSRegularExpression] = {
        let defs: [PrivacyFilterType: String] = [

            // API keys — common vendor prefixes followed by a long token
            .apiKey: [
                #"sk-[A-Za-z0-9\-_]{20,}"#,           // OpenAI / Anthropic style
                #"sk-[A-Za-z0-9\-_\.\s]{20,}"#,       // Wrapped / OCR-split OpenAI-style tokens
                #"pk_(?:live|test)_[A-Za-z0-9]{20,}"#, // Stripe
                #"ghp_[A-Za-z0-9]{36}"#,               // GitHub personal token (classic)
                #"gho_[A-Za-z0-9]{36}"#,               // GitHub OAuth
                #"ghu_[A-Za-z0-9]{36}"#,               // GitHub user-to-server
                #"ghs_[A-Za-z0-9]{36}"#,               // GitHub server-to-server
                #"ghr_[A-Za-z0-9]{36}"#,               // GitHub refresh
                #"github_pat_[A-Za-z0-9_]{40,}"#,                // GitHub fine-grained PAT
                #"github_pat_[A-Za-z0-9_\s]{40,}"#,              // OCR-split fine-grained PAT
                #"AKIA[A-Z0-9]{16}"#,                   // AWS access key ID
                #"xox[baprs]-[A-Za-z0-9\-]+"#,         // Slack tokens
                #"AIza[A-Za-z0-9\-_]{35}"#,             // Google API key
                #"(?i)(?:bearer|token|api[_\- ]?key)\s*[=:]\s*[A-Za-z0-9\-_\.]{16,}"#,
            ].joined(separator: "|"),

            // Credit cards — 16-digit patterns with optional separators
            .creditCard: #"\b(?:4[0-9]{3}|5[1-5][0-9]{2}|3[47][0-9]{2}|6(?:011|5[0-9]{2}))[\ \-]?[0-9]{4}[\ \-]?[0-9]{4}[\ \-]?[0-9]{4}\b"#,

            // Email
            .email: #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#,

            // Phone — Chinese mobile (1[3-9]xxxxxxxxx) and common US formats
            .phone: #"(?:\+?86[\s\-]?)?1[3-9]\d{9}|\b(?:\+?1[\s.\-]?)?\(?\d{3}\)?[\s.\-]?\d{3}[\s.\-]?\d{4}\b"#,

            // Chinese national ID card (18 digits, last may be X)
            .idCard: #"\b\d{17}[\dXx]\b"#,

            // IPv4
            .ipAddress: #"\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\b"#,

            // Password / credential fields with Chinese or English labels.
            // Two shapes:
            //   * inline   "密碼: hunter2"  /  "password=...."
            //   * stacked  "密碼\n4016d6"  — form layouts where the label sits
            //              above the input and OCR returns them on separate
            //              lines. Restrict the value to credential-shaped
            //              tokens (must contain a digit) so prose like
            //              "password\nplease help me" doesn't match.
            .password: #"(?i)(?:密码|密碼|口令|password|passwd|passcode|pwd)(?:\s*[:：=]\s*\S{4,}|[ \t]*\n\s*(?=\S*\d)[A-Za-z0-9!@#$%^&*_\-+=]{4,40})"#,
        ]

        return defs.compactMapValues { pattern in
            try? NSRegularExpression(pattern: pattern)
        }
    }()
}

// MARK: – UserDefaults persistence

extension PrivacyFilter {

    private static let enabledTypesKey = "privacyFilterEnabledTypes"
    private static let passwordTypeMigrationKey = "privacyFilterPasswordTypeEnabledByDefault"

    static func loadFromDefaults() -> PrivacyFilter {
        if let data = UserDefaults.standard.data(forKey: enabledTypesKey),
           var types = try? JSONDecoder().decode(Set<PrivacyFilterType>.self, from: data) {
            if !UserDefaults.standard.bool(forKey: passwordTypeMigrationKey) {
                types.insert(.password)
                UserDefaults.standard.set(true, forKey: passwordTypeMigrationKey)
                if let data = try? JSONEncoder().encode(types) {
                    UserDefaults.standard.set(data, forKey: enabledTypesKey)
                }
            }
            return PrivacyFilter(enabledTypes: types)
        }
        UserDefaults.standard.set(true, forKey: passwordTypeMigrationKey)
        return PrivacyFilter()
    }

    func saveToDefaults() {
        if let data = try? JSONEncoder().encode(enabledTypes) {
            UserDefaults.standard.set(data, forKey: Self.enabledTypesKey)
        }
    }
}
