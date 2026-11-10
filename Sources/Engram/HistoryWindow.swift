import AppKit

/// The clipboard history window: centered, searchable, keyboard driven, and it closes as
/// soon as a clip has been copied.
///
/// The surface follows the system appearance (light and dark) and uses native materials,
/// controls, and colors — the same frosted "popover" look and accent-colored selection
/// as Finder, Spotlight, and System Settings.
@MainActor
final class HistoryWindowController: NSWindowController {
    /// Page size for infinite scroll: the list loads this many clips at a time and fetches
    /// more as the user scrolls.
    private static let pageSize = 100
    private static let searchTopInset: CGFloat = 46
    private static let rowHeight: CGFloat = 46

    private let store: ClipStore
    private let searchField = NSSearchField()
    private let tableView = HistoryTableView()
    private let emptyLabel = NSTextField(labelWithString: "No clips yet — copy something first")
    private let statusLabel = NSTextField(labelWithString: "")

    private var clips: [Clip] = []

    /// Whether more clips exist beyond what's currently loaded (infinite scroll).
    private var hasMore = false
    private var isLoadingMore = false

    /// The app that was frontmost before this window opened. A menu-bar agent keeps
    /// activation when its window closes, so focus has to be handed back explicitly or
    /// the next ⌘V goes nowhere.
    private var previousApp: NSRunningApplication?

    /// The magnified image preview, if currently open.
    private var previewWindow: ImagePreviewWindowController?

    // MARK: - Date filter

    private struct DateFilter {
        let title: String
        /// The lookback window in hours; `nil` means "any time".
        let hours: Int?
    }

    private static let dateFilters: [DateFilter] = [
        DateFilter(title: "Any time", hours: nil),
        DateFilter(title: "Past hour", hours: 1),
        DateFilter(title: "Past 3 hours", hours: 3),
        DateFilter(title: "Past 12 hours", hours: 12),
        DateFilter(title: "Yesterday", hours: 24),
        DateFilter(title: "Last week", hours: 24 * 7),
    ]

    private var dateFilterButtons: [ChipButton] = []
    private var selectedDateFilterIndex = 0

    init(store: ClipStore) {
        self.store = store
        super.init(window: NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
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
        window?.minSize = NSSize(width: 540, height: 340)
        window?.center()
        window?.contentView = makeContentView()
        window?.delegate = self

        // Close the window when the user focuses another app.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
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
        selectDateFilter(0)
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

        let dateFilterRow = makeDateFilterRow()

        root.addSubview(searchField)
        root.addSubview(dateFilterRow)
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

            dateFilterRow.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            dateFilterRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            dateFilterRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: dateFilterRow.bottomAnchor, constant: 10),
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

    // MARK: - Date filter

    private func makeDateFilterRow() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, filter) in Self.dateFilters.enumerated() {
            let button = ChipButton()
            button.baseTitle = filter.title
            button.target = self
            button.action = #selector(dateFilterChanged(_:))
            button.tag = index
            button.isSelected = index == selectedDateFilterIndex
            stack.addArrangedSubview(button)
            dateFilterButtons.append(button)
        }
        return stack
    }

    private func selectDateFilter(_ index: Int) {
        selectedDateFilterIndex = index
        for (buttonIndex, button) in dateFilterButtons.enumerated() {
            button.isSelected = buttonIndex == index
        }
    }

    @objc private func dateFilterChanged(_ sender: NSButton) {
        selectDateFilter(sender.tag)
        reload()
    }

    private func currentSinceDate() -> Date? {
        guard let hours = Self.dateFilters[selectedDateFilterIndex].hours else { return nil }
        return Date().addingTimeInterval(-Double(hours) * 3600)
    }

    // MARK: - Filtering

    private func reload() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let since = currentSinceDate()
        let results = store.search(query, limit: Self.pageSize + 1, since: since)
        if results.count > Self.pageSize {
            hasMore = true
            clips = Array(results.prefix(Self.pageSize))
        } else {
            hasMore = false
            clips = results
        }

        tableView.reloadData()
        if !clips.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }

        emptyLabel.isHidden = !clips.isEmpty
        if clips.isEmpty {
            if !query.isEmpty {
                emptyLabel.stringValue = "No matches"
            } else if selectedDateFilterIndex != 0 {
                emptyLabel.stringValue = "No clips in this time range"
            } else {
                emptyLabel.stringValue = "No clips yet — copy something first"
            }
        }

        updateStatus(for: query, since: since)
    }

    /// Infinite scroll: fetches the next page of results, keyed by the last clip's id.
    private func loadMore() {
        guard hasMore, !isLoadingMore, let last = clips.last else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let since = currentSinceDate()
        let next = store.search(query, limit: Self.pageSize + 1, since: since, beforeId: last.id)
        if next.count > Self.pageSize {
            hasMore = true
            clips.append(contentsOf: next.prefix(Self.pageSize))
        } else {
            hasMore = false
            clips.append(contentsOf: next)
        }
        tableView.reloadData()
        updateStatus(for: query, since: since)
    }

    /// Bottom status: total count normally, match info while a query is active.
    private func updateStatus(for query: String, since: Date?) {
        let total = since.map { store.count(since: $0) } ?? store.count
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            statusLabel.stringValue = "\(total.formatted()) clip\(total == 1 ? "" : "s")"
        } else {
            // The rows shown are the union of prefix + substring matches (see
            // ClipStore.search). A "+" marks that more results are available on scroll.
            statusLabel.stringValue = "\(clips.count.formatted())\(hasMore ? "+" : "") of \(total.formatted())"
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
        if clip.isImage, let imageData = store.imageData(id: clip.id) {
            pasteboard.setData(imageData, forType: .png)
        } else {
            pasteboard.setString(clip.text, forType: .string)
        }
        window?.close()
    }

    // MARK: - Deleting

    private func deleteClip(_ clip: Clip) {
        store.delete(id: clip.id)
        HistoryCellView.invalidateThumbnail(for: clip.id)
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

    // MARK: - Image preview

    private func showPreview(for clip: Clip) {
        guard clip.isImage,
              let data = store.imageData(id: clip.id),
              let image = NSImage(data: data) else { return }
        previewWindow?.close()
        let controller = ImagePreviewWindowController(image: image)
        controller.onClose = { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.window?.makeKeyAndOrderFront(nil)
        }
        previewWindow = controller
        controller.present()
    }

    /// Closes any open image preview without triggering its focus-restore callback.
    private func dismissPreview() {
        previewWindow?.onClose = nil
        previewWindow?.close()
        previewWindow = nil
    }

    private func previewSelectedImage() {
        let row = tableView.selectedRow
        guard clips.indices.contains(row), clips[row].isImage else { return }
        showPreview(for: clips[row])
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

        // Infinite scroll: load the next page when the user nears the bottom.
        let lastVisible = rows.location + rows.length
        if hasMore && lastVisible >= clips.count - 15 {
            loadMore()
        }
    }

    /// Close the history when the user focuses another app. Drop the previous-app handoff
    /// first, so we don't steal focus back after the user deliberately switched away.
    @objc private func appDidResignActive() {
        guard window?.isVisible == true else { return }
        previousApp = nil
        dismissPreview()
        window?.close()
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
        case #selector(NSResponder.moveRight(_:)):
            // Right arrow opens the image preview (like Quick Look); while typing it still
            // moves the text cursor.
            if searchField.stringValue.isEmpty {
                previewSelectedImage()
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
            onHoverEnter: { [weak self] in self?.selectClip(clip) },
            onPreview: { [weak self] in self?.showPreview(for: clip) }
        )
    }
}

extension HistoryWindowController: NSWindowDelegate {
    /// Every close path lands here — Return, click, Escape, or the title-bar button.
    func windowWillClose(_ notification: Notification) {
        dismissPreview()
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

/// A date-filter chip: a rounded pill that tints on hover and fills with the accent color
/// when selected. Shows a pointing-hand cursor on hover.
@MainActor
private final class ChipButton: NSButton {
    var baseTitle: String = "" {
        didSet { updateAppearance() }
    }

    var isSelected = false {
        didSet { updateAppearance() }
    }

    private var isHovering = false {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return NSSize(width: text.width + 18, height: text.height + 8)
    }

    private func updateAppearance() {
        let background: NSColor
        let foreground: NSColor
        if isSelected {
            background = .controlAccentColor
            foreground = .white
        } else if isHovering {
            background = .controlAccentColor.withAlphaComponent(0.18)
            foreground = .labelColor
        } else {
            background = .clear
            foreground = .labelColor
        }
        layer?.backgroundColor = background.cgColor
        attributedTitle = NSAttributedString(string: baseTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: foreground,
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas
        where area.options.contains(.mouseEnteredAndExited) || area.options.contains(.cursorUpdate) {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
}

/// A borderless icon button whose hover ring is a true circle. The ring is a circular
/// `CAShapeLayer` path (not a rounded-rect border), so it can never stretch into an oval
/// no matter how the button is sized. The icon and its ring share one color.
@MainActor
private final class RingButton: NSButton {
    private let ringLayer = CAShapeLayer()

    var showsRing = false {
        didSet { ringLayer.isHidden = !showsRing }
    }

    init(symbolName: String, ringColor: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        ringLayer.fillColor = nil
        ringLayer.strokeColor = ringColor.cgColor
        ringLayer.lineWidth = 1.0
        ringLayer.isHidden = true
        layer?.addSublayer(ringLayer)

        isBordered = false
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        self.image = image
        contentTintColor = ringColor
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

/// Renders the clip as a two-line row. Text clips show the source app's icon and the
/// preview; image clips show a thumbnail and an "Image" label, plus an eye button that
/// opens a magnified preview.
///
/// Selection uses the table view's native `.inset` style (system accent color, rounded
/// corners), so this cell only supplies semantic label colors that adapt to light/dark
/// and flip to white when the row is selected. Icons and thumbnails are full-color and
/// stay unchanged on selection, exactly as Spotlight shows them.
@MainActor
private final class HistoryCellView: NSTableCellView {
    private let clip: Clip
    private let onDelete: (@MainActor () -> Void)
    private let onHoverEnter: (@MainActor () -> Void)
    private let onPreview: (@MainActor () -> Void)
    private let leadingImageView = NSImageView()
    private let textLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let trashButton = RingButton(symbolName: "trash.fill", ringColor: .systemRed)
    private let eyeButton = RingButton(symbolName: "eye.fill", ringColor: .systemBlue)

    private var smallSizeConstraints: [NSLayoutConstraint] = []
    private var largeSizeConstraints: [NSLayoutConstraint] = []

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter
    }()

    /// Resolving an app icon is a disk lookup, so cache by bundle id. Cells are rebuilt
    /// on every filter, but the cache persists for the window's lifetime.
    private static var iconCache: [String: NSImage] = [:]

    /// Decoded thumbnails are cached by clip id so filtering does not re-decode images.
    /// `NSCache` bounds memory automatically instead of growing for the process lifetime.
    private static let thumbnailCache: NSCache<NSNumber, NSImage> = {
        let cache = NSCache<NSNumber, NSImage>()
        cache.countLimit = 500
        return cache
    }()

    /// Drops a cached thumbnail, e.g. when its clip is deleted. Clip ids are reused by
    /// SQLite (INTEGER PRIMARY KEY without AUTOINCREMENT), so a stale entry would
    /// otherwise be shown for a new clip that reuses the id.
    static func invalidateThumbnail(for id: Int64) {
        thumbnailCache.removeObject(forKey: NSNumber(value: id))
    }

    private static func appIcon(for bundleID: String) -> NSImage {
        if let cached = iconCache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!
        iconCache[bundleID] = icon
        return icon
    }

    private static func thumbnail(for clip: Clip) -> NSImage? {
        guard let data = clip.thumb else { return nil }
        if let cached = thumbnailCache.object(forKey: NSNumber(value: clip.id)) { return cached }
        guard let source = NSImage(data: data) else { return nil }
        // The source is already a small thumbnail; downscale to the cell's square so the
        // cache stays tiny.
        let side: CGFloat = 60
        let thumb = NSImage(size: NSSize(width: side, height: side))
        thumb.lockFocus()
        let imageSize = source.size
        let scale = min(side / max(imageSize.width, 1), side / max(imageSize.height, 1))
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        source.draw(
            in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        thumb.unlockFocus()
        thumbnailCache.setObject(thumb, forKey: NSNumber(value: clip.id))
        return thumb
    }

    private static func shortTimestamp(for date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return seconds == 0 ? "now" : "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        if seconds < 604_800 { return "\(seconds / 86_400)d" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    init(
        clip: Clip,
        onDelete: @escaping @MainActor () -> Void,
        onHoverEnter: @escaping @MainActor () -> Void,
        onPreview: @escaping @MainActor () -> Void
    ) {
        self.clip = clip
        self.onDelete = onDelete
        self.onHoverEnter = onHoverEnter
        self.onPreview = onPreview
        super.init(frame: .zero)

        leadingImageView.translatesAutoresizingMaskIntoConstraints = false
        leadingImageView.imageScaling = .scaleProportionallyUpOrDown
        leadingImageView.wantsLayer = true

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

        trashButton.toolTip = "Delete clip"
        trashButton.target = self
        trashButton.action = #selector(deleteTapped)
        trashButton.isHidden = true
        trashButton.translatesAutoresizingMaskIntoConstraints = false
        trashButton.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: ["kind": "trash"]
        ))

        eyeButton.toolTip = "Preview"
        eyeButton.target = self
        eyeButton.action = #selector(previewTapped)
        eyeButton.isHidden = true
        eyeButton.translatesAutoresizingMaskIntoConstraints = false
        eyeButton.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: ["kind": "eye"]
        ))

        addSubview(leadingImageView)
        addSubview(textLabel)
        addSubview(detailLabel)
        addSubview(trashButton)
        addSubview(eyeButton)

        leadingImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14).isActive = true
        leadingImageView.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        smallSizeConstraints = [
            leadingImageView.widthAnchor.constraint(equalToConstant: 16),
            leadingImageView.heightAnchor.constraint(equalToConstant: 16),
        ]
        largeSizeConstraints = [
            leadingImageView.widthAnchor.constraint(equalToConstant: 30),
            leadingImageView.heightAnchor.constraint(equalToConstant: 30),
        ]

        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: leadingImageView.trailingAnchor, constant: 10),
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

            eyeButton.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -6),
            eyeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            eyeButton.widthAnchor.constraint(equalToConstant: 28),
            eyeButton.heightAnchor.constraint(equalToConstant: 28),
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
        switch event.trackingArea?.userInfo?["kind"] as? String {
        case "trash":
            trashButton.showsRing = true
        case "eye":
            eyeButton.showsRing = true
        default:
            trashButton.isHidden = false
            eyeButton.isHidden = !clip.isImage
            onHoverEnter()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        switch event.trackingArea?.userInfo?["kind"] as? String {
        case "trash":
            trashButton.showsRing = false
        case "eye":
            eyeButton.showsRing = false
        default:
            trashButton.isHidden = true
            eyeButton.isHidden = true
            trashButton.showsRing = false
            eyeButton.showsRing = false
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    @objc private func deleteTapped() {
        onDelete()
    }

    @objc private func previewTapped() {
        onPreview()
    }

    /// Hides the hover buttons and rings without waiting for a mouse-exited event. Called
    /// on scroll, where rows move under a stationary cursor.
    func resetHover() {
        trashButton.isHidden = true
        eyeButton.isHidden = true
        trashButton.showsRing = false
        eyeButton.showsRing = false
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

        if clip.isImage {
            NSLayoutConstraint.deactivate(smallSizeConstraints)
            NSLayoutConstraint.activate(largeSizeConstraints)
            leadingImageView.image = Self.thumbnail(for: clip)
                ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            leadingImageView.layer?.cornerRadius = 6
            leadingImageView.layer?.masksToBounds = true
            textLabel.toolTip = "Image"
            textLabel.attributedStringValue = NSAttributedString(
                string: "Image",
                attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: primary]
            )
        } else {
            NSLayoutConstraint.deactivate(largeSizeConstraints)
            NSLayoutConstraint.activate(smallSizeConstraints)
            leadingImageView.layer?.cornerRadius = 0
            leadingImageView.layer?.masksToBounds = false
            if let bundle = clip.appBundle, !bundle.isEmpty {
                leadingImageView.image = Self.appIcon(for: bundle)
            } else {
                leadingImageView.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            }
            textLabel.attributedStringValue = NSAttributedString(
                string: clip.preview,
                attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: primary]
            )
        }

        let age = Self.shortTimestamp(for: clip.createdAt)
        detailLabel.stringValue = [clip.appName, age].compactMap { $0 }.joined(separator: " · ")
        detailLabel.textColor = secondary
        detailLabel.font = .systemFont(ofSize: 11)
    }
}
