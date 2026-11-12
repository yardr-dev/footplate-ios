import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// The QR screen of an approved pairing (yardr-6maq 3.4, after footplate's
// own): the QR the yard's answer makes, drawn here from that string
// verbatim by CoreImage, the code beside it for a device with no camera,
// the minutes it is good for, and End. It draws what the decision model
// holds for the sitting and keeps nothing of its own: the picture is made
// when it is drawn, and no file, cache or log is written. The system keeps
// a snapshot of an app's screen when it leaves the front, for its app
// switcher, in a file of the app's own: so the QR, the code and the minutes
// are drawn only while the app is in front, and the snapshot holds none.

/// Made once: a context costs more than the picture it draws, and holds
/// none of what it drew.
private let qrContext = CIContext()

/// The QR of `text` as a picture: black modules on white, each a whole
/// number of points across, with the four modules of quiet zone a
/// scanner wants, so it reads the same on a light screen and a dark one.
/// Nil where `text` is empty or CoreImage makes none.
func qrPicture(_ text: String, modulePoints: Int = 8) -> UIImage? {
    guard !text.isEmpty else { return nil }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage,
          let raw = qrContext.createCGImage(output, from: output.extent)
    else { return nil }
    let quiet = 4
    let side = CGFloat((raw.width + 2 * quiet) * modulePoints)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
        UIColor.white.setFill()
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // Modules are squares: scaled up with no smoothing, so each edge
        // stays sharp however the screen scales the picture again.
        context.cgContext.interpolationQuality = .none
        UIImage(cgImage: raw).draw(in: CGRect(
            x: CGFloat(quiet * modulePoints), y: CGFloat(quiet * modulePoints),
            width: CGFloat(raw.width * modulePoints), height: CGFloat(raw.height * modulePoints)
        ))
    }
}

/// A pairing's QR, drawn when this view is. It has the string and nothing
/// else, so SwiftUI draws it again only for another string, not on each
/// tick of the countdown beside it.
struct PairingQRImage: View {
    let text: String

    var body: some View {
        if let picture = qrPicture(text) {
            Image(uiImage: picture)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("QR code of the pairing, for the new device to scan")
        } else {
            Text("The QR would not draw: type the code")
                .themeType(.body)
                .foregroundStyle(ThemeColor.textSecondary.color)
        }
    }
}

/// What a decision shows in place of the card once its pairing was
/// approved: the QR, the code, the minutes left and End; or, once the
/// pairing is over, that and nothing of the code.
struct ApprovedPairingView: View {
    let screen: PairingScreen
    var onEnd: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair \(screen.device) for \(screen.user)")
                .themeType(.title)
                .foregroundStyle(ThemeColor.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
            switch screen.phase {
            case .showing(let pairing):
                if scenePhase == .active {
                    showing(pairing)
                } else {
                    Text("The code is hidden while this app is not in front")
                        .themeType(.body)
                        .foregroundStyle(ThemeColor.textSecondary.color)
                        .accessibilityIdentifier("pairing-hidden")
                }
            case .over(let over):
                Text(pairingOverWords(over))
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textSecondary.color)
                    .accessibilityIdentifier("pairing-over")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func showing(_ pairing: Pairing) -> some View {
        PairingQRImage(text: pairing.qr)
            .frame(maxWidth: 280, maxHeight: 280)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("pairing-qr")
        // The code is typed into a device with no camera, so it is the
        // mono face at the title's size. It is not selectable: a copy of it
        // would stand on the system's pasteboard, which other apps and the
        // person's other devices read, and it is to be shown to the device
        // and nobody else.
        Text(pairing.code)
            .font(.custom(ThemeType.code.face, size: ThemeType.title.size, relativeTo: ThemeType.title.textStyle))
            .foregroundStyle(ThemeColor.textPrimary.color)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("pairing-code")
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(pairingLeft(expires: pairing.expires, now: timeline.date))
                .themeType(.meta)
                .foregroundStyle(ThemeColor.textSecondary.color)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("pairing-left")
        }
        if screen.canEnd {
            Button(screen.ending ? "Ending…" : "End", action: onEnd)
                .buttonStyle(FootplateButtonStyle(primary: false))
                .disabled(screen.ending)
                .accessibilityHint("Ends this pairing, so its code is good for nothing")
                .accessibilityIdentifier("pairing-end")
        } else {
            // A pairing of another user's: the yard ends it for its own
            // user's device and for a terminal on the yard's machine.
            (Text("To end it sooner, run ") + Text("yardr user device pair --end").font(ThemeType.code.font) + Text(" on the yard"))
                .themeType(.meta)
                .foregroundStyle(ThemeColor.textSecondary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("pairing-end-elsewhere")
        }
        if let refusal = screen.refusal {
            Text(refusal)
                .themeType(.body)
                .foregroundStyle(ThemeColor.textError.color)
        }
    }
}
