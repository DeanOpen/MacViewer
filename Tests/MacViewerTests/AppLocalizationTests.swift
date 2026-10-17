import Foundation
import Testing
@testable import MacViewer

struct AppLocalizationTests {
    @Test("The packaged resource bundle contains nonempty English and Vietnamese catalogs")
    func bundledCatalogs() throws {
        let english = try catalog("en")
        let vietnamese = try catalog("vi")
        #expect(english.count >= 200 && vietnamese.count >= 200)
        let required = ["Language", "Connect to Windows", "Remember password on this Mac", "Forget saved passwords",
                        "Screen Recording", "Accessibility", "Allow viewing", "Allow control", "Decline",
                        "Computer audio", "Record remote screen…", "Chat", "Disconnect"]
        for key in required {
            #expect(english[key]?.isEmpty == false, "Missing English key: \(key)")
            #expect(vietnamese[key]?.isEmpty == false, "Missing Vietnamese key: \(key)")
        }
        #expect(AppLanguage.localized("Connect to Windows", language: .en) == "Connect to another computer")
        #expect(AppLanguage.localized("Connect to Windows", language: .vi) == "Kết nối đến máy khác")
        #expect(AppLanguage.localized("a-synthetic-unknown-key", language: .vi) == "a-synthetic-unknown-key")
    }

    @Test("Catalog keys and typed format arguments match in both languages")
    func keyAndPlaceholderParity() throws {
        let english = try catalog("en")
        let vietnamese = try catalog("vi")
        #expect(Set(english.keys) == Set(vietnamese.keys))
        for (key, value) in english {
            let translation = try #require(vietnamese[key])
            #expect(!translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(try arguments(value) == arguments(translation), "Format argument mismatch: \(key)")
        }
        #expect(try arguments("Actual size (100%)").isEmpty)
        #expect(try arguments("100%%: %@ %ld") == ["1:@", "2:ld"])
        #expect(try arguments("%2$ld %1$@") == ["1:@", "2:ld"])
    }

    @Test("Parameterized status translation preserves peer names, percent signs and literal English format keys")
    func dynamicStatusFormatting() {
        #expect(AppLanguage.localized("Connected to %@.", language: .en) == "Connected to %@.")
        #expect(AppLanguage.localized("Connecting to %@…", language: .en) == "Connecting to %@…")
        #expect(AppLanguage.localized("Connected to %@@.", language: .en) == "Connected to %@@.")
        let name = "Máy của Hà %@ 135"
        #expect(AppLanguage.localized("Connected to \(name).", language: .vi) == "Đã kết nối với \(name).")
        #expect(AppLanguage.localized("Connecting to \(name)…", language: .vi) == "Đang kết nối \(name)…")
        let monitor = String(format: AppLanguage.localized("Monitor %ld · %ld × %ld", language: .vi),
                             locale: Locale(identifier: "vi"), 2, 1920, 1080)
        #expect(monitor == "Màn hình 2 · 1.920 × 1.080")
    }

    private func catalog(_ language: String) throws -> [String: String] {
        let url = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "strings",
                                                 subdirectory: "\(language).lproj"))
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                            as? [String: String])
    }

    private func arguments(_ text: String) throws -> [String] {
        let expression = try NSRegularExpression(
            pattern: #"%(?:([1-9][0-9]*)\$)?[-+ #0']*[0-9]*(?:\.[0-9]+)?(hh|ll|[hlLqjzt])?([@diuoxXfFeEgGaAcCsSpn%])"#)
        let source = text as NSString
        var next = 1
        var result: [String] = []
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let conversion = source.substring(with: match.range(at: 3))
            if conversion == "%" { continue }
            let position: Int
            if match.range(at: 1).location != NSNotFound {
                position = Int(source.substring(with: match.range(at: 1)))!
            } else { position = next; next += 1 }
            let length = match.range(at: 2).location == NSNotFound ? "" : source.substring(with: match.range(at: 2))
            result.append("\(position):\(length)\(conversion)")
        }
        return result.sorted()
    }
}
