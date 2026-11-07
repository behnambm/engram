import AppKit

/// The clipboard history window: centered, searchable, keyboard driven, and it closes as
/// soon as a clip has been copied.
@MainActor
final class HistoryWindowController: NSWindowController {
    /// Only one page is ever loaded, so opening and filtering stay ~1 ms no matter how
    /// large the history is.
    private static let displayLimit = 200

    /// Inset from the top of the window that clears the traffic-light buttons under a
    /// transparent titlebar (the content extends up into the titlebar area).
    private static let titleBarInset: CGFloat = 44

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
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 480),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        ))
        window?.title = "Clipboard History"
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden
        window?.isMovableByWindowBackground = true
        window?.backgroundColor = .clear
        window?.isOpaque = false
        window?.isReleasedWhenClosed = false
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

        // Translucent, content-area material that lets the desktop show through — the
        // frosted-glass chrome System Settings and Notes use for their surfaces.
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(material)

        searchField.placeholderString = "Search history"
        searchField.controlSize = .large
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.rowHeight = 46
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = .solidHorizontalGridLineMask
        tableView.gridColor = .separatorColor
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

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(divider)
        root.addSubview(scrollView)
        root.addSubview(statusLabel)
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: root.topAnchor),
            material.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            material.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            material.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.titleBarInset),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),

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

        updateStatus(query: query)
    }

    /// The window chrome is transparent now, so the clip count lives in a quiet status
    /// line at the bottom instead of a title — it reads as a status bar, not a header.
    private func updateStatus(query: String) {
        guard !clips.isEmpty else {
            statusLabel.isHidden = true
            return
        }

        if query.isEmpty {
            let total = store.count
            statusLabel.stringValue = "\(total) clip\(total == 1 ? "" : "s")"
        } else {
            statusLabel.stringValue = "\(clips.count) match\(clips.count == 1 ? "" : "es")"
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
        HistoryCellView(clip: clips[row])
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        HistoryRowView()
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

/// A selected row drawn as a rounded, accent-tinted pill instead of a full-width
/// square — the selection style Spotlight and System Settings use for their lists.
@MainActor
private final class HistoryRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let color = isEmphasized
            ? NSColor.selectedContentBackgroundColor
            : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 8, dy: 2),
            xRadius: 8,
            yRadius: 8
        ).fill()
    }
}

/// Recolours its two-tone text (preview + app + time) when the row becomes selected,
/// so dark text never sits on the accent highlight.
@MainActor
private final class HistoryCellView: NSTableCellView {
    private let clip: Clip
    private let textLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter
    }()

    init(clip: Clip) {
        self.clip = clip
        super.init(frame: .zero)

        textLabel.lineBreakMode = .byWordWrapping
        textLabel.usesSingleLineMode = false
        textLabel.maximumNumberOfLines = 2
        textLabel.toolTip = clip.text
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(textLabel)
        addSubview(timeLabel)
        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
            textLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),

            timeLabel.leadingAnchor.constraint(equalTo: textLabel.trailingAnchor, constant: 12),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        render()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    private func render() {
        let emphasized = backgroundStyle == .emphasized
        let primary = emphasized ? NSColor.selectedControlTextColor : NSColor.labelColor
        let secondary = emphasized
            ? NSColor.selectedControlTextColor.withAlphaComponent(0.7)
            : NSColor.secondaryLabelColor
        let tertiary = emphasized
            ? NSColor.selectedControlTextColor.withAlphaComponent(0.55)
            : NSColor.tertiaryLabelColor

        let text = NSMutableAttributedString(
            string: clip.preview,
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: primary]
        )
        if let appName = clip.appName {
            text.append(NSAttributedString(
                string: "  ·  \(appName)",
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: secondary]
            ))
        }
        textLabel.attributedStringValue = text

        timeLabel.textColor = tertiary
        timeLabel.stringValue = Self.relativeFormatter.localizedString(
            for: clip.createdAt,
            relativeTo: Date()
        )
    }
}
