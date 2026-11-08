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
