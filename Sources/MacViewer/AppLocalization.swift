import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, vi
    static let defaultsKey = "MacViewer.language"
    var id: Self { self }
    var title: String {
        switch self { case .system: "System language"; case .en: "English"; case .vi: "Tiếng Việt" }
    }
    var locale: Locale { self == .system ? .current : Locale(identifier: rawValue) }
    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "system") ?? .system
    }
    static func localized(_ key: String, language: AppLanguage = current) -> String {
        let identifier = language == .system
            ? (Locale.preferredLanguages.first?.hasPrefix("vi") == true ? "vi" : "en") : language.rawValue
        for source in [Bundle.main, Bundle.module] {
            if let path = source.path(forResource: identifier, ofType: "lproj"), let bundle = Bundle(path: path) {
                let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
                if value != key { return value }
            }
        }
        // Session state remains plain English internally. Translate the two
        // parameterized connection messages without touching peer names/IDs.
        for (prefix, suffix, format) in [("Connected to ", ".", "Connected to %@."),
                ("Connecting to ", "…", "Connecting to %@…"),
                ("Computer audio stopped: ", "", "Computer audio stopped: %@"),
                ("Remote input stopped: ", "", "Remote input stopped: %@"),
                ("Remote control could not be updated: ", "", "Remote control could not be updated: %@"),
                ("The remote action could not be completed: ", "", "The remote action could not be completed: %@"),
                ("Connected, but the password could not be saved: ", "", "Connected, but the password could not be saved: %@"),
                ("Saved passwords could not be removed: ", "", "Saved passwords could not be removed: %@"),
                ("Saved password unavailable: ", " Enter it manually.", "Saved password unavailable: %@ Enter it manually.")] {
            if key != format, key.hasPrefix(prefix), key.hasSuffix(suffix), key.count > prefix.count + suffix.count {
                let value = String(key.dropFirst(prefix.count).dropLast(suffix.count))
                let translated = localized(format, language: language)
                return String(format: translated, locale: language.locale, value)
            }
        }
        return key
    }
}

func L(_ key: String) -> String { AppLanguage.localized(key) }
func LF(_ key: String, _ values: CVarArg...) -> String {
    String(format: L(key), locale: AppLanguage.current.locale, arguments: values)
}

private struct AppLanguageModifier: ViewModifier {
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue
    func body(content: Content) -> some View {
        content.environment(\.locale, (AppLanguage(rawValue: language) ?? .system).locale)
    }
}
extension View {
    func appLanguage() -> some View { modifier(AppLanguageModifier()) }
}
