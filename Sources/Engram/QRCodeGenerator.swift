import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// QR-code generation from text.
///
/// Symmetric to `QRCodeScanner` (which reads QR codes): this turns a text clip into a
/// PNG QR image so it can be pasted anywhere as a scannable code.
enum QRCodeGenerator {
    /// A black-on-white QR-code PNG encoding `text`, with a 4-module quiet zone (the
    /// white margin scanners need to locate the code). Returns `nil` when the text is
    /// too long for a QR code to hold — the QR format has a hard byte capacity.
    static func pngQRCode(for text: String) -> Data? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // The filter emits one point per module; scale up so modules are crisp instead of
        // sub-pixel, and pad with a 4-module white margin.
        let scale: CGFloat = 12
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let margin = 4 * scale

        let background = CIImage(color: .white).cropped(
            to: scaled.extent.insetBy(dx: -margin, dy: -margin)
        )
        let qr = scaled
            .transformed(by: CGAffineTransform(translationX: margin, y: margin))
            .composited(over: background)

        let context = CIContext()
        guard let cgImage = context.createCGImage(qr, from: qr.extent) else { return nil }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        return representation.representation(using: .png, properties: [:])
    }
}
