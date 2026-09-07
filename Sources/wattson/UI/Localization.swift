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


/// A date and time in the language the user chose for the interface.
///
/// `formatted()` and `Text(_:style:)` follow the system locale, so an English
/// interface on a Chinese Mac printed "2026年9月7日 4:37" in the middle of
/// otherwise English text. The interface language is a setting in this app;
/// dates should honour it like everything else.
func eventStamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: activeLanguage == .chinese ? "zh_CN" : "en_US")
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}


/// A string kept in both languages, rendered at the moment it is displayed.
///
/// Verdict reasons used to be resolved with `L()` when the verdict was made
/// and stored as one language's text. An event flagged before the interface
/// was switched then kept its original wording forever, so a list of events
/// spanning a language change read half in each. Storing both and choosing
/// late costs a few bytes per event and makes the setting mean what it says.
struct Bilingual: Codable, Equatable, Hashable {
    let en: String
    let zh: String

    init(_ en: String, _ zh: String) {
        self.en = en
        self.zh = zh
    }

    /// A string that is the same in both languages — a program name, a number.
    init(_ both: String) {
        self.en = both
        self.zh = both
    }

    var text: String { L(en, zh) }

    /// Older event files stored plain strings; read them as language-neutral
    /// rather than discarding the history.
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            self.en = single
            self.zh = single
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.en = try container.decode(String.self, forKey: .en)
        self.zh = try container.decode(String.self, forKey: .zh)
    }
}
