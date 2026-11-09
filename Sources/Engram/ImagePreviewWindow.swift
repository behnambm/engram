import AppKit

/// A borderless, floating window that shows a clip's image at a magnified size — no
/// title bar, traffic lights, or chrome. Clicking anywhere or pressing Escape closes it.
@MainActor
final class ImagePreviewWindowController {
    private let window: NSWindow
    var onClose: (() -> Void)?

    init(image: NSImage) {
        let size = Self.previewSize(for: image.size)
        window = BorderlessKeyWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        window.isReleasedWhenClosed = false

        let container = PreviewContainerView(frame: NSRect(origin: .zero, size: size))
        container.image = image
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.onClose = { [weak self] in self?.close() }

        window.contentView = container
        window.center()
    }

    func present() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(window.contentView)
    }

    func close() {
        window.close()
        onClose?()
    }

    /// Scales the image so its larger side is ~600pt, with a floor so tiny images still
    /// produce a usable window.
    private static func previewSize(for imageSize: NSSize) -> NSSize {
        let target: CGFloat = 600
        let w = max(imageSize.width, 1)
        let h = max(imageSize.height, 1)
        let scale = target / max(w, h)
        return NSSize(width: max(w * scale, 160), height: max(h * scale, 160))
    }
}

/// A borderless window that can still become key, so keyboard shortcuts (Escape, left
/// arrow) reach its content view.
@MainActor
private final class BorderlessKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Draws the image scaled to fit and reports clicks and Escape so the preview can close.
@MainActor
private final class PreviewContainerView: NSView {
    var image: NSImage?
    var onClose: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        guard let image else { return }
        let imageSize = image.size
        let scale = min(
            bounds.width / max(imageSize.width, 1),
            bounds.height / max(imageSize.height, 1)
        )
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        let rect = NSRect(
            x: (bounds.width - w) / 2,
            y: (bounds.height - h) / 2,
            width: w,
            height: h
        )
        image.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    override func mouseDown(with event: NSEvent) {
        onClose?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onClose?()
    }

    override func keyDown(with event: NSEvent) {
        // Escape (53) or left arrow (123) closes the preview.
        if event.keyCode == 53 || event.keyCode == 123 {
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }
}
