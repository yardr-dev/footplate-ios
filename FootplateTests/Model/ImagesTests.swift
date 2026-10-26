@testable import Footplate
import UIKit
import XCTest

// A picture shrunk for a letter: the target size, the name, and
// the downscale driven end to end through the platform codec
// (after Android's ImagesTest). A large input stands for a phone
// photo.
final class ImagesTests: XCTestCase {
    func testTheLongSideIs1600AndTheAspectIsKept() {
        XCTAssertEqual(targetSize(width: 4000, height: 3000).width, 1600)
        XCTAssertEqual(targetSize(width: 4000, height: 3000).height, 1200)
        XCTAssertEqual(targetSize(width: 3000, height: 4000).width, 1200)
        XCTAssertEqual(targetSize(width: 3000, height: 4000).height, 1600)
        XCTAssertEqual(targetSize(width: 4000, height: 1000).height, 400)
        XCTAssertEqual(targetSize(width: 100, height: 4000).width, 40)
        // Smaller already: as it is, never grown.
        XCTAssertEqual(targetSize(width: 800, height: 600).width, 800)
        XCTAssertEqual(targetSize(width: 1600, height: 1200).height, 1200)
    }

    func testTheNameIsAValidBaseNameForTheJpeg() {
        XCTAssertEqual(jpegName("yard.png"), "yard.jpg")
        XCTAssertEqual(jpegName("IMG_1234.HEIC"), "IMG_1234.jpg")
        XCTAssertEqual(jpegName("a.b.png"), "a.b.jpg")
        XCTAssertEqual(jpegName("photo"), "photo.jpg")
        XCTAssertEqual(jpegName(""), "photo.jpg")
        XCTAssertEqual(jpegName("/private/photos/shed.png"), "shed.jpg")
        XCTAssertEqual(jpegName("C:\\photos\\shed.heic"), "shed.jpg")
        XCTAssertEqual(jpegName("exe\u{202E}gpj.png"), "exegpj.jpg")
        XCTAssertEqual(jpegName("a\nb.png"), "ab.jpg")
        XCTAssertEqual(jpegName(".."), "photo.jpg")
        XCTAssertEqual(jpegName(String(repeating: "x", count: 300) + ".png").utf8.count, 255)
        XCTAssertEqual(jpegName(String(repeating: "😀", count: 100) + ".png").utf8.count, 252)
    }

    func testDownscaleFitsALargePhotoAndIgnoresWhatIsNotAPicture() throws {
        // A smooth photo-like gradient, 1200 by 900: over the fit
        // only in pixels, so the ladder's first size stands.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1800), format: format).image { context in
            UIColor(red: 0.4, green: 0.3, blue: 0.2, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1800))
        }
        let jpeg = try XCTUnwrap(photo.jpegData(compressionQuality: 0.9))
        let shrunk = try XCTUnwrap(downscaleForLetter(jpeg), "no picture shrunk")
        let back = try XCTUnwrap(UIImage(data: shrunk), "the shrunk bytes are no picture")
        XCTAssertEqual(Int(back.size.width * back.scale), 1600)
        XCTAssertEqual(Int(back.size.height * back.scale), 1200)
        XCTAssertLessThanOrEqual(shrunk.count, letterPictureFit)
        XCTAssertTrue(isPicture(shrunk))
        // No picture is the same downscale path, with no output.
        XCTAssertNil(downscaleForLetter(Data("not a picture".utf8)))
        XCTAssertNil(downscaleForLetter(Data()))
    }
}
