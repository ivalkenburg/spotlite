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

    /// Shared with Settings, which can clear launch history.
    let library = AppLibrary()
    private var placement: PanelPlacement!
    private var items: [ResultItem] = []
    private var preferences: Preferences {
        // Not on every change: a drag writes the geometry here on every pointer move.
        didSet {
            guard preferences.aliases != oldValue.aliases else { return }
            aliases = AliasIndex(aliases: preferences.aliases)
        }
    }
    /// Rebuilt only when the aliases change, never per keystroke.
    private var aliases: AliasIndex
    private let caffeine: CaffeineAssertion
    private var cursor = 0

    /// Spotlight's three selection states. The top hit is marked softly; arrowing turns
    /// the selection solid accent blue; the first Backspace after a completion removes
    /// the completion and shows no selection at all, while Return still launches the
    /// top result.
    private enum Selection { case topHit, navigated, dismissed }
    private var selection = Selection.topHit
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
    /// minimum (input height + content insets) otherwise becomes a floor the panel
    /// cannot collapse below once the scroll view has held rows.
    private var listHeight: NSLayoutConstraint!
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
    var onIndexChanged: (([AppEntry]) -> Void)?

    init(caffeine: CaffeineAssertion, preferences: Preferences) {
        self.caffeine = caffeine
        self.preferences = preferences
        aliases = AliasIndex(aliases: preferences.aliases)
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
        library.onChange = { [weak self] apps in
            guard let self else { return }
            self.onIndexChanged?(apps)
            if self.panel.isVisible { self.refreshMatches() }
        }
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

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            // Zero constant: padding baked into a constraint becomes an Auto Layout
            // minimum height, which would stop the panel collapsing back to the input height.
            // The list padding lives in the scroll view's content insets instead.
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.inputHeight),
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
        library.loadIfNeeded()

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

    /// The current index, for the Settings app list. Already sorted by name.
    func indexedApps() -> [AppEntry] {
        library.loadIfNeeded()
        return library.entries
    }

    func hide() {
        guard panel.isVisible, !isDismissing else { return }
        isDismissing = true
        // Taken now rather than when the fade ends: a show() during the fade must
        // already see this query.
        queryMemory.remember(field.stringValue)
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

    private func buildItems(for query: String) -> [ResultItem] {
        let state = caffeine.state
        return SearchResults.build(for: query, entries: library.entries, matcher: matcher,
                                   aliases: aliases,
                                   hiddenBundleIDs: preferences.hiddenBundleIDs,
                                   frecency: library.frecency,
                                   previousResult: previousResult)
            .map { ResultItem($0, caffeine: state) }
    }

    private var calculationFirst: Bool {
        if case .calculation = items.first { return true }
        return false
    }

    /// The top hit is followed by a small gap, and the calculator card carries its own
    /// separator and spacing.
    private func rowHeight(at row: Int) -> CGFloat {
        guard row == 0 else { return Metrics.rowHeight }
        guard calculationFirst else { return Metrics.rowHeight + Metrics.topHitGap }
        // With nothing under it, the card needs no separator; the list's bottom padding
        // follows it directly.
        return items.count > 1 ? Metrics.cardRowHeight : Metrics.cardHeight
    }

    /// The card sits directly under the bar with no divider; rows start after a gap.
    private var listTopInset: CGFloat { calculationFirst ? 0 : Metrics.listTopPadding }

    private var listContentHeight: CGFloat {
        guard !items.isEmpty else { return 0 }
        let rows = items.indices.reduce(0) { $0 + rowHeight(at: $1) }
        return listTopInset + rows + Metrics.listBottomPadding
    }

    /// Lays the list out at its final size, then resizes the glass to reveal it. The
    /// height is capped at Spotlight's maximum, where a partly visible row shows the list
    /// scrolls.
    private func layoutList(animated: Bool) {
        let fullHeight = Metrics.inputHeight + listContentHeight
        let target = min(fullHeight, Metrics.maxPanelHeight)
        listHeight.constant = target - Metrics.inputHeight
        scroll.contentInsets = NSEdgeInsets(top: listTopInset, left: 0,
                                            bottom: Metrics.listBottomPadding, right: 0)
        // Contents vanish at once when the list empties; only the glass animates away.
        scroll.isHidden = items.isEmpty
        divider.isHidden = items.isEmpty || calculationFirst

        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -listTopInset))
        scroll.reflectScrolledClipView(scroll.contentView)
        scrollCursorIntoView()

        resizeGlass(to: target, animated: animated)
        if fullHeight > Metrics.maxPanelHeight { scroll.flashScrollers() }
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
            animator.cancel("height")
            glassHeight.constant = target
            return
        }

        let from = glassHeight.constant
        animator.run("height", duration: Metrics.growDuration, curve: .easeOut) { [weak self] p in
            guard let self else { return }
            self.glassHeight.constant = from + (target - from) * p
            self.panel.contentView?.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Completion and bar icon

    /// The completion pill and the bar icon both follow the selected row, and both
    /// disappear when Backspace dismisses the completion.
    private func updateChrome() {
        guard selection != .dismissed, items.indices.contains(cursor), !field.stringValue.isEmpty else {
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
        case #selector(NSResponder.insertNewline(_:)):
            launch(at: cursor); return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Option-Return arrives as this, not as insertNewline.
            copyPath(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        case #selector(NSResponder.deleteBackward(_:)):
            // Spotlight's first Backspace removes only the completion; the typed text
            // stays. A selection is being deleted on purpose, so that goes through.
            guard bar.isShowingCompletion, textView.selectedRange().length == 0 else { return false }
            dismissCompletion(); return true
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):
            // Command-Delete inside a text field arrives as deleteToBeginningOfLine.
            hideAppUnderCursor(); return true
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

        case .app(let match):
            let entry = match.entry
            let query = field.stringValue
            library.recordLaunch(entry.id)
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
                    self.library.refresh()
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
        view.configure(with: items[row], selection: rowSelection(row), modifiers: modifiers)
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
