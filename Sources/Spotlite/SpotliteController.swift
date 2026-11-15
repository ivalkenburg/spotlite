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
            // Links are absent: they reach the corpus through the library's entries.
            guard preferences.aliases != oldValue.aliases
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
    private let plugins = PluginHost.shared
    private var pluginScope: PluginScope? {
        if case .plugin(let scope) = navigation.scope { return scope }
        return nil
    }
    /// Rows of the plugin level on screen, with a row that stands in while they load,
    /// fail to, or turn out empty.
    private var pluginList = PluginList.empty
    private var pluginStatus: PluginItem?
    /// Whether rows have arrived for the level on screen. Until then an empty level is
    /// waiting, and shows no empty text.
    private var pluginLoaded = false
    private var pluginRun: PluginRun?
    /// Bumped whenever the rows on screen stop being wanted, so a late answer is dropped.
    private var pluginGeneration = 0
    /// Only the latest action in the same navigation session may replace its rows.
    private var pluginActionGeneration = 0
    private var pluginDebounce: DispatchWorkItem?
    /// The query a search level's rows answer, or that its run or pause is fetching.
    /// Cleared with that work and by a failure, which may be worth asking again.
    private var pluginSearchQuery: String?
    /// The generation whose stream has shown rows, so its failure keeps them.
    private var pluginStreamedGeneration = -1
    /// The row to return to once a parent level's list has loaded again.
    private var pluginPendingSelection: (id: String, style: Selection)?
    /// The action list or a confirmation while one shows.
    private var pluginOverlay: PluginOverlay?
    /// The query before the latest edit, to tell typing from deleting.
    private var lastQuery = ""
    /// The query at the last close, offered back on a quick reopen.
    private var queryMemory = QueryMemory()
    private var hideUndo = HideUndoHistory()
    /// The calculator's `ans`: the result on screen when the panel last closed.
    private var previousResult: Double?
    /// Modifiers currently held, which swap the selected row's detail for action hints.
    private var modifiers: NSEvent.ModifierFlags = []
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

    /// Called when the user picks the Settings entry.
    var onOpenSettings: (() -> Void)?
    var onConfigurePlugin: ((String) -> Void)?
    /// Called when the panel itself changes preferences, by hiding an app or being dragged.
    var onPreferencesChanged: ((Preferences) -> Void)?

    init(library: AppLibrary, caffeine: CaffeineAssertion, preferences: Preferences, toasts: ToastPresenter) {
        self.library = library
        self.caffeine = caffeine
        self.preferences = preferences
        self.toasts = toasts
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
        // Never removed: the controller lives as long as the app.
        _ = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
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
        field.onCommandReturn = { [weak self] modifiers in self?.commandReturn(modifiers) ?? false }
        field.onControlOptionReturn = { [weak self] modifiers in self?.copyPath(modifiers) }
        field.onCommandK = { [weak self] in self?.togglePluginActions() ?? false }
        field.onCommandQ = { [weak self] in self?.quitApp() }
        field.onUndoHide = { [weak self] in self?.undoHide() ?? false }

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
        // A click must not take focus from the field: submenus and template-link
        // arguments keep the panel open, and typing must keep reaching the query.
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

    /// The mode the bar and divider were last drawn for. Each show re-applies the
    /// appearance, and rebuilding the magnifier symbol alone costs about 200µs.
    private var appliedVibrancy: Vibrancy.Mode?

    /// The bar's secondary elements and the divider blend additively, as Spotlight's
    /// do; see `Vibrancy`.
    private func applyVibrancy() {
        guard let appearance = content.appearance else { return }
        let mode = Vibrancy.mode(for: appearance)
        guard mode != appliedVibrancy else { return }
        appliedVibrancy = mode
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
        caffeine.refresh()
        loadLibrary()
        runningPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL.map(AppEntry.standardizedPath) })
        // A show during the close fade can still find a submenu or argument open.
        resetNavigation()
        ResultItem.forgetHandlers()

        #if DEBUG
        let prefilledQuery = devQuery
        #else
        let prefilledQuery: String? = nil
        #endif
        let recalled = prefilledQuery == nil ? queryMemory.recall(retention: preferences.queryRetention) : nil
        field.stringValue = prefilledQuery ?? recalled ?? ""
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
        // The nonactivating panel borrows keyboard focus without deactivating the
        // current app. Ordering it out then returns input to the original window,
        // while launches and clicks elsewhere remain free to choose a destination.
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
        // A plugin command's keyword finds it until the user gives it an alias of their own.
        let aliases = plugins.defaultAliases.merging(preferences.aliases) { _, chosen in chosen }
        corpus = SearchCorpus(entries: library.entries,
                              aliases: AliasIndex(aliases: aliases),
                              hiddenBundleIDs: preferences.hiddenBundleIDs,
                              includeSettingsPanes: preferences.showSystemSettings,
                              includeCommands: preferences.showSystemCommands)
    }

    func hide() {
        guard panel.isVisible, !isDismissing else { return }
        isDismissing = true
        pluginActionGeneration &+= 1
        // A result arriving during the fade must not copy, open or notify after Escape.
        cancelPluginWork()
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

    #if DEBUG
    /// Dev captures steal key focus, which would dismiss the panel mid-measurement.
    private let pinnedOpen = ProcessInfo.processInfo.environment["SPOTLITE_DEV_PIN"] == "1"
    /// Scripted dev runs press Return on utilities; they must not train the real history.
    private let recordsUtilityUse: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return ["FRAMES", "SEQUENCE", "MENU", "COMPLETION", "UTILITIES", "PLUGINS", "REGRESSIONS", "CONFIGURATION", "ACTIONS"].allSatisfy {
            environment["SPOTLITE_DEV_\($0)"] != "1"
        }
    }()
    /// Dev hook: prefill a query so the expanded state can be inspected. Read once:
    /// `environment` builds a fresh dictionary on every access.
    private let devQuery = ProcessInfo.processInfo.environment["SPOTLITE_DEV_QUERY"]
    #endif

    @objc private func resignedKey() {
        #if DEBUG
        guard !pinnedOpen else { return }
        #endif
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
        if pluginScope?.source.isSearch == true { searchPlugin(immediately: false) }
        updateMatches(for: query)
    }

    func updateMatches(for query: String) {
        updateMatches(for: query, selecting: nil)
    }

    /// Resolve the selection before creating row views, so entering a menu or
    /// refreshing it does not render one selection and immediately replace its cells.
    private func updateMatches(for query: String, selecting preferred: (id: String, style: Selection)?) {
        items = buildItems(for: query)
        if let preferred, let row = items.firstIndex(where: { $0.identity == preferred.id }) {
            cursor = row
            selection = preferred.style
        } else {
            cursor = 0
            // A dismissed completion stays dismissed until the user types.
            if selection == .navigated { selection = .topHit }
        }
        table.reloadData()
        layoutList(animated: true)
        if cursor != 0 { scrollCursorIntoView() }
        updateChrome()
    }

    /// Rebuilds the list for an unchanged query when something beneath it changes: the
    /// index, or caffeine's state. Keep navigated rows stable, so a refresh does not
    /// change what Return will do.
    private func refreshMatches() {
        let navigatedTo = selection == .navigated && items.indices.contains(cursor)
            ? items[cursor].identity : nil
        updateMatches(for: field.stringValue, selecting: navigatedTo.map { ($0, .navigated) })
    }

    private func recordUtilityUse(_ id: String) {
        #if DEBUG
        guard recordsUtilityUse else { return }
        #endif
        library.recordLaunch(id)
    }

    private func recordSuccessfulLaunch(_ id: String) {
        library.recordLaunch(id)
        // A quick reopen can precede an asynchronous launch completion. Keep the
        // optional list of frequently used apps current if it is already showing.
        if panel.isVisible, preferences.showRecentApps,
           field.stringValue.allSatisfy(\.isWhitespace) { refreshMatches() }
    }

    private func buildItems(for query: String) -> [ResultItem] {
        let state = caffeine.state
        switch navigation.scope {
        case .argument: return []
        case .plugin(let scope):
            guard let plugin = plugins.plugin(id: scope.pluginID) else { return [] }
            let rows = pluginList.matchingIndices(query, matcher: matcher)
            // Loading or a failure first; then what the level says when it has no rows.
            if rows.isEmpty, let status = pluginStatus
                ?? scope.source.emptyText(query: query, loaded: pluginLoaded).map(Self.pluginEmptyRow) {
                return [.plugin(status, PluginRowContext(plugin: plugin, completes: false))]
            }
            // The action list's and a confirmation's rows complete nothing and show their keys.
            let keys = pluginOverlay?.keys
            return rows.map { index in
                .plugin(pluginList.items[index], PluginRowContext(
                    plugin: plugin, completes: keys == nil && !scope.source.isSearch,
                    occurrence: pluginList.occurrence(at: index),
                    key: keys.flatMap { $0.indices.contains(index) ? $0[index] : nil }))
            }
        case .menu(let menu):
            if let utility = SearchUtility(rawValue: menu.id), preferences.hiddenUtilities.contains(utility) {
                return []
            }
            let current = menu.id == SearchUtility.caffeinate.rawValue
                ? SearchMenu.caffeinate(active: state.spotlite) : menu
            return current.search(query, matcher: matcher).map { .menuItem($0, state: state) }
        case .root: break
        }
        return SearchResults.build(for: query, corpus: corpus, matcher: matcher,
                                   frecency: library.frecency,
                                   previousResult: previousResult,
                                   recents: preferences.showRecentApps ? preferences.visibleRows : 0,
                                   webSearch: preferences.webSearchEngine,
                                   webSearchMode: preferences.webSearchMode,
                                   hiddenUtilities: preferences.hiddenUtilities)
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

    private var viewport: ListViewport {
        ListViewport(count: items.count, leadHeight: rowHeight(at: 0),
                     rowHeight: Metrics.rowHeight, visibleRows: placement.visibleRows)
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
            if argument != nil { return true }
            guard items.indices.contains(cursor) else { return true }
            if let submenu = items[cursor].submenu {
                enterScope(.menu(submenu))
            } else if case .app(let match) = items[cursor], match.entry.template != nil {
                enterArgument(for: cursor)
            } else if items[cursor].pluginAction?.entersScope == true {
                launch(at: cursor)
            }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            leaveScope(); return true
        case #selector(NSResponder.insertNewline(_:)):
            // A Return still held from the row that asked must not answer the question.
            if case .confirm = pluginOverlay?.kind, NSApp.currentEvent?.isARepeat == true { return true }
            if argument != nil { openArgument(); return true }
            // Shift runs Return's action unless a plugin row binds it. Control never
            // arrives here: ⌃↩ and ⌃⇧↩ are insertLineBreak.
            let modifiers = returnModifiers
            if modifiers.isEmpty || !performPluginShortcut(modifiers) { launch(at: cursor) }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Option-Return arrives as this, not as insertNewline, and so does ⌥⇧↩.
            copyPath(returnModifiers.union(.option))
            return true
        case #selector(NSResponder.insertLineBreak(_:)):
            // Control-Return arrives as this. Only a plugin gives it a meaning.
            return performPluginShortcut(returnModifiers.union(.control))
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape closes the action list or a question before the panel.
            if !leavePluginOverlay() { hide() }
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            if navigation.canGoBack, field.stringValue.isEmpty {
                leaveScope(); return true
            }
            // Spotlight's first Backspace removes only the completion; the typed text
            // stays. A selection is being deleted on purpose, so that goes through.
            guard bar.isShowingCompletion, textView.selectedRange().length == 0 else { return false }
            dismissCompletion(); return true
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):
            // Command-Delete inside a text field arrives as deleteToBeginningOfLine. With
            // nothing to hide, in a menu or a link's argument, it edits the text as usual.
            return hideAppUnderCursor()
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
            recordUtilityUse(SearchResults.settingsHistoryID)

        case .caffeinate:
            enterScope(.menu(.caffeinate(active: caffeine.state.spotlite)))

        case .menuItem(let item, _):
            if let action = item.action {
                if item.closesPanelOnAction { hide() }
                let succeeded: Bool
                switch action {
                case .startCaffeinate(let duration):
                    succeeded = toasts.startCaffeinate(caffeine, duration: duration,
                                                       position: preferences.toastPosition, on: panel.screen)
                case .stopCaffeinate:
                    succeeded = toasts.stopCaffeinate(caffeine, position: preferences.toastPosition,
                                                      on: panel.screen)
                case .generateUUID(let version):
                    succeeded = toasts.copy(UUIDGenerator.generate(version),
                                            position: preferences.toastPosition, on: panel.screen)
                }
                if succeeded { recordUtilityUse(action.historyID) }
            } else if let submenu = item.submenu {
                enterScope(.menu(submenu))
            }

        case .webSearch(let query, let engine):
            hide()
            guard let url = engine.url(for: query) else { return }
            NSWorkspace.shared.open(url)

        case .plugin(let item, _) where pluginOverlay != nil:
            performOverlayRow(item)

        case .plugin:
            launchPlugin(at: index)

        case .app(let match) where match.entry.kind == .plugin:
            launchPlugin(at: index)

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
                    self.setQuery(query)
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
        pluginActionGeneration &+= 1
        navigation.enter(scope, query: field.stringValue,
                         selectedID: items.indices.contains(cursor) ? items[cursor].identity : nil,
                         selection: selection)
        updateScopeChip()
        setQuery("")
        selection = .topHit
        loadPluginScope()
        updateMatches(for: "")
    }

    private func leaveScope() {
        if leavePluginOverlay() { return }
        guard let parent = navigation.back(behavior: preferences.backNavigationBehavior) else { return }
        pluginActionGeneration &+= 1
        updateScopeChip()
        setQuery(parent.query)
        selection = .topHit
        loadPluginScope()
        let returning = parent.selectedID.map { (id: $0, style: parent.selection) }
        // A list that is still loading has no row to return to yet.
        if pluginRun != nil { pluginPendingSelection = returning }
        updateMatches(for: parent.query, selecting: returning)
    }

    private func setQuery(_ query: String) {
        hideUndo.clear()
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
        case .plugin(let scope):
            let icon = plugins.plugin(id: scope.pluginID).map { PluginHost.icon(scope.icon, in: $0) }
                ?? .symbol(PluginHost.fallbackSymbol)
            switch icon {
            case .symbol: bar.showChip(title: scope.title, icon: ResultItem.pluginImage(icon))
            case .file(let url): bar.showChip(title: scope.title, icon: nil, iconURL: url)
            }
        }
    }

    private func resetNavigation() {
        pluginActionGeneration &+= 1
        pluginOverlay = nil
        navigation.reset()
        bar.hideChip()
        loadPluginScope()
    }

    // MARK: - Plugins

    /// Runs one of a target's actions, asking first when it says to. `confirmed` is the
    /// answer to that question.
    private func performPlugin(_ entry: PluginActionEntry?, on target: PluginTarget, confirmed: Bool = false) {
        // A row without an action only informs.
        guard let entry else { return }
        let plugin = target.plugin
        let title = entry.levelTitle
        let icon = entry.levelIcon
        let commandID = target.commandID
        guard !plugins.needsSetup(plugin.id) else {
            hide()
            onConfigurePlugin?(plugin.id)
            return
        }
        if let confirmation = entry.confirm, !confirmed {
            enterPluginOverlay(.confirm(entry), target: target,
                               rows: confirmation.items(icon: entry.icon).map { ($0, nil) },
                               keys: ["↩", "esc"], title: confirmation.title, icon: icon)
            return
        }
        if let historyID = target.historyID { recordUtilityUse(historyID) }
        switch entry.action {
        case .open(let target):
            hide()
            guard let url = PluginAction.url(for: target) else {
                NSSound.beep()
                return
            }
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard error != nil else { return }
                Task { @MainActor in NSSound.beep() }
            }
        case .copy(let text):
            toasts.copy(text, position: preferences.toastPosition, on: panel.screen)
            hide()
        case .run(let args, let keepOpen):
            runPlugin(plugin, arguments: args, keepOpen: keepOpen, commandID: commandID)
        case .list, .search, .menu:
            guard let source = PluginSource(entry.action) else { return }
            enterScope(.plugin(PluginScope(pluginID: plugin.id, title: title, icon: icon, source: source,
                                           commandID: commandID)))
        }
    }

    // MARK: - Plugin actions

    /// What a plugin row's or command's actions run with. `historyID` is a root command's
    /// entry id; rows inside a plugin learn no history. `commandID` is the manifest
    /// command the user started from, at any depth.
    private struct PluginTarget {
        let plugin: InstalledPlugin
        let actions: PluginActionSet
        let historyID: String?
        let commandID: String
    }

    /// The action list or a confirmation, entered like a level. Its rows stand in for
    /// the level it came from, whose own are kept to come back to without running the
    /// plugin again.
    private struct PluginOverlay {
        enum Kind {
            case actions([PluginActionEntry])
            case confirm(PluginActionEntry)
        }
        let kind: Kind
        let target: PluginTarget
        let ids: [String]
        let keys: [String?]
        let list: PluginList
        let status: PluginItem?
        let loaded: Bool
        /// The level was still loading, so it asks again on return.
        let reloads: Bool
    }

    /// Return on a plugin row or command.
    private func launchPlugin(at index: Int) {
        guard let target = pluginTarget(at: index) else { return }
        performPlugin(target.actions.primary, on: target)
    }

    private func pluginTarget(at index: Int) -> PluginTarget? {
        guard pluginOverlay == nil, items.indices.contains(index) else { return nil }
        switch items[index] {
        case .plugin(let item, let context):
            return PluginTarget(plugin: context.plugin, actions: PluginActionSet(item), historyID: nil,
                                commandID: pluginScope?.commandID ?? "")
        case .app(let match) where match.entry.kind == .plugin:
            guard let (plugin, command) = plugins.command(forEntryID: match.entry.id) else { return nil }
            return PluginTarget(plugin: plugin, actions: PluginActionSet(command), historyID: match.entry.id,
                                commandID: command.id)
        default:
            return nil
        }
    }

    /// The modifiers held with the Return being handled; none outside a key event.
    private var returnModifiers: NSEvent.ModifierFlags {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return [] }
        return event.modifierFlags.intersection([.command, .option, .shift, .control])
    }

    /// Runs the selected plugin row's action for these modifiers. False when the row
    /// is not a plugin's or binds nothing to them, so Return keeps its usual meaning.
    private func performPluginShortcut(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let target = pluginTarget(at: cursor),
              let entry = target.actions.entry(for: PluginShortcut(modifiers)) else { return false }
        performPlugin(entry, on: target)
        return true
    }

    /// ⌘↩ and its chords: a plugin's binding, else Reveal in Finder for ⌘↩ alone.
    private func commandReturn(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        if argument == nil, performPluginShortcut(modifiers) { return true }
        guard modifiers == .command else { return false }
        revealInFinder()
        return true
    }

    /// ⌘K: the selected plugin row's actions, or back out of them. Other rows let the
    /// key go on as before.
    private func togglePluginActions() -> Bool {
        if case .actions = pluginOverlay?.kind { return leavePluginOverlay() }
        guard let target = pluginTarget(at: cursor) else { return false }
        let actions = target.actions
        guard !actions.entries.isEmpty else {
            NSSound.beep()
            return true
        }
        enterPluginOverlay(.actions(actions.entries), target: target, rows: actions.items.map { ($0.item, $0.key) },
                           title: actions.title, icon: actions.icon)
        return true
    }

    private func enterPluginOverlay(_ kind: PluginOverlay.Kind, target: PluginTarget,
                                    rows: [(item: PluginItem, key: String?)], keys: [String?]? = nil,
                                    title: String, icon: String?) {
        let reloads = pluginRun != nil || pluginDebounce != nil
        let saved = (list: pluginList, status: pluginStatus, loaded: pluginLoaded)
        // Nothing may replace the level's rows underneath; a reload on return catches up.
        cancelPluginWork()
        let source = PluginSource.items(rows.map(\.item), options: PluginListOptions(sorts: false))
        navigation.enter(.plugin(PluginScope(pluginID: target.plugin.id, title: title, icon: icon, source: source,
                                             commandID: target.commandID)),
                         query: field.stringValue,
                         selectedID: items.indices.contains(cursor) ? items[cursor].identity : nil,
                         selection: selection)
        pluginOverlay = PluginOverlay(kind: kind, target: target, ids: rows.map(\.item.id),
                                      keys: keys ?? rows.map(\.key), list: saved.list, status: saved.status,
                                      loaded: saved.loaded, reloads: reloads)
        updateScopeChip()
        setQuery("")
        selection = .topHit
        pluginList = PluginList(items: rows.map(\.item), sorts: false)
        pluginStatus = nil
        pluginLoaded = true
        updateMatches(for: "")
    }

    /// Back to the rows, query and selection the overlay opened over, whatever the
    /// back-navigation setting: it is a step aside, not a level the user typed into.
    @discardableResult
    private func leavePluginOverlay() -> Bool {
        guard let overlay = pluginOverlay, let parent = navigation.back(behavior: .restoreQuery) else { return false }
        pluginOverlay = nil
        updateScopeChip()
        setQuery(parent.query)
        selection = .topHit
        let returning = parent.selectedID.map { (id: $0, style: parent.selection) }
        if overlay.reloads {
            loadPluginScope()
            if pluginRun != nil { pluginPendingSelection = returning }
        } else {
            pluginList = overlay.list
            pluginStatus = overlay.status
            pluginLoaded = overlay.loaded
        }
        updateMatches(for: parent.query, selecting: returning)
        return true
    }

    /// Return or a click on the action list's or a confirmation's row. The overlay
    /// closes first, so a level the action enters goes back to the row it came from.
    private func performOverlayRow(_ item: PluginItem) {
        guard let overlay = pluginOverlay, let index = overlay.ids.firstIndex(of: item.id) else { return }
        leavePluginOverlay()
        switch overlay.kind {
        case .actions(let entries):
            performPlugin(entries[index], on: overlay.target)
        case .confirm(let entry):
            guard item.id == PluginConfirmation.confirmID else { return }
            performPlugin(entry, on: overlay.target, confirmed: true)
        }
    }

    /// Runs a plugin's action and applies what it answers: a copy, an address to open,
    /// a toast, new looks for its commands, or rows for the level that stayed open.
    private func runPlugin(_ plugin: InstalledPlugin, arguments: [String], keepOpen: Bool, commandID: String) {
        let query = field.stringValue
        let screen = panel.screen
        let scope = pluginScope
        if !keepOpen { hide() }
        pluginActionGeneration &+= 1
        let generation = pluginActionGeneration
        plugins.run(plugin, arguments: arguments, query: query, command: commandID) { [weak self] result in
            guard let self else { return }
            let position = self.preferences.toastPosition
            switch result {
            case .failure(let error):
                self.toasts.show(.pluginFailure(error), position: position, on: screen)
            case .success(let response):
                self.applyPluginResponse(response, from: plugin, on: screen)
                guard self.panel.isVisible, !self.isDismissing else { return }
                if keepOpen, self.pluginActionGeneration == generation, let scope, scope == self.pluginScope {
                    if let items = response.items, !scope.source.isSearch {
                        // The level's own list may still be loading or streaming; its rows are older.
                        self.cancelPluginWork()
                        self.showPluginItems(items)
                        return // showPluginItems already refreshes the rows and chrome.
                    } else {
                        self.loadPluginScope(keepingRows: true)
                    }
                }
                // A command's new look shows without waiting for the next keystroke.
                self.refreshMatches()
            }
        }
    }

    private func applyPluginResponse(_ response: PluginResponse, from plugin: InstalledPlugin, on screen: NSScreen?) {
        let position = preferences.toastPosition
        plugins.apply(response.update, from: plugin)
        if let text = response.copy { toasts.copy(text, position: position, on: screen) }
        if let target = response.open, let url = PluginAction.url(for: target) {
            NSWorkspace.shared.open(url)
        }
        if let toast = response.toast { toasts.show(ToastMessage(toast), position: position, on: screen) }
    }

    /// Prepares the rows of the level just entered or returned to; outside a plugin
    /// level, drops whatever one left behind.
    private func loadPluginScope(keepingRows: Bool = false) {
        cancelPluginWork()
        if !keepingRows {
            pluginList = .empty
            pluginStatus = nil
            pluginLoaded = false
        }
        guard let scope = pluginScope else { return }
        switch scope.source {
        case .items(let items, let options):
            pluginList = PluginList(items: items, sorts: options.sorts)
            pluginLoaded = true
        case .list(let args, _): fetchPluginItems(scope, arguments: args, query: "")
        case .search: searchPlugin(immediately: true)
        }
    }

    private func cancelPluginWork() {
        pluginGeneration &+= 1
        pluginDebounce?.cancel()
        pluginDebounce = nil
        pluginRun?.cancel()
        pluginRun = nil
        pluginPendingSelection = nil
        pluginSearchQuery = nil
    }

    /// Asks a search level for rows once typing pauses. One-shot: nothing repeats.
    private func searchPlugin(immediately: Bool) {
        guard let scope = pluginScope, case .search(let args, let debounce, let minimum, let options) = scope.source else { return }
        let query = PluginHost.searchQuery(field.stringValue)
        // A space typed before or after the words asks the same question: the rows on
        // screen, or the run or pause fetching them, already answer it.
        if !immediately, query == pluginSearchQuery { return }
        cancelPluginWork()
        // Search rows answer one particular query. Keeping the previous answer
        // actionable during debounce could run it when Return follows new typing.
        // An empty answer can stay until the next one: it does nothing, and dropping
        // it would flash the empty bar on every keystroke.
        pluginLoaded = pluginLoaded && pluginList.items.isEmpty && pluginStatus == nil
        pluginList = .empty
        pluginStatus = nil
        guard query.count >= minimum else {
            // The plugin's text shows below the minimum, and can stay while the first answer loads.
            pluginLoaded = options.emptyText != nil
            return
        }
        pluginSearchQuery = query
        guard !immediately, debounce > 0 else {
            fetchPluginItems(scope, arguments: args + [query], query: query)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pluginDebounce = nil
            self.fetchPluginItems(scope, arguments: args + [query], query: query)
        }
        pluginDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(debounce), execute: work)
    }

    private static let pluginLoadingDelay = DispatchTimeInterval.milliseconds(300)

    private func fetchPluginItems(_ scope: PluginScope, arguments: [String], query: String) {
        guard let plugin = plugins.plugin(id: scope.pluginID) else { return }
        guard !plugins.needsSetup(plugin.id) else {
            hide()
            onConfigurePlugin?(plugin.id)
            return
        }
        pluginGeneration &+= 1
        let generation = pluginGeneration
        pluginRun?.cancel()
        // A streamed level shows rows as lines arrive. Each delivery holds every row so
        // far; one that lands after the run finished or was replaced is dropped.
        var streamed: (@MainActor ([PluginItem]) -> Void)?
        if scope.source.options.streams {
            streamed = { [weak self] rows in
                guard let self, self.pluginGeneration == generation, self.pluginRun != nil else { return }
                self.showPluginItems(rows, streaming: true, extending: self.pluginStreamedGeneration == generation)
                self.pluginStreamedGeneration = generation
            }
        }
        pluginRun = plugins.run(plugin, arguments: arguments, query: query, command: scope.commandID,
                                action: scope.source.isSearch ? .search : .list, rows: streamed) { [weak self] result in
            guard let self, self.pluginGeneration == generation else { return }
            self.pluginRun = nil
            switch result {
            case .success(let response):
                self.applyPluginResponse(response, from: plugin, on: self.panel.screen)
                self.showPluginItems(response.items ?? [], extending: self.pluginStreamedGeneration == generation)
            case .failure(let error) where self.pluginStreamedGeneration == generation:
                self.pluginSearchQuery = nil
                // Rows a stream printed before failing stay usable; the toast says why it stopped.
                self.toasts.show(.pluginFailure(error), position: self.preferences.toastPosition, on: self.panel.screen)
                self.showPluginItems(self.pluginList.items, extending: true)
            case .failure(let error):
                self.pluginSearchQuery = nil
                self.pluginList = .empty
                self.pluginStatus = PluginItem(title: error.message, icon: "exclamationmark.triangle")
                self.refreshPluginRows()
            }
        }
        // A fast plugin answers before this fires, so its list never flashes a placeholder.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pluginLoadingDelay) { [weak self] in
            guard let self, self.pluginGeneration == generation, self.pluginRun != nil,
                  self.pluginList.items.isEmpty else { return }
            self.pluginStatus = Self.pluginLoadingRow
            self.refreshPluginRows()
        }
    }

    /// `streaming` rows are the ones so far: “Loading…” shows when typing filters them
    /// all out, and the empty text waits for the end. `extending` rows begin with
    /// the ones on screen, from the same stream, so only the new ones are prepared.
    private func showPluginItems(_ items: [PluginItem], streaming: Bool = false, extending: Bool = false) {
        let source = pluginScope?.source
        pluginList = extending ? pluginList.appending(items)
            : PluginList(items: items, filterLocally: source?.isSearch != true, sorts: source?.options.sorts ?? true)
        // Rows from anywhere else end what a stream may extend.
        if !extending { pluginStreamedGeneration = -1 }
        // Still loading: what typing filters out may yet arrive.
        pluginStatus = streaming ? Self.pluginLoadingRow : nil
        pluginLoaded = !streaming
        refreshPluginRows()
    }

    private static let pluginLoadingRow = PluginItem(title: "Loading…", icon: "ellipsis")

    /// Stands in for a level with no rows: nothing came back, or typing filtered every row out.
    private static func pluginEmptyRow(_ text: String) -> PluginItem {
        PluginItem(id: "spotlite.empty", title: text, icon: "magnifyingglass")
    }

    private func refreshPluginRows() {
        guard panel.isVisible, !isDismissing else { return }
        if let pending = pluginPendingSelection {
            updateMatches(for: field.stringValue, selecting: pending)
            // A stream may not have reached the row to return to yet.
            if pluginRun == nil || items.contains(where: { $0.identity == pending.id }) { pluginPendingSelection = nil }
        } else {
            refreshMatches()
        }
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

    /// `modifiers` are the ones held with Return, ⌥ among them.
    private func copyPath(_ modifiers: NSEvent.ModifierFlags = .option) {
        let url: URL
        // A plugin row copies what ⌥↩ is bound to: its address unless it says otherwise.
        // Only the exact chord counts, so ⌥⇧↩ never falls back to ⌥↩'s action.
        if pluginTarget(at: cursor) != nil {
            if !performPluginShortcut(modifiers) { NSSound.beep() }
            return
        }
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
    /// Shift and Control mean something only to a plugin's row.
    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let tracked: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        let previous = modifiers.intersection(tracked)
        guard flags.intersection(tracked) != previous else { return }
        modifiers = flags
        guard panel.isVisible, items.indices.contains(cursor) else { return }
        let everyRow: NSEvent.ModifierFlags = [.command, .option]
        guard flags.intersection(everyRow) != previous.intersection(everyRow)
                || items[cursor].pluginActions != nil else { return }
        table.reloadData(forRowIndexes: IndexSet(integer: cursor), columnIndexes: IndexSet(integer: 0))
    }

    /// Hides the app under the cursor. Bound to Command-Delete: the fast path, with the
    /// full list available in Settings for un-hiding.
    /// - Returns: false when the cursor is on nothing that can be hidden.
    private func hideAppUnderCursor() -> Bool {
        guard items.indices.contains(cursor), case .app(let match) = items[cursor],
              let bundleID = match.entry.bundleID else { return false }

        guard preferences.hiddenBundleIDs.insert(bundleID).inserted else { return true }
        hideUndo.record(bundleID)
        Storage.save(preferences)
        onPreferencesChanged?(preferences)
        updateMatches(for: field.stringValue)
        toasts.show(.visibility(match.entry.name, hidden: true),
                    position: preferences.toastPosition, on: panel.screen)
        return true
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
        // Picks up a Reset Size & Position from Settings while the panel is on screen.
        // Place first so the viewport uses the new display's available row count.
        placement.reapply(screenChanged: screenChanged)
        refreshMatches()
    }

    func caffeineStateDidChange() {
        guard panel.isVisible else { return }
        if case .menu = navigation.scope {
            refreshMatches()
            return
        }
        guard argument == nil, !preferences.hiddenUtilities.contains(.caffeinate),
              SearchResults.offersCaffeinate(field.stringValue) else { return }
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

#if DEBUG
/// Development checks live apart from the launcher behavior without widening access.
extension SpotliteController {
    func runDevSetupRoutingCheck(plugin: InstalledPlugin, configure: @escaping (String) -> Void) {
        let saved = preferences
        let savedHandler = onConfigurePlugin
        defer { preferences = saved; onConfigurePlugin = savedHandler }
        preferences.hiddenBundleIDs = []
        library.extras = preferences.extraEntries + plugins.entries(disabled: [])
        onConfigurePlugin = configure
        show()
        setQuery("Configuration Fixture")
        updateMatches(for: field.stringValue)
        let row = items.firstIndex { $0.identity == plugin.entries[0].instanceID }!
        precondition(items[row].hints(modifiers: [], running: false).first?.text == "Setup required")
        launch(at: row)
        precondition(isDismissing && pluginRun == nil)
    }

    /// Offline fixtures cover query replacement, response side effects and short displays.
    func runDevRegressionChecks() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "SpotliteRegressionChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        guard let fixture = plugins.plugin(id: "regression") else {
            throw NSError(domain: "SpotliteRegressionChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Set SPOTLITE_DEV_PLUGINS_DIR to Tests/Fixtures/Plugins"])
        }
        let savedPreferences = preferences
        let restoreClipboard = savedClipboard()
        defer {
            resetNavigation()
            placement.devVisibleFrame = nil
            preferencesDidChange(savedPreferences)
            toasts.dismiss()
            panel.orderOut(nil)
            restoreClipboard()
        }
        show()
        enterScope(.plugin(PluginScope(pluginID: fixture.id, title: "List", icon: nil, source: .list(args: ["list"]))))
        try await Task.sleep(for: .milliseconds(500))
        try check(NSPasteboard.general.string(forType: .string) == "list-response", "List response did not copy")
        leaveScope()
        enterScope(.plugin(PluginScope(pluginID: fixture.id, title: "Search", icon: nil,
                                      source: .search(args: ["search"], debounce: 200, minimumQuery: 1))))
        func typeQuery(_ query: String) {
            let editor = field.currentEditor() as! NSTextView
            editor.insertText(query, replacementRange: NSRange(location: 0, length: (field.stringValue as NSString).length))
        }
        typeQuery("alpha")
        try await Task.sleep(for: .milliseconds(500))
        try check(items.first?.title == "alpha", "Search fixture did not load")
        try check(NSPasteboard.general.string(forType: .string) == "response-alpha", "Search response did not copy")
        typeQuery("beta")
        try check(items.isEmpty, "Previous query's action survived during debounce")
        try await Task.sleep(for: .milliseconds(250))
        try check(items.isEmpty, "Previous query's action survived while loading")
        typeQuery("gamma")
        try await Task.sleep(for: .milliseconds(700))
        try check(items.first?.title == "gamma", "Replacement query did not load")
        try check(NSPasteboard.general.string(forType: .string) == "response-gamma", "Superseded response applied its copy")
        print("DEV regressions: list/search copies, stale actions and superseded responses passed")
        setQuery("dismissed")
        searchPlugin(immediately: true)
        updateMatches(for: field.stringValue)
        hide()
        try check(pluginRun == nil && pluginDebounce == nil, "Dismissal left plugin work running during the fade")
        try await Task.sleep(for: .milliseconds(250))
        try check(NSPasteboard.general.string(forType: .string) == "response-gamma", "Dismissed search applied a late copy")
        print("DEV regressions: dismissal cancels plugin work before the fade")
        resetNavigation()

        preferences.hiddenBundleIDs.subtract(fixture.entries.map(\.id))
        library.extras = preferences.extraEntries + plugins.entries(disabled: [])
        show()
        setQuery("Regression Open Link")
        updateMatches(for: field.stringValue)
        guard let linkRow = items.firstIndex(where: { $0.identity == "com.igorv.spotlite.plugin.regression/open" }) else {
            return try check(false, "Missing root open command")
        }
        select(linkRow, as: .navigated)
        try check(items[linkRow].hints(modifiers: .option, running: false).first?.text == "Copy Link", "Root command lacks copy hint")
        copyPath()
        try check(NSPasteboard.general.string(forType: .string) == "https://example.com/plugin", "Root command did not copy its address")
        try await Task.sleep(for: .milliseconds(200))
        show()
        let nested = PluginItem(title: "Nested link", action: .open("https://example.com/nested"))
        enterScope(.plugin(PluginScope(pluginID: fixture.id, title: "Links", icon: nil, source: .items([nested]))))
        try check(items[0].hints(modifiers: .option, running: false).first?.text == "Copy Link", "Scoped command lacks copy hint")
        copyPath()
        try check(NSPasteboard.general.string(forType: .string) == "https://example.com/nested", "Scoped command did not copy its address")
        try await Task.sleep(for: .milliseconds(200))
        print("DEV regressions: root and scoped plugin addresses share the copy action")

        show()
        let duplicateRows = [
            PluginItem(id: "duplicate", title: "Same title", action: .menu([PluginItem(title: "First", action: .copy("first"))])),
            PluginItem(id: "duplicate", title: "Same title", action: .menu([PluginItem(title: "Second", action: .copy("second"))])),
        ]
        enterScope(.plugin(PluginScope(pluginID: fixture.id, title: "Duplicates", icon: nil, source: .items(duplicateRows))))
        try check(items[0].identity != items[1].identity, "Duplicate plugin ids collided in selection identity")
        select(1, as: .navigated)
        launch(at: 1)
        leaveScope()
        try check(cursor == 1 && selection == .navigated, "Back navigation selected the first duplicate")
        launch(at: cursor)
        launch(at: 0)
        try check(NSPasteboard.general.string(forType: .string) == "second", "Restored duplicate ran the wrong action")
        try await Task.sleep(for: .milliseconds(200))
        print("DEV regressions: duplicate ids retain selection and action after back navigation")

        show()
        let actionScope = PluginScope(pluginID: fixture.id, title: "Actions", icon: nil,
            source: .items([PluginItem(title: "Run action", action: .run(args: ["keep-open", "old"], keepOpen: true))]))
        enterScope(.plugin(actionScope))
        launch(at: 0)
        leaveScope()
        enterScope(.plugin(actionScope))
        try await Task.sleep(for: .milliseconds(550))
        try check(items.first?.title == "Run action", "A late action overwrote a re-entered scope")
        runPlugin(fixture, arguments: ["keep-open", "old"], keepOpen: true, commandID: "")
        runPlugin(fixture, arguments: ["keep-open", "new"], keepOpen: true, commandID: "")
        try await Task.sleep(for: .milliseconds(550))
        try check(items.first?.title == "new", "An older action overwrote the latest action's results")
        runPlugin(fixture, arguments: ["detached-copy"], keepOpen: false, commandID: "")
        try await Task.sleep(for: .milliseconds(250))
        try check(NSPasteboard.general.string(forType: .string) == "detached-action", "Closing cancelled an explicitly selected run action")
        print("DEV regressions: action results respect navigation and invocation order while detached actions finish")

        preferences.visibleRows = 10
        for height in [400.0, 600, 640, 680, 1_130] {
            let frame = CGRect(x: 0, y: 0, width: 1_280, height: height)
            placement.devVisibleFrame = frame
            show()
            items = (0..<20).map { .plugin(PluginItem(title: "Row \($0)"), PluginRowContext(plugin: fixture, completes: false)) }
            table.reloadData()
            layoutList(animated: false)
            panel.layoutIfNeeded()
            let actual = panel.convertToScreen(glass.convert(glass.bounds, to: nil))
            try check(frame.insetBy(dx: -0.5, dy: -0.5).contains(actual), "Glass extends outside \(frame): \(actual)")
            try check(preferences.visibleRows == 10, "Fitting changed the saved row preference")
            select(items.count - 1, as: .navigated)
            try check(viewport.firstRow(showing: cursor, offset: scroll.contentView.bounds.minY,
                                        height: listHeight.constant) == nil, "Last row is unreachable")
            dumpFrames("short-screen-\(Int(height))")
        }
        print("DEV regressions: short displays fit and every row stays reachable")
    }

    /// SPOTLITE_DEV_FOCUS=1 skips hotkey registration so an installed copy can stay running.
    /// Check real AppKit focus with an external app, then a local Settings-like window.
    func runDevFocusChecks(previousApplication: NSRunningApplication?) async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "SpotliteFocusChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        guard let previousApplication, previousApplication != .current else {
            try check(false, "Focus checks need another app in front before launch")
            return
        }
        let savedPreferences = preferences
        let pasteboard = NSPasteboard.general
        let restoreClipboard = savedClipboard()
        defer {
            preferencesDidChange(savedPreferences)
            toasts.dismiss()
            panel.orderOut(nil)
            if NSApp.isActive { previousApplication.activate(options: []) }
            restoreClipboard()
        }
        preferences.hiddenUtilities = []
        preferences.queryRetention = 0

        func checkExternalFocus(_ label: String) throws {
            try check(previousApplication.isActive,
                      "\(label): search must leave the previous app active")
            try check(NSWorkspace.shared.frontmostApplication == previousApplication,
                      "\(label): frontmost app changed")
            print("DEV focus: \(label) preserved \(previousApplication.localizedName ?? "previous app")")
        }

        // Wait for application startup before establishing the external focus fixture.
        previousApplication.activate(options: [])
        try? await Task.sleep(for: .milliseconds(300))
        try checkExternalFocus("before search")
        show()
        try? await Task.sleep(for: .milliseconds(200))
        try check(panel.isKeyWindow && field.currentEditor() != nil, "Search did not take keyboard focus")
        try checkExternalFocus("search opened")
        let editor = field.currentEditor() as! NSTextView
        editor.insertText("2+2", replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(field.stringValue == "2+2", "Search did not accept typing")
        updateMatches(for: field.stringValue)
        launch(at: 0)
        try? await Task.sleep(for: .milliseconds(200))
        try check(!panel.isVisible && pasteboard.string(forType: .string) == "4", "Calculation copy did not dismiss search")
        try checkExternalFocus("calculation copied")

        show()
        setQuery("caf")
        updateMatches(for: "caf")
        launch(at: items.firstIndex { $0.identity == "caffeinate" }!)
        let wasCaffeinated = caffeine.state.spotlite
        launch(at: 0)
        try check(caffeine.state.spotlite != wasCaffeinated, "Caffeinate did not toggle")
        _ = caffeine.toggle()
        try? await Task.sleep(for: .milliseconds(200))
        try check(!panel.isVisible, "Caffeinate did not dismiss search")
        try checkExternalFocus("Caffeinate toggled")

        show()
        let escapeEditor = field.currentEditor() as! NSTextView
        _ = control(field, textView: escapeEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        try? await Task.sleep(for: .milliseconds(200))
        try check(!panel.isVisible, "Escape did not dismiss search")
        try checkExternalFocus("Escape")

        toggle()
        toggle()
        // Reopen before the fade completes: its old completion must not dismiss search.
        toggle()
        try? await Task.sleep(for: .milliseconds(200))
        try check(panel.isVisible && panel.isKeyWindow && !isDismissing, "Reopening did not cancel dismissal")
        try checkExternalFocus("reopened during dismissal")
        toggle()
        try? await Task.sleep(for: .milliseconds(200))
        try check(!panel.isVisible, "Hotkey did not dismiss search")
        try checkExternalFocus("hotkey dismissal")

        let settings = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 120),
                                styleMask: [.titled], backing: .buffered, defer: false)
        settings.title = "Spotlite focus check"
        let input = NSTextField(string: "Continue typing here")
        settings.contentView = input
        defer { settings.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
        settings.makeKeyAndOrderFront(nil)
        settings.makeFirstResponder(input)
        try? await Task.sleep(for: .milliseconds(200))
        let previousResponder = settings.firstResponder
        show()
        hide()
        try? await Task.sleep(for: .milliseconds(200))
        try check(settings.isKeyWindow && settings.firstResponder === previousResponder,
                  "Previous local window or responder did not regain focus")
        print("DEV focus: returned to the previous local window and responder")

        show()
        hide()
        settings.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(200))
        try check(settings.isKeyWindow && !panel.isVisible, "Destination lost focus during dismissal")
        print("DEV focus: a destination selected during dismissal kept focus")

        show()
        settings.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(200))
        try check(settings.isKeyWindow && !panel.isVisible, "Selecting another window did not dismiss search")
        print("DEV focus: switching to another local window dismissed search")

        show()
        previousApplication.activate(options: [])
        try? await Task.sleep(for: .milliseconds(300))
        try check(!panel.isVisible, "Switching apps did not dismiss search")
        try checkExternalFocus("switched to another app")
        print("DEV focus: all checks passed")
    }

    /// Snapshots every clipboard representation; the returned closure puts them back.
    private func savedClipboard() -> () -> Void {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        return {
            pasteboard.clearContents()
            let restored = saved.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
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
        let settingsController = SearchSettingsViewController(model: settingsModel)
        let page = settingsController.view
        page.setFrameSize(page.fittingSize)
        page.layoutSubtreeIfNeeded()
        let picker = DevViews.descendants(page).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles == ["Off", "Prefix matches only", "All matches"] }!
        let frame = picker.convert(picker.bounds, to: page)
        precondition(picker.titleOfSelectedItem == "All matches" && page.bounds.contains(frame))
        print("DEV settings: Search page=\(page.frame) completion picker=\(frame)")
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
        let savedPreferences = preferences
        let savedConfirmations = toasts.showConfirmationMessages
        defer {
            caffeine.stop()
            preferencesDidChange(savedPreferences)
            toasts.showConfirmationMessages = savedConfirmations
        }
        toasts.showConfirmationMessages = true
        preferences.backNavigationBehavior = .restoreQuery
        preferences.hiddenUtilities.remove(.caffeinate)
        caffeine.stop()
        show()
        setQuery("caf")
        updateMatches(for: "caf")
        guard let row = items.firstIndex(where: { $0.identity == "caffeinate" }),
              var editor = field.currentEditor() as? NSTextView else {
            preconditionFailure("Missing Caffeinate or field editor")
        }
        select(row, as: .navigated)
        precondition(items[row].hints(modifiers: [], running: false) == [ResultItem.Hint(text: "Actions", key: "⇥")])
        try? await Task.sleep(for: .milliseconds(400))
        dumpFrames("menu-parent")
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        precondition(!caffeine.state.spotlite && items.count == 5 && cursor == 0 && items[0].identity == "caffeinate.0",
                     "Inactive Caffeinate: active=\(caffeine.state.spotlite), cursor=\(cursor), items=\(items.map(\.identity))")
        for state in [CaffeineState(), CaffeineState(external: true),
                      CaffeineState(session: CaffeineSession(duration: .oneHour), external: true)] {
            for item in SearchMenu.caffeinate(active: state.spotlite).items {
                precondition(ResultItem.menuItem(item, state: state).hints(modifiers: [], running: false).isEmpty)
            }
        }
        try? await Task.sleep(for: .milliseconds(400))
        dumpFrames("submenu-durations")
        try? await SettingsForm.captureWindow(panel, name: "caffeinate-durations")
        for duration in CaffeineDuration.allCases {
            let index = items.firstIndex { $0.identity == "caffeinate.\(duration.rawValue)" }!
            select(index, as: .navigated)
            let before = Date()
            if duration == .fifteenMinutes {
                _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            } else {
                launch(at: index)
            }
            precondition(caffeine.state.spotlite && isDismissing)
            if duration == .untilTurnedOff {
                precondition(caffeine.state.session?.deadline == nil)
            } else {
                let remaining = caffeine.state.session!.deadline!.timeIntervalSince(before)
                precondition(abs(remaining - Double(duration.rawValue)) < 1)
            }
            try? await Task.sleep(for: .milliseconds(300))
            precondition(!panel.isVisible && !navigation.canGoBack)
            toasts.checkDevMessage("Caffeinate enabled")

            show()
            setQuery("caf")
            updateMatches(for: "caf")
            select(items.firstIndex { $0.identity == "caffeinate" }!, as: .navigated)
            editor = field.currentEditor() as! NSTextView
            _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:)))
            precondition(items.count == 6 && items.first?.identity == "caffeinate.stop"
                         && items[1].identity == "caffeinate.0" && !isDismissing)
            precondition(cursor == 0 && selection == .topHit)
            precondition(items.allSatisfy { $0.hints(modifiers: [], running: false).isEmpty })
            caffeineStateDidChange()
            precondition(cursor == 0 && selection == .topHit)
            try? await Task.sleep(for: .milliseconds(400))
            dumpFrames("submenu-active-\(duration.rawValue)")
            if duration == .fifteenMinutes || duration == .untilTurnedOff {
                try? await SettingsForm.captureWindow(panel, name: "caffeinate-active-\(duration.rawValue)")
            }
        }
        let savedRows = preferences.visibleRows
        preferences.visibleRows = 4
        leaveScope()
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        precondition(items[cursor].identity == "caffeinate.stop")
        try? await Task.sleep(for: .milliseconds(400))
        precondition(cursor == 0 && scroll.contentView.bounds.minY == 0)
        precondition(viewport.firstRow(showing: cursor, offset: scroll.contentView.bounds.minY,
                                      height: listHeight.constant) == nil)
        precondition(DevViews.descendants(table).allSatisfy { !($0 is NSSwitch) })
        dumpFrames("submenu-active-four-rows")
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        preferences.visibleRows = savedRows
        precondition(!caffeine.state.spotlite && isDismissing)
        try? await Task.sleep(for: .milliseconds(300))
        toasts.checkDevMessage(ToastMessage.caffeine(succeeded: true, state: caffeine.state).text)
        show()
        setQuery("caf")
        updateMatches(for: "caf")
        select(items.firstIndex { $0.identity == "caffeinate" }!, as: .navigated)
        editor = field.currentEditor() as! NSTextView
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:)))
        setQuery("30")
        updateMatches(for: "30")
        precondition(items.count == 1 && items[0].identity == "caffeinate.1800")
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
        precondition(items.count == 5 && !caffeine.state.spotlite)
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
        precondition(field.stringValue == "caf" && items[cursor].identity == "caffeinate")
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        show()
        precondition(!navigation.canGoBack && argument == nil)
        print("DEV menu: duration order, plain rows, Turn Off first/default, four-row layout, replacement, filtering and navigation passed")
        await runDevNestedMenuChecks(editor)
        await runDevBackNavigationChecks(editor)
    }

    /// Real AppKit conversion and generation checks; preserve every clipboard representation.
    func runDevUtilityChecks() async throws {
        let savedPreferences = preferences
        let savedConfirmations = toasts.showConfirmationMessages
        toasts.showConfirmationMessages = true
        defer {
            preferencesDidChange(savedPreferences)
            toasts.showConfirmationMessages = savedConfirmations
        }
        preferences.hiddenUtilities = []
        let pasteboard = NSPasteboard.general
        let restoreClipboard = savedClipboard()
        defer { restoreClipboard() }
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
        try await runDevSettingsChecks()
        try runDevUtilitySettingsChecks()
        try runDevUtilityVisibilityChecks()
        print("DEV utilities: conversion cards, exact copying, UUID navigation and generation passed")
    }

    private func runDevSettingsChecks() async throws {
        // Exercise controls without writing to the user's preferences or changing their index.
        let model = SettingsModel(preferences: Preferences(applicationDirectories: ["/Applications", "/tmp/Dev Apps"]),
                                  library: library, savePreferences: { _ in })
        let controller = SearchSettingsViewController(model: model)
        let page = controller.view
        page.setFrameSize(page.fittingSize)
        page.layoutSubtreeIfNeeded()
        let views = DevViews.descendants(page)
        let webMode = views.compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles == WebSearchMode.allCases.map(\.title) }!
        let engine = views.compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles == WebSearchEngine.allCases.map(\.name) }!
        try checkUtility(webMode.titleOfSelectedItem == "Only when no local results")
        for (index, mode) in WebSearchMode.allCases.enumerated() {
            webMode.selectItem(at: index)
            webMode.sendAction(webMode.action, to: webMode.target)
            try checkUtility(model.preferences.webSearchMode == mode && engine.isEnabled == (mode != .off))
        }
        let completion = views.compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles == ["Off", "Prefix matches only", "All matches"] }!
        completion.selectItem(at: 1)
        completion.sendAction(completion.action, to: completion.target)
        try checkUtility(model.preferences.appNameCompletion == .prefixOnly)
        try checkUtility(views.compactMap { $0 as? NSButton }.contains { $0.title == "Show frequently used apps" })
        for control in [webMode, engine, completion] {
            try checkUtility(page.bounds.contains(control.convert(control.bounds, to: page)))
        }
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
        reset.performClick(nil)
        webMode.selectItem(at: 1)
        webMode.sendAction(webMode.action, to: webMode.target)
        try await SettingsForm.capture(page, name: "search")

        let apps = library.entries.filter { $0.kind == .app && $0.bundleID != nil }
        guard let first = apps.first, let second = apps.first(where: { $0.id != first.id }) else { return }
        model.preferences.aliases = [first.id: "same", second.id: " SAME "]
        let itemsController = ItemsSettingsViewController(model: model)
        itemsController.setApps([first, second])
        let itemsPage = itemsController.view
        itemsPage.setFrameSize(itemsPage.fittingSize)
        itemsPage.layoutSubtreeIfNeeded()
        let kindPicker = DevViews.descendants(itemsPage).compactMap { $0 as? NSSegmentedControl }.first!
        kindPicker.selectedSegment = 1  // Alias checks apply to indexed apps, not utilities.
        kindPicker.sendAction(kindPicker.action, to: kindPicker.target)
        let itemsTable = DevViews.descendants(itemsPage).compactMap { $0 as? NSTableView }.first!
        let row = itemsTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as! SettingsRowView
        let alias = DevViews.descendants(row).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "alias" }!
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
        let views = DevViews.descendants(page)
        let table = views.compactMap { $0 as? NSTableView }.first!
        let picker = views.compactMap { $0 as? NSSegmentedControl }.first!
        let filter = views.compactMap { $0 as? NSSearchField }.first!
        func select(_ segment: Int) {
            picker.selectedSegment = segment
            picker.sendAction(picker.action, to: picker.target)
            page.layoutSubtreeIfNeeded()
        }
        try checkUtility(picker.label(forSegment: 5) == "Utility" && table.numberOfRows == 5)
        select(5)
        try checkUtility(table.numberOfRows == 4)
        for index in 0..<4 {
            let row = table.view(atColumn: 0, row: index, makeIfNecessary: true) as! SettingsRowView
            let fields = DevViews.descendants(row).compactMap { $0 as? NSTextField }
            let alias = fields.first { $0.placeholderString == "alias" }!
            let name = fields.first { $0 !== alias }!.stringValue
            let utility = SearchUtility.allCases.first { $0.name == name }!
            let checkbox = DevViews.descendants(row).compactMap { $0 as? NSButton }.first!
            try checkUtility(alias.isHidden && checkbox.isEnabled && checkbox.state == .on)
            checkbox.performClick(nil)
            try checkUtility(model.preferences.hiddenUtilities.contains(utility))
            let refreshed = table.view(atColumn: 0, row: index, makeIfNecessary: true) as! SettingsRowView
            DevViews.descendants(refreshed).compactMap { $0 as? NSButton }.first!.performClick(nil)
            try checkUtility(!model.preferences.hiddenUtilities.contains(utility))
            print("DEV settings: Utility row=\(row.frame) name=\(name) aliasHidden=\(alias.isHidden)")
        }
        try checkUtility(saves == 8 && model.preferences.hiddenBundleIDs.isEmpty && model.preferences.aliases.isEmpty)
        select(0)
        try checkUtility(table.numberOfRows == 5)
        select(1)
        try checkUtility(table.numberOfRows == 1)
        let appRow = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! SettingsRowView
        try checkUtility(!DevViews.descendants(appRow).compactMap { $0 as? NSTextField }
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
        let wasActive = caffeine.state.spotlite
        defer {
            if caffeine.state.spotlite != wasActive { caffeine.toggle() }
            preferencesDidChange(savedPreferences)
        }
        for utility in [SearchUtility.caffeinate, .generateUUID] {
            preferences.hiddenUtilities = []
            show()
            let query = utility == .caffeinate ? "caf" : "uuid"
            setQuery(query)
            updateMatches(for: query)
            let index = items.firstIndex { $0.identity == utility.rawValue }!
            launch(at: index)
            try checkUtility(!items.isEmpty)
            if utility == .caffeinate && !caffeine.state.spotlite { caffeine.toggle() }
            var hidden = preferences
            hidden.hiddenUtilities.insert(utility)
            preferencesDidChange(hidden)
            try checkUtility(items.isEmpty)
            if utility == .caffeinate { try checkUtility(caffeine.state.spotlite) }
            leaveScope()
            try checkUtility(!items.contains { $0.identity == utility.rawValue })
        }
        print("DEV utilities: hiding open submenus removes their actions; active Caffeinate stays on")
    }

    private func checkUtility(_ condition: @autoclosure () -> Bool, line: Int = #line) throws {
        guard condition() else { throw NSError(domain: "SpotliteDevChecks", code: line) }
    }

    private func runDevNestedMenuChecks(_ editor: NSTextView) async {
        let fixture = SearchMenu(id: "dev.menu", title: "Menu fixture", items: [
            SearchMenuItem(id: "dev.first", title: "First", action: .startCaffeinate(.untilTurnedOff),
                           closesPanelOnAction: false),
            SearchMenuItem(id: "dev.both", title: "Both", action: .startCaffeinate(.untilTurnedOff),
                           closesPanelOnAction: false, submenu: .caffeinate),
            SearchMenuItem(id: "dev.nested", title: "Nested", submenu: .caffeinate),
        ])
        preferences.visibleRows = max(preferences.visibleRows, fixture.items.count)
        enterScope(.menu(fixture))
        select(1, as: .navigated)
        let originalState = caffeine.state.spotlite
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        guard case .menu(let current) = navigation.scope else { preconditionFailure("Expected fixture") }
        precondition(current.id == fixture.id && caffeine.state.spotlite && cursor == 1)
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        precondition(caffeine.state.spotlite)
        if !originalState { caffeine.stop() }
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
                     + Metrics.listBottomPadding < childHeight)
        _ = control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:)))
        try? await Task.sleep(for: .milliseconds(400))
        precondition(items.count == 5 && items[0].identity == "caffeinate.0"
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
                precondition(items.count == 5 && items[0].identity == "caffeinate.0")
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
        // Nothing to hide in an argument, so Command-Delete must reach the field editor.
        enterScope(.argument(link))
        setQuery("abc")
        precondition(!control(field, textView: editor,
                              doCommandBy: #selector(NSResponder.deleteToBeginningOfLine(_:))))
        leaveScope()
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
        let picker = DevViews.descendants(page).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles == ["Restore previous query", "Clear query"] }!
        let pickerFrame = picker.convert(picker.bounds, to: page)
        precondition(picker.titleOfSelectedItem == "Clear query" && page.bounds.contains(pickerFrame))
        print("DEV settings: Search page=\(page.frame) back-query picker=\(pickerFrame)")
    }

    /// SPOTLITE_DEV_PLUGINS=1 with SPOTLITE_DEV_PLUGINS_DIR=plugins: finds the
    /// example Caffeinate plugin by keyword, loads and filters its list, starts and stops a
    /// session through it, and runs one GitHub search when the network answers.
    func runDevPluginChecks() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
            guard condition() else {
                throw NSError(domain: "SpotlitePluginChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message()])
            }
        }
        func settle(_ milliseconds: Int = 500) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func pluginRow(_ query: String) -> Int? {
            setQuery(query)
            updateMatches(for: query)
            return items.firstIndex {
                if case .app(let match) = $0 { return match.entry.kind == .plugin }
                return false
            }
        }
        let savedPreferences = preferences
        defer {
            preferencesDidChange(savedPreferences)
            toasts.dismiss()
            panel.orderOut(nil)
        }
        preferences.disabledPlugins = []
        preferences.hiddenBundleIDs = []
        preferences.backNavigationBehavior = .restoreQuery
        library.extras = savedPreferences.extraEntries + plugins.entries(disabled: [])
        // These checks read last-run records, which are opt-in.
        plugins.keepPluginRunDiagnostics = true
        defer { plugins.keepPluginRunDiagnostics = false }

        show()
        // The keyword is an alias: it finds a command whose title does not contain it.
        let caffeinate = try { () throws -> Int in
            guard let row = pluginRow("caffeine") else {
                try check(false, "No plugin command for its keyword: \(items.map(\.title))")
                return 0
            }
            return row
        }()
        try check(items[caffeinate].title == "Caffeinate", "Keyword found \(items[caffeinate].title)")
        try check(items[caffeinate].hints(modifiers: [], running: false).first?.key == "⇥", "Command lacks the Tab hint")
        select(caffeinate, as: .navigated)
        dumpFrames("plugin-command")

        launch(at: caffeinate)
        try check(pluginScope?.title == "Caffeinate", "Return did not enter the plugin level")
        await settle()
        try check(items.map(\.title).suffix(5) == ["Until turned off", "15 minutes", "30 minutes", "1 hour", "2 hours"],
                  "Unexpected list: \(items.map(\.title))")
        dumpFrames("plugin-list")
        try check(plugins.lastRun(for: "caffeinate").map { ($0.commandID, $0.action) } ?? ("", .run) == ("caffeinate", .list),
                  "The list run did not name its command and action")
        try? await SettingsForm.captureWindow(panel, name: "plugin-list")
        // "sort": false keeps the durations in order; "half hour" is a keyword of 30 minutes.
        setQuery("hour")
        updateMatches(for: "hour")
        try check(items.map(\.title) == ["30 minutes", "1 hour", "2 hours"], "Filter gave \(items.map(\.title))")
        setQuery("zzzz")
        updateMatches(for: "zzzz")
        try check(items.map(\.title) == ["No such duration"] && items.first?.pluginAction == nil,
                  "Filtered-out list showed \(items.map(\.title))")
        dumpFrames("plugin-empty")
        print("DEV plugins: keyword, level, unsorted filtering and empty text passed")

        // Start a session, then find Turn Off first and the command's new look at the root.
        setQuery("15")
        updateMatches(for: "15")
        launch(at: 0)
        try check(isDismissing, "A run action must close the panel")
        await settle(800)
        // A row nested in the command's list still runs as that command.
        try check(plugins.lastRun(for: "caffeinate").map { ($0.commandID, $0.action) } ?? ("", .list) == ("caffeinate", .run),
                  "A nested run did not name its command and action")
        show()
        guard let active = pluginRow("caffeine") else { return try check(false, "Command vanished") }
        let look = items[active].hints(modifiers: [], running: false).first?.text ?? ""
        try check(look.hasPrefix("Active until"), "Command did not take the plugin's look: \(look)")
        launch(at: active)
        await settle()
        try check(items.first?.title == "Turn Off", "Active list starts with \(items.first?.title ?? "nothing")")
        launch(at: 0)
        await settle(800)
        show()
        guard let stopped = pluginRow("caffeine") else { return try check(false, "Command vanished") }
        try check(items[stopped].hints(modifiers: [], running: false).first?.text == "Caffeinate",
                  "Command kept its active look")
        print("DEV plugins: run actions, toasts and command looks passed")

        // Back navigation returns to the root query with the command selected.
        launch(at: stopped)
        await settle()
        leaveScope()
        try check(pluginScope == nil && field.stringValue == "caffeine" && pluginList.items.isEmpty,
                  "Leaving the level did not restore the root")

        try await runDevPluginRowChecks(pluginID: "caffeinate", check: check)
        resetNavigation()
        show()
        guard let github = pluginRow("github") else { return try check(false, "No GitHub command") }
        launch(at: github)
        let prompt = ["Type a repository name"]
        try check(pluginScope?.source.isSearch == true && items.map(\.title) == prompt,
                  "Search level should start with its empty text, not \(items.map(\.title))")
        let editor = field.currentEditor() as! NSTextView
        editor.insertText("s", replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(items.map(\.title) == prompt && pluginDebounce == nil, "Below minQuery keeps the empty text")
        editor.insertText("wift", replacementRange: NSRange(location: NSNotFound, length: 0))
        // The text stays while the first answer loads, rather than flashing an empty bar.
        try check(items.map(\.title) == prompt && pluginDebounce != nil, "Typing must wait out the debounce")
        await settle(4_000)
        print("DEV plugins: GitHub search returned \(items.count) rows; first: \(items.first?.title ?? "none")")
        if items.count > 1 {
            try check(items.allSatisfy { if case .plugin(let item, _) = $0 { item.accessory?.hasPrefix("★ ") == true } else { false } },
                      "GitHub rows lack star accessories")
            try check(items[0].pluginActions?.entry(for: .command)?.title == "Copy Clone URL"
                      && items[0].pluginActions?.entry(for: .option)?.title == "Copy Link",
                      "GitHub rows lack ⌘↩ Copy Clone URL and ⌥↩ Copy Link")
            dumpVisibleRows("plugin-search-rows")
        }
        try check(!bar.isShowingCompletion, "Search rows must not complete the query")
        dumpFrames("plugin-search")
        try? await SettingsForm.captureWindow(panel, name: "plugin-search")
        hide()
        await settle(300)
        try check(pluginRun == nil && pluginList.items.isEmpty, "Closing must drop plugin work")
        print("DEV plugins: all checks passed")
    }

    /// Accessories, default empty text and keyword ranking on fixed rows of a real plugin.
    private func runDevPluginRowChecks(pluginID: String,
                                       check: (@autoclosure () -> Bool, @autoclosure () -> String) throws -> Void) async throws {
        let long = String(repeating: "A very long repository title ", count: 8)
        let rows = [
            PluginItem(id: "a", title: "alpha", subtitle: "Swift", accessory: "★ 1.2k", action: .open("https://example.com/a")),
            PluginItem(id: "b", title: long, accessory: "Nov 14, 2026 at 10:42", action: .menu([PluginItem(title: "Inner")])),
            PluginItem(id: "c", title: "Gamma", keywords: ["alphabet"], action: .copy("c")),
            PluginItem(id: "d", title: "Delta", subtitle: "No accessory", action: .copy("d")),
        ]
        show()
        enterScope(.plugin(PluginScope(pluginID: pluginID, title: "Rows", icon: nil, source: .items(rows))))
        try check(items.count == 4, "Fixed rows did not load: \(items.map(\.title))")
        try check(items[1].restingHints.map(\.text) == ["Nov 14, 2026 at 10:42"], "Unselected row lacks its accessory")
        try check(items[3].restingHints.isEmpty, "A row without an accessory shows text while unselected")
        try check(items[0].hints(modifiers: [], running: false).map(\.text) == ["Swift", "★ 1.2k"],
                  "Selected row should show subtitle, then accessory")
        try check(items[1].hints(modifiers: [], running: false).last.map { [$0.text, $0.key ?? ""] }
                  == ["Nov 14, 2026 at 10:42", "⇥"], "The Tab key should follow the accessory")
        try? await Task.sleep(for: .milliseconds(400))
        dumpVisibleRows("plugin-accessory")
        select(1, as: .navigated)
        dumpVisibleRows("plugin-accessory-long-selected")
        // A title match ranks above a keyword-only one; without "sort": false order is by score.
        setQuery("alpha")
        updateMatches(for: "alpha")
        try check(items.map(\.title) == ["alpha", "Gamma"], "Keyword ranking gave \(items.map(\.title))")
        setQuery("zzzz")
        updateMatches(for: "zzzz")
        try check(items.map(\.title) == [PluginSource.defaultEmptyText], "Default empty text missing: \(items.map(\.title))")
        print("DEV plugins: accessories, keyword ranking and default empty text passed")
    }

    /// SPOTLITE_DEV_ACTIONS=1 with SPOTLITE_DEV_PLUGINS_DIR=Tests/Fixtures/Plugins: modifier
    /// titles, the ⌘K list, confirmations and a closing run's late answer, through posted
    /// key events where the panel holds the keyboard.
    func runDevPluginActionChecks() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
            guard condition() else {
                throw NSError(domain: "SpotliteActionChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message()])
            }
        }
        guard let fixture = plugins.plugin(id: "actions") else {
            return try check(false, "Set SPOTLITE_DEV_PLUGINS_DIR to Tests/Fixtures/Plugins")
        }
        func settle(_ milliseconds: Int = 150) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        let pasteboard = NSPasteboard.general
        let savedPreferences = preferences
        let savedConfirmations = toasts.showConfirmationMessages
        let restoreClipboard = savedClipboard()
        defer {
            resetNavigation()
            preferencesDidChange(savedPreferences)
            toasts.showConfirmationMessages = savedConfirmations
            toasts.dismiss()
            panel.orderOut(nil)
            restoreClipboard()
        }
        toasts.showConfirmationMessages = true
        preferences.hiddenBundleIDs = []
        // Restoring is the overlay's own rule; the user's setting must not change it.
        preferences.backNavigationBehavior = .clearQuery
        library.extras = savedPreferences.extraEntries + plugins.entries(disabled: [])

        /// A key typed into the panel, dispatched by AppKit as a real one would be.
        func press(_ keyCode: Int, _ characters: String, _ flags: NSEvent.ModifierFlags = [],
                   repeating: Bool = false) async throws {
            // Another app can take the keyboard mid-run; SPOTLITE_DEV_PIN=1 keeps the panel open.
            if !panel.isKeyWindow {
                panel.makeKey()
                panel.makeFirstResponder(field)
            }
            try check(panel.isKeyWindow, "The panel must hold the keyboard for posted keys")
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: panel.windowNumber, context: nil, characters: characters,
                                         charactersIgnoringModifiers: characters, isARepeat: repeating,
                                         keyCode: UInt16(keyCode))!
            NSApp.postEvent(event, atStart: false)
            await settle(60)
        }
        /// Posted keys and plugin runs land on a later turn of the run loop, and a fixed
        /// pause is sometimes too short. Waits for the outcome instead, up to two seconds.
        func eventually(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<100 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }
        /// A closing panel may already have finished hiding by the time it is checked.
        var closed: Bool { isDismissing || !panel.isVisible }
        // kVK_Return, kVK_Escape and kVK_ANSI_K.
        let returnKey = (36, "\r"), escape = (53, "\u{1b}"), commandK = (40, "k")
        func open(_ title: String) throws -> Int {
            show()
            setQuery(title)
            updateMatches(for: title)
            guard let row = items.firstIndex(where: { $0.title == title }) else {
                try check(false, "No root command \(title): \(items.map(\.title))")
                return 0
            }
            select(row, as: .navigated)
            return row
        }

        // Holding a modifier names what Return would do; app rows are untouched.
        var row = try open("Actions Fixture Link")
        try check(items[row].hints(modifiers: .command, running: false).map { [$0.text, $0.key ?? ""] }
                  == [["Copy Name", "⌘↩"], ["Hide", "⌘⌫"]], "⌘ hint: \(items[row].hints(modifiers: .command, running: false))")
        try check(items[row].hints(modifiers: .option, running: false).map(\.text) == ["Copy Link"], "⌥ keeps Copy Link")
        try check(items[row].hints(modifiers: .shift, running: false).map { $0.key } == ["⇧↩"], "⇧ hint")
        try check(items[row].hints(modifiers: [.shift, .command], running: false).map(\.text) == ["Hide"],
                  "An unbound chord keeps the default")
        dumpFrames("plugin-actions-command")

        // ⌘K lists Return's action first, the plugin's next, the built-in copy last.
        try await press(commandK.0, commandK.1, .command)
        _ = await eventually { pluginOverlay != nil }
        try check(pluginOverlay != nil && items.map(\.title) == ["Open", "Copy Name", "Run Confirmed", "Show Rows", "Copy Link"],
                  "Action list: \(items.map(\.title))")
        try check(items.map { $0.restingHints.last?.key } == ["↩", "⌘↩", "⇧↩", nil, "⌥↩"], "Action keys")
        try check(bar.isShowingCompletion == false, "The action list must not complete the query")
        try await Task.sleep(for: .milliseconds(400))
        dumpFrames("plugin-actions-list")
        dumpVisibleRows("plugin-actions-list")
        try? await SettingsForm.captureWindow(panel, name: "plugin-actions-list")
        setQuery("copy")
        updateMatches(for: "copy")
        try check(items.map(\.title) == ["Copy Name", "Copy Link"], "Filtering the list: \(items.map(\.title))")
        // Escape, Backspace on empty, Shift-Tab and ⌘K each return to the row and its query.
        for back in 0..<4 {
            if back > 0 { try await press(commandK.0, commandK.1, .command) }
            switch back {
            case 0: try await press(escape.0, escape.1)
            case 1: _ = control(field, textView: field.currentEditor() as! NSTextView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
            case 2: _ = control(field, textView: field.currentEditor() as! NSTextView, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
            default: try await press(commandK.0, commandK.1, .command)
            }
            try check(pluginOverlay == nil && panel.isVisible && !isDismissing, "Back \(back) left the list open or closed the panel")
            try check(field.stringValue == "Actions Fixture Link" && cursor == row && selection == .navigated,
                      "Back \(back) lost the query or selection: \(field.stringValue) \(cursor)")
        }

        // ⌘↩ runs its binding through the field's key equivalent.
        try await press(returnKey.0, returnKey.1, .command)
        _ = await eventually { pasteboard.string(forType: .string) == "actions-name" }
        try check(pasteboard.string(forType: .string) == "actions-name" && closed, "⌘↩ did not copy the name")
        await settle(300)

        // ⇧↩ asks first. Escape and Cancel answer no; a held Return does not answer.
        row = try open("Actions Fixture Link")
        pasteboard.clearContents()
        try await press(returnKey.0, returnKey.1, .shift)
        guard case .confirm = pluginOverlay?.kind else { return try check(false, "⇧↩ did not ask") }
        try check(items.map(\.title) == ["Run", "Cancel"] && cursor == 0, "Confirmation rows: \(items.map(\.title))")
        try check(items[0].hints(modifiers: [], running: false).map { [$0.text, $0.key ?? ""] }
                  == [["It copies a fixed text.", "↩"]], "Confirmation hint: \(items[0].hints(modifiers: [], running: false))")
        try await Task.sleep(for: .milliseconds(400))
        dumpFrames("plugin-confirm")
        dumpVisibleRows("plugin-confirm")
        try? await SettingsForm.captureWindow(panel, name: "plugin-confirm")
        try await press(returnKey.0, returnKey.1, repeating: true)
        try check(pluginOverlay != nil && !isDismissing, "A repeated Return answered the question")
        try await press(escape.0, escape.1)
        try check(pluginOverlay == nil && panel.isVisible && cursor == row, "Escape did not cancel the question")
        try await press(returnKey.0, returnKey.1, .shift)
        launch(at: 1)
        try check(pluginOverlay == nil && panel.isVisible && pasteboard.string(forType: .string) == nil, "Cancel ran the action")
        try await press(returnKey.0, returnKey.1, .shift)
        try await press(returnKey.0, returnKey.1)
        let confirmed = await eventually { pasteboard.string(forType: .string) == "confirmed-run" }
        try check(confirmed && closed, "Confirming did not run the action: overlay=\(pluginOverlay != nil) query=\(field.stringValue) items=\(items.map(\.title)) cursor=\(cursor)")
        await settle(400)
        try check(pasteboard.string(forType: .string) == "confirmed-run", "The confirmed run did not apply its copy")
        print("DEV actions: modifier hints, ⌘K list and its four ways back, ⌘↩, confirmation and repeat guard passed")

        // A manifest command asks too, and a secondary that enters a level goes back to the row.
        pasteboard.clearContents()
        _ = try open("Actions Fixture Ask")
        launch(at: cursor)
        try check(pluginOverlay != nil && bar.chipTitle == "Run the fixture?", "Command confirm: \(items.map(\.title))")
        try check(items[0].title == PluginConfirmation.defaultButton, "Default button: \(items[0].title)")
        try await press(escape.0, escape.1)
        row = try open("Actions Fixture Link")
        try await press(commandK.0, commandK.1, .command)
        select(3, as: .navigated)
        try await press(returnKey.0, returnKey.1)
        await settle(300)
        try check(pluginScope?.title == "Show Rows" && pluginOverlay == nil && items.map(\.title) == ["alpha", "beta"],
                  "The secondary did not enter its level: \(items.map(\.title))")
        // Rows' own actions, with ⌃ bound to a confirmed keepOpen run.
        try check(items[0].hints(modifiers: .control, running: false).map(\.text) == ["Delete"], "⌃ hint")
        try await press(returnKey.0, returnKey.1, .control)
        try check(bar.chipTitle == "Delete alpha?", "⌃↩ did not ask")
        try await press(returnKey.0, returnKey.1)
        await settle(400)
        try check(pasteboard.string(forType: .string) == "deleted-alpha" && pluginScope?.title == "Show Rows"
                  && panel.isVisible, "The confirmed keepOpen run did not stay in its level")
        try await press(commandK.0, commandK.1, .command)
        try check(items.map(\.title) == ["Open", "Copy Clone URL", "Delete", "Copy Link"], "Row actions: \(items.map(\.title))")
        try await press(escape.0, escape.1)
        // The list was loaded, so returning does not run the plugin again.
        try check(pluginRun == nil && items.map(\.title) == ["alpha", "beta"], "Returning reloaded the level")
        // ⌥⇧↩ that the row does not bind must not fall back to ⌥↩'s Copy Link, and ⌃⌥↩,
        // which the text system would type as a space, must not edit the query.
        pasteboard.clearContents()
        select(0, as: .navigated)
        try await press(returnKey.0, returnKey.1, [.option, .shift])
        try await press(returnKey.0, returnKey.1, [.option, .control])
        try check(pasteboard.string(forType: .string) == nil && !closed && field.stringValue.isEmpty,
                  "An unbound ⌥ chord ran Copy Link or typed \(field.stringValue.unicodeScalars.map(\.value))")
        leaveScope()
        try check(pluginScope == nil && cursor == row, "Back from the level did not return to the command")
        print("DEV actions: command confirmation, a secondary's level, row actions, ⌃↩ and unbound ⌥ chords passed")

        // A completed debounced search has no pending work. Returning from its
        // actions restores the saved rows without starting another process.
        enterScope(.plugin(PluginScope(pluginID: fixture.id, title: "Search", icon: nil,
                                       source: .search(args: ["rows"], debounce: 20, minimumQuery: 1), commandID: "link")))
        setQuery("alpha")
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        let searched = await eventually { pluginRun == nil && pluginLoaded && pluginList.items.count == 2 }
        try check(searched, "The debounced search did not complete")
        let searchGeneration = pluginGeneration
        try await press(commandK.0, commandK.1, .command)
        try check(pluginOverlay != nil, "The search row's action list did not open")
        try await press(escape.0, escape.1)
        // Entering the overlay cancels pending work once, incrementing the generation.
        try check(pluginRun == nil && pluginDebounce == nil && pluginGeneration == searchGeneration + 1,
                  "Returning from actions restarted a completed search")
        try check(field.stringValue == "alpha" && items.map(\.title) == ["alpha", "beta"],
                  "The completed search lost its rows or query")
        leaveScope()
        print("DEV actions: completed debounced searches restore without rerunning passed")

        // A closing run answers after a new session started: its copy applies, its rows do not.
        _ = try open("Actions Fixture Link")
        runPlugin(fixture, arguments: ["late"], keepOpen: false, commandID: "link")
        try check(isDismissing, "A closing run must close the panel at once")
        await settle(250)
        show()
        let fixed = [PluginItem(title: "Session row", action: .copy("session"))]
        enterScope(.plugin(PluginScope(pluginID: fixture.id, title: "Session", icon: nil, source: .items(fixed))))
        await settle(400)
        try check(pasteboard.string(forType: .string) == "late-copy", "The closing run's copy did not apply")
        try check(items.map(\.title) == ["Session row"], "A late answer replaced a newer session's rows: \(items.map(\.title))")
        hide()
        runPlugin(fixture, arguments: ["fail"], keepOpen: false, commandID: "link")
        await settle(400)
        toasts.checkDevMessage("fixture failure")
        print("DEV actions: closing runs apply late answers without touching rows, and report failures")
        print("DEV actions: all checks passed")
    }

    /// Every visible row's frames, for checking accessories against the layout.
    private func dumpVisibleRows(_ tag: String) {
        panel.layoutIfNeeded()
        for row in 0..<min(items.count, placement.visibleRows) {
            (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ResultRowView)?.dumpFrames("\(tag)#\(row)")
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

}

#endif

#if DEBUG
extension SpotliteController {
    /// Streamed rows against the offline stream fixture: rows before exit, selection while
    /// rows append, Loading…, empty text after the end, a failure keeping its rows,
    /// superseded and abandoned searches, and the keystroke cost of a full streamed list.
    func runDevStreamChecks() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
            guard condition() else {
                throw NSError(domain: "SpotliteStreamChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message()])
            }
        }
        func settle(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        guard let fixture = plugins.plugin(id: "stream") else {
            return try check(false, "Set SPOTLITE_DEV_PLUGINS_DIR to Tests/Fixtures/Plugins")
        }
        // These checks read last-run records, which are opt-in.
        plugins.keepPluginRunDiagnostics = true
        defer { plugins.keepPluginRunDiagnostics = false }
        let savedPreferences = preferences
        defer {
            resetNavigation()
            preferencesDidChange(savedPreferences)
            toasts.dismiss()
            panel.orderOut(nil)
        }
        func enter(_ args: [String], search: Bool = false, emptyText: String? = nil) {
            show()
            let options = PluginListOptions(emptyText: emptyText, streams: true)
            let source: PluginSource = search ? .search(args: args, debounce: 0, minimumQuery: 1, options: options)
                : .list(args: args, options: options)
            enterScope(.plugin(PluginScope(pluginID: fixture.id, title: "Stream", icon: nil, source: source,
                                           commandID: search ? "search" : "list")))
        }
        func type(_ query: String) {
            let editor = field.currentEditor() as! NSTextView
            editor.insertText(query, replacementRange: NSRange(location: 0, length: (field.stringValue as NSString).length))
        }
        var titles: [String] { items.map(\.title) }

        // Rows show while the program still runs, and typing filters them as more arrive.
        enter(["list"])
        await settle(250)
        try check(pluginRun != nil && titles == ["alpha one", "beta two"], "Before exit: \(titles), running \(pluginRun != nil)")
        dumpFrames("stream-partial")
        dumpVisibleRows("stream-partial-rows")
        select(1, as: .navigated)
        await settle(600)
        try check(pluginRun != nil && titles.count == 4 && items[cursor].title == "beta two",
                  "Appended rows moved the selection: \(titles), cursor \(cursor)")
        type("zzzz")
        try check(titles == ["Loading…"], "Filtering out every row while streaming gave \(titles)")
        type("alpha")
        try check(titles == ["alpha one", "alpha three"], "Filter while streaming gave \(titles)")
        await settle(900)
        try check(pluginRun == nil && Set(titles) == ["alpha one", "alpha three", "alpha five"], "After exit: \(titles)")
        toasts.checkDevMessage("stream finished")
        let record = plugins.lastRun(for: fixture.id)
        try check(record?.stream?.rows == 5 && record?.stream?.skipped == 1
                  && record?.stream?.errors.first?.hasPrefix("Line 4:") == true,
                  "Record: \(record?.details ?? "none")")
        dumpFrames("stream-done")
        print("DEV stream: rows before exit, filtering and stable selection while appending passed")

        // Nothing yet shows Loading…; the empty text waits for the end of the stream.
        enter(["empty"], emptyText: "Nothing streamed")
        await settle(150)
        try check(titles.isEmpty, "Empty stream showed \(titles) before Loading…")
        await settle(300)
        try check(titles == ["Loading…"], "Slow stream showed \(titles)")
        await settle(500)
        try check(titles == ["Nothing streamed"], "Ended empty stream showed \(titles)")
        enter(["late"])
        await settle(450)
        try check(titles == ["Loading…"], "Late stream showed \(titles)")
        await settle(500)
        try check(titles == ["late row"], "Late row: \(titles)")
        print("DEV stream: Loading… and empty text after the end passed")

        // A failure after rows keeps them and says why in a toast.
        enter(["fail"])
        await settle(700)
        try check(titles == ["kept row"] && pluginStatus == nil, "Failed stream showed \(titles)")
        toasts.checkDevMessage("stream broke")
        print("DEV stream: a failure keeps its rows and shows a toast")

        // A keepOpen run's rows replace the list it ran from, even one still streaming.
        enter(["list"])
        await settle(250)
        try check(pluginRun != nil && !titles.isEmpty, "The stream to replace showed \(titles)")
        runPlugin(fixture, arguments: ["replace"], keepOpen: true, commandID: "list")
        await settle(1_600)
        try check(pluginRun == nil && titles == ["replaced row"], "The stream overwrote the run's rows: \(titles)")
        print("DEV stream: a keepOpen run's rows replace a list that is still streaming")

        // A newer query cancels the older stream; none of its rows show, then or later.
        enter(["search"], search: true)
        type("old")
        await settle(150)
        try check(titles == ["old 0"], "First search showed \(titles)")
        let pidFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spotlite-stream-search.pid")
        let oldPID = pid_t((try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        type("new")
        try check(titles.isEmpty, "The old query's rows stayed: \(titles)")
        for wait in [150, 300, 400] {
            await settle(wait)
            try check(!titles.isEmpty && titles.allSatisfy { $0.hasPrefix("new ") }, "Superseded search leaked rows: \(titles)")
        }
        try check(oldPID > 0 && kill(oldPID, 0) == -1, "The superseded stream kept running")
        // A space around the words asks the same question: the answer stays, with no new run.
        let (answered, answering, generation) = (titles, pluginRun, pluginGeneration)
        type(" new ")
        try check(titles == answered && pluginRun === answering && pluginGeneration == generation,
                  "Adding spaces ran the same search again: \(titles)")
        // Leaving the level cancels its stream too.
        type("leave")
        await settle(150)
        let leavingPID = pid_t((try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        leaveScope()
        await settle(1_200)
        try check(pluginScope == nil && pluginRun == nil && pluginList.items.isEmpty, "Leaving kept stream rows")
        try check(leavingPID > 0 && leavingPID != oldPID && kill(leavingPID, 0) == -1, "Leaving left the stream running")
        try? FileManager.default.removeItem(at: pidFile)
        print("DEV stream: superseded and abandoned searches show no stale rows and stop")

        // Keystroke cost with a full streamed list: the same ranking as any 500-row list.
        enter(["many"])
        for _ in 0..<100 where pluginRun != nil { await settle(20) }
        try check(pluginList.items.count == PluginItem.maxItems && titles.count == PluginItem.maxItems,
                  "Many rows: \(pluginList.items.count)")
        dumpVisibleRows("stream-many")
        let queries = ["r", "re", "rep", "repo 4", "tools", "project42", "zz"]
        var samples: [Double] = []
        for round in 0..<20 {
            for query in queries {
                setQuery(query)
                let start = DispatchTime.now().uptimeNanoseconds
                updateMatches(for: query)
                if round > 0 { samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000) }
            }
        }
        var ranking: [Double] = []
        for _ in 0..<20 {
            for query in queries {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = pluginList.matchingIndices(query, matcher: matcher)
                ranking.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000)
            }
        }
        let rebuild = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 { _ = PluginList(items: pluginList.items) }
        let perList = Double(DispatchTime.now().uptimeNanoseconds - rebuild) / 20_000
        // A delivery of 20 more rows onto 480 prepares only those 20.
        let head = PluginList(items: Array(pluginList.items.prefix(480)))
        let append = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 { _ = head.appending(pluginList.items) }
        let perAppend = Double(DispatchTime.now().uptimeNanoseconds - append) / 20_000
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        print(String(format: "DEV stream: 500 streamed rows, per keystroke median %.0f µs (ranking %.0f µs); "
                     + "whole list %.0f µs, appending 20 rows %.0f µs", median(samples), median(ranking), perList, perAppend))
        hide()

        // The debug runner shows the raw lines and says what was decoded from them.
        let runner = PluginDebugRunnerWindowController(plugin: fixture, host: plugins)
        let controls = DevViews.descendants(runner.window!.contentView!)
        let identified = { (id: String) in controls.first { $0.identifier?.rawValue == id } }
        let status = identified("status") as! NSTextField
        let output = identified("stdout") as! NSTextView
        let picker = controls.compactMap { $0 as? NSPopUpButton }.first!
        try check(picker.itemTitles == ["Stream List (list)", "Stream Search (search)"], "Runner offers \(picker.itemTitles)")
        picker.selectItem(at: 0)
        controls.compactMap { $0 as? NSButton }.first { $0.title == "Run" }!.performClick(nil)
        for _ in 0..<150 where status.stringValue.isEmpty || status.stringValue == "Running…" { await settle(20) }
        try check(status.stringValue.contains("exit 0") && status.stringValue.contains("Valid response: 5 items, toast")
                  && status.stringValue.contains("Streamed 5 rows, skipped 1 line\nLine 4: "),
                  "Runner status: \(status.stringValue)")
        try check(output.string.hasPrefix("{\"title\":\"alpha one\"}\n") && output.string.contains("not json"),
                  "Runner output: \(output.string)")
        print("DEV stream: debug runner status: \(status.stringValue.replacingOccurrences(of: "\n", with: " | "))")
        runner.close()
        print("DEV stream: all checks passed")
    }
}
#endif

/// Top-left origin, so everything pinned to the top keeps its frame while the glass
/// grows or shrinks beneath it. With AppKit's usual bottom-left origin those frames all
/// change with the height, and the resize animation slides the bar's contents up.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
