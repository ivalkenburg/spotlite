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
    private enum Selection { case topHit, navigated, dismissed }
    private var selection = Selection.topHit
    /// The template link Tab entered, and the query that found it for Backspace to bring
    /// back. While set, the field holds the link's argument and the list stays empty.
    private var argument: (link: AppEntry, query: String)?
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

    func dumpFrames(_ tag: String) {
        panel.layoutIfNeeded()
        print("[\(tag)] window=\(panel.frame)")
        print("[\(tag)] host=\(panel.contentView?.frame ?? .zero)")
        print("[\(tag)] glass=\(glass.frame)  cornerRadius=\(glass.cornerRadius)")
        print("[\(tag)] content=\(glass.contentView?.frame ?? .zero)")
        print("[\(tag)] scroll=\(scroll.frame) listHeight=\(listHeight.constant) glassHeight=\(glassHeight.constant)")
    }

    func show() {
        isDismissing = false
        modifiers = NSEvent.modifierFlags
        applyResolvedAppearance()
        caffeine.refresh()
        loadLibrary()
        runningPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        // A show during the close fade finds argument mode still on.
        dropArgument()
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
        queryMemory.remember(argument?.query ?? field.stringValue)
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
        dropArgument()
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
        // The chip already says where Return goes; there is nothing to list.
        guard argument == nil else { return [] }
        let state = caffeine.state
        return SearchResults.build(for: query, corpus: corpus, matcher: matcher,
                                   frecency: library.frecency,
                                   previousResult: previousResult,
                                   recents: preferences.showRecentApps ? preferences.visibleRows : 0,
                                   webSearch: preferences.showWebSearch ? preferences.webSearchEngine : nil)
            .map { ResultItem($0, caffeine: state) }
    }

    private var calculationFirst: Bool {
        if case .calculation = items.first { return true }
        return false
    }

    /// The calculator card carries its own separator and spacing.
    private func rowHeight(at row: Int) -> CGFloat {
        guard row == 0, calculationFirst else { return Metrics.rowHeight }
        // With nothing under it, the card needs no separator; the list's bottom padding
        // follows it directly.
        return items.count > 1 ? Metrics.cardRowHeight : Metrics.cardHeight
    }

    /// The card sits directly under the bar with no divider; rows start after a gap.
    private var listTopInset: CGFloat { calculationFirst ? 0 : Metrics.listTopPadding }

    private var viewport: ListViewport {
        ListViewport(count: items.count, leadHeight: rowHeight(at: 0),
                     rowHeight: Metrics.rowHeight, visibleRows: preferences.visibleRows)
    }

    /// Lays the list out at its final size, then resizes the glass to reveal it. The
    /// list shows whole rows only, up to the Rows Shown setting.
    private func layoutList(animated: Bool) {
        // Contents vanish at once when the list empties; only the glass animates away.
        scroll.isHidden = items.isEmpty
        divider.isHidden = items.isEmpty || calculationFirst

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
        guard target != glassHeight.constant else { return }

        let collapsing = target == Metrics.inputHeight
        guard animated, !collapsing, panel.isVisible, !isDismissing, !placement.isDragging else {
            animator.cancel()
            glassHeight.constant = target
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
            // Anything but a template link keeps the field's own Tab.
            guard items.indices.contains(cursor), case .app(let match) = items[cursor],
                  match.entry.template != nil else { return false }
            enterArgument(for: cursor); return true
        case #selector(NSResponder.insertNewline(_:)):
            if argument != nil { openArgument() } else { launch(at: cursor) }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Option-Return arrives as this, not as insertNewline.
            copyPath(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        case #selector(NSResponder.deleteBackward(_:)) where argument != nil:
            // Backspace past the start of the argument takes the chip away.
            guard field.stringValue.isEmpty else { return false }
            leaveArgument(); return true
        case #selector(NSResponder.deleteBackward(_:)):
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

        case .settings:
            hide()
            onOpenSettings?()

        case .caffeinate:
            // Stays open, unlike every other action: the switch is the only confirmation
            // that anything happened, and closing would hide it.
            caffeine.toggle()

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

    // MARK: - Argument

    /// Swaps the query for the chip of the template link at `row`; what is typed next
    /// fills its `{query}`.
    private func enterArgument(for row: Int) {
        guard case .app(let match) = items[row] else { return }
        argument = (match.entry, field.stringValue)
        bar.showChip(for: items[row])
        field.stringValue = ""
        lastQuery = ""
        updateMatches(for: "")
    }

    /// Backspace on an empty argument: the query comes back with the link selected, so
    /// a mistaken Tab costs one key.
    private func leaveArgument() {
        guard let argument else { return }
        dropArgument()
        field.stringValue = argument.query
        lastQuery = argument.query
        selection = .topHit
        field.currentEditor()?.selectedRange = NSRange(location: (argument.query as NSString).length, length: 0)
        updateMatches(for: argument.query)
        if let row = items.firstIndex(where: { $0.identity == argument.link.instanceID }), row != cursor {
            select(row, as: .navigated)
        }
    }

    private func dropArgument() {
        argument = nil
        bar.hideChip()
    }

    /// The template filled with what is typed, or nil outside argument mode.
    private var argumentURL: URL? {
        guard let argument, let template = argument.link.template else { return nil }
        return Link.resolve(template, argument: field.stringValue)
    }

    private func openArgument() {
        guard let argument, let url = argumentURL else {
            NSSound.beep()
            return
        }
        hide()
        openLink(url, id: argument.link.id)
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
        updateMatches(for: field.stringValue)
        // Picks up a Reset Size & Position from Settings while the panel is on screen.
        placement.reapply(screenChanged: screenChanged)
    }

    func caffeineStateDidChange() {
        guard panel.isVisible, SearchResults.offersCaffeinate(field.stringValue) else { return }
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
        if case .calculation(let expression, let value) = items[row] {
            let card = tableView.makeView(withIdentifier: CalculationCardView.reuseID, owner: self)
                as? CalculationCardView ?? {
                    let v = CalculationCardView(frame: .zero)
                    v.identifier = CalculationCardView.reuseID
                    return v
                }()
            card.configure(expression: expression, value: Calculator.format(value),
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

/// Top-left origin, so everything pinned to the top keeps its frame while the glass
/// grows or shrinks beneath it. With AppKit's usual bottom-left origin those frames all
/// change with the height, and the resize animation slides the bar's contents up.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
