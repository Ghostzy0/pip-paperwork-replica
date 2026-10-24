import AppKit
import PDFKit
import PaperworkCore
import UniformTypeIdentifiers

final class TopStackView: NSStackView { override var isFlipped: Bool { true } }

// Modal NSAlert field editors may have no window undo manager. This editor owns only
// the temporary input's typing history, never the PDF's document history.
final class UndoInputTextView: NSTextView, NSTextViewDelegate {
    private let typingHistory = UndoManager()
    var submit: (() -> Void)?
    var cancel: (() -> Void)?
    override var undoManager: UndoManager? { typingHistory }
    func undoManager(for view: NSTextView) -> UndoManager? { typingHistory }
    override func insertNewline(_ sender: Any?) { submit?() }
    override func cancelOperation(_ sender: Any?) { cancel?() }
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(self) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(self) }
}

final class PaperworkApp: NSObject, NSApplicationDelegate, NSWindowDelegate, PDFViewDelegate, NSMenuItemValidation {
    var window: NSWindow!
    let reader = ReaderView()
    let thumbnails = PDFThumbnailView()
    let thumbnailPanel = NSView()
    let status = NSTextField(wrappingLabelWithString: "Open a PDF to get started. Everything works on this Mac.")
    let titleLabel = NSTextField(labelWithString: "Paperwork Replica")
    let detail = NSTextField(labelWithString: "Local PDF workspace")
    let pageLabel = NSTextField(labelWithString: "No PDF open")
    let search = NSSearchField()
    let inspector = TopStackView()
    let inspectorScroll = NSScrollView()
    let overview = NSStackView()
    let overviewScroll = NSScrollView()
    let overviewRangeLabel = NSTextField(labelWithString: "")
    let overviewControls = NSStackView()
    let annotationTools = NSStackView()
    let pagebar = NSStackView()
    let resultStack = TopStackView()
    let resultScroll = NSScrollView()
    var showingOverview = false
    var showingResults = false
    var showingThumbnails = true
    var annotationMode = false
    var overviewStartPage = 0
    var resultStartIndex = 0
    var needsSearchRefresh = false
    let empty = NSStackView()
    let progress = NSProgressIndicator()
    let edition = ReplicaIdentity()
    var contentView: NSView?
    var ws: Workspace?
    var busy = false
    var cancelFlag: CancellationFlag?
    var controls: [String: NSButton] = [:]
    var matches: [PDFSelection] = []
    var matchIndex = 0
    var recoveryEnabled = false
    var displayedWorkspace: ObjectIdentifier?
    var displayedRevision = -1
    var displayedLocked = false
    var closingApproved = false
    var pendingOpen: URL?
    var recoveryURL: URL {
        let directory = ReplicaIdentity.dataDirectory()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("recovery.pdf")
    }
    var currentIndex: Int { guard let page = reader.currentPage, let pdf = reader.document else { return 0 }; let index = pdf.index(for: page); return index == NSNotFound ? 0 : index }
    func index(of page: PDFPage) -> Int { guard let document = page.document else { return 0 }; let n = document.index(for: page); return n == NSNotFound ? 0 : n }

    func applicationDidFinishLaunching(_ notification: Notification) {
        CanonicalPDF.helperURL = Bundle.main.resourceURL?.appendingPathComponent("canonical-pdf")
        NSApp.setActivationPolicy(.regular)
        NotificationCenter.default.addObserver(self, selector: #selector(textEditingBegan(_:)), name: NSControl.textDidBeginEditingNotification, object: nil)
        setupMenu(); setupWindow()
        if let pendingOpen { openURL(pendingOpen) }
        else if let input = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".pdf") }) { openURL(URL(fileURLWithPath: input)) }
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard let first = filenames.first else { sender.reply(toOpenOrPrint: .failure); return }
        let url = URL(fileURLWithPath: first)
        if window == nil { pendingOpen = url } else if !busy && canLeave() { openURL(url) }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { closingApproved || canLeave() ? .terminateNow : .terminateCancel }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closingApproved = canLeave(); return closingApproved }
    func canLeave() -> Bool {
        if busy { showError(PaperworkError.invalid("Stop the current task before closing the workspace.")); return false }
        guard ws?.dirty == true else { return true }
        return confirm("Leave this working copy?", "Save a separate copy first to keep your changes. Your opened original is unchanged.", action: "Leave without saving")
    }
    func setupMenu() {
        let root = NSMenu()
        func menu(_ name: String, _ entries: [(String, String, String)]) {
            let item = NSMenuItem(); let sub = NSMenu(title: name); item.submenu = sub; root.addItem(item)
            for (title, key, action) in entries {
                if title == "-" { sub.addItem(.separator()); continue }
                let child = NSMenuItem(title: title, action: #selector(command(_:)), keyEquivalent: key); child.representedObject = action; child.target = self; sub.addItem(child)
            }
        }
        menu(edition.displayName, [("About \(edition.displayName)", "", "about"), ("-", "", ""), ("Quit \(edition.displayName)", "q", "quit")])
        menu("File", [("Open PDF…", "o", "open"), ("Open sample", "", "sample"), ("Save a copy…", "s", "save"), ("Extract pages…", "", "extract"), ("Split into page files…", "", "split"), ("Insert or merge PDF…", "", "insert"), ("Optimise a copy…", "", "optimise"), ("Searchable scan copy…", "", "ocr"), ("Export text…", "", "text"), ("Export page image…", "", "image"), ("Flatten a copy…", "", "flatten"), ("-", "", ""), ("Enable local recovery", "", "recovery"), ("Restore recovery", "", "restore"), ("Discard recovery", "", "discard")])
        menu("Edit", [("Undo document change", "z", "undo"), ("Redo document change", "Z", "redo"), ("Find…", "f", "find"), ("Find next", "g", "nextMatch"), ("Copy selected text", "c", "copy"), ("Select text tool", "", "select"), ("Highlight selection", "", "highlight"), ("Underline selection", "", "underline"), ("Strike through selection", "", "strikeOut"), ("Sticky note tool", "", "note"), ("Freehand tool", "", "ink")])
        menu("Pages", [("Page overview", "", "overview"), ("Previous page", "[", "previous"), ("Next page", "]", "next"), ("Go to page…", "l", "go"), ("Rotate clockwise", "r", "rotate"), ("Move page earlier", "", "earlier"), ("Move page later", "", "later"), ("Delete this page…", "", "delete")])
        let viewItems: [(String, String, String)] = [("Show or hide thumbnails", "", "toggleThumbnails"), ("Page overview", "", "overview"), ("Toggle dark appearance", "", "dark")]
        menu("View", viewItems)
        if let edit = root.items.first(where: { $0.submenu?.title == "Edit" })?.submenu {
            if let copy = edit.items.first(where: { ($0.representedObject as? String) == "copy" }) { edit.removeItem(copy) }
            for (title, key, action) in [("Cut", "x", #selector(NSText.cut(_:))), ("Copy", "c", #selector(NSText.copy(_:))), ("Paste", "v", #selector(NSText.paste(_:))), ("Select all", "a", #selector(NSText.selectAll(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = nil; edit.addItem(item)
            }
        }
        NSApp.mainMenu = root
    }
    func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: size, weight: weight); field.textColor = secondary ? .secondaryLabelColor : .labelColor; return field
    }
    func button(_ title: String, _ action: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(command(_:))); b.identifier = .init(action); b.bezelStyle = .rounded; b.setAccessibilityLabel(title); b.toolTip = title; controls[action] = b; return b
    }
    func updateButtonStates(in view: NSView?) {
        guard let view, !(view is PDFView), !(view is PDFThumbnailView) else { return }
        if let button = view as? NSButton, let action = button.identifier?.rawValue,
           controls[action] != nil || (action == "backReader" && controls["overview"] != nil) {
            button.isEnabled = enabled(action)
        }
        for child in view.subviews { updateButtonStates(in: child) }
    }
    func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView { let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = spacing; stack.alignment = .centerY; return stack }
    func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView { let stack = NSStackView(views: views); stack.orientation = .vertical; stack.spacing = spacing; stack.alignment = .leading; return stack }
    func setupWindow() {
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 840), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = edition.displayName; window.minSize = NSSize(width: 980, height: 620); window.delegate = self; window.appearance = NSAppearance(named: .darkAqua)
        let content = NSView(); window.contentView = content; contentView = content
        content.wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold); detail.textColor = .secondaryLabelColor; detail.font = .systemFont(ofSize: 12)
        titleLabel.stringValue = edition.displayName
        search.placeholderString = "Search in document"; search.setAccessibilityLabel("Search in document"); search.target = self; search.action = #selector(findText); search.widthAnchor.constraint(equalToConstant: 210).isActive = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let titleGroup = column([titleLabel, detail], spacing: 2)
        let documentTab = NSBox(); documentTab.boxType = .custom; documentTab.borderWidth = 1; documentTab.borderColor = .separatorColor; documentTab.contentViewMargins = NSSize(width: 10, height: 5); documentTab.wantsLayer = true; documentTab.layer?.cornerRadius = 6; documentTab.layer?.masksToBounds = true; documentTab.contentView = titleGroup
        let header = row([documentTab, spacer, search, button("Find", "search")], spacing: 8)
        let mainTools = row([button("Read", "readMode"), button("Annotate", "annotateMode"), button("Pages", "overview"), button("Hide thumbnails", "toggleThumbnails"), button("Open…", "open"), button("Save a copy…", "save")], spacing: 6)
        [button("Select", "select"), button("Highlight", "highlight"), button("Underline", "underline"), button("Strikeout", "strikeOut"), button("Note", "note"), button("Pen", "ink"), button("Undo", "undo"), button("Redo", "redo")].forEach { annotationTools.addArrangedSubview($0) }; annotationTools.orientation = .horizontal; annotationTools.alignment = .centerY; annotationTools.spacing = 6
        annotationTools.isHidden = true
        [button("‹", "previous"), pageLabel, button("›", "next"), button("Go to page…", "go"), button("−", "zoomOut"), button("+", "zoomIn"), button("Fit", "fit"), button("Rotate", "rotate"), button("Earlier", "earlier"), button("Later", "later"), button("Delete…", "delete")].forEach { pagebar.addArrangedSubview($0) }; pagebar.orientation = .horizontal; pagebar.alignment = .centerY; pagebar.spacing = 6
        controls["previous"]?.setAccessibilityLabel("Previous page"); controls["next"]?.setAccessibilityLabel("Next page"); controls["zoomOut"]?.setAccessibilityLabel("Zoom out"); controls["zoomIn"]?.setAccessibilityLabel("Zoom in")
        reader.autoScales = true; reader.displayMode = .singlePageContinuous; reader.displayDirection = .vertical; reader.delegate = self; reader.setAccessibilityLabel("PDF document")
        thumbnails.pdfView = reader; thumbnails.thumbnailSize = NSSize(width: 112, height: 145); thumbnails.backgroundColor = .controlBackgroundColor; thumbnails.setAccessibilityLabel("Page thumbnails")
        thumbnailPanel.translatesAutoresizingMaskIntoConstraints = false
        let thumbColumn = column([label("THUMBNAILS", size: 10, weight: .semibold, secondary: true), thumbnails], spacing: 8)
        thumbnailPanel.addSubview(thumbColumn); thumbColumn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([thumbColumn.leadingAnchor.constraint(equalTo: thumbnailPanel.leadingAnchor), thumbColumn.trailingAnchor.constraint(equalTo: thumbnailPanel.trailingAnchor), thumbColumn.topAnchor.constraint(equalTo: thumbnailPanel.topAnchor), thumbColumn.bottomAnchor.constraint(equalTo: thumbnailPanel.bottomAnchor)])
        thumbnailPanel.widthAnchor.constraint(equalToConstant: 150).isActive = true; thumbnails.widthAnchor.constraint(equalTo: thumbnailPanel.widthAnchor).isActive = true
        inspector.orientation = .vertical; inspector.alignment = .leading; inspector.spacing = 10; inspector.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14); inspector.translatesAutoresizingMaskIntoConstraints = false
        inspectorScroll.documentView = inspector; inspectorScroll.hasVerticalScroller = true; inspectorScroll.drawsBackground = false; inspectorScroll.widthAnchor.constraint(equalToConstant: 216).isActive = true; inspector.widthAnchor.constraint(equalTo: inspectorScroll.contentView.widthAnchor).isActive = true
        resultStack.orientation = .vertical; resultStack.alignment = .leading; resultStack.spacing = 8; resultStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14); resultStack.translatesAutoresizingMaskIntoConstraints = false
        resultScroll.documentView = resultStack; resultScroll.hasVerticalScroller = true; resultScroll.drawsBackground = false; resultScroll.widthAnchor.constraint(equalToConstant: 250).isActive = true; resultStack.widthAnchor.constraint(equalTo: resultScroll.contentView.widthAnchor).isActive = true; resultScroll.isHidden = true
        let viewer = NSView(); reader.translatesAutoresizingMaskIntoConstraints = false; viewer.addSubview(reader)
        overview.orientation = .horizontal; overview.alignment = .top; overview.spacing = 12; overview.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        overviewScroll.documentView = overview; overviewScroll.hasHorizontalScroller = true; overviewScroll.hasVerticalScroller = false; overviewScroll.drawsBackground = false; overviewScroll.translatesAutoresizingMaskIntoConstraints = false; overviewScroll.isHidden = true; overviewScroll.setAccessibilityLabel("Navigation-only page overview"); viewer.addSubview(overviewScroll)
        empty.orientation = .vertical; empty.alignment = .centerX; empty.spacing = 12
        empty.addArrangedSubview(label("Open a PDF", size: 22, weight: .semibold))
        empty.addArrangedSubview(label("Read and organise a local working copy. The opened original stays unchanged.", size: 13, secondary: true))
        empty.addArrangedSubview(button("Open PDF…", "open")); empty.addArrangedSubview(button("Open synthetic sample", "sample")); empty.translatesAutoresizingMaskIntoConstraints = false; viewer.addSubview(empty)
        NSLayoutConstraint.activate([reader.leadingAnchor.constraint(equalTo: viewer.leadingAnchor), reader.trailingAnchor.constraint(equalTo: viewer.trailingAnchor), reader.topAnchor.constraint(equalTo: viewer.topAnchor), reader.bottomAnchor.constraint(equalTo: viewer.bottomAnchor), overviewScroll.leadingAnchor.constraint(equalTo: viewer.leadingAnchor), overviewScroll.trailingAnchor.constraint(equalTo: viewer.trailingAnchor), overviewScroll.topAnchor.constraint(equalTo: viewer.topAnchor), overviewScroll.bottomAnchor.constraint(equalTo: viewer.bottomAnchor), empty.centerXAnchor.constraint(equalTo: viewer.centerXAnchor), empty.centerYAnchor.constraint(equalTo: viewer.centerYAnchor)])
        overviewRangeLabel.font = .systemFont(ofSize: 11); overviewRangeLabel.textColor = .secondaryLabelColor
        [button("Previous 24 pages", "overviewPrevious"), overviewRangeLabel, button("Next 24 pages", "overviewNext")].forEach { overviewControls.addArrangedSubview($0) }; overviewControls.orientation = .horizontal; overviewControls.alignment = .centerY; overviewControls.spacing = 8; overviewControls.isHidden = true
        let documentArea = column([overviewControls, viewer], spacing: 4); documentArea.alignment = .width; documentArea.setContentHuggingPriority(.init(1), for: .horizontal)
        let body = row([thumbnailPanel, documentArea, inspectorScroll, resultScroll], spacing: 8); body.alignment = .height; body.detachesHiddenViews = true
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 2
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        let foot = row([progress, status, button("Stop", "stop"), button("Search results", "toggleInspector")], spacing: 8); controls["stop"]?.isHidden = true
        let root = column([header, mainTools, annotationTools, pagebar, body, foot], spacing: 7); root.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12); root.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor), root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor), header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24), mainTools.widthAnchor.constraint(equalTo: header.widthAnchor), annotationTools.widthAnchor.constraint(equalTo: header.widthAnchor), pagebar.widthAnchor.constraint(equalTo: header.widthAnchor), body.widthAnchor.constraint(equalTo: header.widthAnchor), foot.widthAnchor.constraint(equalTo: header.widthAnchor), body.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)])
        body.setContentHuggingPriority(.init(1), for: .vertical); viewer.setContentHuggingPriority(.init(1), for: .horizontal)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: reader)
        reader.editField = { [weak self] p, a in self?.editForm(p, a) }; reader.noteAt = { [weak self] p, point in self?.addNote(p, point) }; reader.inkDone = { [weak self] p, points in self?.addInk(p, points) }
        refresh(); window.center(); window.makeKeyAndOrderFront(nil)
    }
    func setOverview(_ showing: Bool) {
        if showingOverview == showing { return }
        showingOverview = showing
        reader.isHidden = showing || ws == nil; overviewScroll.isHidden = !showing || ws == nil
        pagebar.isHidden = showing; overviewControls.isHidden = !showing
        annotationTools.isHidden = showing || !annotationMode
        if showing { overviewStartPage = 0; rebuildOverview() }
        if let toggle = controls["overview"] {
            let title = showing ? "Return to reader" : "Pages"
            toggle.title = title; toggle.identifier = NSUserInterfaceItemIdentifier(showing ? "backReader" : "overview")
            toggle.setAccessibilityLabel(title); toggle.toolTip = title
            toggle.setAccessibilityValue(showing ? "Navigation-only page overview" : "Reader")
        }
        window.contentView?.layoutSubtreeIfNeeded()
        if showing { focusOverviewContent() }
        if !showing {
            if let page = reader.document?.page(at: currentIndex) { reader.go(to: page) }
            window.makeFirstResponder(reader)
        }
        search.isEnabled = !showing && !busy
        updateButtonStates(in: contentView)
    }
    func rebuildOverview() {
        for view in overview.arrangedSubviews { overview.removeArrangedSubview(view); view.removeFromSuperview() }
        guard let pdf = reader.document else { return }
        let start = min(max(0, overviewStartPage), max(0, pdf.pageCount - 1))
        let end = min(start + 24, pdf.pageCount)
        overviewStartPage = start
        overviewRangeLabel.stringValue = pdf.pageCount == 0 ? "No pages" : "Pages \(start + 1)–\(end) of \(pdf.pageCount) · Navigation only"
        controls["overviewPrevious"]?.isEnabled = start > 0
        controls["overviewNext"]?.isEnabled = end < pdf.pageCount
        guard start < end else { return }
        for index in start..<end {
            guard let page = pdf.page(at: index) else { continue }
            let card = NSStackView(); card.orientation = .vertical; card.alignment = .centerX; card.spacing = 6
            let image = page.thumbnail(of: NSSize(width: 138, height: 178), for: .mediaBox)
            let preview = NSImageView(image: image); preview.imageScaling = .scaleProportionallyUpOrDown; preview.widthAnchor.constraint(equalToConstant: 138).isActive = true; preview.heightAnchor.constraint(equalToConstant: 178).isActive = true; preview.setAccessibilityLabel("Page \(index + 1) preview")
            let select = NSButton(title: "Page \(index + 1)", target: self, action: #selector(overviewPageClicked(_:))); select.tag = index; select.setAccessibilityLabel("Open page \(index + 1)")
            card.addArrangedSubview(preview); card.addArrangedSubview(select); card.widthAnchor.constraint(equalToConstant: 154).isActive = true; overview.addArrangedSubview(card)
        }
    }
    @objc func overviewPageClicked(_ sender: NSButton) { if let page = reader.document?.page(at: sender.tag) { reader.go(to: page); setOverview(false) } }
    func turnOverviewPage(_ offset: Int) {
        guard let pageCount = reader.document?.pageCount else { return }
        overviewStartPage = min(max(0, overviewStartPage + offset), max(0, pageCount - 1))
        rebuildOverview()
    }
    @objc func overviewPrevious() { turnOverviewPage(-24) }
    @objc func overviewNext() { turnOverviewPage(24) }
    func refreshSearchResults() {
        for view in resultStack.arrangedSubviews { resultStack.removeArrangedSubview(view); view.removeFromSuperview() }
        resultStack.addArrangedSubview(label("SEARCH RESULTS", size: 10, weight: .semibold, secondary: true))
        if needsSearchRefresh { resultStack.addArrangedSubview(label("The document changed. Search again to refresh results.", secondary: true)); return }
        if search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { resultStack.addArrangedSubview(label("Search this document to see matching pages.", secondary: true)); return }
        if matches.isEmpty { resultStack.addArrangedSubview(label("No matches found in the latest search.", secondary: true)); return }
        let pageCounts = Dictionary(grouping: matches.indices, by: { index -> Int in
            matches[index].pages.first.flatMap { reader.document?.index(for: $0) } ?? 0
        }).mapValues(\.count)
        let first = resultStartIndex
        let last = min(first + 25, matches.count)
        let matchedPages = Set(pageCounts.keys).count
        resultStack.addArrangedSubview(label("\(first + 1)–\(last) of \(matches.count) matches · \(matchedPages) pages", size: 12, weight: .medium))
        let previous = NSButton(title: "Previous 25", target: self, action: #selector(resultPrevious(_:)))
        let next = NSButton(title: "Next 25", target: self, action: #selector(resultNext(_:)))
        previous.bezelStyle = .rounded; next.bezelStyle = .rounded
        previous.setAccessibilityLabel("Previous 25 search results"); next.setAccessibilityLabel("Next 25 search results")
        let controlsRow = row([previous, next], spacing: 6)
        resultStack.addArrangedSubview(controlsRow)
        previous.isEnabled = first > 0 && !busy
        next.isEnabled = last < matches.count && !busy
        for index in first..<last {
            let match = matches[index]
            let pageIndex = match.pages.first.flatMap { reader.document?.index(for: $0) } ?? 0
            let excerpt = match.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? search.stringValue
            let item = NSButton(title: "Page \(pageIndex + 1) · \(pageCounts[pageIndex, default: 0]) on page · \(excerpt.prefix(90))", target: self, action: #selector(searchResultClicked(_:))); item.tag = index; item.setAccessibilityLabel("Search result \(index + 1) of \(matches.count), page \(pageIndex + 1)"); item.alignment = .left; item.toolTip = excerpt; item.isEnabled = !busy
            resultStack.addArrangedSubview(item)
        }
    }
    @objc func searchResultClicked(_ sender: NSButton) { guard !busy, matches.indices.contains(sender.tag) else { return }; matchIndex = sender.tag; setOverview(false); showMatch() }
    @objc func resultPrevious(_ sender: NSButton) { guard !busy else { return }; resultStartIndex = max(0, resultStartIndex - 25); refreshSearchResults() }
    @objc func resultNext(_ sender: NSButton) { guard !busy else { return }; resultStartIndex = min(max(0, matches.count - 1), resultStartIndex + 25); refreshSearchResults() }
    func updatePanelToggle() {
        guard let toggle = controls["toggleInspector"] else { return }
        let title = showingResults ? "Document details" : "Search results"
        toggle.title = title; toggle.setAccessibilityLabel(title); toggle.toolTip = title
        toggle.setAccessibilityValue(showingResults ? "Showing search results" : "Showing document details")
    }
    func setThumbnailsVisible(_ visible: Bool) {
        if showingThumbnails == visible { return }
        if !visible, let focused = window.firstResponder as? NSView, focused.isDescendant(of: thumbnailPanel) { focusPrimaryContent() }
        showingThumbnails = visible; thumbnailPanel.isHidden = !visible
        controls["toggleThumbnails"]?.title = visible ? "Hide thumbnails" : "Show thumbnails"
        controls["toggleThumbnails"]?.setAccessibilityLabel(visible ? "Hide thumbnails" : "Show thumbnails")
        controls["toggleThumbnails"]?.toolTip = visible ? "Hide page thumbnails" : "Show page thumbnails"
        window.contentView?.layoutSubtreeIfNeeded()
    }
    func setAnnotationMode(_ enabled: Bool) {
        annotationMode = enabled && !showingOverview
        annotationTools.isHidden = !annotationMode
        controls["annotateMode"]?.setAccessibilityValue(annotationMode ? "Annotation tools shown" : "Annotation tools hidden")
        controls["annotateMode"]?.setAccessibilityLabel(annotationMode ? "Hide annotation tools" : "Show annotation tools")
        controls["annotateMode"]?.title = annotationMode ? "Hide annotation tools" : "Annotate"
        if !annotationMode { reader.tool = "select" }
        window.contentView?.layoutSubtreeIfNeeded()
    }
    func focusPrimaryContent() {
        if showingOverview { focusOverviewContent() }
        else { window.makeFirstResponder(reader) }
    }
    func focusOverviewContent() {
        if let card = overview.arrangedSubviews.first as? NSStackView,
           let select = card.arrangedSubviews.last as? NSButton,
           !select.isHidden, select.isEnabled {
            window.makeFirstResponder(select)
            return
        }
        if let returnButton = controls["overview"], !returnButton.isHidden {
            window.makeFirstResponder(returnButton)
        }
    }
    func announce(_ message: String) { status.stringValue = message; NSAccessibility.post(element: status, notification: .announcementRequested, userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]) }
    @objc func textEditingBegan(_ notification: Notification) {
        guard !(notification.object is NSSecureTextField) else { return }
        // AppKit field editors default to no undo. Keep typing history separate from PDF history,
        // including editors inside modal form sheets rather than only the main search field.
        let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView
            ?? (NSApp.keyWindow?.firstResponder as? NSTextView)
        if editor?.isFieldEditor == true { editor?.allowsUndo = true }
    }
    func showError(_ error: Error) {
        let message = (error as? PaperworkError)?.localizedDescription ?? "The operation could not finish. Check the file and folder permissions, then try again."
        announce(message); let alert = NSAlert(); alert.messageText = "Could not finish"; alert.informativeText = message; alert.addButton(withTitle: "OK"); alert.beginSheetModal(for: window)
    }
    func confirm(_ title: String, _ message: String, action: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: action); return alert.runModal() == .alertSecondButtonReturn
    }
    func input(_ title: String, message: String = "", value: String = "", secret: Bool = false) -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        if secret {
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
            field.stringValue = value; field.setAccessibilityLabel(title); alert.accessoryView = field; alert.window.initialFirstResponder = field
            return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
        }
        let editor = UndoInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 36))
        editor.delegate = editor
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.undoManager?.runLoopModes = [.default, .modalPanel]
        editor.font = .systemFont(ofSize: 13); editor.string = value
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.setAccessibilityLabel(title)
        editor.submit = { [weak alert] in alert?.buttons.first?.performClick(nil) }
        editor.cancel = { [weak alert] in alert?.buttons.last?.performClick(nil) }
        let undoItems = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Edit" })?.submenu?.items.filter {
            let action = $0.representedObject as? String
            return action == "undo" || action == "redo"
        } ?? []
        let originalUndoRouting = undoItems.map { ($0, $0.action, $0.target, $0.title) }
        for item in undoItems {
            let action = item.representedObject as? String
            item.title = action == "undo" ? "Undo typing" : "Redo typing"
            item.action = Selector(action == "undo" ? "undo:" : "redo:")
            item.target = nil
        }
        defer {
            for (item, action, target, title) in originalUndoRouting {
                item.action = action; item.target = target; item.title = title
            }
        }
        alert.accessoryView = editor; alert.window.initialFirstResponder = editor
        defer {
            editor.undoManager?.removeAllActions()
            editor.delegate = nil; editor.submit = nil; editor.cancel = nil
        }
        return alert.runModal() == .alertFirstButtonReturn ? editor.string : nil
    }
    func focusedTextEditor() -> NSTextView? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              editor.isEditable, editor.isFieldEditor || editor is UndoInputTextView else { return nil }
        return editor
    }
    func refresh(page: Int? = nil) {
        let index = page ?? currentIndex
        reader.workspace = ws
        let identity = ws.map { ObjectIdentifier($0) }
        if identity != displayedWorkspace || displayedRevision != ws?.revision || displayedLocked != (ws?.document.isLocked ?? false) {
            let workspaceReplaced = identity != displayedWorkspace
            if !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { needsSearchRefresh = true; search.stringValue = "" }
            if let pdf = ws?.document {
                // PDFKit's inline widgets can be edited through keyboard/accessibility even when
                // mouseDown is intercepted. Render a read-only copy; all edits use the core.
                let rendered = pdf.dataRepresentation().flatMap(PDFDocument.init(data:))
                for i in 0..<(rendered?.pageCount ?? 0) { for field in rendered?.page(at: i)?.annotations ?? [] where field.type == "Widget" { field.isReadOnly = true } }
                reader.document = rendered ?? (pdf.isLocked ? pdf : nil)
            } else { reader.document = nil }
            displayedWorkspace = identity; displayedRevision = ws?.revision ?? -1; displayedLocked = ws?.document.isLocked ?? false; matches = []; resultStartIndex = 0; refreshSearchResults()
            if showingOverview && workspaceReplaced { overviewStartPage = min(overviewStartPage, max(0, (reader.document?.pageCount ?? 1) - 1)); rebuildOverview() }
        }
        empty.isHidden = ws != nil; reader.isHidden = ws == nil || showingOverview; overviewScroll.isHidden = ws == nil || !showingOverview; resultScroll.isHidden = ws == nil || !showingResults; thumbnailPanel.isHidden = !showingThumbnails
        if let ws {
            titleLabel.stringValue = ws.sourceURL?.deletingPathExtension().lastPathComponent ?? "Synthetic sample"
            titleLabel.setAccessibilityLabel("Open document: \(titleLabel.stringValue), one document workspace")
            titleLabel.toolTip = "Current document · one document workspace"
            detail.stringValue = "PDF · \(ws.document.pageCount) pages" + (ws.dirty ? " · Unsaved changes" : " · Original preserved")
            if let p = reader.document?.page(at: min(max(0, index), max(0, ws.document.pageCount - 1))) { reader.go(to: p) }
        } else { titleLabel.stringValue = "Paperwork Replica"; titleLabel.setAccessibilityLabel("Paperwork Replica"); detail.stringValue = "Local PDF workspace" }
        reader.interactionEnabled = !busy && !showingOverview; search.isEnabled = !busy && !showingOverview
        updateButtonStates(in: contentView)
        pageChanged(); updateInspector(); updatePanelToggle()
        if showingResults { refreshSearchResults() }
    }
    func enabled(_ action: String) -> Bool {
        if action == "toggleInspector" { return ws != nil && !busy }
        if action == "stop" { return busy }
        if action == "overviewPrevious" { return showingOverview && overviewStartPage > 0 }
        if action == "overviewNext" { return showingOverview && overviewStartPage + 24 < (reader.document?.pageCount ?? 0) }
        if showingOverview && ["rotate", "earlier", "later", "delete", "highlight", "underline", "strikeOut", "note", "ink", "select", "previous", "next", "go", "zoomIn", "zoomOut", "fit", "find", "search", "nextMatch", "copy", "undo", "redo", "insert", "extract", "split", "optimise", "ocr", "text", "image", "flatten", "unlock", "annotateMode"].contains(action) { return false }
        if busy { return false }
        if action == "overview" { return ws != nil && !busy }
        if action == "backReader" { return showingOverview && !busy }
        if ["open", "sample", "about", "quit", "more", "dark", "restore", "discard", "recovery", "toggleThumbnails", "readMode", "annotateMode"].contains(action) { return true }
        guard let ws else { return false }
        if action == "undo" { return ws.canUndo }
        if action == "redo" { return ws.canRedo }
        if ["highlight", "underline", "strikeOut", "note", "ink", "rotate", "earlier", "later", "delete", "insert"].contains(action) { return ws.editable }
        if ["save", "extract", "split", "optimise", "ocr", "text", "image", "flatten"].contains(action) { return !ws.encryptedInput && !ws.signedInput && !ws.document.isLocked && ws.document.allowsCopying }
        return !ws.document.isLocked
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let action = item.representedObject as? String ?? ""
        if action == "undo" || action == "redo", let editor = focusedTextEditor() {
            item.title = action == "undo" ? "Undo typing" : "Redo typing"
            return action == "undo" ? (editor.undoManager?.canUndo ?? false) : (editor.undoManager?.canRedo ?? false)
        }
        if action == "undo" || action == "redo" { item.title = action == "undo" ? "Undo document change" : "Redo document change" }
        if action == "toggleInspector" {
            item.title = showingResults ? "Show document details" : "Show search results"
            return !busy
        }
        return enabled(action)
    }
    @objc func pageChanged() {
        guard let ws, !ws.document.isLocked else { pageLabel.stringValue = ws?.document.isLocked == true ? "Locked PDF" : "No PDF open"; return }
        pageLabel.stringValue = "\(currentIndex + 1) / \(ws.document.pageCount)"; updateInspector()
    }
    func updateInspector() {
        for v in inspector.arrangedSubviews { inspector.removeArrangedSubview(v); v.removeFromSuperview() }
        inspector.addArrangedSubview(label("DOCUMENT", size: 11, weight: .semibold, secondary: true))
        guard let ws else { inspector.addArrangedSubview(label("Open a PDF to see its notes and form fields.", secondary: true)); return }
        if let reason = ws.readOnlyReason { inspector.addArrangedSubview(label(reason, secondary: true)); if ws.document.isLocked { inspector.addArrangedSubview(button("Unlock PDF", "unlock")) }; return }
        inspector.addArrangedSubview(label("Page \(currentIndex + 1)", size: 18, weight: .semibold))
        if let p = ws.document.page(at: currentIndex) {
            if p.annotations.isEmpty { inspector.addArrangedSubview(label("No annotations on this page. Select text and choose a mark-up tool.", secondary: true)) }
            for (i, a) in p.annotations.enumerated() {
                let title = a.type == "Widget" ? (a.fieldName ?? "Form field") : (a.type ?? "Annotation")
                inspector.addArrangedSubview(label(title, weight: .semibold))
                inspector.addArrangedSubview(label(a.widgetStringValue ?? a.contents ?? "", secondary: true))
                let action = NSButton(title: a.type == "Widget" ? "Edit field…" : "Remove annotation", target: self, action: #selector(inspectorAction(_:))); action.tag = i; action.isEnabled = ws.editable && !busy; inspector.addArrangedSubview(action)
            }
        }
        inspector.addArrangedSubview(label("Your original stays unchanged. Save a copy to keep these edits.", size: 12, secondary: true))
        inspector.addArrangedSubview(button("Insert or merge…", "insert")); inspector.addArrangedSubview(button("Extract pages…", "extract")); inspector.addArrangedSubview(button("Searchable scan…", "ocr"))
        inspector.addArrangedSubview(label(recoveryEnabled ? "Recovery is on. A private local copy is kept after each edit." : "Recovery is off. Enable it in File to keep an editable local snapshot.", size: 12, secondary: true))
        updateButtonStates(in: contentView)
    }
    func perform(_ body: () throws -> Void, message: String = "Working copy updated. Save a copy to keep it.", page: Int? = nil, storeRecovery: Bool = true) {
        let retainedPage = page ?? currentIndex
        do {
            try body()
            refresh(page: retainedPage)
            if storeRecovery, recoveryEnabled, let ws, ws.dirty { try Recovery.store(ws, at: recoveryURL) }
            announce(message)
        } catch { refresh(page: retainedPage); showError(error) }
    }
    @objc func command(_ sender: Any) {
        let action = (sender as? NSMenuItem)?.representedObject as? String ?? (sender as? NSButton)?.identifier?.rawValue ?? ""
        if sender is NSMenuItem, action == "undo" || action == "redo", let editor = focusedTextEditor() {
            if action == "undo", editor.undoManager?.canUndo == true { editor.undoManager?.undo() }
            if action == "redo", editor.undoManager?.canRedo == true { editor.undoManager?.redo() }
            return
        }
        guard enabled(action) else { return }
        switch action {
        case "open": openPicker()
        case "sample": if canLeave() { do { ws = try SampleDocument.make(); refresh(page: 0); announce("Sample PDF opened. It contains synthetic content.") } catch { showError(error) } }
        case "save": save()
        case "quit": NSApp.terminate(nil)
        case "undo": perform({ try ws?.undo() })
        case "redo": perform({ try ws?.redo() })
        case "rotate": perform({ try ws?.rotate(currentIndex) })
        case "earlier": let i = currentIndex; perform({ try ws?.move(i, by: -1) }, page: max(0, i - 1))
        case "later": let i = currentIndex; perform({ try ws?.move(i, by: 1) }, page: i + 1)
        case "delete": if confirm("Delete this page from the working copy?", "Your original stays unchanged. You can undo this change.", action: "Delete page") { perform({ try ws?.delete(currentIndex) }) }
        case "previous": reader.goToPreviousPage(nil)
        case "next": reader.goToNextPage(nil)
        case "go": if let s = input("Go to page", value: "\(currentIndex + 1)"), let n = Int(s), let p = reader.document?.page(at: n - 1) { reader.go(to: p) }
        case "zoomIn": reader.zoomIn(nil)
        case "zoomOut": reader.zoomOut(nil)
        case "fit": reader.autoScales = true
        case "overview": setOverview(true)
        case "backReader": setOverview(false)
        case "overviewPrevious": overviewPrevious()
        case "overviewNext": overviewNext()
        case "toggleThumbnails": setThumbnailsVisible(!showingThumbnails)
        case "annotateMode": setAnnotationMode(true)
        case "readMode": setAnnotationMode(false)
        case "find": window.makeFirstResponder(search)
        case "search": findText()
        case "nextMatch": if !matches.isEmpty { matchIndex = (matchIndex + 1) % matches.count; showMatch() }
        case "copy": reader.copy(nil)
        case "select", "note", "ink": reader.tool = action; announce(action == "select" ? "Select text in the PDF." : (action == "note" ? "Click a page to add a sticky note." : "Drag within a page to draw a line."))
        case "highlight", "underline", "strikeOut":
            guard let selection = reader.currentSelection, let kind = AnnotationKind(rawValue: action) else { announce("Select some text in the PDF first."); return }; perform({ try ws?.markSelection(selection, kind: kind) })
        case "unlock": if let password = input("Unlock PDF", message: "The password is used only now. Encrypted PDFs stay read-only.", secret: true) { perform({ try ws?.unlock(password) }, message: "PDF unlocked for reading.") }
        case "insert": insert()
        case "extract": extract()
        case "split": split()
        case "optimise": save(options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true], suffix: "optimised", message: "Optimisation may reduce image detail and may not make every PDF smaller.")
        case "flatten": save(options: [.burnInAnnotationsOption: true], suffix: "flattened", message: "Annotations will become page content. Keep an editable copy too.")
        case "ocr": startOCR()
        case "text": exportText()
        case "image": exportImage()
        case "stop": cancelFlag?.cancel(); announce("Stopping after the current recognition request. Your working copy is kept.")
        case "recovery":
            if recoveryEnabled { recoveryEnabled = false; announce("Recovery is off. Existing recovery remains until you discard it.") }
            else if confirm("Keep a local recovery copy?", "Document content will be stored in this app’s Application Support folder after each edit. It is not encrypted by the app. You can discard it in File.", action: "Enable recovery") { recoveryEnabled = true; if let ws, ws.editable { perform({ try Recovery.store(ws, at: recoveryURL) }, message: "Local recovery enabled.") } }; updateInspector()
        case "restore": if canLeave() { perform({ ws = try Recovery.restore(at: recoveryURL) }, message: "Recovery opened. Save a separate copy to keep it.", page: 0) }
        case "discard": if confirm("Discard the local recovery copy?", "This removes only the app’s saved recovery file. The open working copy and your PDFs stay as they are.", action: "Discard recovery") { perform({ try Recovery.discard(at: recoveryURL) }, message: "Local recovery discarded. Further edits will create a new recovery copy while recovery is on.", storeRecovery: false) }
        case "dark":
            window.appearance = NSAppearance(named: window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .aqua : .darkAqua)
        case "toggleInspector":
            if let focused = window.firstResponder as? NSView, focused.isDescendant(of: showingResults ? resultScroll : inspectorScroll) { focusPrimaryContent() }
            showingResults.toggle(); resultScroll.isHidden = !showingResults || ws == nil; inspectorScroll.isHidden = showingResults; updatePanelToggle(); window.contentView?.layoutSubtreeIfNeeded()
        case "about": about()
        case "more":
            let menu = NSMenu(); for (title, key) in [("Insert or merge…", "insert"), ("Extract pages…", "extract"), ("Split into page files…", "split"), ("Optimise a copy…", "optimise"), ("Searchable scan copy…", "ocr"), ("Export text…", "text"), ("Export page image…", "image"), ("Flatten a copy…", "flatten"), ("About Paperwork", "about")] { let i = NSMenuItem(title: title, action: #selector(command(_:)), keyEquivalent: ""); i.target = self; i.representedObject = key; menu.addItem(i) }; if let b = sender as? NSButton { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height), in: b) }
        default: break
        }
    }
    func openPicker() {
        guard canLeave() else { return }; let p = NSOpenPanel(); p.allowedContentTypes = [.pdf]; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url { openURL(url) }
    }
    func openURL(_ url: URL) {
        do { let next = try Workspace.load(url); ws = next; reader.tool = "select"; refresh(page: 0); announce(next.readOnlyReason ?? "PDF opened. Your original is preserved.") } catch { showError(error) }
    }
    func save(options: [PDFDocumentWriteOption: Any] = [:], suffix: String = "edited", message: String? = nil, output: PDFDocument? = nil) {
        guard let ws else { return }; if let message, !confirm("Save a separate \(suffix) copy?", message, action: "Choose destination") { return }
        let p = NSSavePanel(); p.allowedContentTypes = [.pdf]; p.nameFieldStringValue = (ws.sourceURL?.deletingPathExtension().lastPathComponent ?? "Sample") + "-\(suffix).pdf"
        if p.runModal() == .OK, let url = p.url {
            // Create-only by design. Existing-file replacement is intentionally refused even if a picker offers it.
            perform({ try ws.saveCopy(to: url, document: output, options: options) }, message: "Copy saved to \(url.lastPathComponent). Original preserved.")
        }
    }
    func insert() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.pdf]; p.message = "Insert all pages after the current page. Your originals stay unchanged."
        if p.runModal() == .OK, let url = p.url { perform({ let other = try Workspace.load(url); try ws?.insert(other, after: currentIndex) }) }
    }
    func extract() {
        guard let ws, let value = input("Extract pages", message: "Enter pages such as 1-3, 5. The order you enter is preserved.", value: "\(currentIndex + 1)") else { return }
        do { let indices = try Workspace.range(value, count: ws.document.pageCount); let pdf = try ws.extract(indices); save(suffix: "extracted", output: pdf) } catch { showError(error) }
    }
    func split() {
        guard let ws else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.message = "Choose a folder. Separate page PDFs will be placed in a new subfolder."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        perform({
            let target = folder.appendingPathComponent("Paperwork-pages-" + String(UUID().uuidString.prefix(8)))
            let staging = folder.appendingPathComponent(".paperwork-split-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: staging) }
            for i in 0..<ws.document.pageCount { try ws.saveCopy(to: staging.appendingPathComponent(String(format: "Page-%04d.pdf", i + 1)), document: ws.extract([i])) }
            try FileManager.default.moveItem(at: staging, to: target)
        }, message: "Separate page copies saved in a new folder. Originals preserved.")
    }
    @objc func findText() {
        guard let ws, !busy, !ws.document.isLocked else { return }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        needsSearchRefresh = false; matches = query.isEmpty ? [] : (reader.document?.findString(query, withOptions: .caseInsensitive) ?? []); matchIndex = 0; resultStartIndex = 0; showingResults = true; inspectorScroll.isHidden = true; resultScroll.isHidden = false; refreshSearchResults(); updatePanelToggle()
        if matches.isEmpty { reader.clearSelection(); announce(query.isEmpty ? "Enter words to find in this PDF." : "No matches. Scanned pages may need a searchable copy.") } else { showMatch() }
    }
    func showMatch() { let selection = matches[matchIndex]; reader.setCurrentSelection(selection, animate: false); reader.go(to: selection); announce("Match \(matchIndex + 1) of \(matches.count). Use Command G for the next.") }
    func addNote(_ page: PDFPage, _ point: NSPoint) {
        guard !busy else { return }
        guard let ws, let text = input("Sticky note", message: "Write a note for this page.") else { return }
        perform({ try ws.annotate(.text, page: index(of: page), bounds: NSRect(x: point.x, y: point.y, width: 24, height: 24), text: text) })
    }
    func addInk(_ page: PDFPage, _ points: [NSPoint]) {
        guard !busy else { return }
        guard let ws, let first = points.first else { return }; var box = NSRect(origin: first, size: NSSize(width: 1, height: 1)); for p in points { box = box.union(NSRect(origin: p, size: NSSize(width: 1, height: 1))) }; box = box.insetBy(dx: -3, dy: -3)
        perform({ try ws.annotate(.ink, page: index(of: page), bounds: box, points: points) })
    }
    func editForm(_ page: PDFPage, _ annotation: PDFAnnotation) {
        guard !busy else { return }
        guard let ws, ws.editable else { announce("This PDF is read-only."); return }
        guard let annotationIndex = page.annotations.firstIndex(of: annotation), let corePage = ws.document.page(at: index(of: page)), corePage.annotations.indices.contains(annotationIndex) else { return }
        let annotation = corePage.annotations[annotationIndex]
        let value: String
        if annotation.widgetFieldType == .button {
            guard annotation.widgetControlType == .checkBoxControl || annotation.widgetControlType == .radioButtonControl else { announce("Form action buttons are disabled."); return }
            let on = annotation.buttonWidgetStateString
            guard confirm(annotation.fieldName ?? "Form choice", annotation.buttonWidgetState == .onState ? "Clear this form selection?" : "Select this form option?", action: annotation.buttonWidgetState == .onState ? "Clear selection" : "Select option") else { return }
            value = annotation.buttonWidgetState == .onState ? "Off" : on
        } else if annotation.widgetFieldType == .choice {
            let choices = annotation.choices ?? []
            guard !choices.isEmpty else { announce("This form has no available choices."); return }
            let menu = NSMenu()
            for choice in choices { let item = NSMenuItem(title: choice, action: #selector(formChoice(_:)), keyEquivalent: ""); item.target = self; item.representedObject = ["page": index(of: page), "annotation": annotationIndex, "value": choice] as [String: Any]; menu.addItem(item) }
            menu.popUp(positioning: nil, at: NSPoint(x: reader.bounds.midX, y: reader.bounds.midY), in: reader); return
        } else {
            guard !annotation.isPasswordField else { announce("Password form fields are not stored here."); return }
            guard let entered = input(annotation.fieldName ?? "Form field", message: "Your opened original stays unchanged.", value: annotation.widgetStringValue ?? "") else { return }
            value = entered
        }
        perform({ try ws.fill(page: index(of: page), annotation: annotationIndex, value: value) })
    }
    @objc func formChoice(_ sender: NSMenuItem) {
        guard !busy else { return }
        guard let item = sender.representedObject as? [String: Any], let page = item["page"] as? Int, let annotation = item["annotation"] as? Int, let value = item["value"] as? String else { return }
        perform({ try ws?.fill(page: page, annotation: annotation, value: value) })
    }
    @objc func inspectorAction(_ sender: NSButton) {
        guard !busy, let ws, let page = ws.document.page(at: currentIndex), page.annotations.indices.contains(sender.tag) else { return }; let a = page.annotations[sender.tag]
        if a.type == "Widget" { editForm(page, a) } else { perform({ try ws.removeAnnotation(page: currentIndex, annotation: sender.tag) }) }
    }
    func startOCR() {
        guard let ws else { return }
        do {
            let languages: [String]
            languages = ["en-GB"]
            let languageNames = languages.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 }.joined(separator: ", ")
            guard confirm("Make a searchable scan copy?", "This uses on-device recognition: \(languageNames). Pages are flattened into images with invisible searchable text. Forms and annotations will no longer be editable. Recognition can make mistakes.", action: "Recognise text") else { return }
            let selectedLanguages: [String]? = nil
            let bytes = try ws.data(); let flag = CancellationFlag(); cancelFlag = flag; busy = true; progress.startAnimation(nil); controls["stop"]?.isHidden = false; refresh(); announce("Recognising text on this Mac.")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try LocalOCR.searchableCopy(data: bytes, cancelled: { flag.isCancelled }, progress: { done, total in DispatchQueue.main.async { self?.status.stringValue = "Recognising page \(done) of \(total)." } }, recognitionLanguages: selectedLanguages) }
                DispatchQueue.main.async {
                    guard let self else { return }; self.busy = false; self.cancelFlag = nil; self.progress.stopAnimation(nil); self.controls["stop"]?.isHidden = true; self.refresh()
                    switch result { case .success(let pdf): if flag.isCancelled { self.announce("OCR stopped. Your working copy was kept."); return }; self.announce("Recognition finished in \(languageNames). Choose where to save the searchable copy."); self.save(suffix: "searchable", output: pdf)
                    case .failure(let error): self.showError(error) }
                }
            }
        } catch { showError(error) }
    }
    func exportText() {
        guard let ws else { return }; let p = NSSavePanel(); p.allowedContentTypes = [.plainText]; p.nameFieldStringValue = "Document.txt"
        if p.runModal() == .OK, let url = p.url { perform({ guard !FileManager.default.fileExists(atPath: url.path) else { throw PaperworkError.invalid("Choose a new filename to preserve existing files.") }; try Workspace.writeNew(Data((ws.document.string ?? "").utf8), to: url) }, message: "Text exported. Scanned pages without OCR may have no text.") }
    }
    func exportImage() {
        guard let page = ws?.document.page(at: currentIndex) else { return }; let p = NSSavePanel(); p.allowedContentTypes = [.png]; p.nameFieldStringValue = "Page-\(currentIndex + 1).png"
        if p.runModal() == .OK, let url = p.url { perform({ let size = page.bounds(for: .mediaBox).size; guard size.width <= 2400, size.height <= 2400 else { throw PaperworkError.invalid("Extract a smaller page before exporting an image.") }; let img = page.thumbnail(of: NSSize(width: size.width * 2, height: size.height * 2), for: .mediaBox); guard let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { throw PaperworkError.invalid("The page image could not be prepared.") }; try Workspace.writeNew(png, to: url) }, message: "Page image exported.") }
    }
    func about() {
        let alert = NSAlert(); alert.messageText = "\(edition.displayName) · \(edition.releaseVersion)"; alert.informativeText = "An original local PDF workspace by Ghostzy0.\n\nBuilt with Apple PDFKit and Vision. MIT app source. PDF Expert and Adobe Acrobat are independent workflow references; no affiliation.\n\nExperimental: supported forms only; no redaction, cryptographic signing or content-text replacement. OCR flattens pages. Encrypted and signed PDFs are read-only.\n\nSource and issue tracker: github.com/Ghostzy0/pip-paperwork-replica"; alert.addButton(withTitle: "OK"); alert.beginSheetModal(for: window)
    }
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) { announce("Links are inert in this local workspace. Copy a URL into your browser if you choose to visit it.") }
    func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) { announce("Opening remote documents from a PDF is disabled.") }
}

let app = NSApplication.shared
let delegate = PaperworkApp()
app.delegate = delegate
app.run()
