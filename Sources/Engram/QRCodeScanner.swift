import Foundation
import ImageIO
import Vision

/// QR-code detection over raw image bytes.
///
/// Uses Vision's `VNDetectBarcodesRequest` restricted to the `.qr` symbology. It runs
/// entirely on-device and needs no permission or entitlement. Detection is synchronous:
/// it is only invoked from a user button tap, never from the clipboard capture path.
enum QRCodeScanner {
    /// Returns the payloads of every QR code found in `imageData`, in Vision's detection
    /// order. Empty when the image cannot be decoded or contains no QR code.
    static func decodeQRCodes(in imageData: Data) -> [String] {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return []
        }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: imageOrientation(of: source),
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let observations = request.results else { return [] }
        return observations.compactMap { $0.payloadStringValue }
    }

    /// The EXIF orientation stored in the image, or `.up` when absent (PNG screenshots and
    /// most copied images carry none). Passing the real orientation lets Vision decode QR
    /// codes in rotated photos instead of only upright ones.
    private static func imageOrientation(of source: CGImageSource) -> CGImagePropertyOrientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let number = properties[kCGImagePropertyOrientation] as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: number.uint32Value) else {
            return .up
        }
        return orientation
    }
}
