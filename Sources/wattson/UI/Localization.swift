import Foundation

enum Language: String, Codable, CaseIterable {
    case system, english, chinese

    var displayName: String {
        switch self {
        case .system:  return L("System", "跟随系统")
        case .english: return "English"
        case .chinese: return "中文"
        }
    }
}

/// Which language the UI is currently drawn in.
///
/// A plain global rather than an environment value: every view already observes
/// `AppModel`, so changing the setting redraws them, and the redraw re-evaluates
/// each `L(...)` call against the new value.
///
/// Unchecked because it is written once, from the main thread, when the user
/// picks a language, and only ever read thereafter.
nonisolated(unsafe) var activeLanguage: Language = .system

/// Inline bilingual string. Keeping both languages at the call site means there
/// are no keys to keep in sync with a separate table, and the English source
/// text stays readable in the code.
func L(_ en: String, _ zh: String) -> String {
    switch activeLanguage {
    case .english: return en
    case .chinese: return zh
    case .system:
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? zh : en
    }
}
