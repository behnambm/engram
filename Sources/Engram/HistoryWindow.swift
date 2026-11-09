import AppKit

/// The clipboard history window: centered, searchable, keyboard driven, and it closes as
/// soon as a clip has been copied.
///
/// The surface follows the system appearance (light and dark) and uses native materials,
/// controls, and colors — the same frosted "popover" look and accent-colored selection
/// as Finder, Spotlight, and System Settings.
@MainActor
final class HistoryWindowController: NSWindowController {
    /// Only one page is ever loaded, so opening and filtering stay ~1 ms no matter how
    /// large the history is.
    private static let displayLimit = 200
    private static let searchTopInset: CGFloat = 46
    private static let rowHeight: CGFloat = 46

    private let store: ClipStore
    private let searchField = NSSearchField()
    private let tableView = HistoryTableView()
    private let emptyLabel = NSTextField(labelWithString: "No clips yet — copy something first")
    private let statusLabel = NSTextField(labelWithString: "")

    private var clips: [Clip] = []

    /// The app that was frontmost before this window opened. A menu-bar agent keeps
    /// activation when its window closes, so focus has to be handed back explicitly or
    /// the next ⌘V goes nowhere.
    private var previousApp: NSRunningApplication?

    init(store: ClipStore) {
        self.store = store
        super.init(window: NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        ))
        window?.title = "Engram"
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden
        window?.isMovableByWindowBackground = true
        window?.backgroundColor = .clear
        window?.isOpaque = false
        window?.hasShadow = true
        // A hotkey palette must appear on the desktop the user is on, not the one the
        // agent happened to launch from. moveToActiveSpace does that without switching
        // Spaces; fullScreenAuxiliary lets it show over a full-screen app.
        window?.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window?.isReleasedWhenClosed = false
        window?.minSize = NSSize(width: 460, height: 320)
        window?.center()
        window?.contentView = makeContentView()
        window?.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        // Remember who had focus before we steal it, so it can be given back on close.
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }

        searchField.stringValue = ""
        reload()

        window?.center()

        // A background agent is not active, and macOS refuses focus requests that do not
        // follow user input. Ask for activation, then order the window front regardless so
        // it is never hidden behind the app the user came from.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()

        // Typing is the first thing the user does here, so the search field takes focus
        // instead of the list.
        window?.makeFirstResponder(searchField)
    }

    private func makeContentView() -> NSView {
        let root = NSView()

        // The translucent popover material is the whole surface: it adapts to light and
        // dark automatically and lets the search field and table read as native controls.
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(material)

        // A native search field: rounded bezel, magnifier, and a clear (×) button that
        // appears once there is text. No custom border or container to fight with.
        searchField.placeholderString = "Search history"
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 15)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.style = .inset
        tableView.selectionHighlightStyle = .regular
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.onActivate = { [weak self] in self?.copySelected() }
        tableView.onCancel = { [weak self] in self?.window?.close() }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Observe scroll so lingering trash hover can be reset when rows move under a
        // stationary cursor (see clipViewDidScroll).
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(scrollView)
        root.addSubview(statusLabel)
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: root.topAnchor),
            material.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            material.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            material.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.searchTopInset),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        return root
    }

    // MARK: - Filtering

    private func reload() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        clips = store.search(query, limit: Self.displayLimit)

        tableView.reloadData()
        if !clips.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }

        emptyLabel.isHidden = !clips.isEmpty
        if clips.isEmpty {
            emptyLabel.stringValue = query.isEmpty
                ? "No clips yet — copy something first"
                : "No matches"
        }

        updateStatus(for: query)
    }

    /// Bottom status: total count normally, match info while a query is active.
    private func updateStatus(for query: String) {
        let total = store.count
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            statusLabel.stringValue = "\(total.formatted()) clip\(total == 1 ? "" : "s")"
        } else {
            // The rows shown are the union of prefix + substring matches (see
            // ClipStore.search), capped at displayLimit. A "+" marks a capped page.
            let capped = clips.count == Self.displayLimit
            statusLabel.stringValue = "\(clips.count.formatted())\(capped ? "+" : "") of \(total.formatted())"
        }
        statusLabel.isHidden = false
    }

    private func moveSelection(by delta: Int) {
        guard !clips.isEmpty else { return }
        let current = tableView.selectedRow < 0 ? 0 : tableView.selectedRow
        let next = min(max(current + delta, 0), clips.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: - Copying

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard clips.indices.contains(row) else { return }
        copy(clips[row])
    }

    private func copySelected() {
        let row = tableView.selectedRow
        guard clips.indices.contains(row) else { return }
        copy(clips[row])
    }

    private func copy(_ clip: Clip) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(clip.text, forType: .string)
        window?.close()
    }

    // MARK: - Deleting

    private func deleteClip(_ clip: Clip) {
        store.delete(id: clip.id)
        reload()
    }

    private func deleteSelected() {
        let row = tableView.selectedRow
        guard clips.indices.contains(row) else { return }
        deleteClip(clips[row])
    }

    /// Hover mirrors keyboard selection: hovering a row selects it, so Return and Delete
    /// act on the entry under the pointer.
    private func selectClip(_ clip: Clip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    /// Scrolling moves rows under a stationary cursor without a mouse-moved event, so a
    /// trash button would linger on the row the pointer already left. Reset hover on every
    /// visible row whenever the clip view scrolls.
    @objc private func clipViewDidScroll() {
        let rows = tableView.rows(in: tableView.visibleRect)
        guard rows.length > 0 else { return }
        for row in rows.location..<NSMaxRange(rows) {
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? HistoryCellView {
                cell.resetHover()
            }
        }
    }
}

extension HistoryWindowController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        reload()
    }

    /// The search field is edited by a field editor, so its keys never reach `keyDown`.
    /// This is the AppKit hook that catches navigation commands before the editor handles
    /// them — arrow keys move the list, Return copies, Escape closes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            copySelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            window?.close()
            return true
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
            // Backspace edits the query while it has text; on an empty field the delete
            // key removes the selected entry instead.
            if searchField.stringValue.isEmpty {
                deleteSelected()
                return true
            }
            return false
        default:
            return false
        }
    }
}

extension HistoryWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        clips.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let clip = clips[row]
        return HistoryCellView(
            clip: clip,
            onDelete: { [weak self] in self?.deleteClip(clip) },
            onHoverEnter: { [weak self] in self?.selectClip(clip) }
        )
    }
}

extension HistoryWindowController: NSWindowDelegate {
    /// Every close path lands here — Return, click, Escape, or the title-bar button.
    func windowWillClose(_ notification: Notification) {
        guard let app = previousApp else { return }
        previousApp = nil

        // Hand activation back once the window is actually gone, so the user's next
        // keystroke (⌘V) goes to the app they were working in.
        DispatchQueue.main.async {
            app.activate()
        }
    }
}

/// Table view that reports Return and Escape instead of swallowing them.
@MainActor
private final class HistoryTableView: NSTableView {
    var onActivate: (@MainActor () -> Void)?
    var onCancel: (@MainActor () -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:  // Return, keypad Enter
            onActivate?()
        case 53:  // Escape
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}

/// A borderless trash button whose hover ring is a true circle. The ring is a circular
/// `CAShapeLayer` path (not a rounded-rect border), so it can never stretch into an oval
/// no matter how the button is sized.
@MainActor
private final class TrashButton: NSButton {
    private let ringLayer = CAShapeLayer()

    var showsRing = false {
        didSet { ringLayer.isHidden = !showsRing }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        ringLayer.fillColor = nil
        ringLayer.strokeColor = NSColor.systemRed.cgColor
        ringLayer.lineWidth = 1.0
        ringLayer.isHidden = true
        layer?.addSublayer(ringLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        ringLayer.frame = bounds
        let diameter = min(bounds.width, bounds.height)
        let circle = NSRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        ).insetBy(dx: ringLayer.lineWidth / 2, dy: ringLayer.lineWidth / 2)
        ringLayer.path = CGPath(ellipseIn: circle, transform: nil)
    }
}

/// Renders the clip as a two-line row: the source app's icon on the left, the preview
/// on the first line, and "App · time ago" on the second.
///
/// Selection uses the table view's native `.inset` style (system accent color, rounded
/// corners), so this cell only supplies semantic label colors that adapt to light/dark
/// and flip to white when the row is selected. App icons are full-color and stay
/// unchanged on selection, exactly as Spotlight shows them.
@MainActor
private final class HistoryCellView: NSTableCellView {
    private let clip: Clip
    private let onDelete: (@MainActor () -> Void)
    private let onHoverEnter: (@MainActor () -> Void)
    private let iconView = NSImageView()
    private let textLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let trashButton = TrashButton()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter
    }()

    /// Resolving an icon is a disk lookup, so cache by bundle id. Cells are rebuilt on
    /// every filter, but the cache persists for the window's lifetime.
    private static var iconCache: [String: NSImage] = [:]

    private static func appIcon(for bundleID: String) -> NSImage {
        if let cached = iconCache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!
        iconCache[bundleID] = icon
        return icon
    }

    private static func shortTimestamp(for date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return seconds == 0 ? "now" : "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        if seconds < 604_800 { return "\(seconds / 86_400)d" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    init(clip: Clip, onDelete: @escaping @MainActor () -> Void, onHoverEnter: @escaping @MainActor () -> Void) {
        self.clip = clip
        self.onDelete = onDelete
        self.onHoverEnter = onHoverEnter
        super.init(frame: .zero)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.usesSingleLineMode = true
        textLabel.maximumNumberOfLines = 1
        textLabel.toolTip = clip.text
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.usesSingleLineMode = true
        detailLabel.maximumNumberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // A borderless, red trash button revealed on hover.
        let trashImage = NSImage(systemSymbolName: "trash.fill", accessibilityDescription: "Delete clip")
        trashImage?.isTemplate = true
        trashButton.image = trashImage
        trashButton.isBordered = false
        trashButton.contentTintColor = .systemRed
        trashButton.toolTip = "Delete clip"
        trashButton.target = self
        trashButton.action = #selector(deleteTapped)
        trashButton.isHidden = true
        trashButton.translatesAutoresizingMaskIntoConstraints = false

        // Scoped to the button so the red ring and hand cursor appear only while the
        // pointer is over the trash icon, even though the button is usually hidden.
        trashButton.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: ["kind": "trash"]
        ))

        addSubview(iconView)
        addSubview(textLabel)
        addSubview(detailLabel)
        addSubview(trashButton)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            textLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: trashButton.leadingAnchor, constant: -8),
            textLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),

            detailLabel.leadingAnchor.constraint(equalTo: textLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trashButton.leadingAnchor, constant: -8),
            detailLabel.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 2),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -7),

            trashButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trashButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            trashButton.widthAnchor.constraint(equalToConstant: 28),
            trashButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        render()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: ["kind": "row"]
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea?.userInfo?["kind"] as? String == "trash" {
            setTrashHovered(true)
        } else {
            trashButton.isHidden = false
            onHoverEnter()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea?.userInfo?["kind"] as? String == "trash" {
            setTrashHovered(false)
        } else {
            trashButton.isHidden = true
            setTrashHovered(false)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    private func setTrashHovered(_ hovered: Bool) {
        trashButton.showsRing = hovered
    }

    @objc private func deleteTapped() {
        onDelete()
    }

    /// Hides the trash button and ring without waiting for a mouse-exited event. Called
    /// on scroll, where rows move under a stationary cursor.
    func resetHover() {
        trashButton.isHidden = true
        setTrashHovered(false)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    private func render() {
        let emphasized = backgroundStyle == .emphasized
        let primary = emphasized ? NSColor.selectedTextColor : NSColor.labelColor
        let secondary = emphasized
            ? NSColor.selectedTextColor.withAlphaComponent(0.72)
            : NSColor.secondaryLabelColor

        textLabel.attributedStringValue = NSAttributedString(
            string: clip.preview,
            attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: primary]
        )

        let age = Self.shortTimestamp(for: clip.createdAt)
        detailLabel.stringValue = [clip.appName, age].compactMap { $0 }.joined(separator: " · ")
        detailLabel.textColor = secondary
        detailLabel.font = .systemFont(ofSize: 11)

        if let bundle = clip.appBundle, !bundle.isEmpty {
            iconView.image = Self.appIcon(for: bundle)
        } else {
            iconView.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        }
    }
}
