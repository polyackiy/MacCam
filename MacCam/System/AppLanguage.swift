import Foundation

/// The interface languages MacCam ships translations for. The display name is the
/// language's own autonym — always shown in that language, never translated.
enum AppLanguage: String, CaseIterable, Identifiable {
    case en, ru, es, fr, de
    case ptBR = "pt-BR"
    case it
    case zhHans = "zh-Hans"
    case ja

    var id: String { rawValue }

    /// The language's name written in that language.
    var autonym: String {
        switch self {
        case .en: return "English"
        case .ru: return "Русский"
        case .es: return "Español"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .ptBR: return "Português (Brasil)"
        case .it: return "Italiano"
        case .zhHans: return "简体中文"
        case .ja: return "日本語"
        }
    }

    /// Best-effort match of an `AppleLanguages` identifier (e.g. `"fr-FR"`,
    /// `"zh-Hans-CN"`) to a supported language: exact code first, then a
    /// script-qualified prefix, then the two-letter base. Returns nil when the
    /// language isn't one MacCam ships.
    static func match(_ identifier: String) -> AppLanguage? {
        let lower = identifier.lowercased()
        if let exact = allCases.first(where: { $0.rawValue.lowercased() == lower }) {
            return exact
        }
        if let scripted = allCases.first(where: {
            $0.rawValue.contains("-") && lower.hasPrefix($0.rawValue.lowercased() + "-")
        }) {
            return scripted
        }
        let base = String(lower.prefix(2))
        return allCases.first(where: { $0.rawValue == base })
    }
}

/// Reads and writes the per-app language override via the standard
/// `AppleLanguages` key in the app's own preferences — the same mechanism
/// macOS's per-app language setting uses. Takes effect on the next launch.
enum LanguageOverride {
    private static let key = "AppleLanguages"

    /// The explicitly-chosen language, or nil for "follow the system". Reads the
    /// app's *persistent* domain so the system's launch-time language list (in the
    /// argument domain) is not mistaken for an override.
    static func current() -> AppLanguage? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: bundleID),
              let languages = domain[key] as? [String],
              let first = languages.first else { return nil }
        return AppLanguage.match(first)
    }

    /// Persist an override (or remove it for "System default").
    static func set(_ language: AppLanguage?) {
        let defaults = UserDefaults.standard
        if let language {
            defaults.set([language.rawValue], forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
