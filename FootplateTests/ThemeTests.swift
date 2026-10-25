import XCTest
import UIKit
@testable import Footplate

final class ThemeTests: XCTestCase {
    // There was no existing test path in the skeleton. Read vendored upstream
    // CSS, rather than duplicating the catalogue's hex values in expectations.
    @MainActor
    func testThemeMatchesTokens() throws {
        let bundle = Bundle(for: ThemeTests.self)
        let css = try String(contentsOf: XCTUnwrap(bundle.url(forResource: "colors", withExtension: "css")), encoding: .utf8)
        let root = try block(css, selector: ":root")
        let light = try block(css, selector: "[data-theme=\"light\"]")
        for (style, overrides) in [(UIUserInterfaceStyle.dark, root), (.light, light)] {
            for role in ThemeColor.allCases {
                let expected = try hex(overrides[role.rawValue] ?? XCTUnwrap(root[role.rawValue]), root: root)
                let color = try XCTUnwrap(UIColor(named: role.rawValue, in: .main, compatibleWith: nil))
                    .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
                for (actual, shift) in [(red, 16), (green, 8), (blue, 0)] {
                    XCTAssertEqual(actual, CGFloat((expected >> shift) & 255) / 255, accuracy: 0.0001, "\(style): \(role)")
                }
                XCTAssertEqual(alpha, 1)
            }
        }
        let typeCSS = try String(contentsOf: XCTUnwrap(bundle.url(forResource: "typography", withExtension: "css")), encoding: .utf8)
        let phone = try block(typeCSS, selector: "[data-platform=\"phone\"]")
        for role in ThemeType.allCases {
            let value = try XCTUnwrap(phone["type-\(role.rawValue)"])
            let face = role == .code ? "font-mono" : "font-sans"
            XCTAssertEqual(value, "\(role.weight) \(Int(role.size))px/\(Int(role.leading))px var(--\(face))")
            XCTAssertNotNil(UIFont(name: role.face, size: role.size), "Bundled face \(role.face) is registered")
        }
    }

    private func block(_ css: String, selector: String) throws -> [String: String] {
        let start = try XCTUnwrap(css.range(of: selector))
        let open = try XCTUnwrap(css.range(of: "{", range: start.upperBound..<css.endIndex))
        let close = try XCTUnwrap(css.range(of: "}", range: open.upperBound..<css.endIndex))
        let text = String(css[open.upperBound..<close.lowerBound])
        let pattern = try NSRegularExpression(pattern: #"--([\w-]+)\s*:\s*([^;]+);"#)
        return Dictionary(uniqueKeysWithValues: pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            let key = String(text[Range(match.range(at: 1), in: text)!])
            let value = String(text[Range(match.range(at: 2), in: text)!]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (key, value)
        })
    }

    private func hex(_ value: String, root: [String: String]) throws -> UInt32 {
        if value.hasPrefix("var(--") {
            return try hex(XCTUnwrap(root[String(value.dropFirst(6).dropLast())]), root: root)
        }
        return try XCTUnwrap(UInt32(value.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16))
    }
}
