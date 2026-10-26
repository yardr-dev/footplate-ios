import Foundation
import UIKit

// A picture shrunk for a letter (after Android's model/Images.kt):
// a full-size phone photo (3 to 8 MB) would not cross the edge —
// one frame carries 3 MiB, and a call's body 1 MiB — so the
// picture goes as a JPEG of about 1600 px on the long side, a few
// hundred KB. The encode is fresh, so no EXIF (and no location)
// survives; `UIImage` has applied the orientation to the picture
// it draws, so nothing arrives sideways.

/// The long side a letter's picture is shrunk to.
let letterLongSide = 1600

/// The most bytes a letter's picture is: its base64 still fits a
/// call's 1 MiB body, and far under the edge's 3 MiB frame.
let letterPictureFit = 700_000

/// The size a picture of `width` by `height` is drawn at: the
/// long side `longSide`, the aspect kept, never grown.
func targetSize(width: Int, height: Int, longSide: Int = letterLongSide) -> (width: Int, height: Int) {
    let longest = max(width, height)
    if longest <= longSide { return (width, height) }
    let scale = Double(longSide) / Double(longest)
    return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
}

private let bidiControls: Set<UInt32> = [
    0x061C, 0x200E, 0x200F,
    0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
    0x2066, 0x2067, 0x2068, 0x2069,
]

/// The name a letter carries the picture under: the picked `name`
/// with a `.jpg` ending, since the bytes are converted. Mail takes
/// only a base name and refuses separators, controls, bidi
/// controls, and names over 255 UTF-8 bytes, so keep the useful
/// part and make the result valid.
func jpegName(_ name: String) -> String {
    let base = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
    let baseName = base.split(separator: "\\", omittingEmptySubsequences: false).last.map(String.init) ?? base
    var safe = ""
    for scalar in baseName.unicodeScalars {
        let point = scalar.value
        if (0xD800...0xDFFF).contains(point) { continue }
        if point <= 0x1F || (0x7F...0x9F).contains(point) { continue }
        if bidiControls.contains(point) { continue }
        if point == 0x2028 || point == 0x2029 { continue }
        safe.unicodeScalars.append(scalar)
    }
    let stem: String
    if let dot = safe.lastIndex(of: ".") {
        let head = String(safe[..<dot])
        stem = head.isEmpty || head == "." || head == ".." ? "photo" : head
    } else {
        stem = safe.isEmpty || safe == "." || safe == ".." ? "photo" : safe
    }
    var limited = ""
    var bytes = 0
    for scalar in stem.unicodeScalars {
        let count = scalar.utf8.count
        if bytes + count > 255 - 4 { break }
        limited.unicodeScalars.append(scalar)
        bytes += count
    }
    return "\(limited.isEmpty ? "photo" : limited).jpg"
}

/// A picture picked on the phone, shrunk to a JPEG a letter can
/// carry, or nil where it is no picture: the long side 1600 at
/// quality 85 first, then down the ladder (70, 55; 1200, 800 px)
/// until it fits `letterPictureFit`. The first fit wins; where
/// nothing fits, the smallest.
func downscaleForLetter(_ bytes: Data) -> Data? {
    guard let image = UIImage(data: bytes) else { return nil }
    let pixelWidth = Int((image.size.width * image.scale).rounded())
    let pixelHeight = Int((image.size.height * image.scale).rounded())
    guard pixelWidth > 0, pixelHeight > 0 else { return nil }
    var smallest: Data? = nil
    for longSide in [letterLongSide, 1200, 800] {
        let size = targetSize(width: pixelWidth, height: pixelHeight, longSide: longSide)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let shrunk = UIGraphicsImageRenderer(size: CGSize(width: size.width, height: size.height), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }
        for quality in [0.85, 0.70, 0.55] {
            guard let jpeg = shrunk.jpegData(compressionQuality: quality) else { continue }
            smallest = jpeg
            if jpeg.count <= letterPictureFit { return jpeg }
        }
    }
    return smallest
}
