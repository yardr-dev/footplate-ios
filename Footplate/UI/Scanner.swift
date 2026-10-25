import SwiftUI
import VisionKit

// The QR is read by VisionKit's DataScannerViewController, which
// draws the camera view itself and hands back the recognised text,
// so the app holds no capture-session code of its own (design 3.2).
// Where it cannot run the Pair screen says so and Type the code
// stands.

enum ScannerAvailability {
    static var isAvailable: Bool {
        // Only the Pair screen asks, on the main actor; VisionKit
        // marks the checks main-actor-isolated without annotating
        // its callers.
        MainActor.assumeIsolated {
            DataScannerViewController.isSupported && DataScannerViewController.isAvailable
        }
    }

    static let unavailableLine = "The scanner cannot run here. Type the code instead."
    static let nothingReadLine = "The scanner read no text. Scan the code again, or type it."
    static let failedLine = "The scanner did not open. Type the code instead."
}

struct ScannerView: UIViewControllerRepresentable {
    var onRead: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRead: onRead)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onRead = onRead
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onRead: (String) -> Void

        init(onRead: @escaping (String) -> Void) {
            self.onRead = onRead
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            handle(addedItems)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didTapOn item: RecognizedItem
        ) {
            handle([item])
        }

        private func handle(_ items: [RecognizedItem]) {
            for item in items {
                switch item {
                case .barcode(let barcode):
                    if let payload = barcode.payloadStringValue, !payload.isEmpty {
                        onRead(payload)
                        return
                    }
                case .text(let text):
                    if !text.transcript.isEmpty {
                        onRead(text.transcript)
                        return
                    }
                @unknown default:
                    continue
                }
            }
        }
    }
}
