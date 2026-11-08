@testable import Footplate
import SwiftUI
import UIKit

/// A picture for a note to carry in the screenshot tests, drawn here so
/// they need no fixture file: a timetable board in the brand's surface and
/// ink.
func timetablePNG() -> Data {
    let size = CGSize(width: 720, height: 450)
    return UIGraphicsImageRenderer(size: size).pngData { context in
        UIColor(ThemeColor.surfaceRaised.color).setFill()
        context.fill(CGRect(origin: .zero, size: size))
        let ink = UIColor(ThemeColor.textPrimary.color)
        let faint = UIColor(ThemeColor.borderStrong.color)
        let font = UIFont.monospacedSystemFont(ofSize: 38, weight: .regular)
        let rows = [("01:40", "Freight", "on time"), ("02:00", "Night run", "on time"), ("02:25", "Day run", "held")]
        for (index, row) in rows.enumerated() {
            let y = 70 + CGFloat(index) * 110
            faint.setFill()
            context.fill(CGRect(x: 40, y: y + 70, width: size.width - 80, height: 2))
            for (text, x) in [(row.0, 40), (row.1, 190), (row.2, 500)] as [(String, CGFloat)] {
                (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: ink])
            }
        }
    }
}

/// A picture that says what it is in large type, for the shots of a bead's
/// media, where the order of a grid shows by what each says: `title` on the
/// brand's raised surface under a rust edge, small enough to stay whole in
/// the square a grid crops it to.
func labelledPNG(_ title: String, size: CGSize = CGSize(width: 720, height: 450)) -> Data {
    UIGraphicsImageRenderer(size: size).pngData { context in
        UIColor(ThemeColor.surfaceRaised.color).setFill()
        context.fill(CGRect(origin: .zero, size: size))
        UIColor(ThemeColor.accent.color).setFill()
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: 18))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: min(size.width, size.height) / 9, weight: .semibold),
            .foregroundColor: UIColor(ThemeColor.textPrimary.color),
        ]
        let text = title as NSString
        let box = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (size.width - box.width) / 2, y: (size.height - box.height) / 2), withAttributes: attributes)
    }
}
