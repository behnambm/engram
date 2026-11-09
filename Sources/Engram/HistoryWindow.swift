import AppKit

/// The clipboard history window: centered, searchable, keyboard driven, and it closes as
/// soon as a clip has been copied.
@MainActor
final class HistoryWindowController: NSWindowController {
    /// Only one page is ever loaded, so opening and filtering stay ~1 ms no matter how
    /// large the history is.
    private static let displayLimit = 200
    private static let titleBarHeight: CGFloat = 46
    private static let searchTopInset: CGFloat = 61
    private static let searchHeight: CGFloat = 43
    private static let rowHeight: CGFloat = 36

    private let store: ClipStore
    private let titleLabel = NSTextField(labelWithString: "Engram — Clipboard History")
    private let searchContainer = NSView()
    private let searchField = NSTextField()
    private let tableView = HistoryTableView()
    private let emptyLabel = NSTextField(labelWithString: "No clips yet — copy something first")
    private let statusLabel = NSTextField(labelWithString: "")

    fileprivate enum Palette {
        static let background = NSColor(calibratedRed: 0.086, green: 0.090, blue: 0.184, alpha: 1)
        static let searchBackground = NSColor(calibratedRed: 0.176, green: 0.184, blue: 0.298, alpha: 1)
        static let searchBorder = NSColor(calibratedRed: 0.42, green: 0.43, blue: 0.58, alpha: 1)
        static let divider = NSColor(calibratedRed: 0.204, green: 0.208, blue: 0.298, alpha: 1)
        static let selectedRow = NSColor(calibratedRed: 0.145, green: 0.176, blue: 0.353, alpha: 1)
        static let primaryText = NSColor(calibratedRed: 0.941, green: 0.941, blue: 0.969, alpha: 1)
        static let secondaryText = NSColor(calibratedRed: 0.56, green: 0.565, blue: 0.635, alpha: 1)
    }
    private var clips: [Clip] = []

    /// The app that was frontmost before this window opened. A menu-bar agent keeps
    /// activation when its window closes, so focus has to be handed back explicitly or
    /// the next ⌘V goes nowhere.
    private var previousApp: NSRunningApplication?

    init(store: ClipStore) {
        self.store = store
        super.init(window: NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 310),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        ))
        window?.title = "Engram — Clipboard History"
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden
        window?.isMovableByWindowBackground = true
        window?.backgroundColor = Palette.background
        window?.appearance = NSAppearance(named: .darkAqua)
        window?.isOpaque = true
        window?.isReleasedWhenClosed = false
        window?.minSize = NSSize(width: 430, height: 280)
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
        root.wantsLayer = true
        root.layer?.backgroundColor = Palette.background.cgColor

        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        titleLabel.textColor = Palette.secondaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        searchContainer.wantsLayer = true
        searchContainer.layer?.backgroundColor = Palette.searchBackground.cgColor
        searchContainer.layer?.cornerRadius = 14
        searchContainer.layer?.borderWidth = 1.4
        searchContainer.layer?.borderColor = Palette.searchBorder.cgColor
        searchContainer.translatesAutoresizingMaskIntoConstraints = false

        // A plain NSTextField: the rounded container already draws the border, so a
        // bezelled NSSearchField would add a second bezel plus an orphaned magnifier and
        // cancel button that the container's own border would fight with.
        searchField.placeholderString = "Search history"
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 18)
        searchField.textColor = Palette.primaryText
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.focusRingType = .none
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.backgroundColor = .clear
        searchField.usesSingleLineMode = true
        searchContainer.addSubview(searchField)

        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
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

        emptyLabel.textColor = Palette.secondaryText
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = Palette.secondaryText
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Palette.divider.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        root.addSubview(titleLabel)
        root.addSubview(searchContainer)
        root.addSubview(divider)
        root.addSubview(scrollView)
        root.addSubview(statusLabel)
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 85),
            titleLabel.centerYAnchor.constraint(equalTo: root.topAnchor, constant: Self.titleBarHeight / 2),

            searchContainer.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.searchTopInset),
            searchContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 17),
            searchContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -17),
            searchContainer.heightAnchor.constraint(equalToConstant: Self.searchHeight),

            searchField.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -8),
            searchField.topAnchor.constraint(equalTo: searchContainer.topAnchor, constant: 4),
            searchField.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: -4),

            divider.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.titleBarHeight),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 9),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -9),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 29),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

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
            let matches = store.matchCount(trimmed)
            statusLabel.stringValue = "\(matches.formatted()) of \(total.formatted())"
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

extension HistoryWindowController: NSTextFieldDelegate {
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

/// A selected row drawn as a rounded indigo pill to match the history window palette.
@MainActor
private final class HistoryRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let base = HistoryWindowController.Palette.selectedRow
        // A non-key window keeps the row selected but dims the pill, so the active
        // window's selection is visually distinct.
        let fill = isEmphasized ? base : base.withAlphaComponent(0.45)
        fill.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 8, dy: 0),
            xRadius: 12,
            yRadius: 12
        ).fill()
    }
}

/// Renders clip preview with compact source and timestamp metadata.
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

    private static func shortTimestamp(for date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return seconds == 0 ? "now" : "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        if seconds < 604_800 { return "\(seconds / 86_400)d" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    init(clip: Clip) {
        self.clip = clip
        super.init(frame: .zero)

        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.usesSingleLineMode = true
        textLabel.maximumNumberOfLines = 1
        textLabel.toolTip = clip.text
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timeLabel.font = .systemFont(ofSize: 13)
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
        let primary = HistoryWindowController.Palette.primaryText
        let secondary = emphasized
            ? HistoryWindowController.Palette.primaryText.withAlphaComponent(0.72)
            : HistoryWindowController.Palette.secondaryText

        textLabel.attributedStringValue = NSAttributedString(
            string: clip.preview,
            attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: primary]
        )

        let age = Self.shortTimestamp(for: clip.createdAt)
        timeLabel.stringValue = [clip.appName, age].compactMap { $0 }.joined(separator: " · ")
        timeLabel.textColor = secondary
        timeLabel.font = .systemFont(ofSize: 14)
    }
}
