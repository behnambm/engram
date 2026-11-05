import AppKit

/// The clipboard history window: centered, keyboard driven, and it closes as soon as
/// a clip has been copied.
@MainActor
final class HistoryWindowController: NSWindowController {
    /// Only the newest page is ever loaded, so opening the window stays ~1 ms no matter
    /// how large the history is.
    private static let displayLimit = 200

    private let store: ClipStore
    private let tableView = HistoryTableView()
    private let emptyLabel = NSTextField(labelWithString: "No clips yet — copy something first")
    private var clips: [Clip] = []

    init(store: ClipStore) {
        self.store = store
        super.init(window: NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ))
        window?.title = "Clipboard History"
        window?.isReleasedWhenClosed = false
        window?.center()
        window?.contentView = makeContentView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        clips = store.recent(limit: Self.displayLimit)
        tableView.reloadData()
        emptyLabel.isHidden = !clips.isEmpty

        if !clips.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }

        window?.center()

        // A background agent is not active, and macOS refuses focus requests that do not
        // follow user input. Ask for activation, then order the window front regardless so
        // it is never hidden behind the app the user came from.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.makeFirstResponder(tableView)
    }

    private func makeContentView() -> NSView {
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
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

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
