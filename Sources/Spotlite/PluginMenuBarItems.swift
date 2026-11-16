import AppKit
import SpotliteCore

/// The menu-bar items of plugin looks that ask for one, such as Caffeinate's cup while
/// it keeps the display awake. An item exists only while its look lasts, and its menu
/// is built when clicked: with no such look, this holds nothing.
@MainActor
final class PluginMenuBarItems: NSObject, NSMenuDelegate {
    private var items: [String: NSStatusItem] = [:]
    /// What each item was last drawn from, so a refresh redraws only what changed.
    private var drawn: [String: PluginLooks.Look] = [:]
    private var hidden: Set<String> = []
    private var disabled: Set<String> = []

    /// An action picked in a menu, after any confirmation.
    var onPerform: ((PluginSecondaryAction, InstalledPlugin, String) -> Void)?

    private let host: PluginHost

    init(host: PluginHost = .shared) {
        self.host = host
    }

    /// Draws the items for the host's looks. `hidden` are plugins kept out of the menu
    /// bar; `disabled` are switched off, whose items stay while their process runs.
    func refresh(hidden: Set<String>, disabled: Set<String>) {
        // Called on every preference change; most leave these alone.
        guard hidden != self.hidden || disabled != self.disabled else { return }
        self.hidden = hidden
        self.disabled = disabled
        refresh()
    }

    func refresh() {
        let now = Date()
        var wanted: [String: PluginLooks.Look] = [:]
        for (id, look) in host.looks.looks where look.update.menuBar != nil && !hidden.contains(look.pluginID) {
            guard !look.update.hasExpired(at: now) else { continue }
            // A switched-off plugin's look stays only while there is a process to stop.
            if !isAvailable(look, entryID: id), look.process == nil { continue }
            wanted[id] = look
        }
        for id in items.keys where wanted[id] == nil {
            // Dropping the reference is not enough; the item must be removed explicitly.
            if let item = items.removeValue(forKey: id) { NSStatusBar.system.removeStatusItem(item) }
            drawn[id] = nil
        }
        // In key order, so items added together keep one order across launches.
        for (id, look) in wanted.sorted(by: { $0.key < $1.key }) where drawn[id] != look {
            let item = items[id] ?? makeItem(entryID: id)
            items[id] = item
            draw(item, look: look, entryID: id)
            drawn[id] = look
        }
    }

    private func makeItem(entryID: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Keeps a position the user ⌘-dragged it to with this look, not with whichever
        // transient item gets the next generated name.
        item.autosaveName = "plugin." + entryID
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        return item
    }

    private func draw(_ item: NSStatusItem, look: PluginLooks.Look, entryID: String) {
        guard let button = item.button else { return }
        let description = summary(of: look)
        button.image = image(for: look, entryID: entryID, description: description)
        button.imagePosition = .imageOnly
        button.toolTip = description
        item.menu?.identifier = NSUserInterfaceItemIdentifier(entryID)
    }

    /// The subtitle, or the command's title when the plugin gave none.
    private func summary(of look: PluginLooks.Look) -> String {
        look.update.displaySubtitle() ?? look.commandTitle
    }

    private func image(for look: PluginLooks.Look, entryID: String, description: String) -> NSImage? {
        let raw = look.update.icon ?? host.command(forEntryID: entryID)?.command.icon
        let icon = raw.map { PluginIcon($0, directory: look.directory) } ?? .symbol(PluginHost.fallbackSymbol)
        switch icon {
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            let image = (NSImage(systemSymbolName: name, accessibilityDescription: description)
                ?? NSImage(systemSymbolName: PluginHost.fallbackSymbol, accessibilityDescription: description))?
                .withSymbolConfiguration(configuration)
            image?.isTemplate = true
            return image
        case .file(let url):
            let image = PluginIcon.imageExtensions.contains(url.pathExtension.lowercased())
                ? NSImage(contentsOf: url) : NSWorkspace.shared.icon(forFile: url.path)
            image?.size = NSSize(width: 18, height: 18)
            image?.accessibilityDescription = description
            return image
        }
    }

    /// Whether the look's plugin is installed, switched on and still has its command.
    private func isAvailable(_ look: PluginLooks.Look, entryID: String) -> Bool {
        !disabled.contains(look.pluginID) && host.command(forEntryID: entryID) != nil
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let id = menu.identifier?.rawValue else { return }
        guard let look = host.looks.look(for: id, at: Date()) else {
            // The deadline passed before the timer or the wake caught it.
            menu.addItem(note("Ended"))
            DispatchQueue.main.async { [host] in host.expireLooks() }
            return
        }
        menu.addItem(note(summary(of: look)))
        let available = isAvailable(look, entryID: id)
        if !available {
            let text = if host.plugin(id: look.pluginID) == nil { "\(look.pluginName) is no longer installed" }
                else if disabled.contains(look.pluginID) { "\(look.pluginName) is switched off" }
                else { "\(look.pluginName) no longer has this command" }
            menu.addItem(note(text))
        }
        let actions = look.update.menuBar?.actions ?? []
        if !actions.isEmpty {
            menu.addItem(.separator())
            for action in actions {
                let entry = NSMenuItem(title: action.title, action: available ? #selector(performAction(_:)) : nil,
                                       keyEquivalent: "")
                entry.target = self
                // The action itself: a run may replace the look while the menu is open.
                entry.representedObject = MenuAction(entryID: id, action: action)
                // Autoenabling would also grey it out, but only once the menu is shown.
                entry.isEnabled = available
                if let symbol = action.icon, !symbol.contains("/") {
                    entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
                menu.addItem(entry)
            }
        }
        if !available, look.process != nil {
            menu.addItem(.separator())
            let stop = NSMenuItem(title: "Stop", action: #selector(stopProcess(_:)), keyEquivalent: "")
            stop.target = self
            stop.representedObject = id
            menu.addItem(stop)
        }
    }

    private func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let picked = sender.representedObject as? MenuAction,
              let (plugin, command) = host.command(forEntryID: picked.entryID) else { return }
        let action = picked.action
        if let confirm = action.confirm, !ask(confirm) { return }
        onPerform?(action, plugin, command.id)
    }

    private final class MenuAction {
        let entryID: String
        let action: PluginSecondaryAction
        init(entryID: String, action: PluginSecondaryAction) {
            self.entryID = entryID
            self.action = action
        }
    }

    @objc private func stopProcess(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        host.stopProcess(forEntryID: id)
    }

    /// The panel's in-place question needs the panel; the menu bar asks with an alert.
    /// The alert needs focus, which always goes back: the panel, if it opens next, takes
    /// keys without activating Spotlite, so the previous app gets them again on close.
    private func ask(_ confirmation: PluginConfirmation) -> Bool {
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message ?? ""
        let button = alert.addButton(withTitle: confirmation.button)
        button.hasDestructiveAction = confirmation.isDestructive
        alert.addButton(withTitle: "Cancel")
        if confirmation.isDestructive { alert.alertStyle = .warning }
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if previous?.processIdentifier != getpid() { previous?.activate() }
        return confirmed
    }

    #if DEBUG
    /// Dev checks read what an item shows.
    func devItem(forEntryID id: String) -> NSStatusItem? { items[id] }
    var devItemCount: Int { items.count }
    #endif
}
