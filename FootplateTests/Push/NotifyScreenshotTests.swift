@testable import Footplate
import SwiftUI
import UIKit
import XCTest

// The telling a wake shows, rendered at phone size (the bead's
// screenshots): the two lines a wake engine made of a stand-in
// yard's boards, drawn as the banner carries them. The system's
// banner itself — its chrome, its timing, its tap on a locked
// phone — is checked by hand on a device, as ShowTests hold; this
// shot is the wording, in the phone's own type and colours.
// Hand-run for the bead note; the gate runs it too, and it only
// asserts each shot renders non-empty. PNGs land in
// `NOTIFY_SHOTS_DIR`, or the temporary directory's `notify-shots`.
@MainActor
final class NotifyScreenshotTests: XCTestCase {
    /// A telling as the banner carries it: its title over its body,
    /// on the raised surface, as one card. Test-only drawing; the
    /// app ships no such view, since the system draws the banner.
    private struct TellingCard: View {
        let telling: Telling

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(telling.title)
                    .font(ThemeType.label.font)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .lineLimit(1)
                Text(telling.body)
                    .font(ThemeType.body.font)
                    .foregroundStyle(ThemeColor.textSecondary.color)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(ThemeColor.surfaceRaised.color)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ThemeColor.borderSubtle.color, lineWidth: 1))
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ThemeColor.surfaceApp.color)
        }
    }

    func testTheTellingsAWakeShowsRender() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no window scene to render in"
        )
        let checkpoints = MemoryCheckpointStore()
        checkpoints.transaction { $0.save(yard: "laptop", YardCheckpoint(emptyBoard())) }
        let mailBoard = board(letters: [Letter(seq: 11, from: "yardmaster", to: "jo", text: "The shed is painted. Shall I land it?")])
        let mail = await WakeEngine(
            yards: [WakeYard(name: "laptop", title: "laptop")],
            fetch: { _ in mailBoard },
            checkpoints: checkpoints,
            targets: MemoryWakeTargetStore(),
            canSuppress: false
        ).handle(wakeId: "w-mail", kind: .mail, shown: .elsewhere)
        guard case .show(let mailTelling) = mail else {
            return XCTFail("the mail wake shows: \(mail)")
        }
        let decisionBoard = board(open: [OpenAsk(bead: "yd-links", ask: 3, question: "Move this yard's links to the declared source now?", asker: "yardmaster")])
        let decision = await WakeEngine(
            yards: [WakeYard(name: "laptop", title: "laptop")],
            fetch: { _ in decisionBoard },
            checkpoints: checkpoints,
            targets: MemoryWakeTargetStore(),
            canSuppress: false
        ).handle(wakeId: "w-decision", kind: .decision, shown: .elsewhere)
        guard case .show(let decisionTelling) = decision else {
            return XCTFail("the decision wake shows: \(decision)")
        }

        let dir = ProcessInfo.processInfo.environment["NOTIFY_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("notify-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await render(TellingCard(telling: mailTelling), scene: scene, to: dir.appendingPathComponent("telling-mail.png"))
        try await render(TellingCard(telling: decisionTelling), scene: scene, to: dir.appendingPathComponent("telling-decision.png"))
    }

    private func emptyBoard() -> Board {
        Board(me: "jo", head: 10)
    }

    private func board(letters: [Letter] = [], open: [OpenAsk] = []) -> Board {
        var board = Board(me: "jo", head: 10)
        board.cursor = 10
        board.letters = Dictionary(uniqueKeysWithValues: letters.map { ($0.seq, $0) })
        board.open = open
        return board
    }

    private func render(_ view: some View, scene: UIWindowScene, to file: URL) async throws {
        let hosting = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 200)
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
        let png = try XCTUnwrap(image.pngData(), "the rendered telling has no PNG")
        try png.write(to: file)
        XCTAssertGreaterThan(png.count, 5000, "the rendered telling looks blank")
        window.isHidden = true
    }
}
