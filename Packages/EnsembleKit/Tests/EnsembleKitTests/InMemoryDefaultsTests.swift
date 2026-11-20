import Foundation
import Testing
@testable import EnsembleKit

/// The in-memory stand-in for `UserDefaults` that tests and snapshot renders use, and the rule that they use it.
@Suite struct InMemoryDefaultsTests {
    @Test func missingKeysReadAsTheRealClassReadsThem() {
        let defaults: UserDefaults = InMemoryDefaults()
        #expect(defaults.object(forKey: "missing") == nil)
        #expect(defaults.string(forKey: "missing") == nil)
        #expect(defaults.stringArray(forKey: "missing") == nil)
        #expect(defaults.dictionary(forKey: "missing") == nil)
        #expect(defaults.bool(forKey: "missing") == false)
        #expect(defaults.integer(forKey: "missing") == 0)
        #expect(defaults.double(forKey: "missing") == 0)
    }

    /// Code under test calls the typed readers and writers on a plain `UserDefaults`, so they are called that way here.
    @Test func typedWritersAndReadersGoThroughTheStandIn() {
        let store = InMemoryDefaults()
        let defaults: UserDefaults = store
        defaults.set(true, forKey: "bool")
        defaults.set(42, forKey: "integer")
        defaults.set(1.5, forKey: "double")
        defaults.set("text", forKey: "string")
        defaults.set(["a", "b"], forKey: "strings")
        defaults.set(["level": 2], forKey: "dictionary")
        defaults.set(Data([1, 2, 3]), forKey: "data")
        #expect(store.dictionaryRepresentation().count == 7, "every writer reached the stand-in")

        #expect(defaults.bool(forKey: "bool"))
        #expect((defaults.object(forKey: "bool") as? Bool) == true)
        #expect(defaults.integer(forKey: "integer") == 42)
        #expect(defaults.double(forKey: "double") == 1.5)
        #expect((defaults.object(forKey: "double") as? Double) == 1.5)
        #expect(defaults.string(forKey: "string") == "text")
        #expect(defaults.stringArray(forKey: "strings") == ["a", "b"])
        #expect((defaults.dictionary(forKey: "dictionary") as? [String: Int]) == ["level": 2])
        #expect(defaults.data(forKey: "data") == Data([1, 2, 3]))
        // The conversions the real class makes.
        #expect(defaults.string(forKey: "integer") == "42")
        #expect(defaults.bool(forKey: "integer"))
    }

    @Test func removingAndSettingNilBothClearAKey() {
        let defaults: UserDefaults = InMemoryDefaults()
        defaults.set("one", forKey: "a")
        defaults.set("two", forKey: "b")
        defaults.removeObject(forKey: "a")
        defaults.set(nil, forKey: "b")
        #expect(defaults.object(forKey: "a") == nil)
        #expect(defaults.object(forKey: "b") == nil)
    }

    @Test func eachStoreIsSeparateAndSeesNoOtherDomain() {
        let first = InMemoryDefaults()
        let second = InMemoryDefaults()
        first.set("mine", forKey: "key")
        #expect(second.object(forKey: "key") == nil)
        // A real suite also answers with the global domain's values, such as the language list.
        #expect(first.object(forKey: "AppleLanguages") == nil)
    }

    @Test func nothingIsWrittenToThePreferencesFolder() {
        let defaults: UserDefaults = InMemoryDefaults()
        defaults.set(true, forKey: "bool")
        defaults.set(["a"], forKey: "strings")
        defaults.removeObject(forKey: "bool")
        defaults.synchronize()
        #expect(UserDefaults.standard.persistentDomain(forName: InMemoryDefaults.unusedDomain) == nil)
        let file = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/\(InMemoryDefaults.unusedDomain).plist")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// A suite with a new name per run leaves a file in `~/Library/Preferences` every time, even when the code calls
    /// `removePersistentDomain(forName:)` afterwards. Thousands of them piled up before this rule. Tests, snapshot
    /// renders and previews take `InMemoryDefaults()`; a suite is only made from a fixed name written out in full.
    @Test func noSuiteIsMadeFromANamePerRun() throws {
        let opening = "UserDefaults(" + "suiteName:"
        let fixedName = try Regex(#"^\s*"[^"\\]+"\s*\)"#)
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repository = package.deletingLastPathComponent().deletingLastPathComponent()
        let folders = [package.appendingPathComponent("Sources"), package.appendingPathComponent("Tests"),
                       repository.appendingPathComponent("Apps")]

        var found: [String] = []
        var filesRead = 0
        for folder in folders {
            guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                filesRead += 1
                guard text.contains(opening) else { continue }
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    guard let range = line.range(of: opening) else { continue }
                    let argument = line[range.upperBound...]
                    // `UserDefaults(suiteName:)` in a comment names the initializer and makes nothing.
                    if argument.hasPrefix(")") || argument.firstMatch(of: fixedName) != nil { continue }
                    found.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(filesRead > 100, "the search read the source folders")
        #expect(found.isEmpty, "use InMemoryDefaults() instead of a suite named per run: \(found.joined(separator: ", "))")
    }
}
