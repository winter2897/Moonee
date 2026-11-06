import Foundation
import Testing
import UIKit

/// Every SF Symbol name written in the app's sources exists on this iOS (a wrong name draws nothing).
/// Reads the source tree next to this file (the simulator can see the Mac's disk).
struct SymbolNameTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Moonee")

    /// `systemName: "x"`, `systemImage: "x"`, `symbol: "x"`, `icon: "x"`, `HeaderCircle("x")`, `?? "x"` after icon/symbol,
    /// and every literal inside a `var symbol/icon…: String { … }` switch.
    static func names(in text: String) -> Set<String> {
        let literal = #""([a-z0-9]+(?:\.[a-z0-9]+)*)""#
        let patterns = [
            #"(?:systemName|systemImage|symbol|icon)\s*:\s*"# + literal,
            #"HeaderCircle\(\s*"# + literal,
            #"(?:icon|symbol)\s*\?\?\s*"# + literal,
        ]
        var found = Set<String>()
        for p in patterns {
            let re = try! NSRegularExpression(pattern: p)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                found.insert(String(text[Range(m.range(at: 1), in: text)!]))
            }
        }
        let lit = try! NSRegularExpression(pattern: literal)
        // Icon picker lists: `static let icons = ["x", "y"]`.
        let list = try! NSRegularExpression(pattern: #"(?:icons|symbols)\s*(?::\s*\[String\])?\s*=\s*\[([^\]]*)\]"#)
        for m in list.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let body = String(text[Range(m.range(at: 1), in: text)!])
            for l in lit.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                found.insert(String(body[Range(l.range(at: 1), in: body)!]))
            }
        }
        // Computed symbol properties: `var symbol: String { switch self { case .a: "x" … } }`.
        let block = try! NSRegularExpression(pattern: #"var (?:symbol|icon|systemImage)\w*\s*:\s*String\??\s*\{"#)
        for m in block.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            var depth = 0, end = text.index(text.startIndex, offsetBy: m.range.upperBound - 1)
            for i in text[end...].indices {
                if text[i] == "{" { depth += 1 } else if text[i] == "}" { depth -= 1; if depth == 0 { end = i; break } }
            }
            let start = text.index(text.startIndex, offsetBy: m.range.upperBound)
            let body = String(text[start..<end])
            for l in lit.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                found.insert(String(body[Range(l.range(at: 1), in: body)!]))
            }
        }
        return found
    }

    @Test func everySymbolExists() throws {
        let files = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        try #require(files.count > 20, "source tree not found at \(Self.sources.path)")
        var checked = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for name in Self.names(in: text) {
                checked += 1
                #expect(UIImage(systemName: name) != nil, "\(file.lastPathComponent): no SF Symbol named \"\(name)\"")
            }
        }
        #expect(checked > 100)
    }

    /// Default categories, jars and wallet types use real symbols (they are stored in SwiftData, so a typo sticks).
    @Test func seedSymbolsExist() {
        let text = (try? String(contentsOf: Self.sources.appending(path: "Core/Models.swift"), encoding: .utf8)) ?? ""
        let names = Self.names(in: text)
        #expect(names.contains("fork.knife"))
        for name in names { #expect(UIImage(systemName: name) != nil, "Models.swift: \"\(name)\"") }
    }
}
