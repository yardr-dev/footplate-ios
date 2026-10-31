@testable import Footplate
import SwiftUI
import UIKit
import XCTest

// Try a demo rendered in the simulator (the bead's screenshots): the Pair
// screen a person with no yard sees, with the button, and the demo's tabs
// under their banner with the data the yard makes up, in the system's dark
// and light, at phone and pad size. Hand-run for the bead note; the gate
// runs it too, and it only asserts that each screen renders non-empty and
// that the demo has data to draw. PNGs land in `DEMO_SHOTS_DIR`, or the
// temporary directory's `demo-shots` where that names none.
@MainActor
final class DemoScreenshotTests: XCTestCase {
    private let phone = CGSize(width: 402, height: 874)
    private let pad = CGSize(width: 834, height: 1194)

    private func scene() throws -> UIWindowScene {
        try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no window scene to render in"
        )
    }

    private func shots() throws -> URL {
        let dir = ProcessInfo.processInfo.environment["DEMO_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("demo-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testTheFirstScreenOffersTheDemo() async throws {
        let scene = try scene()
        let fake = FakeYard()
        let records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        let pair = PairModel(pairer: Pairer(edge: try fake.edge(), records: records), records: records, nav: Nav())
        XCTAssertEqual(records.kept.yards, [])
        XCTAssertEqual(pair.state.step, .choose)
        let dir = try shots()
        // The camera is there on a phone, so the screen is drawn as a
        // phone's: Scan, Type the code and Try a demo.
        let screen = PairScreen(model: pair, scannerAvailable: true, onDemo: {})
        try await render(screen, scene: scene, size: phone, style: .dark, to: dir.appendingPathComponent("first-iphone-dark.png"))
        try await render(screen, scene: scene, size: phone, style: .light, to: dir.appendingPathComponent("first-iphone-light.png"))
        try await render(screen, scene: scene, size: pad, style: .dark, to: dir.appendingPathComponent("first-ipad-dark.png"))
    }

    func testTheDemoTabsRender() async throws {
        let scene = try scene()
        let demo = Demo()
        defer { demo.close() }
        let deadline = ContinuousClock.now + .seconds(10)
        while demo.inbox.state.rows.isEmpty || demo.decisions.state.open.isEmpty, ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(demo.inbox.state.rows.isEmpty)
        XCTAssertEqual(demo.decisions.state.open.count, 1)
        demo.line.open(yard: "demo")
        defer { demo.line.leave() }
        while !demo.line.state.read, ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(demo.line.state.read)
        let dir = try shots()
        func tabs() -> DemoTabs {
            DemoTabs(demo: demo, onLeave: {})
        }

        demo.nav.place = .crew
        try await render(tabs(), scene: scene, size: phone, style: .dark, to: dir.appendingPathComponent("crew-iphone-dark.png"))
        try await render(tabs(), scene: scene, size: phone, style: .light, to: dir.appendingPathComponent("crew-iphone-light.png"))
        try await render(tabs(), scene: scene, size: pad, style: .dark, to: dir.appendingPathComponent("crew-ipad-dark.png"))
        demo.nav.place = .decide
        try await render(tabs(), scene: scene, size: phone, style: .dark, to: dir.appendingPathComponent("decide-iphone-dark.png"))
        demo.nav.place = .lines
        try await render(tabs(), scene: scene, size: phone, style: .dark, to: dir.appendingPathComponent("lines-iphone-dark.png"))
        // The line pushed as its route map, and a bead as its card: no
        // page to open in a browser.
        demo.nav.openLine(yard: "demo", depot: "timetable", flow: "default")
        try await render(tabs(), scene: scene, size: phone, style: .dark, to: dir.appendingPathComponent("route-iphone-dark.png"))
        demo.line.openBead("yd-7h9q")
        try await render(tabs(), scene: scene, size: phone, style: .dark, to: dir.appendingPathComponent("bead-iphone-dark.png"))
        demo.nav.linesPath = []

        // The yard switch: the demo yard, and the way out in place of
        // pairing another yard or forgetting this one.
        XCTAssertTrue(demo.inbox.state.demo)
        try await render(
            YardSwitchView(state: demo.inbox.state), scene: scene, size: phone, style: .dark,
            to: dir.appendingPathComponent("switch-iphone-dark.png")
        )

        // The yardmaster's conversation, and the question's card.
        demo.nav.place = .crew
        demo.nav.openConversation(yard: "demo", with: "yardmaster")
        demo.conversation.open(yard: "demo", with: "yardmaster")
        defer { demo.conversation.leave() }
        while demo.conversation.state.letters.count < 4, ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(demo.conversation.state.letters.count, 4)
        try await render(tabs(), scene: scene, size: phone, style: .dark, to: dir.appendingPathComponent("conversation-iphone-dark.png"))
        demo.nav.crewPath = []
        demo.nav.place = .decide
        demo.nav.openDecision(yard: "demo", bead: "yd-4k2m", ask: 3)
        demo.decision.open(yard: "demo", bead: "yd-4k2m", ask: 3)
        defer { demo.decision.leave() }
        while !demo.decision.state.read, ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(demo.decision.state.read)
        try await render(tabs(), scene: scene, size: phone, style: .dark, to: dir.appendingPathComponent("decision-iphone-dark.png"))
    }

    private func render(
        _ view: some View, scene: UIWindowScene, size: CGSize, style: UIUserInterfaceStyle, to file: URL
    ) async throws {
        // As the scene draws it: the accent is the app's, not the system's.
        let hosting = UIHostingController(rootView: AnyView(view.tint(ThemeColor.textAccent.color)))
        hosting.overrideUserInterfaceStyle = style
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(700))
        hosting.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            hosting.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let png = try XCTUnwrap(image.pngData(), "the rendered screen has no PNG")
        XCTAssertEqual(image.size, size)
        try png.write(to: file)
        XCTAssertGreaterThan(png.count, 10000, "the rendered screen looks blank")
        window.isHidden = true
    }
}
