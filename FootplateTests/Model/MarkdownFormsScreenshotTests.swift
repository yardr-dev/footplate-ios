@testable import Footplate
import SwiftUI
import UIKit
import XCTest

// The four forms drawn at phone size: the whole-text sample with the
// table's head, the quote's bar, the rule's line and a link with its host,
// and a wide table scrolling sideways whole. Hand-run for the bead note;
// the gate runs it too, and it only asserts that each screen renders
// non-empty at phone size, with the one sideways scroll a table takes.
// PNGs land in `FORMS_SHOTS_DIR`, or the temporary directory's
// `forms-shots` where that names none.
@MainActor
final class MarkdownFormsScreenshotTests: XCTestCase {
    /// A table wider than the phone: seven columns of two-word cells.
    private static let wide = """
    | One | Two | Three | Four | Five | Six | Seven |
    | --- | --- | ----- | ---- | ---- | --- | ----- |
    | alpha bravo | charlie delta | echo foxtrot | golf hotel | india juliett | kilo lima | mike november |
    """

    func testMarkdownFormsRender() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no window scene to render in"
        )
        let dir = ProcessInfo.processInfo.environment["FORMS_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("forms-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertEqual(messageBlocks(MarkdownFixture.forms).count, 5)
        let formsAppeared = expectation(description: "the whole-text sample appeared")
        let window = try await render(
            ScrollView {
                MessageText(text: MarkdownFixture.forms)
                    .onAppear { formsAppeared.fulfill() }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
            },
            scene: scene, to: dir.appendingPathComponent("forms.png"), height: 480, appeared: formsAppeared
        )
        let scrolls = horizontalScrolls(in: window)
        XCTAssertEqual(scrolls.count, 1, "the table scrolls sideways whole")
        if let table = scrolls.first {
            XCTAssertLessThanOrEqual(table.contentSize.width, table.bounds.width, "the narrow table fits the screen")
        }
        window.isHidden = true

        let wideTableAppeared = expectation(description: "the wide table appeared")
        let wideWindow = try await render(
            ScrollView {
                MessageText(text: Self.wide)
                    .onAppear { wideTableAppeared.fulfill() }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
            },
            scene: scene, to: dir.appendingPathComponent("forms-wide.png"), height: 400, appeared: wideTableAppeared
        )
        let wideScrolls = horizontalScrolls(in: wideWindow)
        XCTAssertEqual(wideScrolls.count, 1, "the wide table is one sideways scroll")
        if let table = wideScrolls.first {
            XCTAssertGreaterThan(table.contentSize.width, table.bounds.width, "the wide table outruns the screen")
        }
        wideWindow.isHidden = true
    }

    private func render(_ view: some View, scene: UIWindowScene, to file: URL, height: CGFloat, appeared: XCTestExpectation) async throws -> UIWindow {
        let (window, hosting) = host(view, scene: scene, height: height)
        await fulfillment(of: [appeared], timeout: 5)
        window.layoutIfNeeded()
        hosting.view.layoutIfNeeded()
        try snapshot(hosting.view, in: window, to: file, height: height)
        return window
    }

    private func host(_ view: some View, scene: UIWindowScene, height: CGFloat) -> (UIWindow, UIHostingController<AnyView>) {
        let hosting = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: height)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.frame = window.bounds
        return (window, hosting)
    }

    private func snapshot(_ drawn: UIView, in window: UIWindow, to file: URL, height: CGFloat) throws {
        drawn.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            drawn.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let png = try XCTUnwrap(image.pngData(), "the rendered screen has no PNG")
        XCTAssertEqual(image.size, CGSize(width: 402, height: height))
        try png.write(to: file)
        XCTAssertGreaterThan(png.count, 10000, "the rendered screen looks blank")
    }

    /// The scroll views that scroll sideways: the tables, which are short,
    /// beside the screen's own, which fills the window.
    private func horizontalScrolls(in view: UIView) -> [UIScrollView] {
        var found = view.subviews.flatMap { horizontalScrolls(in: $0) }
        if let scroll = view as? UIScrollView, !(scroll is UITextView), scroll.bounds.height < 400 { found.append(scroll) }
        return found
    }
}
