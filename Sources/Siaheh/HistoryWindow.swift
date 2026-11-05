import AppKit

/// The clipboard history window: centered, searchable, keyboard driven, and it closes as
/// soon as a clip has been copied.
@MainActor
final class HistoryWindowController: NSWindowController {
    /// Only one page is ever loaded, so opening and filtering stay ~1 ms no matter how
    /// large the history is.
    private static let displayLimit = 200

    private let store: ClipStore
    private let searchField = HistorySearchField()
    private let tableView = HistoryTableView()
    private let emptyLabel = NSTextField(labelWithString: "No clips yet — copy something first")
    private var clips: [Clip] = []

    /// The app that was frontmost before this window opened. A menu-bar agent keeps
    /// activation when its window closes, so focus has to be handed back explicitly or
    /// the next ⌘V goes nowhere.
    private var previousApp: NSRunningApplication?

    init(store: ClipStore) {
        self.store = store
        super.init(window: NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ))
        window?.title = "Clipboard History"
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
        searchField.placeholderString = "Search history"
        searchField.delegate = self
        searchField.onMoveSelection = { [weak self] delta in self?.moveSelection(by: delta) }
        searchField.onActivate = { [weak self] in self?.copySelected() }
        searchField.onCancel = { [weak self] in self?.window?.close() }
        searchField.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.rowHeight = 30
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
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
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(searchField)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        return container
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

        updateTitle(query: query)
    }

    /// The count in the title separates "recording nothing" from "rendering nothing".
    private func updateTitle(query: String) {
        if query.isEmpty {
            let total = store.count
            window?.title = total == 0
                ? "Clipboard History — nothing recorded yet"
                : "Clipboard History — \(total) clip\(total == 1 ? "" : "s")"
        } else {
            window?.title = clips.isEmpty
                ? "Clipboard History — no matches"
                : "Clipboard History — \(clips.count) match\(clips.count == 1 ? "" : "es")"
        }
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
}

extension HistoryWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        clips.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let clip = clips[row]
        let cell = NSTableCellView()

        let label = NSTextField(labelWithAttributedString: Self.describe(clip))
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = clip.text
        label.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private static func describe(_ clip: Clip) -> NSAttributedString {
        let description = NSMutableAttributedString(
            string: clip.preview,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        if let appName = clip.appName {
            description.append(NSAttributedString(
                string: "  ·  \(appName)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
        }
        return description
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

/// Search field that keeps the list keyboard-usable: typing filters, and the arrow keys
/// and Return belong to the list rather than to the text editor.
@MainActor
private final class HistorySearchField: NSSearchField {
    var onMoveSelection: ((Int) -> Void)?
    var onActivate: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onMoveSelection?(1)   // ↓
        case 126: onMoveSelection?(-1)  // ↑
        case 36, 76: onActivate?()      // Return, keypad Enter
        case 53: onCancel?()            // Escape
        default: super.keyDown(with: event)
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
