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
    private let plugins: PluginManager
    private let pluginContent = PluginContentView(frame: .zero)
    private var pluginContentHeight: NSLayoutConstraint!
    private var pluginSearchTask: Task<Void, Never>?
    private var pluginActionTask: Task<Void, Never>?
    private var pluginActionReference: PluginCommandReference?
    private var pluginActionID: String?
    private var globalSearchTask: Task<Void, Never>?
    private var pluginSearchGeneration = 0
    private var pluginLoading = false
    private var pluginProblem: String?
    private var submittedPluginQuery: String?
    private var globalQuery: String?
    private var globalResults: [String: [PluginResult]] = [:]
    private var suppressPrefixOnce = false

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
    private let toasts: ToastPresenter
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
    private var hideUndo = HideUndoHistory()
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
    init(library: AppLibrary, preferences: Preferences, toasts: ToastPresenter,
         plugins: PluginManager) {
        self.library = library
        self.preferences = preferences
        self.toasts = toasts
        self.plugins = plugins
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
        plugins.onUI = { [weak self] id, method, args, context in self?.handlePluginUI(id, method: method, args: args, context: context) }
        NotificationCenter.default.addObserver(self, selector: #selector(pluginsDidChange), name: .spotlitePluginsChanged, object: plugins)
    }

    // MARK: - Construction

    private func buildUI() {
        panel.onNavigateBack = { [weak self] in
            guard let self, self.pluginLocation != nil else { return false }
            self.leaveScope(); return true
        }
        glass.cornerRadius = Metrics.cornerRadius
        glass.style = .regular
        applyResolvedAppearance()

        field.delegate = self
        field.onCommandDigit = { [weak self] index in self?.launch(at: index) }
        field.onCommandReturn = { [weak self] in self?.revealInFinder() }
        field.onCommandQ = { [weak self] in self?.quitApp() }
        field.onUndoHide = { [weak self] in self?.undoHide() ?? false }
        field.onPluginShortcut = { [weak self] event in self?.pluginShortcut(event) ?? false }

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
        // A click must not take focus from the field: Plugin actions and a template link keep
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

        pluginContent.isHidden = true
        pluginContent.onAction = { [weak self] action, values in
            guard let self, let location = self.pluginLocation, let reference = self.pluginReference(location) else { return }
            self.runPluginAction(reference, item: nil, action: action, values: values)
        }
        pluginContent.onBack = { [weak self] in self?.leaveScope() }
        for v in [scroll, divider, pluginContent] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }

        listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        pluginContentHeight = pluginContent.heightAnchor.constraint(equalToConstant: 0)
        // The list padding sits outside the scroll view rather than in its content
        // insets, so rows are clipped at the padding instead of showing slivers in it.
        listTop = scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.inputHeight)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            listTop,
            listHeight,
            pluginContent.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pluginContent.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pluginContent.topAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.inputHeight),
            pluginContentHeight,

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
        hideUndo.clear()
        isDismissing = false
        modifiers = NSEvent.modifierFlags
        applyResolvedAppearance()
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
        glass.layer?.removeAnimation(forKey: "show")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
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
        cancelPluginSearch()
        cancelPluginAction()
        globalSearchTask?.cancel(); globalSearchTask = nil
        // Taken now rather than when the fade ends: a show() during the fade must
        // already see this query.
        queryMemory.remember(navigation.rootQuery ?? field.stringValue)
        if case .calculation(_, let value) = items.first { previousResult = value }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Holds the shrunk transform until the window is ordered out; removed on show.
            let shrink = scaleAnimation(from: 1, to: Metrics.hideEndScale, duration: Metrics.hideDuration)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            glass.layer?.add(shrink, forKey: "hide")
        }
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
        hideUndo.clear()
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
        hideUndo.clear()
        let query = field.stringValue
        // Typing brings the completion back. Deleting after Backspace dismissed it does
        // not, so a run of Backspaces keeps the bare query, as in Spotlight.
        if query.count > lastQuery.count || query.isEmpty { selection = .topHit }
        lastQuery = query
        updateMatches(for: query)
    }

    func updateMatches(for query: String) {
        if case .root = navigation.scope, !suppressPrefixOnce,
           let (reference, argument) = plugins.prefixMatch(query) {
            enterPlugin(reference, query: argument)
            return
        }
        suppressPrefixOnce = false
        if let location = pluginLocation, !location.isActionMenu, (location.view.type ?? "list") == "list" {
            schedulePluginSearch(query)
        } else if case .root = navigation.scope {
            scheduleGlobalSearch(query)
        }
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
    /// index or plugin state. Preserve a row the user explicitly selected.
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
        switch navigation.scope {
        case .plugin(let location): return pluginItems(location, query: query)
        case .argument: return []
        case .menu(let menu):
            if let utility = SearchUtility(rawValue: menu.id), preferences.hiddenUtilities.contains(utility) {
                return []
            }
            return menu.search(query, matcher: matcher).map { .menuItem($0) }
        case .root: break
        }
        var built = SearchResults.build(for: query, corpus: corpus, matcher: matcher,
                                   frecency: library.frecency,
                                   previousResult: previousResult,
                                   recents: preferences.showRecentApps ? preferences.visibleRows : 0,
                                   webSearch: preferences.showWebSearch ? preferences.webSearchEngine : nil,
                                   hiddenUtilities: preferences.hiddenUtilities,
                                   pluginCommands: plugins.commandIndex)
            .map { ResultItem($0) }
        let web = built.last.flatMap { item -> ResultItem? in if case .webSearch = item { return item }; return nil }
        if web != nil { built.removeLast() }
        for reference in plugins.globalCommands {
            built.append(contentsOf: (globalResults[reference.id] ?? []).map { .pluginResult(reference, $0) })
        }
        if let web { built.append(web) }
        return built
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

    private var viewport: ListViewport {
        ListViewport(count: items.count, leadHeight: rowHeight(at: 0),
                     rowHeight: Metrics.rowHeight, visibleRows: preferences.visibleRows)
    }

    /// Lays the list out at its final size, then resizes the glass to reveal it. The
    /// list shows whole rows only, up to the Rows Shown setting.
    private func layoutList(animated: Bool) {
        if let location = pluginLocation, !location.isActionMenu, ["detail", "form"].contains(location.view.type ?? "") {
            scroll.isHidden = true; divider.isHidden = false; pluginContent.isHidden = false
            let height = max(180, min(340, Metrics.maxPanelHeight(visibleRows: preferences.visibleRows) - Metrics.inputHeight))
            pluginContentHeight.constant = height
            listHeight.constant = 0
            resizeGlass(to: Metrics.inputHeight + height, animated: animated)
            return
        }
        pluginContent.isHidden = true
        // Contents vanish at once when the list empties; only the glass animates away.
        scroll.isHidden = items.isEmpty
        divider.isHidden = items.isEmpty || cardFirst

        var target = Metrics.inputHeight
        if items.isEmpty {
            listHeight.constant = 0
        } else {
            listTop.constant = Metrics.inputHeight + Metrics.listTopPadding
            showRows(from: 0)
            target += Metrics.listTopPadding + viewport.restingHeight + Metrics.listBottomPadding
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
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !collapsing, panel.isVisible, !isDismissing, !placement.isDragging else {
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
        // pill after nothing would read as a stray " – Safari".
        guard selection != .dismissed, items.indices.contains(cursor),
              !field.stringValue.allSatisfy(\.isWhitespace) else {
            bar.clear()
            return
        }
        bar.show(items[cursor], appNameCompletion: preferences.appNameCompletion)
    }

    // MARK: - Keyboard

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveCursor(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveCursor(by: -1); return true
        case #selector(NSResponder.insertTab(_:)):
            if pluginLocation?.view.type == "form" { return pluginContent.focusForm() }
            if openPluginActions() { return true }
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
            if let location = pluginLocation, !location.isActionMenu {
                if location.view.type == "form" || location.view.type == "detail" { pluginContent.submit(); return true }
                if pluginSearchMode(location) == "enter", submittedPluginQuery != field.stringValue {
                    schedulePluginSearch(field.stringValue, force: true); renderPluginItems(); return true
                }
            }
            if argument != nil { openArgument() } else { launch(at: cursor) }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Option-Return arrives as this, not as insertNewline.
            copyPath(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if pluginLocation != nil { leaveScope() } else { hide() }; return true
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
        case .pluginCommand(let reference): enterPlugin(reference)
        case .pluginResult(let reference, let result):
            if let action = result.actions?.first { runPluginAction(reference, item: result, action: action) }
        case .pluginAction(let reference, let result, let action):
            leaveScope()
            runPluginAction(reference, item: result, action: action)
        case .pluginNotice: break
        case .calculation(_, let value):
            let text = Calculator.format(value)
            toasts.copy(text, position: preferences.toastPosition, on: panel.screen)
            hide()

        case .conversion(_, let result):
            toasts.copy(result, position: preferences.toastPosition, on: panel.screen)
            hide()

        case .generateUUID:
            enterScope(.menu(.generateUUID))

        case .settings:
            hide()
            onOpenSettings?()

        case .menuItem(let item):
            if let action = item.action {
                if item.closesPanelOnAction { hide() }
                switch action {
                case .generateUUID(let version):
                    toasts.copy(UUIDGenerator.generate(version),
                                position: preferences.toastPosition, on: panel.screen)
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

    private func enterScope(_ scope: SearchScope, fromPlugin: Bool = false) {
        if !fromPlugin { cancelPluginAction() }
        globalSearchTask?.cancel(); globalSearchTask = nil
        globalQuery = nil
        if var location = pluginLocation, location.view.type == "form", let values = try? pluginContent.formValues() {
            location.view.values = values
            navigation.replaceScope(.plugin(location))
        }
        cancelPluginSearch()
        navigation.enter(scope, query: field.stringValue,
                         selectedID: items.indices.contains(cursor) ? items[cursor].identity : nil,
                         selection: selection)
        updateScopeChip()
        panel.makeFirstResponder(field)
        setQuery("")
        selection = .topHit
        updateMatches(for: "")
    }

    private func leaveScope(cancelAction: Bool = true) {
        if cancelAction { cancelPluginAction() }
        let oldPlugin = pluginLocation?.pluginID
        cancelPluginSearch()
        guard let parent = navigation.back(behavior: preferences.backNavigationBehavior) else { return }
        if oldPlugin != pluginLocation?.pluginID, let oldPlugin {
            plugins.release(oldPlugin)
        }
        if let location = pluginLocation { pluginContent.configure(location.view) }
        updateScopeChip()
        panel.makeFirstResponder(field)
        setQuery(parent.query)
        selection = .topHit
        suppressPrefixOnce = true
        updateMatches(for: parent.query)
        if let row = items.firstIndex(where: { $0.identity == parent.selectedID }) {
            select(row, as: parent.selection)
        }
    }

    private func setQuery(_ query: String) {
        hideUndo.clear()
        field.stringValue = query
        lastQuery = query
        field.currentEditor()?.selectedRange = NSRange(location: (query as NSString).length, length: 0)
    }

    private func updateScopeChip() {
        switch navigation.scope {
        case .plugin(let location):
            bar.showChip(title: location.isActionMenu ? "Actions" : location.view.title,
                         icon: ResultItem.symbol(pluginReference(location)?.command.icon ?? "puzzlepiece.extension"))
            field.placeholderString = location.view.placeholder
        case .root: bar.hideChip()
        case .menu(let menu):
            bar.showChip(title: menu.title, icon: ResultItem.symbol(menu.symbolName))
        case .argument(let link):
            let url = ResultItem.iconURL(for: link)
            bar.showChip(title: link.name, icon: url == nil ? ResultItem.linkIcon : nil, iconURL: url)
        }
    }

    private func resetNavigation() {
        cancelPluginAction()
        cancelPluginSearch()
        if let id = pluginLocation?.pluginID { plugins.release(id) }
        globalSearchTask?.cancel(); globalSearchTask = nil; globalQuery = nil; globalResults.removeAll()
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
        toasts.copy(url.isFileURL ? url.path : url.absoluteString,
                    position: preferences.toastPosition, on: panel.screen)
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

        guard preferences.hiddenBundleIDs.insert(bundleID).inserted else { return }
        hideUndo.record(bundleID)
        Storage.save(preferences)
        onPreferencesChanged?(preferences)
        updateMatches(for: field.stringValue)
        toasts.show(.visibility(match.entry.name, hidden: true),
                    position: preferences.toastPosition, on: panel.screen)
    }

    /// Consume Command-Z only while hides remain newer than the last query edit.
    private func undoHide() -> Bool {
        guard let bundleID = hideUndo.pop(hiddenBundleIDs: preferences.hiddenBundleIDs) else { return false }
        let name = library.entries.first { $0.bundleID == bundleID }?.name ?? bundleID
        preferences.hiddenBundleIDs.remove(bundleID)
        Storage.save(preferences)
        onPreferencesChanged?(preferences)
        updateMatches(for: field.stringValue)
        if let row = items.firstIndex(where: {
            if case .app(let match) = $0 { return match.entry.bundleID == bundleID }
            return false
        }) {
            select(row, as: .navigated)
        }
        toasts.show(.visibility(name, hidden: false), position: preferences.toastPosition, on: panel.screen)
        return true
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

// Plugin navigation shares the launcher's cursor and its saved parent contexts.
extension SpotliteController {
    private var pluginLocation: PluginLocation? {
        if case .plugin(let location) = navigation.scope { return location }
        return nil
    }

    private func pluginReference(_ location: PluginLocation) -> PluginCommandReference? {
        guard let plugin = plugins.plugins.first(where: { $0.id == location.pluginID && $0.enabled }),
              let command = plugin.manifest.commands.first(where: { $0.id == location.commandID }) else { return nil }
        return PluginCommandReference(plugin: plugin, command: command, packageURL: plugins.store.packageURL(plugin))
    }

    private func enterPlugin(_ reference: PluginCommandReference, query: String = "") {
        plugins.acquire(reference.plugin.id)
        let view = PluginView(id: reference.command.id, title: reference.command.title)
        enterScope(.plugin(PluginLocation(pluginID: reference.plugin.id, commandID: reference.command.id, view: view)))
        if !query.isEmpty { setQuery(query); updateMatches(for: query) }
    }

    @objc private func pluginsDidChange(_ notification: Notification) {
        guard notification.userInfo?["commandsChanged"] as? Bool == true else { return }
        if notification.userInfo?["commandOwner"] != nil {
            // Command metadata belongs to root search. Scoped views update through
            // the plugin UI API, without another query or a temporary loading row.
            if panel.isVisible, !isDismissing, case .root = navigation.scope { renderPluginItems() }
            return
        }
        if let location = pluginLocation, pluginReference(location) == nil {
            while pluginLocation != nil { leaveScope() }
        }
        guard panel.isVisible, !isDismissing else { return }
        globalQuery = nil
        refreshMatches()
    }

    private func cancelPluginSearch() {
        pluginSearchGeneration &+= 1
        pluginSearchTask?.cancel(); pluginSearchTask = nil
        pluginLoading = false
        pluginProblem = nil
    }

    private func cancelPluginAction() {
        pluginActionID = nil; pluginActionReference = nil
        pluginActionTask?.cancel(); pluginActionTask = nil
    }

    private func pluginSearchMode(_ location: PluginLocation) -> String {
        location.view.searchMode ?? pluginReference(location)?.command.searchMode ?? "automatic"
    }

    private func schedulePluginSearch(_ query: String, force: Bool = false) {
        guard let location = pluginLocation, !location.isActionMenu,
              let reference = pluginReference(location) else { return }
        cancelPluginSearch()
        if !reference.plugin.showCommands { return }
        if pluginSearchMode(location) == "enter", !force, !query.isEmpty { return }
        submittedPluginQuery = query
        pluginLoading = true
        let generation = pluginSearchGeneration
        let delay = force ? 0 : min(max(reference.command.debounceMilliseconds ?? 150, 0), 2000)
        pluginSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                let view = try await self.plugins.search(reference, query: query, view: location.view, context: "search:\(generation)")
                try Task.checkCancellation()
                guard generation == self.pluginSearchGeneration,
                      self.pluginLocation?.pluginID == location.pluginID,
                      self.pluginLocation?.view.id == location.view.id else { return }
                self.pluginLoading = false
                self.applyPluginView(view)
            } catch is CancellationError {} catch {
                guard generation == self.pluginSearchGeneration else { return }
                self.pluginLoading = false
                self.pluginProblem = error.localizedDescription
                self.renderPluginItems()
            }
        }
    }

    private func applyPluginView(_ view: PluginView) {
        guard var location = pluginLocation else { return }
        location.view = view
        navigation.replaceScope(.plugin(location))
        pluginContent.configure(view)
        updateScopeChip()
        renderPluginItems()
    }

    private func pluginItems(_ location: PluginLocation, query: String) -> [ResultItem] {
        guard let reference = pluginReference(location) else { return [] }
        if location.isActionMenu {
            return (location.actionsFor?.actions ?? location.view.actions ?? [])
                .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
                .map { .pluginAction(reference, location.actionsFor, $0) }
        }
        var result = (location.view.items ?? []).map { ResultItem.pluginResult(reference, $0) }
        if let problem = pluginProblem {
            result.append(.pluginNotice(title: "Plugin could not complete the request", message: problem, symbol: "exclamationmark.triangle"))
        } else if pluginLoading {
            result.append(.pluginNotice(title: "Searching…", message: location.view.title, symbol: "ellipsis"))
        } else if result.isEmpty && (location.view.type ?? "list") == "list" {
            let enter = pluginSearchMode(location) == "enter" && submittedPluginQuery != query
            result.append(.pluginNotice(title: enter ? "Press Return to search" : query.isEmpty ? "Type to search" : "No results",
                                        message: location.view.title, symbol: "magnifyingglass"))
        }
        return result
    }

    private func renderPluginItems() {
        let selectedID = selection == .navigated && items.indices.contains(cursor) ? items[cursor].identity : nil
        items = buildItems(for: field.stringValue)
        if let selectedID, let index = items.firstIndex(where: { $0.identity == selectedID }) { cursor = index }
        else { cursor = 0; if selection == .navigated { selection = .topHit } }
        table.reloadData()
        layoutList(animated: true)
        if selection == .navigated { scrollCursorIntoView() }
        updateChrome()
    }

    private func scheduleGlobalSearch(_ query: String) {
        guard globalQuery != query else { return }
        globalSearchTask?.cancel(); globalSearchTask = nil
        globalQuery = query; globalResults.removeAll(keepingCapacity: true)
        let providers = plugins.globalCommands.filter { $0.command.searchMode != "enter" }
        guard !providers.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let manager = plugins
        globalSearchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            await withTaskGroup(of: (PluginCommandReference, [PluginResult]).self) { group in
                for reference in providers {
                    group.addTask {
                        do {
                            let view = try await manager.search(reference, query: query, global: true)
                            return (reference, view.items ?? [])
                        } catch { return (reference, []) }
                    }
                }
                for await (reference, results) in group {
                    guard !Task.isCancelled, let self, self.globalQuery == query,
                          case .root = self.navigation.scope else { group.cancelAll(); continue }
                    self.globalResults[reference.id] = results
                    self.renderPluginItems()
                }
            }
        }
    }

    private func openPluginActions() -> Bool {
        guard items.indices.contains(cursor) else { return false }
        switch items[cursor] {
        case .pluginCommand(let reference): enterPlugin(reference); return true
        case .pluginResult(let reference, let result):
            guard !(result.actions ?? []).isEmpty else { return true }
            plugins.acquire(reference.plugin.id)
            let view = pluginLocation?.view ?? PluginView(id: reference.command.id, title: reference.command.title)
            enterScope(.plugin(PluginLocation(pluginID: reference.plugin.id, commandID: reference.command.id,
                view: view, actionsFor: result, isActionMenu: true)))
            return true
        default: return false
        }
    }

    private func runPluginAction(_ reference: PluginCommandReference, item: PluginResult?, action: PluginAction,
                                 values: [String: PluginValue] = [:]) {
        pluginActionTask?.cancel()
        pluginActionReference = reference
        let actionID = UUID().uuidString
        pluginActionID = actionID
        plugins.acquire(reference.plugin.id)
        let view = pluginLocation?.view
        let query = field.stringValue
        pluginActionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.pluginActionID == actionID {
                    self.pluginActionReference = nil; self.pluginActionID = nil
                }
                if self.pluginLocation?.pluginID != reference.plugin.id && self.pluginActionReference?.plugin.id != reference.plugin.id {
                    self.plugins.release(reference.plugin.id)
                }
            }
            do {
                var args: [String: PluginValue] = ["command": .string(reference.command.id), "query": .string(query),
                    "action": try .encode(action), "values": .object(values)]
                if let item { args["item"] = try .encode(item) }
                if let view { args["view"] = try .encode(view) }
                _ = try await self.plugins.request(reference.plugin.id, method: "action", params: .object(args), context: "action:\(actionID)")
                try Task.checkCancellation()
                if action.close == true { self.hide() }
            } catch is CancellationError {} catch {
                guard self.pluginActionID == actionID else { return }
                self.pluginProblem = error.localizedDescription
                if self.pluginLocation != nil {
                    self.pluginContent.showError(error.localizedDescription)
                    self.renderPluginItems()
                }
                else { NSLog("Spotlite plugin action: %@", error.localizedDescription) }
            }
        }
    }

    private func handlePluginUI(_ id: String, method: String, args: PluginValue, context: String?) {
        guard !isDismissing, panel.isVisible,
              pluginLocation?.pluginID == id || pluginActionReference?.plugin.id == id else { return }
        let currentSearch = context == "search:\(pluginSearchGeneration)" && pluginLocation?.pluginID == id
        let currentAction = pluginActionID.map { context == "action:\($0)" } == true && pluginActionReference?.plugin.id == id
        let backgroundUpdate = context == nil && method == "ui.update" && pluginLocation?.pluginID == id
        guard currentSearch || currentAction || backgroundUpdate else { return }
        switch method {
        case "ui.close": hide()
        case "ui.pop": if pluginLocation != nil { leaveScope(cancelAction: false) }
        case "ui.push", "ui.replace", "ui.update":
            guard let view = try? args.decode(PluginView.self) else { return }
            if method == "ui.update" {
                guard pluginLocation?.view.id == view.id else { return }
                applyPluginView(view)
            } else if method == "ui.replace", pluginLocation != nil {
                cancelPluginSearch(); applyPluginView(view)
            } else {
                guard let reference = pluginLocation.flatMap(pluginReference) ?? pluginActionReference else { return }
                plugins.acquire(id)
                enterScope(.plugin(PluginLocation(pluginID: id, commandID: reference.command.id, view: view)), fromPlugin: true)
                pluginContent.configure(view)
            }
        default: break
        }
    }

    private func pluginShortcut(_ event: NSEvent) -> Bool {
        guard (field.currentEditor()?.selectedRange.length ?? 0) == 0,
              items.indices.contains(cursor), case .pluginResult(let reference, let item) = items[cursor] else { return false }
        let actual = event.modifierFlags.intersection([.command, .option, .control, .shift])
        for action in item.actions ?? [] {
            guard let key = action.key?.lowercased() else { continue }
            let parts = key.split(separator: "+").map(String.init)
            var expected: NSEvent.ModifierFlags = []
            if parts.contains("cmd") { expected.insert(.command) }
            if parts.contains("alt") { expected.insert(.option) }
            if parts.contains("ctrl") { expected.insert(.control) }
            if parts.contains("shift") { expected.insert(.shift) }
            if !expected.isEmpty, expected == actual, parts.last == event.charactersIgnoringModifiers?.lowercased() {
                runPluginAction(reference, item: item, action: action); return true
            }
        }
        return false
    }
}

/// Development checks live apart from the launcher behavior without widening access.
extension SpotliteController {
    private func devDescendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + devDescendants(of: $0) }
    }

    /// Check key-equivalent routing without changing preferences or the live editor.
    private func runDevUndoShortcutChecks() {
        let search = SearchField(frame: .zero)
        var pendingHide = true
        var attempts = 0
        search.onUndoHide = {
            attempts += 1
            return pendingHide
        }
        func undoEvent(_ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                             timestamp: 0, windowNumber: 0, context: nil,
                             characters: "z", charactersIgnoringModifiers: "z",
                             isARepeat: false, keyCode: 6)!
        }
        precondition(search.performKeyEquivalent(with: undoEvent(.command)))
        precondition(attempts == 1)
        pendingHide = false
        // No editor in this fixture: an unconsumed undo must fall through.
        precondition(!search.performKeyEquivalent(with: undoEvent(.command)))
        precondition(attempts == 2)
        _ = search.performKeyEquivalent(with: undoEvent([.command, .shift]))
        _ = search.performKeyEquivalent(with: undoEvent([.command, .option]))
        precondition(attempts == 2)
        print("DEV undo: Command-Z dispatch, fallback and modifier filtering passed")
    }

    /// Exercise completion visibility and real field-editor deletion without saving preferences.
    func runDevCompletionChecks() async {
        runDevUndoShortcutChecks()
        let savedPreferences = preferences
        defer { preferencesDidChange(savedPreferences) }
        show()
        let entry = AppEntry(url: URL(fileURLWithPath: "/System/Applications/Safari.app"),
                             name: "Google Chrome", bundleID: nil)
        let fixtureMatcher = Matcher()
        guard let editor = field.currentEditor() as? NSTextView else { preconditionFailure("Missing editor") }
        for mode in AppNameCompletion.allCases {
            preferences.appNameCompletion = mode
            for query in ["go", "gc", "Google Chrome"] {
                setQuery(query)
                items = fixtureMatcher.search(query, in: [entry]).map(ResultItem.app)
                precondition(items.count == 1)
                cursor = 0
                selection = .topHit
                table.reloadData()
                layoutList(animated: false)
                updateChrome()
                let visible = mode != .off && query != "Google Chrome"
                    && (query == "go" || mode == .allMatches)
                precondition(bar.isShowingCompletion == visible)
                precondition((editor.insertionPointColor == .clear) == visible)
                precondition(rowSelection(0) == .topHit)
                let consumed = control(field, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
                precondition(consumed == visible && field.stringValue == query)
                if !consumed {
                    editor.deleteBackward(nil)
                    precondition(field.stringValue == String(query.dropLast()))
                    precondition(selection == .topHit)
                }
                // Restore before dumping, so frames describe the selected mode.
                setQuery(query)
                items = fixtureMatcher.search(query, in: [entry]).map(ResultItem.app)
                cursor = 0
                table.reloadData()
                layoutList(animated: false)
                selection = .topHit
                updateChrome()
                try? await Task.sleep(for: .milliseconds(100))
                dumpFrames("completion-\(mode.rawValue)-\(query)")
            }
        }
        let settingsModel = SettingsModel(preferences: preferences, library: library)
        let settingsController = AppearanceSettingsViewController(model: settingsModel)
        let page = settingsController.view
        page.setFrameSize(page.fittingSize)
        page.layoutSubtreeIfNeeded()
        let picker = devDescendants(of: page).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles == ["Off", "Prefix matches only", "All matches"] }!
        let frame = picker.convert(picker.bounds, to: page)
        precondition(picker.titleOfSelectedItem == "All matches" && page.bounds.contains(frame))
        print("DEV settings: Appearance page=\(page.frame) completion picker=\(frame)")
        print("DEV completion: all modes, caret, Backspace, selection and settings layout passed")
    }

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
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
        defer {
            pasteboard.clearContents()
            let restored = saved.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
        do { try await runDevPluginMenuChecks() }
        catch { print("DEV menu failed: \(error)"); exit(1) }
        guard let editor = field.currentEditor() as? NSTextView else { exit(1) }
        await runDevNestedMenuChecks(editor)
        await runDevBackNavigationChecks(editor)
    }

    func runDevPluginChecks() async throws {
        guard ProcessInfo.processInfo.environment["SPOTLITE_DEV_PLUGIN_ROOT"] != nil else {
            throw PluginError.invalid("Set SPOTLITE_DEV_PLUGIN_ROOT to a temporary directory for isolated plugin checks.")
        }
        try await runDevPluginMenuChecks()
        try await plugins.waitUntilLoaded()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpotlitePluginFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); plugins.shutdown() }
        let id = "dev.spotlite.fixture"
        let manifest = #"{"id":"dev.spotlite.fixture","name":"Plugin Fixture","version":"1.0.0","apiVersion":1,"background":true,"commands":[{"id":"fixture","title":"Plugin Fixture","prefix":"fixture","global":true,"debounceMilliseconds":0}]}"#
        try Data(manifest.utf8).write(to: root.appendingPathComponent("manifest.json"))
        let source = #"""
        local s = require("spotlite")
        return {
          search = function(args)
            if args.query == "slow" then s.timers.sleep({seconds=0.35}) end
            if args.query == "metadata" then s.timers.sleep({seconds=0.15}) end
            if args.query == "crash" then os.exit(7) end
            if args.query == "hang" then while true do end end
            if args.query == "error" then error("fixture search error") end
            return {id="fixture", title="Plugin Fixture", items={
              {id=args.query == "" and "root" or args.query, title=args.query == "" and "Open Form" or args.query,
               actions={{id="form", title="Open Form"},{id="background",title="Background task"},{id="metadata",title="Update Command Icon"}}}
            }}
          end,
          action = function(args)
            if args.action.id == "metadata" then
              s.commands.update({id="fixture",icon="bolt"})
              s.timers.sleep({seconds=0.2})
            elseif args.action.id == "form" then
              local process = s.process.run({executable="/usr/bin/printf", arguments={"%s", "plugin process"}})
              assert(process.stdout == "plugin process" and process.status == 0, "process API failed")
              s.storage.set({key="process", value=process.stdout})
              s.ui.push({id="form",title="Fixture Form",type="form", fields={
                {id="name",title="Name",required=true}, {id="count",title="Count",type="number",defaultValue=2}
              }, actions={{id="submit",title="Show Details"}}})
            elseif args.action.id == "submit" then
              s.storage.set({key="submitted",value=args.values})
              s.ui.push({id="detail",title="Fixture Details",type="detail",markdown="Hello **" .. args.values.name .. "**",
                actions={{id="back",title="Back"}}})
            elseif args.action.id == "background" then
              s.background(function() s.timers.sleep({seconds=0.15}); s.storage.set({key="background",value=true}) end)
            elseif args.action.id == "resources" then
              s.power.create({id="fixture",type="PreventUserIdleDisplaySleep",name="Plugin resource fixture"})
              s.status.set({id="fixture",icon="puzzlepiece.extension",tooltip="Plugin resource fixture",menu={}})
            elseif args.action.id == "back" then s.ui.pop() end
          end
        }
        """#
        try Data(source.utf8).write(to: root.appendingPathComponent("main.lua"))
        try await plugins.install(root, development: true)
        guard let reference = plugins.commandIndex.commands.first(where: { $0.plugin.id == id }) else { throw PluginError.failed("Fixture command missing.") }
        show()
        try await plugins.setGlobalSearch(id, true)
        setQuery("fast"); updateMatches(for: "fast")
        await globalSearchTask?.value
        try checkUtility(items.contains { if case .pluginResult(let owner, let result) = $0 { return owner.plugin.id == id && result.title == "fast" }; return false })
        setQuery("slow"); updateMatches(for: "slow")
        try await Task.sleep(for: .milliseconds(180))
        enterScope(.menu(.generateUUID))
        leaveScope()
        await globalSearchTask?.value
        try checkUtility(items.contains { if case .pluginResult(let owner, let result) = $0 { return owner.plugin.id == id && result.title == "slow" }; return false })
        print("DEV plugins: Back resumes a cancelled global search for the restored query")
        try await plugins.setGlobalSearch(id, false)
        setQuery("fixture initial"); updateMatches(for: "fixture initial")
        await pluginSearchTask?.value
        try checkUtility(pluginLocation?.pluginID == id && field.stringValue == "initial")
        leaveScope()
        try checkUtility(pluginLocation == nil && field.stringValue == "fixture initial")
        print("DEV plugins: global opt-in and direct command prefixes passed")
        show(); enterPlugin(reference)
        await pluginSearchTask?.value
        setQuery("slow"); updateMatches(for: "slow")
        try await Task.sleep(for: .milliseconds(30))
        setQuery("fast"); updateMatches(for: "fast")
        await pluginSearchTask?.value
        try await Task.sleep(for: .milliseconds(400))
        try checkUtility(items.first?.title == "fast")
        print("DEV plugins: cancelled/stale searches cannot replace newer results")
        setQuery("metadata"); updateMatches(for: "metadata")
        await pluginSearchTask?.value
        try await Task.sleep(for: .milliseconds(180))
        let stableHeight = glassHeight.constant
        let metadataItem = pluginLocation!.view.items![0]
        runPluginAction(reference, item: metadataItem, action: metadataItem.actions![2])
        var maximumHeight = stableHeight
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(10))
            maximumHeight = max(maximumHeight, glassHeight.constant)
        }
        await pluginActionTask?.value
        print("DEV plugin metadata: resting=\(stableHeight) max=\(maximumHeight)")
        try checkUtility(maximumHeight <= stableHeight + 0.5 && !pluginLoading)
        setQuery(""); updateMatches(for: "")
        await pluginSearchTask?.value
        try checkUtility(openPluginActions())
        try checkUtility(pluginLocation?.isActionMenu == true && items.count == 3)
        leaveScope()
        await pluginSearchTask?.value
        launch(at: 0)
        await pluginActionTask?.value
        try checkUtility(pluginLocation?.view.type == "form")
        guard let text = devDescendants(of: pluginContent).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && !($0 is NSSecureTextField) }),
              let queryEditor = field.currentEditor() as? NSTextView else { throw PluginError.failed("Native form field or query editor missing.") }
        _ = control(field, textView: queryEditor, doCommandBy: #selector(NSResponder.insertTab(_:)))
        try checkUtility(text.currentEditor() != nil)
        let processValue = try await plugins.store.storedValue(id, key: "process")
        try checkUtility(processValue == .string("plugin process"))
        try await Task.sleep(for: .milliseconds(170))
        dumpFrames("plugin-form")
        devCapture("plugin-form", view: glass)
        let savedGeometry = preferences.panelGeometry
        var narrow = preferences
        narrow.panelGeometry = PanelGeometry(width: PanelGeometry.minWidth, verticalFraction: savedGeometry.verticalFraction)
        preferencesDidChange(narrow)
        try await Task.sleep(for: .milliseconds(170))
        dumpFrames("plugin-form-min")
        devCapture("plugin-form-min", view: glass)
        narrow.panelGeometry = savedGeometry
        preferencesDidChange(narrow)
        text.stringValue = "Spotlite"
        text.currentEditor()?.string = "Spotlite"
        pluginContent.submit()
        await pluginActionTask?.value
        try checkUtility(pluginLocation?.view.type == "detail")
        try await Task.sleep(for: .milliseconds(170))
        dumpFrames("plugin-detail")
        devCapture("plugin-detail", view: glass)
        leaveScope()
        try checkUtility(pluginLocation?.view.type == "form")
        leaveScope()
        await pluginSearchTask?.value
        try checkUtility(pluginLocation?.view.id == "fixture" && field.stringValue.isEmpty)
        setQuery("error"); updateMatches(for: "error")
        await pluginSearchTask?.value
        try checkUtility(pluginProblem?.contains("fixture search error") == true)
        setQuery("fast"); updateMatches(for: "fast")
        await pluginSearchTask?.value
        try checkUtility(items.first?.title == "fast")
        let action = pluginLocation!.view.items![0].actions![1]
        runPluginAction(reference, item: pluginLocation!.view.items![0], action: action)
        await pluginActionTask?.value
        leaveScope()
        try await Task.sleep(for: .milliseconds(300))
        let backgroundValue = try await plugins.store.storedValue(id, key: "background")
        try checkUtility(backgroundValue == .bool(true))
        try checkUtility(plugins.status(id) == "Ready")
        print("DEV plugins: native form/detail stack, process/storage APIs, errors, background lifetime and idle release passed")
        plugins.acquire(id)
        _ = try await plugins.request(id, method: "search", params: .object(["query": .string("warm")]))
        let hanging = Task { try await self.plugins.request(id, method: "search", params: .object(["query": .string("hang")])) }
        try await Task.sleep(for: .milliseconds(60))
        plugins.stop(id, force: true)
        var interrupted = false
        do { _ = try await hanging.value } catch { interrupted = true }
        try checkUtility(interrupted)
        try await plugins.restart(id)
        do { _ = try await plugins.request(id, method: "search", params: .object(["query": .string("crash")])) }
        catch {}
        try checkUtility(plugins.status(id) == "Failed")
        try await plugins.restart(id)
        plugins.release(id)
        try checkUtility(plugins.status(id) == "Ready")
        print("DEV plugins: infinite loop Force Stop, crash reporting and explicit restart passed")
        plugins.acquire(id)
        _ = try await plugins.request(id, method: "action", params: .object(["action": .object(["id": .string("resources")])]))
        try checkUtility(plugins.host.hasResources(id))
        plugins.stop(id, force: true)
        try checkUtility(!plugins.host.hasResources(id))
        try await plugins.restart(id)
        plugins.release(id)
        print("DEV plugins: Stop releases native power assertions and menu bar resources")
        for (owner, pid) in plugins.runningProcessIDs {
            print("DEV plugin helper: \(owner) pid=\(pid)")
            let metrics = Process()
            metrics.executableURL = URL(fileURLWithPath: "/bin/ps")
            metrics.arguments = ["-p", String(pid), "-o", "pid=,%cpu=,rss=,time="]
            try metrics.run(); metrics.waitUntilExit()
        }
        let page = PluginsSettingsViewController(manager: plugins)
        page.view.setFrameSize(page.view.fittingSize)
        page.view.layoutSubtreeIfNeeded()
        let settingsWindow = NSWindow(contentRect: NSRect(origin: .zero, size: page.view.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
        settingsWindow.contentView = page.view
        settingsWindow.center(); settingsWindow.orderFront(nil)
        if let table = devDescendants(of: page.view).compactMap({ $0 as? NSTableView }).first { table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false) }
        try await Task.sleep(for: .milliseconds(200))
        page.view.layoutSubtreeIfNeeded()
        devCapture("plugin-settings", view: page.view)
        print("DEV plugins: settings frame=\(page.view.frame)")
        settingsWindow.orderOut(nil)
        if ProcessInfo.processInfo.environment["SPOTLITE_DEV_GITHUB"] == "1",
           let github = plugins.commandIndex.commands.first(where: { $0.plugin.id == "com.spotlite.github" }) {
            plugins.acquire(github.plugin.id)
            let result = try await plugins.search(github, query: "repo:swiftlang/swift")
            try checkUtility(result.items?.isEmpty == false)
            plugins.release(github.plugin.id)
            print("DEV plugins: live GitHub repository search returned \(result.items?.count ?? 0) results")
        }
        try await plugins.uninstall(id, removeData: true)
        print("DEV plugins: all checks passed")
    }

    private func devCapture(_ name: String, view: NSView) {
        guard let directory = ProcessInfo.processInfo.environment["SPOTLITE_DEV_CAPTURE_DIR"] else { return }
        view.layoutSubtreeIfNeeded()
        let output = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let window = view.window {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.path]
            do {
                try capture.run(); capture.waitUntilExit()
                if capture.terminationStatus == 0 { return }
            } catch { print("DEV screenshot: \(error)") }
        }
        print("DEV screenshot: using view-cache fallback for \(name)")
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: output) }
    }

    private func runDevPluginMenuChecks() async throws {
        try await plugins.waitUntilLoaded()
        show()
        for plugin in plugins.plugins where plugin.enabled && plugin.manifest.testEntry != nil {
            guard let reference = plugins.commandIndex.commands.first(where: { $0.plugin.id == plugin.id }) else { continue }
            enterPlugin(reference)
            await pluginSearchTask?.value
            try await Task.sleep(for: .milliseconds(180))
            let height = glassHeight.constant
            var minimum = height, maximum = height, completed = false
            let check = Task {
                defer { completed = true }
                return try await self.plugins.request(plugin.id, method: "test", params: .object([:]))
            }
            for _ in 0..<1000 {
                if completed { break }
                try await Task.sleep(for: .milliseconds(10))
                minimum = min(minimum, glassHeight.constant)
                maximum = max(maximum, glassHeight.constant)
            }
            guard completed else {
                check.cancel(); plugins.stop(plugin.id, force: true)
                throw PluginError.failed("Reference plugin checks timed out.")
            }
            _ = try await check.value
            print("DEV plugin reference geometry: \(plugin.manifest.name) height=\(height) min=\(minimum) max=\(maximum)")
            try checkUtility(minimum >= height - 0.5 && maximum <= height + 0.5)
            leaveScope()
            print("DEV plugin reference: \(plugin.manifest.name) tests passed")
        }
        show()
    }

    /// Real AppKit conversion and generation checks; preserve every clipboard representation.
    func runDevUtilityChecks() async throws {
        try await plugins.waitUntilLoaded()
        let savedPreferences = preferences
        defer { preferencesDidChange(savedPreferences) }
        preferences.hiddenUtilities = []
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
            toasts.checkDevMessage("Copied to clipboard")
            try? await Task.sleep(for: .milliseconds(300))
            toasts.checkDevMessage("Copied to clipboard")
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
            toasts.checkDevMessage("Copied to clipboard")
            try? await Task.sleep(for: .milliseconds(300))
        }
        try runDevSettingsChecks()
        try runDevUtilitySettingsChecks()
        try runDevUtilityVisibilityChecks()
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
        let views = devDescendants(of: page)
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

        let apps = library.entries.filter { $0.kind == .app && $0.bundleID != nil }
        guard let first = apps.first, let second = apps.first(where: { $0.id != first.id }) else { return }
        model.preferences.aliases = [first.id: "same", second.id: " SAME "]
        let itemsController = ItemsSettingsViewController(model: model)
        itemsController.setApps([first, second])
        let itemsPage = itemsController.view
        itemsPage.setFrameSize(itemsPage.fittingSize)
        itemsPage.layoutSubtreeIfNeeded()
        let kindPicker = devDescendants(of: itemsPage).compactMap { $0 as? NSSegmentedControl }.first!
        kindPicker.selectedSegment = 1  // Alias checks apply to indexed apps, not utilities.
        kindPicker.sendAction(kindPicker.action, to: kindPicker.target)
        let itemsTable = devDescendants(of: itemsPage).compactMap { $0 as? NSTableView }.first!
        let row = itemsTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as! SettingsRowView
        let alias = devDescendants(of: row).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "alias" }!
        try checkUtility(alias.toolTip?.contains(second.name) == true)
        alias.stringValue = "different"
        row.controlTextDidChange(Notification(name: NSText.didChangeNotification))
        try checkUtility(alias.toolTip == nil)
        row.controlTextDidEndEditing(Notification(name: NSText.didEndEditingNotification))
        try checkUtility(model.preferences.aliases[first.id] == "different")
        print("DEV settings: alias warning names, live edits and duplicate acceptance passed")
    }

    private func runDevUtilitySettingsChecks() throws {
        var saves = 0
        let model = SettingsModel(preferences: Preferences(), library: library, savePreferences: { _ in saves += 1 })
        let controller = ItemsSettingsViewController(model: model)
        let app = AppEntry(url: URL(fileURLWithPath: "/Applications/Calculator.app"),
                           name: "Calculator", bundleID: "dev.calculator")
        controller.setApps([app])
        let page = controller.view
        page.setFrameSize(page.fittingSize)
        page.layoutSubtreeIfNeeded()
        let views = devDescendants(of: page)
        let table = views.compactMap { $0 as? NSTableView }.first!
        let picker = views.compactMap { $0 as? NSSegmentedControl }.first!
        let filter = views.compactMap { $0 as? NSSearchField }.first!
        func select(_ segment: Int) {
            picker.selectedSegment = segment
            picker.sendAction(picker.action, to: picker.target)
            page.layoutSubtreeIfNeeded()
        }
        try checkUtility(picker.label(forSegment: 5) == "Utility" && table.numberOfRows == SearchUtility.allCases.count + 1)
        select(5)
        try checkUtility(table.numberOfRows == SearchUtility.allCases.count)
        for index in 0..<SearchUtility.allCases.count {
            let row = table.view(atColumn: 0, row: index, makeIfNecessary: true) as! SettingsRowView
            let fields = devDescendants(of: row).compactMap { $0 as? NSTextField }
            let alias = fields.first { $0.placeholderString == "alias" }!
            let name = fields.first { $0 !== alias }!.stringValue
            let utility = SearchUtility.allCases.first { $0.name == name }!
            let checkbox = devDescendants(of: row).compactMap { $0 as? NSButton }.first!
            try checkUtility(alias.isHidden && checkbox.isEnabled && checkbox.state == .on)
            checkbox.performClick(nil)
            try checkUtility(model.preferences.hiddenUtilities.contains(utility))
            let refreshed = table.view(atColumn: 0, row: index, makeIfNecessary: true) as! SettingsRowView
            devDescendants(of: refreshed).compactMap { $0 as? NSButton }.first!.performClick(nil)
            try checkUtility(!model.preferences.hiddenUtilities.contains(utility))
            print("DEV settings: Utility row=\(row.frame) name=\(name) aliasHidden=\(alias.isHidden)")
        }
        try checkUtility(saves == SearchUtility.allCases.count * 2 && model.preferences.hiddenBundleIDs.isEmpty && model.preferences.aliases.isEmpty)
        select(0)
        try checkUtility(table.numberOfRows == SearchUtility.allCases.count + 1)
        select(1)
        try checkUtility(table.numberOfRows == 1)
        let appRow = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! SettingsRowView
        try checkUtility(!devDescendants(of: appRow).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "alias" }!.isHidden)
        select(5)
        filter.stringValue = "UUID"
        filter.sendAction(filter.action, to: filter.target)
        try checkUtility(table.numberOfRows == 1)
        filter.stringValue = "nothing matches"
        filter.sendAction(filter.action, to: filter.target)
        try checkUtility(table.numberOfRows == 0)
        try checkUtility(page.bounds.contains(picker.convert(picker.bounds, to: page)))
        try checkUtility(picker.intrinsicContentSize.width <= picker.frame.width)
        print("DEV settings: Items page=\(page.frame) tabs=\(picker.frame) naturalTabsWidth=\(picker.intrinsicContentSize.width); Utility toggles, filtering, All and row reuse passed")
    }

    private func runDevUtilityVisibilityChecks() throws {
        let savedPreferences = preferences
        defer { preferencesDidChange(savedPreferences) }
        let utility = SearchUtility.generateUUID
        preferences.hiddenUtilities = []
        show(); setQuery("uuid"); updateMatches(for: "uuid")
        let index = items.firstIndex { $0.identity == utility.rawValue }!
        launch(at: index)
        try checkUtility(!items.isEmpty)
        var hidden = preferences
        hidden.hiddenUtilities.insert(utility)
        preferencesDidChange(hidden)
        try checkUtility(items.isEmpty)
        leaveScope()
        try checkUtility(!items.contains { $0.identity == utility.rawValue })
        print("DEV utilities: hiding an open submenu removes its actions")
    }

    private func checkUtility(_ condition: @autoclosure () -> Bool, line: Int = #line) throws {
        guard condition() else { throw NSError(domain: "SpotliteDevChecks", code: line) }
    }

    private func runDevNestedMenuChecks(_ editor: NSTextView) async {
        let child = SearchMenu(id: "dev.child", title: "Child", items: [
            SearchMenuItem(id: "dev.child.action", title: "Copy UUID", action: .generateUUID(.v4))
        ])
        let fixture = SearchMenu(id: "dev.menu", title: "Menu fixture", items: [
            SearchMenuItem(id: "dev.first", title: "First", action: .generateUUID(.v4),
                           closesPanelOnAction: false),
            SearchMenuItem(id: "dev.both", title: "Both", action: .generateUUID(.v4),
                           closesPanelOnAction: false, submenu: child),
            SearchMenuItem(id: "dev.nested", title: "Nested", submenu: child),
        ])
        preferences.visibleRows = max(preferences.visibleRows, fixture.items.count)
        enterScope(.menu(fixture))
        select(1, as: .navigated)
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        guard case .menu(let current) = navigation.scope else { preconditionFailure("Expected fixture") }
        precondition(current.id == fixture.id && cursor == 1)
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
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
        precondition(Metrics.inputHeight + Metrics.listTopPadding + viewport.restingHeight
                     + Metrics.listBottomPadding > childHeight)
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:)))
        try? await Task.sleep(for: .milliseconds(400))
        precondition(items.count == 1 && items[0].identity == "dev.child.action"
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
                precondition(items.count == 1 && items[0].identity == "dev.child.action")
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
                    setQuery("uuid")
                    updateMatches(for: "uuid")
                    let row = items.firstIndex(where: { $0.identity == "generateUUID" })!
                    select(row, as: .navigated)
                    enterScope(isArgument ? .argument(link) : .menu(.generateUUID))
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
                        precondition(field.stringValue == "uuid" && items[cursor].identity == "generateUUID"
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
        let picker = devDescendants(of: page).compactMap { $0 as? NSPopUpButton }
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
