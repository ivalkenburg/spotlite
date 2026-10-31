import AppKit
import SpotliteCore

struct ToastMessage: Equatable {
    let text: String
    let symbol: String
    /// Failures, external-assertion explanations and explicit previews always show.
    var isConfirmation = true

    static func copied(succeeded: Bool) -> ToastMessage {
        succeeded
            ? ToastMessage(text: "Copied to clipboard", symbol: "doc.on.clipboard")
            : ToastMessage(text: "Couldn’t copy to clipboard", symbol: "exclamationmark.triangle", isConfirmation: false)
    }

    static func visibility(_ name: String, hidden: Bool) -> ToastMessage {
        ToastMessage(text: "\(hidden ? "Hidden" : "Restored") \(name)",
                     symbol: hidden ? "eye.slash" : "eye")
    }

    static func caffeine(succeeded: Bool, state: CaffeineState) -> ToastMessage {
        guard succeeded else {
            return ToastMessage(text: "Couldn’t \(state.spotlite ? "disable" : "enable") Caffeinate",
                                symbol: "exclamationmark.triangle", isConfirmation: false)
        }
        let text: String
        if state.spotlite {
            text = "Caffeinate enabled"
        } else if state.external {
            text = "Spotlite Caffeinate disabled; another app is keeping the display awake"
        } else {
            text = "Caffeinate disabled"
        }
        return ToastMessage(text: text, symbol: state.spotlite ? "cup.and.saucer.fill" : "cup.and.saucer",
                            isConfirmation: state.spotlite || !state.external)
    }

    static func caffeineFinished(succeeded: Bool, state: CaffeineState) -> ToastMessage {
        guard succeeded else {
            return ToastMessage(text: "Couldn’t stop Caffeinate", symbol: "exclamationmark.triangle",
                                isConfirmation: false)
        }
        return ToastMessage(text: state.external
                            ? "Caffeinate finished; another app is keeping the display awake"
                            : "Caffeinate finished",
                            symbol: "cup.and.saucer", isConfirmation: !state.external)
    }
}

/// Shared by launcher, menu bar and Settings. No views or scheduled work exist while
/// idle. A new message replaces the current one, including during its closing fade.
@MainActor
final class ToastPresenter {
    private var panel: ToastPanel?
    private var dismissal: Task<Void, Never>?
    private var currentMessage: ToastMessage?
    var showConfirmationMessages = true {
        didSet {
            if !showConfirmationMessages, currentMessage?.isConfirmation == true { dismiss() }
        }
    }

    static var pointerScreen: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }

    func show(_ message: ToastMessage, position: ToastPosition, on screen: NSScreen? = nil) {
        guard showConfirmationMessages || !message.isConfirmation else { return }
        guard let screen = screen ?? Self.pointerScreen else { return }
        dismissal?.cancel()
        let window = panel ?? ToastPanel()
        panel = window
        currentMessage = message
        let content = ToastView(message: message, maxWidth: min(480, max(80, screen.visibleFrame.width - 96)))
        window.contentView = content
        window.setFrame(position.frame(for: content.fittingSize, in: screen.visibleFrame), display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        content.layer?.opacity = window.isVisible ? 1 : 0
        // No activation, key-window change, event monitor or connection to the launcher.
        window.orderFrontRegardless()
        Self.fade(content, to: 1)
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: message.text,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
        dismissal = Task { @MainActor [weak self, weak window] in
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            // Sleep can finish before cancellation while its MainActor continuation waits.
            guard !Task.isCancelled, let self, let window else { return }
            if let content = window.contentView { Self.fade(content, to: 0) }
            do { try await Task.sleep(for: .seconds(Self.fadeDuration)) }
            catch { return }
            guard !Task.isCancelled else { return }
            window.orderOut(nil)
            self.panel = nil
            self.dismissal = nil
            self.currentMessage = nil
        }
    }

    @discardableResult
    func copy(_ value: String, position: ToastPosition, on screen: NSScreen?,
              to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        let succeeded = pasteboard.setString(value, forType: .string)
        show(.copied(succeeded: succeeded), position: position, on: screen)
        return succeeded
    }

    @discardableResult
    func startCaffeinate(_ caffeine: CaffeineAssertion, duration: CaffeineDuration,
                         position: ToastPosition, on screen: NSScreen? = nil) -> Bool {
        let succeeded = caffeine.start(duration)
        show(.caffeine(succeeded: succeeded, state: caffeine.state), position: position, on: screen)
        return succeeded
    }

    @discardableResult
    func stopCaffeinate(_ caffeine: CaffeineAssertion, position: ToastPosition, on screen: NSScreen? = nil) -> Bool {
        let succeeded = caffeine.stop()
        show(.caffeine(succeeded: succeeded, state: caffeine.state), position: position, on: screen)
        return succeeded
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel = nil
        currentMessage = nil
    }

    private static var fadeDuration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
    }

    /// Explicit layer animation also runs when Spotlite is inactive. AppKit's window
    /// animator can defer alpha updates for a nonactivating window. Replacing content
    /// discards its old layer, so an older fade can never dim the next message.
    private static func fade(_ view: NSView, to opacity: Float) {
        guard let layer = view.layer else { return }
        let start = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "toastFade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        if fadeDuration > 0, start != opacity {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = start
            animation.toValue = opacity
            animation.duration = fadeDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: "toastFade")
        }
        CATransaction.commit()
    }
}

private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
    }
}

/// Text and icon sit outside the effect view so vibrancy and translucency never dim
/// them. A lightweight visual effect supplies blur beneath a half-transparent backing.
@MainActor
private final class ToastView: NSView {
    let label: NSTextField
    let icon = NSImageView()
    private let effect = NSVisualEffectView()
    private let backing = NSView()
    private let size: NSSize
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter

    init(message: ToastMessage, maxWidth: CGFloat) {
        label = NSTextField(wrappingLabelWithString: message.text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        let font = label.font!
        let textBounds = (message.text as NSString).boundingRect(
            with: NSSize(width: maxWidth - 62, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        // NSTextField adds two points on each side of its text drawing rect.
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        size = NSSize(width: min(maxWidth, ceil(textBounds.width) + 62),
                      height: min(lineHeight * 3, ceil(textBounds.height)) + 26)
        icon.image = NSImage(systemSymbolName: message.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        icon.contentTintColor = .labelColor
        icon.setAccessibilityElement(false)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        backing.wantsLayer = true
        for view in [effect, backing, icon, label] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        setFrameSize(size)
        needsLayout = true
        updateBacking()
        workspaceNotifications.addObserver(self, selector: #selector(updateBacking),
                                           name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                           object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { workspaceNotifications.removeObserver(self) }

    override var fittingSize: NSSize { size }

    override func layout() {
        super.layout()
        effect.frame = bounds
        backing.frame = bounds
        icon.frame = NSRect(x: 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 42, y: 12, width: max(0, bounds.width - 58),
                            height: max(0, bounds.height - 24))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBacking()
    }

    @objc private func updateBacking() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effect.isHidden = reduceTransparency
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        backing.layer?.backgroundColor = NSColor(srgbRed: dark ? 0.12 : 0.96,
                                                 green: dark ? 0.12 : 0.96,
                                                 blue: dark ? 0.12 : 0.96,
                                                 alpha: reduceTransparency ? 1 : 0.5).cgColor
    }
}

#if DEBUG
extension ToastPresenter {
    private func toggleCaffeinate(_ caffeine: CaffeineAssertion, position: ToastPosition, on screen: NSScreen? = nil) {
        let succeeded = caffeine.toggle()
        show(.caffeine(succeeded: succeeded, state: caffeine.state), position: position, on: screen)
    }

    /// SPOTLITE_DEV_TOAST=1: exercise native windows and controls without saving prefs
    /// or touching the general clipboard. Frame assertions catch clipped/wrapped labels.
    func runDevChecks(caffeine: CaffeineAssertion) async throws {
        func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
            guard condition() else {
                throw NSError(domain: "ToastChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: description])
            }
        }
        let savedConfirmations = showConfirmationMessages
        showConfirmationMessages = true
        defer {
            dismiss()
            showConfirmationMessages = savedConfirmations
        }
        let keyWindow = NSApp.keyWindow
        let active = NSApp.isActive
        let screen = Self.pointerScreen!
        try check(panel == nil && dismissal == nil, "Presenter must start without views or work")

        for display in NSScreen.screens {
            for position in ToastPosition.allCases {
                show(.copied(succeeded: true), position: position, on: display)
                let window = panel!
                let content = window.contentView as! ToastView
                try check(display.visibleFrame.contains(window.frame), "Toast escaped display")
                try check(!window.canBecomeKey && !window.canBecomeMain && window.ignoresMouseEvents,
                          "Toast must be passive")
                try check(NSApp.keyWindow === keyWindow && NSApp.isActive == active, "Toast took focus")
                let labelFrame = content.label.convert(content.label.bounds, to: content)
                let iconFrame = content.icon.convert(content.icon.bounds, to: content)
                try check(content.bounds.contains(labelFrame) && content.bounds.contains(iconFrame),
                          "Toast clipped its text or icon")
                print("DEV toast: \(display.localizedName) \(position.rawValue) window=\(window.frame) label=\(labelFrame) icon=\(iconFrame)")
            }
        }

        let external = ToastMessage.caffeine(succeeded: true,
                                             state: CaffeineState(external: true))
        show(external, position: .bottomCenter, on: screen)
        let content = panel!.contentView as! ToastView
        let labelFrame = content.label.convert(content.label.bounds, to: content)
        try check(content.bounds.contains(labelFrame) && labelFrame.height > 20,
                  "External caffeine message must wrap within the toast")
        print("DEV toast: wrapped window=\(panel!.frame) label=\(labelFrame)")
        try check(ToastMessage.caffeine(succeeded: false, state: CaffeineState()).text == "Couldn’t enable Caffeinate",
                  "Enable failure was reported as success")
        try check(ToastMessage.caffeine(succeeded: false, state: CaffeineState(session: CaffeineSession(duration: .untilTurnedOff))).text == "Couldn’t disable Caffeinate",
                  "Disable failure was reported as success")
        try check(ToastMessage.copied(succeeded: false).text == "Couldn’t copy to clipboard",
                  "Clipboard failure was reported as success")
        let originalState = caffeine.state.spotlite
        defer { if caffeine.state.spotlite != originalState { caffeine.toggle() } }
        toggleCaffeinate(caffeine, position: .bottomCenter, on: screen)
        checkDevMessage(ToastMessage.caffeine(succeeded: caffeine.state.spotlite != originalState,
                                              state: caffeine.state).text)
        let beforeRefresh = panel?.contentView
        caffeine.refresh()
        try check(panel?.contentView === beforeRefresh, "Background refresh generated a toast")
        if caffeine.state.spotlite != originalState {
            toggleCaffeinate(caffeine, position: .bottomCenter, on: screen)
        }

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        copy("private clipboard fixture", position: .bottomCenter, on: screen, to: pasteboard)
        checkDevMessage("Copied to clipboard")
        try check(pasteboard.string(forType: .string) == "private clipboard fixture",
                  "Clipboard contents changed")

        showConfirmationMessages = false
        try check(panel == nil && dismissal == nil, "Disabling confirmations kept a routine message alive")
        for message in [ToastMessage.copied(succeeded: true), .visibility("Fixture", hidden: true),
                        .caffeine(succeeded: true, state: CaffeineState()),
                        .caffeineFinished(succeeded: true, state: CaffeineState())] {
            show(message, position: .bottomCenter, on: screen)
            try check(panel == nil && dismissal == nil, "A disabled confirmation created views or work")
        }
        copy("copy without confirmation", position: .bottomCenter, on: screen, to: pasteboard)
        try check(panel == nil && pasteboard.string(forType: .string) == "copy without confirmation",
                  "Suppressing confirmation changed clipboard behavior")
        for message in [ToastMessage.copied(succeeded: false),
                        .caffeine(succeeded: false, state: CaffeineState()),
                        .caffeineFinished(succeeded: false, state: CaffeineState()), external,
                        .caffeineFinished(succeeded: true, state: CaffeineState(external: true))] {
            show(message, position: .bottomCenter, on: screen)
            checkDevMessage(message.text)
            dismiss()
        }
        showConfirmationMessages = true
        print("DEV toast: routine confirmations suppressed; clipboard, failures and external explanations preserved")

        // Real IOKit assertions plus a short wall-clock deadline exercise scheduling,
        // renewal and cancellation without waiting for a full duration preset.
        try check(caffeine.start(.fifteenMinutes, now: Date().addingTimeInterval(-899.8)), "Could not start timed session")
        try check(caffeine.start(.thirtyMinutes), "Could not replace timed session")
        let replacement = caffeine.state.session?.deadline
        try await Task.sleep(for: .milliseconds(400))
        try check(caffeine.state.spotlite && caffeine.state.session?.deadline == replacement,
                  "An old deadline stopped its replacement")
        try check(caffeine.start(.fifteenMinutes, now: Date().addingTimeInterval(-899.8)), "Could not shorten session")
        try check(caffeine.start(.untilTurnedOff), "Could not remove deadline")
        try await Task.sleep(for: .milliseconds(400))
        try check(caffeine.state.spotlite && caffeine.state.session?.deadline == nil,
                  "A canceled deadline stopped an indefinite session")
        try check(caffeine.start(.fifteenMinutes, now: Date().addingTimeInterval(-899.8)), "Could not schedule expiry")
        try await Task.sleep(for: .milliseconds(500))
        try check(!caffeine.state.spotlite, "Timed assertion did not expire")
        checkDevMessage(ToastMessage.caffeineFinished(succeeded: true, state: caffeine.state).text)
        try check(caffeine.start(.fifteenMinutes, now: Date().addingTimeInterval(-901)), "Could not start expired fixture")
        try check(!caffeine.state.spotlite, "Refresh did not handle an expired session")
        checkDevMessage(ToastMessage.caffeineFinished(succeeded: true, state: caffeine.state).text)
        let expirationContent = panel?.contentView
        caffeine.refresh()
        try check(panel?.contentView === expirationContent, "Refresh repeated the expiration message")
        // A resume after the deadline must release immediately, without needing ticks.
        let now = Date()
        try check(caffeine.start(.fifteenMinutes, now: now), "Could not start wake fixture")
        caffeine.expireIfNeeded(now: now.addingTimeInterval(2400))
        try check(!caffeine.state.spotlite, "Sleep extended the session")
        try check(NSApp.keyWindow === keyWindow && NSApp.isActive == active, "Expiry took focus")
        print("DEV caffeine: deadline replacement, cancellation, timer/refresh expiry, single feedback and elapsed sleep passed")

        let model = SettingsModel(preferences: Preferences(), library: AppLibrary(directories: []),
                                  savePreferences: { _ in })
        let settings = AppearanceSettingsViewController(model: model)
        let page = settings.view
        page.setFrameSize(page.fittingSize)
        page.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let picker = descendants(page).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles == ToastPosition.allCases.map(\.title) }!
        try check(picker.titleOfSelectedItem == "Bottom Center", "Wrong placement default")
        let confirmations = descendants(page).compactMap { $0 as? NSButton }
            .first { $0.title == "Show confirmation messages" }!
        try check(confirmations.state == .on, "Confirmations must default on")
        confirmations.performClick(nil)
        try check(!model.preferences.showConfirmationMessages, "Confirmation control did not persist")
        model.onToast = { [weak self, weak model] message in
            guard let model else { return }
            self?.show(message, position: model.preferences.toastPosition)
        }
        showConfirmationMessages = false
        for (index, position) in ToastPosition.allCases.enumerated() {
            picker.selectItem(at: index)
            picker.sendAction(picker.action, to: picker.target)
            try check(model.preferences.toastPosition == position, "Placement control did not update preferences")
            checkDevMessage("Messages will appear here")
        }
        showConfirmationMessages = true
        let pickerFrame = picker.convert(picker.bounds, to: page)
        try check(page.bounds.contains(pickerFrame), "Placement control escaped Settings")
        print("DEV toast: Appearance page=\(page.frame) position picker=\(pickerFrame)")
        try await SettingsForm.capture(page, name: "appearance")

        var visibilityMessages: [ToastMessage] = []
        model.onToast = { visibilityMessages.append($0) }
        let items = ItemsSettingsViewController(model: model)
        items.setApps([])
        let itemsPage = items.view
        itemsPage.setFrameSize(itemsPage.fittingSize)
        itemsPage.layoutSubtreeIfNeeded()
        let table = descendants(itemsPage).compactMap { $0 as? NSTableView }.first!
        let itemRow = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! SettingsRowView
        let checkbox = descendants(itemRow).compactMap { $0 as? NSButton }.first!
        checkbox.performClick(nil)
        let refreshedRow = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! SettingsRowView
        descendants(refreshedRow).compactMap { $0 as? NSButton }.first!.performClick(nil)
        try check(visibilityMessages.count == 2 && visibilityMessages[0].text.hasPrefix("Hidden ")
                  && visibilityMessages[1].text.hasPrefix("Restored "), "Settings visibility feedback missing")

        show(.visibility("Fixture", hidden: true), position: .bottomCenter, on: screen)
        let reusedWindow = panel
        try await Task.sleep(for: .milliseconds(1200))
        show(.copied(succeeded: true), position: .topRight, on: screen)
        try check(panel === reusedWindow, "Messages stacked instead of replacing")
        try await Task.sleep(for: .milliseconds(1100))
        checkDevMessage("Copied to clipboard")
        try await Task.sleep(for: .milliseconds(1200))
        try check(panel == nil && dismissal == nil, "Toast did not dismiss and release its resources")

        show(.copied(succeeded: true), position: .bottomCenter, on: screen)
        try await Task.sleep(for: .milliseconds(2040))
        show(.copied(succeeded: true), position: .bottomCenter, on: screen)
        try await Task.sleep(for: .milliseconds(250))
        checkDevMessage("Copied to clipboard")
        let layer = panel!.contentView!.layer!
        let opacity = layer.presentation()?.opacity ?? layer.opacity
        try check(opacity > 0.99, "A stale fade dimmed the replacement: opacity=\(opacity)")
        dismiss()
        try await Task.sleep(for: .milliseconds(170))
        try check(panel == nil && dismissal == nil, "Explicit dismissal left work behind")
        print("DEV toast: focus, placement, wrapping, copy, caffeine, Settings, replacement, fades and cleanup passed")
    }

    func checkDevMessage(_ text: String) {
        precondition(panel?.isVisible == true)
        precondition((panel?.contentView as? ToastView)?.label.stringValue == text)
    }
}
#endif
