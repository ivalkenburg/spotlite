import AppKit
import SpotliteCore

/// Owns the panel, its contents, and the show/hide lifecycle.
@MainActor
final class SpotliteController: NSObject, NSTextFieldDelegate, NSTableViewDataSource,
                                NSTableViewDelegate {

    private let panel = SpotlitePanel()
    private let glass = NSGlassEffectView()
    private let content = FlippedView()
    /// Lazy so the appearance applied at the start of construction can reach it.
    private lazy var bar = SearchBar(in: content)
    var field: SearchField { bar.field }
    /// Hairline between the query and the results, so the two don't read as one surface.
    private let divider = NSView()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let matcher = Matcher()

    /// Owned by the app delegate and shared with Settings.
    let library: AppLibrary
    private var placement: PanelPlacement!
    private var items: [ResultItem] = []
    private var preferences: Preferences {
        // Not on every change: a drag writes the geometry here on every pointer move.
        didSet {
            guard preferences.links != oldValue.links
                || preferences.aliases != oldValue.aliases
                || preferences.hiddenBundleIDs != oldValue.hiddenBundleIDs
                || preferences.showSystemSettings != oldValue.showSystemSettings
                || preferences.showSystemCommands != oldValue.showSystemCommands
            else { return }
            rebuildCorpus()
        }
    }
    /// Rebuilt when the index, aliases, hidden apps, links or kind settings change, never
    /// per keystroke.
    private var corpus = SearchCorpus.empty
    private let caffeine: CaffeineAssertion
    private var cursor = 0
    /// Bundle paths of running apps, taken when the panel opens rather than per row
    /// render. The panel lives for seconds, so launches while it is open don't matter.
    /// Taken even with the dot off: the Quit hint needs it too.
    private var runningPaths: Set<String> = []

    /// Spotlight's three selection states. The top hit is marked softly; arrowing turns
    /// the selection solid accent blue; the first Backspace after a completion removes
    /// the completion and shows no selection at all, while Return still launches the
    /// top result.
    private typealias Selection = SearchSelection
    private var selection = Selection.topHit
    private var navigation = SearchNavigation()
    private var argument: AppEntry? {
        if case .argument(let link) = navigation.scope { return link }
        return nil
    }
    /// The query before the latest edit, to tell typing from deleting.
    private var lastQuery = ""
    /// The query at the last close, offered back on a quick reopen.
    private var queryMemory = QueryMemory()
    /// The calculator's `ans`: the result on screen when the panel last closed.
    private var previousResult: Double?
    /// Modifiers currently held, which swap the selected row's detail for action hints.
    private var modifiers: NSEvent.ModifierFlags = []
    private var flagsMonitor: Any?
    /// True while the close fade runs. The panel is still on screen, but toggling must
    /// treat it as hidden, and a show that lands mid-fade must cancel the pending cleanup.
    private var isDismissing = false
    /// The list height is set explicitly rather than inferred: an implicit Auto Layout
    /// minimum otherwise becomes a floor the panel cannot collapse below once the scroll
    /// view has held rows.
    private var listHeight: NSLayoutConstraint!
    /// The list's top edge, below the bar and its top padding.
    private var listTop: NSLayoutConstraint!
    /// The glass's own height inside the fixed-size window, animated as results appear.
    private var glassHeight: NSLayoutConstraint!
    /// Steps the glass's size constraints frame by frame; see `FrameAnimator`.
    private var animator: FrameAnimator!

    private let leadingEdge = ResizeEdgeView(edge: .leading)
    private let trailingEdge = ResizeEdgeView(edge: .trailing)
    private let moveHandle = MoveHandleView()

    /// Called when the user picks the Settings entry, or hides an app.
    var onOpenSettings: (() -> Void)?
    var onPreferencesChanged: ((Preferences) -> Void)?
    init(library: AppLibrary, caffeine: CaffeineAssertion, preferences: Preferences) {
        self.library = library
        self.caffeine = caffeine
        self.preferences = preferences
        super.init()
        placement = PanelPlacement(panel: panel) { [unowned self] in self.preferences }
        buildUI()
        placement.onGeometryChange = { [weak self] geometry, finished in
            guard let self else { return }
            self.preferences.panelGeometry = geometry
            guard finished else { return }
            Storage.save(self.preferences)
            self.onPreferencesChanged?(self.preferences)
        }
        moveHandle.receiver = placement
        leadingEdge.receiver = placement
        trailingEdge.receiver = placement
        rebuildCorpus()
        NotificationCenter.default.addObserver(
            self, selector: #selector(resignedKey),
            name: NSWindow.didResignKeyNotification, object: panel
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveScrollStarted),
            name: NSScrollView.willStartLiveScrollNotification, object: scroll
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

        field.delegate = self
        field.onCommandDigit = { [weak self] index in self?.launch(at: index) }
        field.onCommandReturn = { [weak self] in self?.revealInFinder() }
        field.onCommandQ = { [weak self] in self?.quitApp() }

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
        // A click must not take focus from the field: Caffeinate and a template link keep
        // the panel open, and typing has to keep reaching the query.
        table.refusesFirstResponder = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false

        for v in [scroll, divider] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }

        listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        // The list padding sits outside the scroll view rather than in its content
        // insets, so rows are clipped at the padding instead of showing slivers in it.
        listTop = scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.inputHeight)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            listTop,
            listHeight,

            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.horizontalInset),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Metrics.horizontalInset),
            divider.topAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.dividerY),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])

        for handle in [moveHandle, leadingEdge, trailingEdge] as [NSView] {
            handle.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(handle)
        }
        // Only the part of the bar the query text doesn't occupy is draggable, so
        // click-and-drag to select text still works.
        moveHandle.textEndX = { [weak self] in
            guard let self else { return 0 }
            return self.bar.typedTextEndX(in: self.content) + 8
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
        // Rows are laid out at the list's final height and revealed by the glass's
        // growing edge, so anything past the glass must not draw.
        content.clipsToBounds = true
        glass.wantsLayer = true
        glass.shadow = {
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(Metrics.shadowOpacity)
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
        glassHeight = glass.heightAnchor.constraint(equalToConstant: Metrics.inputHeight)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m),
            glass.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -m),
            glassHeight,
            glass.topAnchor.constraint(equalTo: host.topAnchor, constant: m),
        ])
        panel.contentView = host
        animator = FrameAnimator(view: host)
        applyVibrancy()
    }

    /// Glass gives its contents a vibrant appearance, which can keep label colors white
    /// even when the glass itself is light. Resolve the theme once and apply the same
    /// concrete appearance to every layer before any of them becomes visible. By default
    /// the glass is left untinted, as Spotlight's is, so the backdrop's colour shows
    /// through the blur; the Tint setting blends it toward the theme's neutral colour.
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
        let tint = preferences.glassTint
        glass.tintColor = tint > 0
            ? Metrics.glassTint(dark: name == .darkAqua).withAlphaComponent(tint)
            : nil
        applyVibrancy()
    }

    /// The bar's secondary elements and the divider blend additively, as Spotlight's
    /// do; see `Vibrancy`.
    private func applyVibrancy() {
        guard let appearance = content.appearance else { return }
        let mode = Vibrancy.mode(for: appearance)
        bar.applyVibrancy(mode)
        Vibrancy.fill(divider, Vibrancy.fill, mode)
    }

    // MARK: - Lifecycle

    func toggle() {
        panel.isVisible && !isDismissing ? hide() : show()
    }

    func show() {
        isDismissing = false
        modifiers = NSEvent.modifierFlags
        applyResolvedAppearance()
        caffeine.refresh()
        loadLibrary()
        runningPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        // A show during the close fade can still find a submenu or argument open.
        resetNavigation()
        ResultItem.forgetHandlers()

        let recalled = devQuery == nil ? queryMemory.recall(retention: preferences.queryRetention) : nil
        field.stringValue = devQuery ?? recalled ?? ""
        lastQuery = field.stringValue
        selection = .topHit
        // Anchor first: the glass grows downward from the placed top edge.
        placement.place()
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
        // A recalled query is selected whole, as in Spotlight, so typing replaces it and
        // Return repeats it. A dev query gets the caret at the end, as typing leaves it.
        if let editor = field.currentEditor() {
            let length = (field.stringValue as NSString).length
            editor.selectedRange = recalled != nil
                ? NSRange(location: 0, length: length)
                : NSRange(location: length, length: 0)
        }
        // The completion is placed from the field editor's layout, which exists only
        // once the field is first responder.
        updateChrome()
        animateIn()
    }

    /// Spotlight's open: a quick fade while the panel settles from slightly larger.
    private func animateIn() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Metrics.showFadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        glass.layer?.removeAnimation(forKey: "hide")
        let settle = scaleAnimation(from: Metrics.showStartScale, to: 1,
                                    duration: Metrics.showScaleDuration)
        glass.layer?.add(settle, forKey: "show")
    }

    /// Presentation-only: the model transform stays identity, so AppKit's own layer
    /// management never sees a scaled view. A view's layer anchors at its origin, so the
    /// scale is wrapped in translations to act about the centre.
    private func scaleAnimation(from start: CGFloat, to end: CGFloat, duration: Double) -> CABasicAnimation {
        let bounds = glass.layer?.bounds ?? .zero
        func scaled(_ s: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(-bounds.width / 2, -bounds.height / 2, 0)
            t = CATransform3DConcat(t, CATransform3DMakeScale(s, s, 1))
            return CATransform3DConcat(t, CATransform3DMakeTranslation(bounds.width / 2, bounds.height / 2, 0))
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = scaled(start)
        animation.toValue = scaled(end)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return animation
    }

    private func loadLibrary() {
        if library.loadIfNeeded() { rebuildCorpus() }
    }

    func libraryDidChange() {
        rebuildCorpus()
        if panel.isVisible { refreshMatches() }
    }

    private func rebuildCorpus() {
        corpus = SearchCorpus(entries: library.entries,
                              aliases: AliasIndex(aliases: preferences.aliases),
                              hiddenBundleIDs: preferences.hiddenBundleIDs,
                              includeSettingsPanes: preferences.showSystemSettings,
                              includeCommands: preferences.showSystemCommands)
    }

    func hide() {
        guard panel.isVisible, !isDismissing else { return }
        isDismissing = true
        // Taken now rather than when the fade ends: a show() during the fade must
        // already see this query.
        queryMemory.remember(navigation.rootQuery ?? field.stringValue)
        if case .calculation(_, let value) = items.first { previousResult = value }
        // Holds the shrunk transform until the window is ordered out; removed on show.
        let shrink = scaleAnimation(from: 1, to: Metrics.hideEndScale, duration: Metrics.hideDuration)
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        glass.layer?.add(shrink, forKey: "hide")
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
        glass.layer?.removeAnimation(forKey: "hide")
        resetNavigation()
        field.stringValue = ""
        lastQuery = ""
        selection = .topHit
        items = []
        cursor = 0
        table.reloadData()
        layoutList(animated: false)
        updateChrome()
        placement.release()
    }

    /// Dev captures steal key focus, which would dismiss the panel mid-measurement.
    private let pinnedOpen = ProcessInfo.processInfo.environment["SPOTLITE_DEV_PIN"] == "1"
    /// Dev hook: prefill a query so the expanded state can be inspected. Read once:
    /// `environment` builds a fresh dictionary on every access.
    private let devQuery = ProcessInfo.processInfo.environment["SPOTLITE_DEV_QUERY"]

    @objc private func resignedKey() {
        guard !pinnedOpen else { return }
        hide()
    }

    /// A trackpad scroll uses the resting height, so scrolling back to the top after the
    /// arrow keys shortened the list doesn't leave its last row cut off.
    @objc private func liveScrollStarted() {
        let resting = viewport.restingHeight
        guard !items.isEmpty, listHeight.constant != resting else { return }
        listHeight.constant = resting
        scroll.layoutSubtreeIfNeeded()
    }

    // MARK: - Query

    func controlTextDidChange(_ obj: Notification) {
        let query = field.stringValue
        // Typing brings the completion back. Deleting after Backspace dismissed it does
        // not, so a run of Backspaces keeps the bare query, as in Spotlight.
        if query.count > lastQuery.count || query.isEmpty { selection = .topHit }
        lastQuery = query
        updateMatches(for: query)
    }

    func updateMatches(for query: String) {
        items = buildItems(for: query)
        cursor = 0
        // A new result list starts from the top hit again; a dismissed completion stays
        // dismissed until the user types.
        if selection == .navigated { selection = .topHit }
        table.reloadData()
        layoutList(animated: true)
        updateChrome()
    }

    /// Rebuilds the list for an unchanged query when something beneath it changes: the
    /// index, or caffeine's state. A row the user arrowed to stays selected, so toggling
    /// Caffeinate does not leave Return aimed at whatever now sits at the top.
    private func refreshMatches() {
        let navigatedTo = selection == .navigated && items.indices.contains(cursor)
            ? items[cursor].identity : nil
        updateMatches(for: field.stringValue)
        guard let navigatedTo, let row = items.firstIndex(where: { $0.identity == navigatedTo })
        else { return }
        select(row, as: .navigated)
    }

    private func recordSuccessfulLaunch(_ id: String) {
        library.recordLaunch(id)
        // A quick reopen can precede an asynchronous launch completion. Keep the
        // optional recent-app list current if that completion arrives while it shows.
        if panel.isVisible, preferences.showRecentApps,
           field.stringValue.allSatisfy(\.isWhitespace) { refreshMatches() }
    }

    private func buildItems(for query: String) -> [ResultItem] {
        let state = caffeine.state
        switch navigation.scope {
        case .argument: return []
        case .menu(let menu):
            return menu.search(query, matcher: matcher).map { .menuItem($0, state: state) }
        case .root: break
        }
        return SearchResults.build(for: query, corpus: corpus, matcher: matcher,
                                   frecency: library.frecency,
                                   previousResult: previousResult,
                                   recents: preferences.showRecentApps ? preferences.visibleRows : 0,
                                   webSearch: preferences.showWebSearch ? preferences.webSearchEngine : nil)
            .map { ResultItem($0, caffeine: state) }
    }

    private var cardFirst: Bool {
        items.first?.isCard == true
    }

    /// The calculator card carries its own separator and spacing.
    private func rowHeight(at row: Int) -> CGFloat {
        guard row == 0, cardFirst else { return Metrics.rowHeight }
        // With nothing under it, the card needs no separator; the list's bottom padding
        // follows it directly.
        return items.count > 1 ? Metrics.cardRowHeight : Metrics.cardHeight
    }

    /// The card sits directly under the bar with no divider; rows start after a gap.
    private var listTopInset: CGFloat { cardFirst ? 0 : Metrics.listTopPadding }

    private var viewport: ListViewport {
        ListViewport(count: items.count, leadHeight: rowHeight(at: 0),
                     rowHeight: Metrics.rowHeight, visibleRows: preferences.visibleRows)
    }

    /// Lays the list out at its final size, then resizes the glass to reveal it. The
    /// list shows whole rows only, up to the Rows Shown setting.
    private func layoutList(animated: Bool) {
        // Contents vanish at once when the list empties; only the glass animates away.
        scroll.isHidden = items.isEmpty
        divider.isHidden = items.isEmpty || cardFirst

        var target = Metrics.inputHeight
        if items.isEmpty {
            listHeight.constant = 0
        } else {
            listTop.constant = Metrics.inputHeight + listTopInset
            showRows(from: 0)
            target += listTopInset + viewport.restingHeight + Metrics.listBottomPadding
        }
        resizeGlass(to: target, animated: animated)
    }

    /// Starts the list at `first`. Rows past the resting list begin on a row boundary,
    /// so keyboard scrolling never cuts a row off.
    private func showRows(from first: Int) {
        let viewport = viewport
        listHeight.constant = viewport.height(from: first)
        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: viewport.top(of: first)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Stands down while a drag is in flight; the size is applied directly then, since an
    /// animation would lag the pointer.
    ///
    /// Clearing the query snaps back to the bar: its contents are already gone, so a
    /// shrinking empty panel only delays the next keystroke's feedback.
    private func resizeGlass(to target: CGFloat, animated: Bool) {
        let collapsing = target == Metrics.inputHeight
        guard animated, !collapsing, panel.isVisible, !isDismissing, !placement.isDragging else {
            // Cancel even when the current height already equals the target: an older
            // grow animation may still be waiting to run after a quick navigation.
            animator.cancel()
            glassHeight.constant = target
            return
        }
        guard target != glassHeight.constant else {
            // A rapid back/entry can return to this height before an older animation
            // starts moving toward a different one.
            animator.cancel()
            return
        }

        let from = glassHeight.constant
        animator.run(duration: Metrics.growDuration) { [weak self] p in
            guard let self else { return }
            self.glassHeight.constant = from + (target - from) * p
            self.panel.contentView?.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Completion and bar icon

    /// The completion pill and the bar icon both follow the selected row, and both
    /// disappear when Backspace dismisses the completion.
    private func updateChrome() {
        // Blank, not just empty: recents answer a query of spaces too, and a completion
        // pill after nothing would read as a stray " — Safari".
        guard selection != .dismissed, items.indices.contains(cursor),
              !field.stringValue.allSatisfy(\.isWhitespace) else {
            bar.clear()
            return
        }
        bar.show(items[cursor])
    }

    // MARK: - Keyboard

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveCursor(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveCursor(by: -1); return true
        case #selector(NSResponder.insertTab(_:)):
            if argument != nil { return true }
            guard items.indices.contains(cursor) else { return true }
            if let submenu = items[cursor].submenu {
                enterScope(.menu(submenu))
            } else if case .app(let match) = items[cursor], match.entry.template != nil {
                enterArgument(for: cursor)
            }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            leaveScope(); return true
        case #selector(NSResponder.insertNewline(_:)):
            if argument != nil { openArgument() } else { launch(at: cursor) }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Option-Return arrives as this, not as insertNewline.
            copyPath(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        case #selector(NSResponder.deleteBackward(_:)):
            if navigation.canGoBack, field.stringValue.isEmpty {
                leaveScope(); return true
            }
            // Spotlight's first Backspace removes only the completion; the typed text
            // stays. A selection is being deleted on purpose, so that goes through.
            guard bar.isShowingCompletion, textView.selectedRange().length == 0 else { return false }
            dismissCompletion(); return true
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):
            // Command-Delete inside a text field arrives as deleteToBeginningOfLine.
            if argument == nil { hideAppUnderCursor() }
            return true
        default:
            return false
        }
    }

    /// Wraps in both directions — standard for a short list. With the completion
    /// dismissed nothing is selected, so Down starts from the first row.
    private func moveCursor(by delta: Int) {
        guard !items.isEmpty else { return }
        let next = selection == .dismissed
            ? (delta > 0 ? 0 : items.count - 1)
            : (cursor + delta + items.count) % items.count
        select(next, as: .navigated)
    }

    /// Return still launches the top result, so the cursor goes back to it.
    private func dismissCompletion() {
        select(0, as: .dismissed)
    }

    private func select(_ row: Int, as style: Selection) {
        let previous = cursor
        cursor = row
        selection = style
        table.reloadData(forRowIndexes: IndexSet([previous, cursor]),
                         columnIndexes: IndexSet(integer: 0))
        scrollCursorIntoView()
        updateChrome()
    }

    /// Scrolls by whole rows. A trackpad scroll can leave the list between rows; the
    /// next arrow key that moves off screen lines it up again.
    private func scrollCursorIntoView() {
        guard !items.isEmpty,
              let first = viewport.firstRow(showing: cursor, offset: scroll.contentView.bounds.minY,
                                            height: listHeight.constant)
        else { return }
        showRows(from: first)
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
        case .calculation(_, let value):
            let text = Calculator.format(value)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            hide()

        case .conversion(_, let result):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result, forType: .string)
            hide()

        case .generateUUID:
            enterScope(.menu(.generateUUID))

        case .settings:
            hide()
            onOpenSettings?()

        case .caffeinate:
            enterScope(.menu(.caffeinate))

        case .menuItem(let item, _):
            if let action = item.action {
                if item.closesPanelOnAction { hide() }
                switch action {
                case .toggleCaffeinate: caffeine.toggle()
                case .generateUUID(let version):
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(UUIDGenerator.generate(version), forType: .string)
                }
            } else if let submenu = item.submenu {
                enterScope(.menu(submenu))
            }

        case .webSearch(let query, let engine):
            hide()
            guard let url = engine.url(for: query) else { return }
            NSWorkspace.shared.open(url)

        case .app(let match) where match.entry.kind == .settingsPane:
            hide()
            openSettingsPane(match.entry)

        case .app(let match) where match.entry.kind == .command:
            guard let command = SystemCommand(id: match.entry.id) else { return }
            hide()
            let id = match.entry.id
            SystemCommandRunner.run(command) { [weak self] in self?.recordSuccessfulLaunch(id) }

        case .app(let match) where match.entry.template != nil:
            // Nothing to open until the argument is typed.
            enterArgument(for: index)

        case .app(let match) where match.entry.kind == .link:
            hide()
            openLink(match.entry.url, id: match.entry.id)

        case .app(let match):
            let entry = match.entry
            let query = field.stringValue
            hide()

            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            // Fire and forget: waiting on a slow-launching app would freeze the panel.
            NSWorkspace.shared.openApplication(at: entry.url, configuration: config) { [weak self] _, error in
                let succeeded = error == nil
                Task { @MainActor in
                    guard let self else { return }
                    if succeeded {
                        self.recordSuccessfulLaunch(entry.id)
                        return
                    }
                    // The app is gone, so the whole index is suspect: rescan rather than
                    // just dropping this entry, or the stale one returns from the cache.
                    self.show()
                    // show() clears the field. Restore the query, otherwise the panel
                    // reopens blank and the failure reads as nothing having happened.
                    self.field.stringValue = query
                    self.updateMatches(for: query)
                    self.library.refresh()
                }
            }
        }
    }

    /// A folder that has since gone, or an address no app handles, beeps.
    private func openLink(_ url: URL, id: String) {
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            let succeeded = error == nil
            Task { @MainActor in
                if succeeded { self?.recordSuccessfulLaunch(id) }
                else { NSSound.beep() }
            }
        }
    }

    // MARK: - Scoped navigation

    private func enterScope(_ scope: SearchScope) {
        navigation.enter(scope, query: field.stringValue,
                         selectedID: items.indices.contains(cursor) ? items[cursor].identity : nil,
                         selection: selection)
        updateScopeChip()
        setQuery("")
        selection = .topHit
        updateMatches(for: "")
    }

    private func leaveScope() {
        guard let parent = navigation.back(behavior: preferences.backNavigationBehavior) else { return }
        updateScopeChip()
        setQuery(parent.query)
        selection = .topHit
        updateMatches(for: parent.query)
        if let row = items.firstIndex(where: { $0.identity == parent.selectedID }) {
            select(row, as: parent.selection)
        }
    }

    private func setQuery(_ query: String) {
        field.stringValue = query
        lastQuery = query
        field.currentEditor()?.selectedRange = NSRange(location: (query as NSString).length, length: 0)
    }

    private func updateScopeChip() {
        switch navigation.scope {
        case .root: bar.hideChip()
        case .menu(let menu):
            bar.showChip(title: menu.title, icon: ResultItem.symbol(menu.symbolName))
        case .argument(let link):
            let url = ResultItem.iconURL(for: link)
            bar.showChip(title: link.name, icon: url == nil ? ResultItem.linkIcon : nil, iconURL: url)
        }
    }

    private func resetNavigation() {
        navigation.reset()
        bar.hideChip()
    }

    // MARK: - Argument

    /// Swaps the query for the chip of the template link at `row`; what is typed next
    /// fills its `{query}`.
    private func enterArgument(for row: Int) {
        guard case .app(let match) = items[row] else { return }
        enterScope(.argument(match.entry))
    }

    /// The template filled with what is typed, or nil outside argument mode.
    private var argumentURL: URL? {
        guard let argument, let template = argument.template else { return nil }
        return Link.resolve(template, argument: field.stringValue)
    }

    private func openArgument() {
        guard let argument, let url = argumentURL else {
            NSSound.beep()
            return
        }
        hide()
        openLink(url, id: argument.id)
    }

    /// Opens a pane, or System Settings itself when the pane's link is refused: that is
    /// still closer to what was asked for than nothing, and a rescan would not fix it.
    private func openSettingsPane(_ entry: AppEntry) {
        guard let bundleID = entry.bundleID, let url = SettingsPaneIndex.url(for: bundleID) else { return }
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            let succeeded = error == nil
            Task { @MainActor in
                guard let self else { return }
                if succeeded {
                    self.recordSuccessfulLaunch(entry.id)
                    return
                }
                NSWorkspace.shared.openApplication(at: SettingsPaneIndex.systemSettingsApp,
                                                   configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, fallbackError in
                    guard fallbackError == nil else { return }
                    Task { @MainActor in self?.recordSuccessfulLaunch(entry.id) }
                }
            }
        }
    }

    /// The app under the cursor, or a beep when the cursor is on something that isn't
    /// an app — the alternate actions have no meaning for a calculation, Settings or a pane.
    /// Links answer too where asked: they have a path or an address to reveal or copy.
    private func appUnderCursor(allowingLinks: Bool = false) -> MatchResult? {
        guard items.indices.contains(cursor), case .app(let match) = items[cursor],
              match.entry.kind == .app || (allowingLinks && match.entry.kind == .link) else {
            NSSound.beep()
            return nil
        }
        return match
    }

    private func revealInFinder() {
        guard let match = appUnderCursor(allowingLinks: true) else { return }
        guard match.entry.url.isFileURL else {
            NSSound.beep()
            return
        }
        hide()
        NSWorkspace.shared.activateFileViewerSelecting([match.entry.url])
    }

    private func copyPath() {
        let url: URL
        if argument != nil {
            guard let filled = argumentURL else {
                NSSound.beep()
                return
            }
            url = filled
        } else {
            guard let match = appUnderCursor(allowingLinks: true) else { return }
            url = match.entry.url
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.isFileURL ? url.path : url.absoluteString, forType: .string)
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
        refreshMatches()
        // Picks up a Reset Size & Position from Settings while the panel is on screen.
        placement.reapply(screenChanged: screenChanged)
    }

    func caffeineStateDidChange() {
        guard panel.isVisible else { return }
        if case .menu = navigation.scope {
            refreshMatches()
            return
        }
        guard argument == nil, SearchResults.offersCaffeinate(field.stringValue) else { return }
        refreshMatches()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight(at: row) }

    private func rowSelection(_ row: Int) -> RowSelection {
        guard row == cursor, selection != .dismissed else { return .none }
        return selection == .navigated ? .navigated : .topHit
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if let content = items[row].cardContent {
            let card = tableView.makeView(withIdentifier: CalculationCardView.reuseID, owner: self)
                as? CalculationCardView ?? {
                    let v = CalculationCardView(frame: .zero)
                    v.identifier = CalculationCardView.reuseID
                    return v
                }()
            card.configure(expression: content.expression, value: content.result,
                           selection: rowSelection(row), showsSeparator: items.count > 1)
            return card
        }
        let view = tableView.makeView(withIdentifier: ResultRowView.reuseID, owner: self) as? ResultRowView
            ?? {
                let v = ResultRowView(frame: .zero)
                v.identifier = ResultRowView.reuseID
                return v
            }()
        view.configure(with: items[row], selection: rowSelection(row), modifiers: modifiers,
                       running: items[row].isRunning(in: runningPaths),
                       marksRunning: preferences.showRunningIndicator)
        return view
    }

    /// Hover must never move the cursor: an incidental mouse position silently
    /// changing what Enter does is a genuinely dangerous interaction in a launcher.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// Development checks live apart from the launcher behavior without widening access.
extension SpotliteController {
    func dumpFrames(_ tag: String) {
        panel.layoutIfNeeded()
        print("[\(tag)] window=\(panel.frame)")
        print("[\(tag)] host=\(panel.contentView?.frame ?? .zero)")
        print("[\(tag)] glass=\(glass.frame)  cornerRadius=\(glass.cornerRadius)")
        print("[\(tag)] content=\(glass.contentView?.frame ?? .zero)")
        print("[\(tag)] scroll=\(scroll.frame) listHeight=\(listHeight.constant) glassHeight=\(glassHeight.constant)")
        bar.dumpFrames(tag)
        if items.indices.contains(cursor),
           let card = table.view(atColumn: 0, row: cursor, makeIfNecessary: true) as? CalculationCardView {
            card.dumpFrames(tag)
        }
        if items.indices.contains(cursor),
           let row = table.view(atColumn: 0, row: cursor, makeIfNecessary: true) as? ResultRowView {
            row.dumpFrames(tag)
        }
    }

    /// Exercise scoped keyboard navigation through the real field editor and dump
    /// frames after the glass animation settles. Only invoked by the dev hook.
    func runDevMenuFrames() async {
        let savedPreferences = preferences
        defer { preferencesDidChange(savedPreferences) }
        preferences.backNavigationBehavior = .restoreQuery
        show()
        setQuery("caf")
        updateMatches(for: "caf")
        guard let row = items.firstIndex(where: { $0.identity == "caffeinate" }),
              let editor = field.currentEditor() as? NSTextView else {
            print("DEV menu: missing Caffeinate or field editor")
            exit(1)
        }
        select(row, as: .navigated)
        precondition(items[row].switchState == nil)
        try? await Task.sleep(for: .milliseconds(400))
        dumpFrames("menu-parent")
        let originalState = caffeine.state.spotlite
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        precondition(caffeine.state.spotlite == originalState)
        try? await Task.sleep(for: .milliseconds(400))
        precondition(items.count == 1 && items[0].title == "Toggle Caffeinate")
        dumpFrames("submenu")
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        precondition(caffeine.state.spotlite != originalState && items[0].switchState == caffeine.state.spotlite)
        dumpFrames("submenu-toggled")
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        precondition(caffeine.state.spotlite == originalState)
        setQuery("tgc")
        updateMatches(for: "tgc")
        precondition(items.count == 1)
        dumpFrames("submenu-filtered")
        setQuery("safari")
        updateMatches(for: "safari")
        precondition(items.isEmpty)
        dumpFrames("submenu-no-match")
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
        precondition(field.stringValue == "caf" && items[cursor].identity == "caffeinate" && selection == .navigated)
        try? await Task.sleep(for: .milliseconds(400))
        dumpFrames("submenu-backtab")
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:)))
        precondition(items.count == 1 && items[0].title == "Toggle Caffeinate" && caffeine.state.spotlite == originalState)
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
        precondition(field.stringValue == "caf" && items[cursor].identity == "caffeinate")
        print("DEV menu: Return/Tab entry, toggle, filtering, Shift+Tab and empty Backspace passed")
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        show()
        precondition(!navigation.canGoBack && argument == nil)
        print("DEV menu: Escape and reopen reset passed")
        await runDevNestedMenuChecks(editor)
        await runDevBackNavigationChecks(editor)
    }

    /// Real AppKit conversion and generation checks; preserve every clipboard representation.
    func runDevUtilityChecks() async throws {
        let pasteboard = NSPasteboard.general
        let savedClipboard = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            pasteboard.clearContents()
            let restored = savedClipboard.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
        for query in ["255 to hex", "18446744073709551615 to binary", "10 km to miles", "32 f to c"] {
            show()
            setQuery(query)
            updateMatches(for: query)
            try? await Task.sleep(for: .milliseconds(400))
            let expected = QuickConversion.evaluate(query)!
            try checkUtility(cardFirst && items.first?.cardContent?.result == expected)
            try checkUtility(table.view(atColumn: 0, row: 0, makeIfNecessary: true) is CalculationCardView)
            dumpFrames("conversion-\(query)")
            if let card = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CalculationCardView {
                try checkUtility(card.hasValidGeometry)
            }
            launch(at: 0)
            try checkUtility(pasteboard.string(forType: .string) == expected && isDismissing)
            try? await Task.sleep(for: .milliseconds(300))
        }
        for version in UUIDVersion.allCases {
            show()
            setQuery("uuid")
            updateMatches(for: "uuid")
            let rootRow = items.firstIndex { $0.identity == "generateUUID" }!
            select(rootRow, as: .navigated)
            let editor = field.currentEditor() as! NSTextView
            _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:)))
            try checkUtility(items.map(\.identity) == ["uuid.v4", "uuid.v7"])
            _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
            try checkUtility(field.stringValue == "uuid" && items[cursor].identity == "generateUUID")
            _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            setQuery(version.rawValue)
            updateMatches(for: version.rawValue)
            try checkUtility(items.count == 1 && items[0].identity == "uuid." + version.rawValue)
            try? await Task.sleep(for: .milliseconds(400))
            dumpFrames("uuid-\(version.rawValue)")
            _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            let generated = pasteboard.string(forType: .string)!
            let parsed = UUID(uuidString: generated)!
            try checkUtility(parsed.uuid.6 >> 4 == (version == .v4 ? 4 : 7))
            try checkUtility(generated == generated.lowercased() && isDismissing)
            try? await Task.sleep(for: .milliseconds(300))
        }
        try runDevSettingsChecks()
        print("DEV utilities: conversion cards, exact copying, UUID navigation and generation passed")
    }

    private func runDevSettingsChecks() throws {
        // Exercise controls without writing to the user's preferences or changing their index.
        let model = SettingsModel(preferences: Preferences(applicationDirectories: ["/Applications", "/tmp/Dev Apps"]),
                                  library: library, savePreferences: { _ in })
        let controller = SearchSettingsViewController(model: model)
        let page = controller.view
        page.setFrameSize(page.fittingSize)
        page.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let views = descendants(page)
        let locationLabel = views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "App locations:" }!
        let locationView = views.first { $0 is ApplicationDirectoriesView }!
        let labelAlignment = locationLabel.convert(locationLabel.alignmentRect(forFrame: locationLabel.bounds), to: page)
        let listFrame = locationView.convert(locationView.bounds, to: page)
        try checkUtility(abs(labelAlignment.maxY - listFrame.maxY) < 0.01)
        print("DEV settings: location label alignment=\(labelAlignment) location view=\(listFrame) top difference=\(labelAlignment.maxY - listFrame.maxY)")
        let directoryTable = views.compactMap { $0 as? NSTableView }.first!
        let buttons = views.compactMap { $0 as? NSButton }
        let remove = buttons.first { $0.title == "Remove" }!
        let reset = buttons.first { $0.title == "Reset to Default" }!
        directoryTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        remove.performClick(nil)
        try checkUtility(model.preferences.applicationDirectories == ["/tmp/Dev Apps"])
        reset.performClick(nil)
        try checkUtility(model.preferences.applicationDirectories == AppIndex.searchDirectories.map(\.path))
        while !model.preferences.applicationDirectories.isEmpty {
            directoryTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            remove.performClick(nil)
        }
        try checkUtility(directoryTable.numberOfRows == 0 && !remove.isEnabled)
        let locations = views.first { $0 is ApplicationDirectoriesView }!
        try checkUtility(page.bounds.contains(locations.convert(locations.bounds, to: page)))
        print("DEV settings: Search page=\(page.frame) locations=\(locations.convert(locations.bounds, to: page)); remove/reset/empty passed")

        let apps = library.entries.filter { $0.bundleID != nil }
        guard let first = apps.first, let second = apps.first(where: { $0.id != first.id }) else { return }
        model.preferences.aliases = [first.id: "same", second.id: " SAME "]
        let itemsController = ItemsSettingsViewController(model: model)
        itemsController.setApps([first, second])
        let itemsPage = itemsController.view
        itemsPage.setFrameSize(itemsPage.fittingSize)
        itemsPage.layoutSubtreeIfNeeded()
        let itemsTable = descendants(itemsPage).compactMap { $0 as? NSTableView }.first!
        let row = itemsTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as! SettingsRowView
        let alias = descendants(row).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "alias" }!
        try checkUtility(alias.toolTip?.contains(second.name) == true)
        alias.stringValue = "different"
        row.controlTextDidChange(Notification(name: NSText.didChangeNotification))
        try checkUtility(alias.toolTip == nil)
        row.controlTextDidEndEditing(Notification(name: NSText.didEndEditingNotification))
        try checkUtility(model.preferences.aliases[first.id] == "different")
        print("DEV settings: alias warning names, live edits and duplicate acceptance passed")
    }

    private func checkUtility(_ condition: @autoclosure () -> Bool, line: Int = #line) throws {
        guard condition() else { throw NSError(domain: "SpotliteDevChecks", code: line) }
    }

    private func runDevNestedMenuChecks(_ editor: NSTextView) async {
        let fixture = SearchMenu(id: "dev.menu", title: "Menu fixture", items: [
            SearchMenuItem(id: "dev.first", title: "First", action: .toggleCaffeinate,
                           closesPanelOnAction: false),
            SearchMenuItem(id: "dev.both", title: "Both", action: .toggleCaffeinate,
                           closesPanelOnAction: false, submenu: .caffeinate),
            SearchMenuItem(id: "dev.nested", title: "Nested", submenu: .caffeinate),
        ])
        preferences.visibleRows = max(preferences.visibleRows, fixture.items.count)
        enterScope(.menu(fixture))
        select(1, as: .navigated)
        let originalState = caffeine.state.spotlite
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        guard case .menu(let current) = navigation.scope else { preconditionFailure("Expected fixture") }
        precondition(current.id == fixture.id && caffeine.state.spotlite != originalState && cursor == 1)
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        precondition(caffeine.state.spotlite == originalState)
        var updated = preferences
        updated.backNavigationBehavior = .clearQuery
        preferencesDidChange(updated)
        precondition(cursor == 1 && selection == .navigated)
        preferences.backNavigationBehavior = .restoreQuery

        for style in [Selection.topHit, .dismissed, .navigated] {
            select(0, as: style)
            // The same dispatcher serves a mouse click and Cmd-digit on a nonselected row.
            launch(at: 2)
            _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
            precondition(cursor == 0 && selection == style && items[0].identity == "dev.first")
        }

        select(1, as: .navigated)
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:)))
        try? await Task.sleep(for: .milliseconds(400))
        let childHeight = glassHeight.constant
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
        precondition(Metrics.inputHeight + listTopInset + viewport.restingHeight
                     + Metrics.listBottomPadding > childHeight)
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:)))
        try? await Task.sleep(for: .milliseconds(400))
        precondition(items.count == 1 && items[0].identity == "caffeinate.toggle"
                     && glassHeight.constant == childHeight)
        dumpFrames("nested-rapid-roundtrip")
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertBacktab(_:)))

        let backKeys = [#selector(NSResponder.insertBacktab(_:)), #selector(NSResponder.deleteBackward(_:))]
        for behavior in BackNavigationBehavior.allCases {
            preferences.backNavigationBehavior = behavior
            for key in backKeys {
                setQuery("bo")
                updateMatches(for: "bo")
                select(0, as: .navigated)
                _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:)))
                precondition(items.count == 1 && items[0].identity == "caffeinate.toggle")
                _ = control(field, textView: editor, doCommandBy: key)
                switch behavior {
                case .restoreQuery:
                    precondition(field.stringValue == "bo" && items[cursor].identity == "dev.both"
                                 && selection == .navigated)
                case .clearQuery:
                    precondition(field.stringValue.isEmpty && items.count == fixture.items.count
                                 && cursor == 0 && selection == .topHit)
                }
            }
        }
        resetNavigation()
        setQuery("")
        updateMatches(for: "")
        precondition(ResultItem.symbol("folder") === ResultItem.symbol("folder"))
        print("DEV menu: nested navigation, direct action plus submenu, nonselected activation and rapid resize passed")
    }

    private func runDevBackNavigationChecks(_ editor: NSTextView) async {
        let backKeys = [#selector(NSResponder.insertBacktab(_:)), #selector(NSResponder.deleteBackward(_:))]
        let link = Link(name: "Docs", target: "https://example.com/?q={query}").entry!
        for behavior in BackNavigationBehavior.allCases {
            for key in backKeys {
                for isArgument in [false, true] {
                    setQuery("caf")
                    updateMatches(for: "caf")
                    let row = items.firstIndex(where: { $0.identity == "caffeinate" })!
                    select(row, as: .navigated)
                    enterScope(isArgument ? .argument(link) : .menu(.caffeinate))
                    // Change the preference after entry: the next back action must use it.
                    var updated = preferences
                    updated.backNavigationBehavior = behavior
                    updated.showRecentApps = false
                    preferencesDidChange(updated)
                    if key == #selector(NSResponder.insertBacktab(_:)) {
                        setQuery("filter")
                        updateMatches(for: "filter")
                    }
                    _ = control(field, textView: editor, doCommandBy: key)
                    precondition(!navigation.canGoBack && argument == nil)
                    switch behavior {
                    case .restoreQuery:
                        precondition(field.stringValue == "caf" && items[cursor].identity == "caffeinate"
                                     && selection == .navigated)
                    case .clearQuery:
                        precondition(field.stringValue.isEmpty && items.isEmpty && cursor == 0 && selection == .topHit)
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(400))
            dumpFrames("back-\(behavior.rawValue)")
        }
        print("DEV menu: both back-query modes and live changes passed for menus and arguments")

        let settingsModel = SettingsModel(preferences: preferences, library: library)
        let settingsController = SearchSettingsViewController(model: settingsModel)
        let page = settingsController.view
        page.setFrameSize(page.fittingSize)
        page.layoutSubtreeIfNeeded()
        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        let picker = descendants(of: page).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles == ["Restore previous query", "Clear query"] }!
        let pickerFrame = picker.convert(picker.bounds, to: page)
        precondition(picker.titleOfSelectedItem == "Clear query" && page.bounds.contains(pickerFrame))
        print("DEV settings: Search page=\(page.frame) back-query picker=\(pickerFrame)")
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

}

/// Top-left origin, so everything pinned to the top keeps its frame while the glass
/// grows or shrinks beneath it. With AppKit's usual bottom-left origin those frames all
/// change with the height, and the resize animation slides the bar's contents up.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
