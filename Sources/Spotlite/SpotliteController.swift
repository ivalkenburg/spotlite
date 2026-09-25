import AppKit
import SpotliteCore

/// Owns the panel, its contents, and the show/hide lifecycle.
@MainActor
final class SpotliteController: NSObject, NSTextFieldDelegate, NSTableViewDataSource,
                                NSTableViewDelegate, PanelDragReceiver {

    private let panel = SpotlitePanel()
    private let glass = NSGlassEffectView()
    private let content = NSView()
    let field = SearchField()
    private let magnifier = NSImageView()
    /// Hairline between the query and the results, so the two don't read as one surface.
    private let divider = NSBox()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let matcher = Matcher()

    private var entries: [AppEntry] = []
    private var items: [ResultItem] = []
    private var frecency = Storage.loadFrecency()
    private var preferences: Preferences {
        didSet { aliases = AliasIndex(aliases: preferences.aliases) }
    }
    /// Rebuilt only when preferences change, never per keystroke.
    private var aliases: AliasIndex
    /// Cached so pruning on every show doesn't rebuild it from the index each time.
    private var indexedIDs: Set<String> = []
    private var watcher: DirectoryWatcher?
    private var fingerprint: [String: Date] = [:]
    private var hasLoadedIndex = false
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    /// Set when a query matches nothing but the Settings entry should still be offered.
    private static let settingsKeywords = ["settings", "preferences", "spotlite"]
    private static let caffeineKeywords = ["caffeinate", "caffeine"]
    private let caffeine: CaffeineAssertion
    private var cursor = 0
    /// Modifiers currently held, which swap the selected row's detail for action hints.
    private var modifiers: NSEvent.ModifierFlags = []
    private var flagsMonitor: Any?
    /// True while the close fade runs. The panel is still on screen, but toggling must
    /// treat it as hidden, and a show that lands mid-fade must cancel the pending cleanup.
    private var isDismissing = false
    /// Resize is driven by row-count changes, not keystrokes.
    private var lastRowCount = -1
    /// The list height is set explicitly rather than inferred: an implicit Auto Layout
    /// minimum (input height + content insets) otherwise becomes a floor the window
    /// cannot collapse below once the scroll view has held rows.
    private var listHeight: NSLayoutConstraint!
    /// Top edge stays put while the panel grows downward.
    private var anchorTopY: CGFloat = 0
    /// Fixed for one presentation so moving the pointer to another display cannot make
    /// the panel jump while its result count changes.
    private var activeVisibleFrame: CGRect?

    private let leadingEdge = ResizeEdgeView(edge: .leading)
    private let trailingEdge = ResizeEdgeView(edge: .trailing)
    private let moveHandle = MoveHandleView()

    /// The geometry as stored. `fittedGeometry` is what actually gets used.
    private var geometry: PanelGeometry { preferences.panelGeometry }
    /// Live drag state. Non-nil only between mouse-down and the drag ending.
    private var drag: (kind: PanelDrag, origin: NSPoint, start: PanelGeometry,
                       screen: CGRect, engaged: Bool)?

    /// Called when the user picks the Settings entry, or hides an app.
    var onOpenSettings: (() -> Void)?
    var onPreferencesChanged: ((Preferences) -> Void)?
    var onIndexChanged: (([AppEntry]) -> Void)?

    init(caffeine: CaffeineAssertion, preferences: Preferences) {
        self.caffeine = caffeine
        self.preferences = preferences
        aliases = AliasIndex(aliases: preferences.aliases)
        super.init()
        buildUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(resignedKey),
            name: NSWindow.didResignKeyNotification, object: panel
        )
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.modifiersChanged(event.modifierFlags)
            return event
        }
    }

    // MARK: - Construction

    private func buildUI() {
        glass.cornerRadius = Metrics.cornerRadius
        glass.style = .regular
        applyResolvedAppearance()

        // Primary label color, as Spotlight uses: secondary reads washed out on glass.
        var symbolConfig = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        symbolConfig = symbolConfig.applying(.init(paletteColors: [.labelColor]))
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")?
            .withSymbolConfiguration(symbolConfig)
        magnifier.contentTintColor = .labelColor

        field.delegate = self
        field.onCommandDigit = { [weak self] index in self?.launch(at: index) }
        field.onCommandReturn = { [weak self] in self?.revealInFinder() }
        field.onCommandQ = { [weak self] in self?.quitApp() }

        divider.boxType = .separator
        divider.isHidden = true

        table.headerView = nil
        table.rowHeight = Metrics.rowHeight
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Metrics.listPadding, left: 0,
                                            bottom: Metrics.listPadding, right: 0)

        for v in [magnifier, field, scroll, divider] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }

        listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.magnifierInset),
            magnifier.topAnchor.constraint(equalTo: content.topAnchor),
            magnifier.heightAnchor.constraint(equalToConstant: Metrics.inputHeight),
            magnifier.widthAnchor.constraint(equalToConstant: Metrics.magnifierWidth),

            field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: Metrics.magnifierGap),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Metrics.horizontalInset),
            // Centered against the magnifier, not stretched to the input height:
            // a text field taller than its line draws the text at the top, not the middle.
            field.centerYAnchor.constraint(equalTo: magnifier.centerYAnchor),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            // Zero constant: padding baked into a constraint becomes an Auto Layout
            // minimum height, which would stop the panel collapsing back to the input height.
            // The list padding lives in the scroll view's content insets instead.
            scroll.topAnchor.constraint(equalTo: magnifier.bottomAnchor),
            listHeight,

            // Overlaps the list's top content inset, so it adds no height of its own.
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.horizontalInset),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Metrics.horizontalInset),
            divider.topAnchor.constraint(equalTo: magnifier.bottomAnchor),
        ])

        for handle in [moveHandle, leadingEdge, trailingEdge] as [NSView] {
            handle.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(handle)
        }
        moveHandle.receiver = self
        leadingEdge.receiver = self
        trailingEdge.receiver = self
        // Only the part of the bar the query text doesn't occupy is draggable, so
        // click-and-drag to select text still works.
        moveHandle.textEndX = { [weak self] in
            guard let self else { return 0 }
            let textWidth = self.field.attributedStringValue.size().width
            return self.field.frame.minX + textWidth + 8
        }

        NSLayoutConstraint.activate([
            moveHandle.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            moveHandle.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            moveHandle.topAnchor.constraint(equalTo: content.topAnchor),
            moveHandle.heightAnchor.constraint(equalToConstant: Metrics.inputHeight),

            leadingEdge.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            leadingEdge.widthAnchor.constraint(equalToConstant: Metrics.resizeEdgeWidth),
            leadingEdge.topAnchor.constraint(equalTo: content.topAnchor),
            leadingEdge.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            trailingEdge.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            trailingEdge.widthAnchor.constraint(equalToConstant: Metrics.resizeEdgeWidth),
            trailingEdge.topAnchor.constraint(equalTo: content.topAnchor),
            trailingEdge.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        glass.contentView = content
        glass.wantsLayer = true
        glass.shadow = {
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(CGFloat(Metrics.shadowOpacity))
            sh.shadowBlurRadius = Metrics.shadowRadius
            sh.shadowOffset = NSSize(width: 0, height: Metrics.shadowOffsetY)
            return sh
        }()

        // The glass view sits inside a transparent margin rather than being the window's
        // contentView: filling the frame exactly clips its shadow into a square halo.
        let host = MarginHostView()
        host.glass = glass
        host.onEffectiveAppearanceChange = { [weak self] in
            guard let self, self.preferences.themeMode == .system else { return }
            self.applyResolvedAppearance()
        }
        host.addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false
        let m = Metrics.windowMargin
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m),
            glass.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -m),
            glass.topAnchor.constraint(equalTo: host.topAnchor, constant: m),
            glass.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -m),
        ])
        panel.contentView = host
    }

    /// Glass gives its contents a vibrant appearance, which can keep label colors white
    /// even when the glass itself is light. Resolve the theme once and apply the same
    /// concrete appearance to every layer before any of them becomes visible. The glass
    /// is left untinted, as Spotlight's is, so the backdrop's colour shows through the blur.
    private func applyResolvedAppearance() {
        let name: NSAppearance.Name
        switch preferences.themeMode {
        case .light:
            name = .aqua
        case .dark:
            name = .darkAqua
        case .system:
            name = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .darkAqua : .aqua
        }
        let appearance = NSAppearance(named: name)
        // Leaving the panel itself inherited in System mode lets the host observe later
        // system changes; glass and content still receive the resolved value immediately.
        panel.appearance = preferences.themeMode == .system ? nil : appearance
        glass.appearance = appearance
        content.appearance = appearance
    }

    // MARK: - Lifecycle

    func toggle() {
        panel.isVisible && !isDismissing ? hide() : show()
    }

    func dumpFrames(_ tag: String) {
        panel.layoutIfNeeded()
        print("[\(tag)] window=\(panel.frame)")
        print("[\(tag)] host=\(panel.contentView?.frame ?? .zero)")
        print("[\(tag)] glass=\(glass.frame)  cornerRadius=\(glass.cornerRadius)")
        print("[\(tag)] content=\(glass.contentView?.frame ?? .zero)")
        print("[\(tag)] scroll=\(scroll.frame) listHeight=\(listHeight.constant)")
    }

    func show() {
        isDismissing = false
        modifiers = NSEvent.modifierFlags
        applyResolvedAppearance()
        caffeine.refresh()
        loadIndexIfNeeded()

        // Dev hook: prefill a query so the expanded state can be inspected.
        field.stringValue = ProcessInfo.processInfo.environment["SPOTLITE_DEV_QUERY"] ?? ""
        // Anchor first: updateMatches resizes against anchorTopY, and an in-flight
        // resize animation would otherwise finish last and clobber the placement.
        position()
        updateMatches(for: field.stringValue)
        // Prepare the correctly-themed backing contents while the window is still
        // hidden. Otherwise Liquid Glass can expose one inherited-appearance frame.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()

        // Starts from wherever a cancelled close fade left off, not from zero, so a
        // quick re-open doesn't flash.
        if !panel.isVisible { panel.alphaValue = 0 }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        animateIn()
    }

    /// A short fade with a slight grow from the centre. The window frame is left alone:
    /// it is owned by the geometry code, and animating it would fight row-count resizes.
    private func animateIn() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Metrics.showDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        // Presentation-only: the model transform stays identity, so AppKit's own layer
        // management never sees a scaled view. A view's layer anchors at its origin,
        // so the scale is wrapped in translations to grow from the centre.
        guard let layer = glass.layer else { return }
        let w = layer.bounds.width / 2, h = layer.bounds.height / 2
        let s = Metrics.showStartScale
        var from = CATransform3DMakeTranslation(-w, -h, 0)
        from = CATransform3DConcat(from, CATransform3DMakeScale(s, s, 1))
        from = CATransform3DConcat(from, CATransform3DMakeTranslation(w, h, 0))
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = from
        grow.toValue = CATransform3DIdentity
        grow.duration = Metrics.showDuration
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(grow, forKey: "show")
    }

    /// The current index, for the Settings app list. Already sorted by name.
    func indexedApps() -> [AppEntry] {
        loadIndexIfNeeded()
        return entries
    }

    /// Loads the index on first use and starts watching; on later calls does the cheap
    /// staleness check that catches changes FSEvents missed while the machine was asleep.
    private func loadIndexIfNeeded() {
        guard hasLoadedIndex else {
            hasLoadedIndex = true
            entries = AppIndex.loadCached() ?? []
            indexedIDs = Set(entries.map(\.id))
            pruneFrecency()
            fingerprint = AppIndex.directoriesFingerprint()
            startWatching()
            // Cached results make the first frame immediate; this scan guarantees that
            // changes made while Spotlite was not running are still discovered.
            requestIndexRefresh()
            return
        }

        let current = AppIndex.directoriesFingerprint()
        guard current != fingerprint else { return }
        fingerprint = current
        requestIndexRefresh()
    }

    /// Coalesces refresh requests and keeps bundle traversal plus cache writes off the
    /// main actor. Only complete immutable snapshots cross back into the UI.
    private func requestIndexRefresh() {
        guard refreshTask == nil else {
            refreshPending = true
            return
        }

        refreshTask = Task { [weak self] in
            let refreshed = await Task.detached(priority: .utility) {
                AppIndex.refresh()
            }.value
            guard let self else { return }
            self.entries = refreshed
            self.indexedIDs = Set(refreshed.map(\.id))
            self.pruneFrecency()
            self.fingerprint = AppIndex.directoriesFingerprint()
            self.onIndexChanged?(refreshed)
            if self.panel.isVisible { self.updateMatches(for: self.field.stringValue) }

            self.refreshTask = nil
            if self.refreshPending {
                self.refreshPending = false
                self.requestIndexRefresh()
            }
        }
    }

    func hide() {
        guard panel.isVisible, !isDismissing else { return }
        isDismissing = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Metrics.hideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                // A show() during the fade cleared the flag and owns the panel now.
                guard let self, self.isDismissing else { return }
                self.isDismissing = false
                self.finishHide()
            }
        }
    }

    private func finishHide() {
        panel.orderOut(nil)
        field.stringValue = ""
        items = []
        cursor = 0
        lastRowCount = -1
        activeVisibleFrame = nil
    }

    /// Dev captures steal key focus, which would dismiss the panel mid-measurement.
    private let pinnedOpen = ProcessInfo.processInfo.environment["SPOTLITE_DEV_PIN"] == "1"

    @objc private func resignedKey() {
        guard !pinnedOpen else { return }
        hide()
    }

    /// Placed on whichever display the user chose. Following the pointer is the default
    /// because your eyes are usually where your mouse is, but on a fixed multi-monitor
    /// setup an incidental pointer position is the wrong signal.
    private func position() {
        guard let frame = selectedVisibleFrame() else { return }
        activeVisibleFrame = frame
        apply(fitted(for: frame), on: frame, rows: 0, animated: false)
    }

    private func selectedVisibleFrame() -> CGRect? {
        let screen: NSScreen?
        switch preferences.panelScreen {
        case .followPointer:
            let mouse = NSEvent.mouseLocation
            screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        case .primary:
            // `screens.first` is the one with the menu bar; `main` follows key window.
            screen = NSScreen.screens.first ?? NSScreen.main
        }
        return screen?.visibleFrame
    }

    /// Stored geometry clamped to what this screen can actually hold. The clamp is never
    /// written back: unplugging a display must not destroy the real setting.
    private func fitted(for visibleFrame: CGRect) -> PanelGeometry {
        geometry.fitted(visibleFrame: visibleFrame,
                        chromeInset: Metrics.chromeInset,
                        expandedHeight: Metrics.height(forRows: Metrics.maxVisibleRows))
    }

    private var currentVisibleFrame: CGRect {
        if let drag { return drag.screen }
        return activeVisibleFrame ?? selectedVisibleFrame() ?? .zero
    }

    /// The single place the panel's frame is computed, so width, vertical position and
    /// row-count growth can never disagree about where the panel belongs.
    private func apply(_ geometry: PanelGeometry, on visibleFrame: CGRect, rows: Int, animated: Bool) {
        anchorTopY = geometry.anchorTopY(visibleFrame: visibleFrame)

        let height = Metrics.windowHeight(forRows: rows)
        let width = Metrics.windowWidth(for: geometry.width)
        let frame = NSRect(x: visibleFrame.midX - width / 2,
                           y: anchorTopY + Metrics.chromeInset - height,
                           width: width, height: height)

        guard animated, panel.isVisible else {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak panel] in
            // A borderless transparent window caches its shadow from the old alpha
            // mask; without this the previous size ghosts as chamfers at the corners.
            Task { @MainActor in panel?.invalidateShadow() }
        }
    }

    /// Dev harness: show -> type -> clear, logging the panel frame at each step,
    /// so the collapse-back state can be measured rather than eyeballed.
    func runDevSequence() {
        show()
        NSLog("DEV step1 shown: \(panel.frame)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.field.stringValue = "a"
            self.updateMatches(for: "a")
            NSLog("DEV step2 typed: \(self.panel.frame)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                self.field.stringValue = ""
                self.updateMatches(for: "")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSLog("DEV step3 cleared: \(self.panel.frame)")
                }
            }
        }
    }

    // MARK: - Query

    func controlTextDidChange(_ obj: Notification) {
        updateMatches(for: field.stringValue)
    }

    func updateMatches(for query: String) {
        items = buildItems(for: query)
        cursor = 0
        table.reloadData()
        resizeIfRowCountChanged()
        scrollCursorIntoView()
    }

    /// Assembles the result list: a calculation pinned on top when the query is
    /// arithmetic, then apps ranked by textual score plus frecency, then Settings when
    /// the query asks for it. Apps still appear below a calculation, since `x^2`
    /// shouldn't hide an app named X.
    private func buildItems(for query: String) -> [ResultItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var result: [ResultItem] = []
        if let value = Calculator.evaluate(trimmed) {
            result.append(.calculation(value: value))
        }

        let matches = matcher.search(trimmed, in: entries, aliases: aliases,
                                     limit: max(1, entries.count))
        let ranked = AppRanking.rank(matches,
                                     hiddenBundleIDs: preferences.hiddenBundleIDs,
                                     frecency: frecency)
        result.append(contentsOf: ranked.map(ResultItem.app))

        // The self-indexed escape hatch: reachable even with the menu bar icon hidden.
        // Three characters minimum, or a bare "s" or "p" would summon it on every search.
        let lowered = trimmed.lowercased()
        if lowered.count >= 3, SpotliteController.settingsKeywords.contains(where: { $0.hasPrefix(lowered) }) {
            result.append(.settings)
        }
        if lowered.count >= 3, SpotliteController.caffeineKeywords.contains(where: { $0.hasPrefix(lowered) }) {
            result.append(.caffeinate(state: caffeine.state))
        }
        return result
    }

    /// The whole point of row-count-triggered resizing: typing narrows results constantly,
    /// but the window only moves when the number of *visible* rows actually changes.
    private func resizeIfRowCountChanged() {
        let rows = min(items.count, Metrics.maxVisibleRows)
        guard rows != lastRowCount else { return }
        lastRowCount = rows

        listHeight.constant = Metrics.height(forRows: items.count) - Metrics.inputHeight
        scroll.isHidden = rows == 0
        divider.isHidden = rows == 0

        // Stand down while a drag is in flight. The drag reconciles the row count itself
        // when it ends.
        guard drag == nil else { return }

        let visibleFrame = currentVisibleFrame
        // NSGlassEffectView visibly nudges its top edge while its window is live-resized,
        // even though the start and end frames share the exact same top coordinate.
        // Applying the row-count resize directly avoids that transient glass morph.
        apply(fitted(for: visibleFrame), on: visibleFrame, rows: items.count, animated: false)
    }

    // MARK: - Keyboard

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveCursor(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveCursor(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            launch(at: cursor); return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Option-Return arrives as this, not as insertNewline.
            copyPath(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):
            // Command-Delete inside a text field arrives as deleteToBeginningOfLine.
            hideAppUnderCursor(); return true
        default:
            return false
        }
    }

    /// Wraps in both directions — standard for a short list.
    private func moveCursor(by delta: Int) {
        guard !items.isEmpty else { return }
        let previous = cursor
        cursor = (cursor + delta + items.count) % items.count
        table.reloadData(forRowIndexes: IndexSet([previous, cursor]),
                         columnIndexes: IndexSet(integer: 0))
        scrollCursorIntoView()
    }

    private func scrollCursorIntoView() {
        guard !items.isEmpty else { return }
        table.scrollRowToVisible(cursor)
    }

    @objc private func tableClicked() {
        let row = table.clickedRow
        guard row >= 0 else { return }
        launch(at: row)
    }

    // MARK: - Launch

    private func launch(at index: Int) {
        guard items.indices.contains(index) else { return }

        switch items[index] {
        case .calculation(let value):
            let text = Calculator.format(value)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            hide()

        case .settings:
            hide()
            onOpenSettings?()

        case .caffeinate(let state):
            // Stays open, unlike every other action: the switch is the only confirmation
            // that anything happened, and closing would hide it.
            guard state != .external else {
                NSSound.beep()
                caffeine.refresh()
                return
            }
            caffeine.toggle()

        case .app(let match):
            let entry = match.entry
            let query = field.stringValue
            frecency.recordLaunch(entry.id)
            Storage.save(frecency)
            hide()

            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            // Fire and forget: waiting on a slow-launching app would freeze the panel.
            NSWorkspace.shared.openApplication(at: entry.url, configuration: config) { [weak self] _, error in
                guard error != nil else { return }
                Task { @MainActor in
                    guard let self else { return }
                    // The app is gone, so the whole index is suspect: rescan rather than
                    // just dropping this entry, or the stale one returns from the cache.
                    self.show()
                    // show() clears the field. Restore the query, otherwise the panel
                    // reopens blank and the failure reads as nothing having happened.
                    self.field.stringValue = query
                    self.updateMatches(for: query)
                    self.requestIndexRefresh()
                }
            }
        }
    }

    /// The app under the cursor, or a beep when the cursor is on something that isn't
    /// an app — the alternate actions have no meaning for a calculation or Settings.
    private func appUnderCursor() -> MatchResult? {
        guard items.indices.contains(cursor), case .app(let match) = items[cursor] else {
            NSSound.beep()
            return nil
        }
        return match
    }

    private func revealInFinder() {
        guard let match = appUnderCursor() else { return }
        hide()
        NSWorkspace.shared.activateFileViewerSelecting([match.entry.url])
    }

    private func copyPath() {
        guard let match = appUnderCursor() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(match.entry.url.path, forType: .string)
        hide()
    }

    private func quitApp() {
        guard appUnderCursor() != nil else { return }
        let running = items[cursor].runningApplications
        guard !running.isEmpty else {
            NSSound.beep()
            return
        }
        running.forEach { $0.terminate() }
        hide()
    }

    /// Redraws only the selected row: it is the only one whose detail depends on modifiers.
    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let relevant = flags.intersection([.command, .option])
        guard relevant != modifiers.intersection([.command, .option]) else { return }
        modifiers = flags
        guard panel.isVisible, items.indices.contains(cursor) else { return }
        table.reloadData(forRowIndexes: IndexSet(integer: cursor), columnIndexes: IndexSet(integer: 0))
    }

    /// Hides the app under the cursor. Bound to Command-Delete: the fast path, with the
    /// full list available in Settings for un-hiding.
    private func hideAppUnderCursor() {
        guard items.indices.contains(cursor), case .app(let match) = items[cursor],
              let bundleID = match.entry.bundleID else { return }

        preferences.hiddenBundleIDs.insert(bundleID)
        Storage.save(preferences)
        onPreferencesChanged?(preferences)
        updateMatches(for: field.stringValue)
    }

    /// Re-reads preferences after the Settings window changes them, so hiding or
    /// un-hiding an app takes effect on the next keystroke rather than the next launch.
    func preferencesDidChange(_ updated: Preferences) {
        let screenChanged = preferences.panelScreen != updated.panelScreen
        preferences = updated
        applyResolvedAppearance()
        guard panel.isVisible else { return }
        updateMatches(for: field.stringValue)
        // Picks up a Reset Size & Position from Settings while the panel is on screen.
        if screenChanged { activeVisibleFrame = selectedVisibleFrame() }
        let visibleFrame = currentVisibleFrame
        apply(fitted(for: visibleFrame), on: visibleFrame, rows: items.count, animated: true)
    }

    func caffeineStateDidChange() {
        guard panel.isVisible else { return }
        let query = field.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        guard query.count >= 3,
              SpotliteController.caffeineKeywords.contains(where: { $0.hasPrefix(query) })
        else { return }
        updateMatches(for: field.stringValue)
    }

    /// Drops launch history for apps that are gone and caps what remains. Called when a
    /// cached or freshly scanned index is installed, never on the panel's hot path.
    private func pruneFrecency() {
        guard !indexedIDs.isEmpty else { return }
        if frecency.prune(keeping: indexedIDs) { Storage.save(frecency) }
    }

    private func startWatching() {
        let paths = AppIndex.searchDirectories.map(\.path)
        watcher = DirectoryWatcher(paths: paths) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.requestIndexRefresh()
            }
        }
    }

    // MARK: - Dragging

    func dragBegan(_ kind: PanelDrag, at screenPoint: NSPoint) {
        let frame = currentVisibleFrame
        drag = (kind, screenPoint, fitted(for: frame), frame, engaged: false)
    }

    func dragChanged(to screenPoint: NSPoint) {
        guard var session = drag else { return }

        let dx = screenPoint.x - session.origin.x
        let dy = screenPoint.y - session.origin.y

        // A click always jitters a pixel or two; without this every click on the header
        // would nudge the panel.
        if !session.engaged {
            guard max(abs(dx), abs(dy)) >= Metrics.dragThreshold else { return }
            session.engaged = true
        }
        drag = session

        let updated: PanelGeometry
        switch session.kind {
        case .move:
            updated = session.start.moved(pointerDelta: dy, visibleHeight: session.screen.height)
        case .resize(let edge):
            updated = session.start.resized(edge: edge, pointerDelta: dx)
        }

        preferences.panelGeometry = updated
        // Never animated: an animation here would leave the panel lagging the pointer.
        apply(fitted(for: session.screen), on: session.screen, rows: items.count, animated: false)
    }

    func dragEnded() {
        guard let session = drag else { return }
        drag = nil
        guard session.engaged else { return }

        Storage.save(preferences)
        onPreferencesChanged?(preferences)
        // Reconcile whatever row-count change was suppressed while dragging.
        apply(fitted(for: session.screen), on: session.screen, rows: items.count, animated: false)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: ResultRowView.reuseID, owner: self) as? ResultRowView
            ?? {
                let v = ResultRowView(frame: .zero)
                v.identifier = ResultRowView.reuseID
                return v
            }()
        view.configure(with: items[row], selected: row == cursor, modifiers: modifiers)
        return view
    }

    /// Hover must never move the cursor: an incidental mouse position silently
    /// changing what Enter does is a genuinely dangerous interaction in a launcher.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
