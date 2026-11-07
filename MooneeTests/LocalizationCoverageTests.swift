import Foundation
import Testing

/// Every UI language ships every string: a key translated to Vietnamese must also have Thai and Lao.
struct LocalizationCoverageTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Moonee")
    /// The widget extension ships its own catalog.
    static let widgets = sources.deletingLastPathComponent().appending(path: "MooneeWidgets")

    @Test func translatedKeysHaveThaiAndLao() throws {
        let catalogs = [Self.sources, Self.widgets].flatMap { FileManager.default.enumerator(at: $0, includingPropertiesForKeys: nil)! }
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "xcstrings" }
        #expect(catalogs.contains { $0.lastPathComponent == "Widgets.xcstrings" })
        #expect(catalogs.count > 5)
        var missing: [String] = []
        for url in catalogs {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            for (key, entry) in json["strings"] as? [String: [String: Any]] ?? [:] where entry["shouldTranslate"] as? Bool != false {
                let langs = Set((entry["localizations"] as? [String: Any] ?? [:]).keys)
                guard langs.contains("vi") else { continue }
                for lang in ["th", "lo"] where !langs.contains(lang) { missing.append("\(url.lastPathComponent) \(lang): \(key)") }
            }
        }
        #expect(missing.isEmpty, "Add th/lo for:\n\(missing.sorted().joined(separator: "\n"))")
    }
}
