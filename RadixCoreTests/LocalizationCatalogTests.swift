import Foundation
import XCTest

final class LocalizationCatalogTests: XCTestCase {
    private struct LocalizedSourceLiteral {
        let value: String
        let file: String
        let line: Int
    }

    func testCatalogProvidesEveryExtractedKeyInSupportedLocales() throws {
        let catalogs = try appLocalizationCatalogs()
        let duplicateKeys = Set(catalogs["Localizable", default: [:]].keys)
            .intersection(catalogs["Interface", default: [:]].keys)
        XCTAssertTrue(duplicateKeys.isEmpty, "Localization keys must belong to exactly one table: \(duplicateKeys.sorted())")

        let strings = catalogs.values.reduce(into: [String: Any]()) { merged, catalog in
            merged.merge(catalog) { existing, _ in existing }
        }
        XCTAssertGreaterThanOrEqual(strings.count, 400)
        XCTAssertEqual(catalogs["Interface"]?.count, 8)

        let supportedLocales = Set(["es", "fr", "zh-Hans", "de", "it"])
        for (key, value) in strings {
            let entry = try XCTUnwrap(value as? [String: Any], "Invalid catalog entry for \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "Missing localizations for \(key)")
            XCTAssertTrue(supportedLocales.isSubset(of: Set(localizations.keys)), "Missing supported locale for \(key)")

            for locale in supportedLocales {
                let localization = try XCTUnwrap(localizations[locale] as? [String: Any])
                if let stringUnit = localization["stringUnit"] as? [String: Any] {
                    try assertTranslated(stringUnit, locale: locale, key: key)
                } else {
                    let variations = try XCTUnwrap(localization["variations"] as? [String: Any])
                    let plurals = try XCTUnwrap(variations["plural"] as? [String: Any])
                    XCTAssertFalse(plurals.isEmpty, "Missing plural variants for \(locale) key \(key)")
                    for (category, value) in plurals {
                        let variant = try XCTUnwrap(value as? [String: Any])
                        let stringUnit = try XCTUnwrap(variant["stringUnit"] as? [String: Any])
                        try assertTranslated(stringUnit, locale: locale, key: "\(key) [\(category)]")
                    }
                }
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

    func testEveryAppSourceLocalizationLiteralExistsInCatalog() throws {
        let root = repositoryRoot
        let catalog = try appLocalizationCatalogs().values.reduce(into: [String: Any]()) { merged, table in
            merged.merge(table) { existing, _ in existing }
        }
        let catalogTemplates = Set(catalog.keys.map(localizationTemplate))
        let sourceFiles = try swiftSourceFiles(in: root.appendingPathComponent("Radix"))

        XCTAssertTrue(
            sourceFiles.contains { $0.path.hasSuffix("/Features/Onboarding/OnboardingView.swift") },
            "The localization audit must include SwiftPM-excluded UI sources."
        )
        XCTAssertTrue(
            sourceFiles.contains { $0.lastPathComponent == "ContentView.swift" },
            "The localization audit must include ContentView."
        )

        let literals = try sourceFiles.flatMap(localizedLiterals)
        XCTAssertGreaterThan(literals.count, 400, "Unexpectedly few localized literals were extracted from app sources.")

        let missing = literals.filter { !catalogTemplates.contains(localizationTemplate($0.value)) }
        XCTAssertTrue(
            missing.isEmpty,
            missing.map { "\($0.file):\($0.line): missing catalog key for \(String(reflecting: $0.value))" }
                .joined(separator: "\n")
        )
    }

    func testInterfaceCatalogKeysUseExplicitTableName() throws {
        let catalogs = try appLocalizationCatalogs()
        let interfaceCatalog = catalogs["Interface", default: [:]]
        let source = try swiftSourceFiles(in: repositoryRoot.appendingPathComponent("Radix"))
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        for key in interfaceCatalog.keys {
            XCTAssertTrue(
                source.contains("\"\(key)\", tableName: \"Interface\""),
                "Interface key must explicitly select its string table: \(key)"
            )
        }
    }

    func testSwiftPackageCoreSourceListMatchesCoreFilesOnDisk() throws {
        let root = repositoryRoot
        let packageSource = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let sourcesMarker = try XCTUnwrap(packageSource.range(of: "sources: ["))
        let sourcesEnd = try XCTUnwrap(
            packageSource.range(of: "\n            ]", range: sourcesMarker.upperBound..<packageSource.endIndex)
        )
        let sourcesBlock = String(packageSource[sourcesMarker.upperBound..<sourcesEnd.lowerBound])
        let listedSources = Set(matches(in: sourcesBlock, pattern: #"([^"\n]+\.swift)"#).map(\.value))

        let appSourceRoot = root.appendingPathComponent("Radix")
        let expectedSources = Set(try swiftSourceFiles(in: appSourceRoot).compactMap { url -> String? in
            let relativePath = String(url.path.dropFirst(appSourceRoot.path.count + 1))
            let firstComponent = relativePath.split(separator: "/").first.map(String.init)
            if ["App", "Features", "Shared"].contains(firstComponent) { return nil }
            if ["ContentView.swift", "RadixApp.swift"].contains(relativePath) { return nil }
            return relativePath
        })

        XCTAssertEqual(
            listedSources,
            expectedSources,
            "Package.swift's explicit RadixCore sources must track every non-UI Swift source exactly."
        )
    }

    func testXcodeSynchronizedAppTargetIncludesLocalizationResources() throws {
        let root = repositoryRoot
        let projectSource = try String(
            contentsOf: root.appendingPathComponent("Radix.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        XCTAssertTrue(projectSource.contains("isa = PBXFileSystemSynchronizedRootGroup;"))
        XCTAssertTrue(projectSource.contains("path = Radix;"))
        XCTAssertTrue(projectSource.contains("fileSystemSynchronizedGroups = ("))
        XCTAssertTrue(projectSource.contains("membershipExceptions = (\n\t\t\t\tInfo.plist,"))
        XCTAssertFalse(projectSource.contains("Localizable.xcstrings,"), "The string catalog must not be excluded from the synchronized app target.")
        XCTAssertFalse(projectSource.contains("Interface.xcstrings,"), "The interface string catalog must not be excluded from the synchronized app target.")
        XCTAssertFalse(projectSource.contains("InfoPlist.xcstrings,"), "The Info.plist catalog must not be excluded from the synchronized app target.")

        for resource in ["Localizable.xcstrings", "Interface.xcstrings", "InfoPlist.xcstrings"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent("Radix/\(resource)").path),
                "Missing app localization resource: \(resource)"
            )
        }
        let knownRegionsBlock = try XCTUnwrap(
            matches(in: projectSource, pattern: #"knownRegions\s*=\s*\(([\s\S]*?)\);"#).first?.value
        )
        let knownRegions = Set(knownRegionsBlock.split(separator: ",").map { region in
            region.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        })
        for locale in ["en", "es", "fr", "zh-Hans", "de"] {
            XCTAssertTrue(knownRegions.contains(locale), "Xcode project is missing supported locale \(locale).")
        }
    }

    private func assertTranslated(
        _ stringUnit: [String: Any],
        locale: String,
        key: String
    ) throws {
        XCTAssertEqual(stringUnit["state"] as? String, "translated", "Untranslated \(locale) value for \(key)")
        let value = try XCTUnwrap(stringUnit["value"] as? String, "Missing \(locale) value for \(key)")
        let sourceKey = key.components(separatedBy: " [").first ?? key
        XCTAssertEqual(
            formatSpecifiers(in: value),
            formatSpecifiers(in: sourceKey),
            "Format specifiers changed in the \(locale) translation for \(key)"
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func localizationCatalog(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["sourceLanguage"] as? String, "en", "Unexpected source language in \(url.lastPathComponent)")
        return try XCTUnwrap(object["strings"] as? [String: Any])
    }

    private func appLocalizationCatalogs() throws -> [String: [String: Any]] {
        let radixRoot = repositoryRoot.appendingPathComponent("Radix")
        return [
            "Localizable": try localizationCatalog(at: radixRoot.appendingPathComponent("Localizable.xcstrings")),
            "Interface": try localizationCatalog(at: radixRoot.appendingPathComponent("Interface.xcstrings"))
        ]
    }

    private func swiftSourceFiles(in directory: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        )
        return try enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.pathExtension == "swift",
                  try url.resourceValues(forKeys: Set(keys)).isRegularFile == true else {
                return nil
            }
            return url
        }
        .sorted { $0.path < $1.path }
    }

    private func localizedLiterals(in fileURL: URL) throws -> [LocalizedSourceLiteral] {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let patterns = [
            #"\bString\s*\(\s*localized\s*:\s*"((?:\\.|[^"\\])*)""#,
            #"\b(?:Text|Label|Button|Toggle|Picker|Section|TextField|SecureField|Menu|GroupBox|LabeledContent|NavigationLink|CommandMenu|ProgressView|TableColumn|Window)\s*\(\s*"((?:\\.|[^"\\])*)""#,
            #"\bContentUnavailableView\s*\(\s*"((?:\\.|[^"\\])*)""#,
            #"\.(?:navigationTitle|accessibilityLabel|accessibilityHint|help|confirmationDialog|alert)\s*\(\s*"((?:\\.|[^"\\])*)""#,
            #"\.searchable\s*\([^\n]*\bprompt\s*:\s*"((?:\\.|[^"\\])*)""#
        ]

        return patterns.flatMap { pattern in
            matches(in: source, pattern: pattern).map { match in
                let location = source.distance(from: source.startIndex, to: match.range.lowerBound)
                let prefix = source.prefix(location)
                let line = prefix.reduce(into: 1) { count, character in
                    if character == "\n" { count += 1 }
                }
                return LocalizedSourceLiteral(
                    value: decodedSwiftLiteral(match.value),
                    file: fileURL.path.replacingOccurrences(of: repositoryRoot.path + "/", with: ""),
                    line: line
                )
            }
        }
    }

    private func decodedSwiftLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\n"#, with: "\n")
            .replacingOccurrences(of: #"\t"#, with: "\t")
            .replacingOccurrences(of: #"\""#, with: "\"")
            .replacingOccurrences(of: #"\\"#, with: #"\"#)
    }

    private func localizationTemplate(_ value: String) -> String {
        let withoutInterpolations = replacingSwiftInterpolations(in: value, with: "{value}")
        return withoutInterpolations.replacingOccurrences(
            of: #"%(?:[0-9]+\$)?(?:lld|ld|llu|lu|d|u|f|@)"#,
            with: "{value}",
            options: .regularExpression
        )
    }

    private func replacingSwiftInterpolations(in value: String, with replacement: String) -> String {
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "\\" else {
                result.append(value[index])
                index = value.index(after: index)
                continue
            }
            let openParenthesis = value.index(after: index)
            guard openParenthesis < value.endIndex, value[openParenthesis] == "(" else {
                result.append(value[index])
                index = openParenthesis
                continue
            }

            var depth = 1
            var cursor = value.index(after: openParenthesis)
            while cursor < value.endIndex, depth > 0 {
                if value[cursor] == "(" { depth += 1 }
                if value[cursor] == ")" { depth -= 1 }
                cursor = value.index(after: cursor)
            }
            result += replacement
            index = cursor
        }
        return result
    }

    private func matches(in value: String, pattern: String) -> [(value: String, range: Range<String.Index>)] {
        let expression = try! NSRegularExpression(pattern: pattern)
        let searchRange = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: searchRange).compactMap { match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: value),
                  let fullRange = Range(match.range(at: 0), in: value) else {
                return nil
            }
            return (String(value[valueRange]), fullRange)
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
