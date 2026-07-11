import Foundation
import XCTest

final class LocalizationCatalogTests: XCTestCase {
    func testCatalogProvidesEveryExtractedKeyInSupportedLocales() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repositoryRoot
            .appendingPathComponent("Radix")
            .appendingPathComponent("Localizable.xcstrings")

        let data = try Data(contentsOf: catalogURL)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["sourceLanguage"] as? String, "en")

        let strings = try XCTUnwrap(object["strings"] as? [String: Any])
        XCTAssertGreaterThanOrEqual(strings.count, 400)

        let supportedLocales = Set(["es", "fr", "zh-Hans", "de"])
        for (key, value) in strings {
            let entry = try XCTUnwrap(value as? [String: Any], "Invalid catalog entry for \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
            XCTAssertTrue(supportedLocales.isSubset(of: Set(localizations.keys)), "Missing supported locale for \(key)")

            for locale in supportedLocales {
                let localization = try XCTUnwrap(localizations[locale] as? [String: Any])
                let stringUnit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                XCTAssertEqual(stringUnit["state"] as? String, "translated", "Untranslated \(locale) value for \(key)")
                let value = try XCTUnwrap(stringUnit["value"] as? String, "Missing \(locale) value for \(key)")
                XCTAssertEqual(
                    formatSpecifiers(in: value),
                    formatSpecifiers(in: key),
                    "Format specifiers changed in the \(locale) translation for \(key)"
                )
            }
        }
    }

    func testInfoPlistCatalogProvidesGermanForEveryEntry() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repositoryRoot
            .appendingPathComponent("Radix")
            .appendingPathComponent("InfoPlist.xcstrings")

        let data = try Data(contentsOf: catalogURL)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(object["strings"] as? [String: Any])
        XCTAssertFalse(strings.isEmpty)

        for (key, value) in strings {
            let entry = try XCTUnwrap(value as? [String: Any], "Invalid metadata catalog entry for \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
            let german = try XCTUnwrap(localizations["de"] as? [String: Any], "Missing German localization for \(key)")
            let stringUnit = try XCTUnwrap(german["stringUnit"] as? [String: Any])
            XCTAssertEqual(stringUnit["state"] as? String, "translated", "Untranslated German metadata value for \(key)")
            XCTAssertNotNil(stringUnit["value"] as? String, "Missing German metadata value for \(key)")
        }
    }

    private func formatSpecifiers(in value: String) -> [String: Int] {
        let pattern = #"%(?:[0-9]+\$)?(?:lld|ld|llu|lu|d|u|f|@)"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)

        return expression.matches(in: value, range: range).reduce(into: [:]) { counts, match in
            guard let range = Range(match.range, in: value) else { return }
            let specifier = value[range]
                .replacingOccurrences(of: #"%[0-9]+\$"#, with: "%", options: .regularExpression)
            counts[specifier, default: 0] += 1
        }
    }
}
