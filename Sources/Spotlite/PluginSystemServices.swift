import AppKit
import IOKit.pwr_mgt
import SpotliteCore

/// Native resource primitives. Feature policy, labels, refresh cadence and actions
/// belong to the plugin that owns each resource.
@MainActor
final class PluginSystemServices {
    private var assertions: [String: [String: IOPMAssertionID]] = [:]
    private var indicators: [String: [String: PluginStatusItem]] = [:]
    var onEvent: ((String, PluginValue) -> Void)?

    func hasResources(_ owner: String) -> Bool {
        !(assertions[owner] ?? [:]).isEmpty || !(indicators[owner] ?? [:]).isEmpty
    }
    func cleanup(_ owner: String) {
        for value in assertions.removeValue(forKey: owner)?.values ?? Dictionary<String, IOPMAssertionID>().values {
            IOPMAssertionRelease(value)
        }
        for indicator in indicators.removeValue(forKey: owner)?.values ?? Dictionary<String, PluginStatusItem>().values {
            indicator.remove()
        }
    }
    func createAssertion(owner: String, id: String?, type: String, name: String) throws -> PluginValue {
        let handle = id ?? UUID().uuidString
        if assertions[owner]?[handle] != nil { return .string(handle) }
        var native = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &native)
        guard status == kIOReturnSuccess else { throw PluginError.failed("Power assertion failed (\(status)).") }
        assertions[owner, default: [:]][handle] = native
        return .string(handle)
    }
    func getAssertion(owner: String, handle: String) -> PluginValue { .bool(assertions[owner]?[handle] != nil) }
    func releaseAssertion(owner: String, handle: String) throws -> PluginValue {
        guard let native = assertions[owner]?[handle] else { return .bool(false) }
        let status = IOPMAssertionRelease(native)
        guard status == kIOReturnSuccess else { throw PluginError.failed("Power assertion release failed (\(status)).") }
        assertions[owner]?.removeValue(forKey: handle)
        return .bool(true)
    }
    func listAssertions() throws -> PluginValue {
        var unmanaged: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&unmanaged)
        guard status == kIOReturnSuccess,
              let source = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            throw PluginError.failed("Could not read power assertions (\(status)).")
        }
        var rows: [PluginValue] = []
        for (pid, entries) in source {
            for entry in entries {
                rows.append(.object([
                    "pid": .number(pid.doubleValue),
                    "process": .string(entry["Process Name"] as? String ?? ""),
                    "type": .string(entry[kIOPMAssertionTypeKey as String] as? String ?? ""),
                    "name": .string(entry[kIOPMAssertionNameKey as String] as? String ?? ""),
                    "level": .number((entry[kIOPMAssertionLevelKey as String] as? NSNumber)?.doubleValue ?? 0)
                ]))
            }
        }
        return .array(rows)
    }
    func setIndicator(owner: String, value: PluginValue) throws -> PluginValue {
        guard let id = value["id"].string, !id.isEmpty else { throw PluginError.invalid("Status items need an ID.") }
        let indicator: PluginStatusItem
        if let existing = indicators[owner]?[id] { indicator = existing }
        else {
            indicator = PluginStatusItem(id: id) { [weak self] event in self?.onEvent?(owner, event) }
            indicators[owner, default: [:]][id] = indicator
        }
        indicator.apply(value)
        return .bool(true)
    }
    func removeIndicator(owner: String, id: String) -> PluginValue {
        indicators[owner]?.removeValue(forKey: id)?.remove()
        return .bool(true)
    }
    func getIndicator(owner: String, id: String) -> PluginValue { indicators[owner]?[id]?.value ?? .null }
}

@MainActor
private final class PluginStatusItem: NSObject, NSMenuDelegate {
    private let id: String
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let event: (PluginValue) -> Void
    private(set) var value: PluginValue = .null

    init(id: String, event: @escaping (PluginValue) -> Void) {
        self.id = id; self.event = event
        super.init()
        menu.autoenablesItems = false; menu.delegate = self
        item.menu = menu
    }
    func apply(_ value: PluginValue) {
        self.value = value
        let tooltip = value["tooltip"].string ?? ""
        let image = NSImage(systemSymbolName: value["icon"].string ?? "puzzlepiece.extension", accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = tooltip
        menu.removeAllItems()
        for entry in value["menu"].array ?? [] {
            if entry["separator"].bool == true { menu.addItem(.separator()); continue }
            let row = NSMenuItem(title: entry["title"].string ?? "", action: nil, keyEquivalent: "")
            if let action = entry["id"].string {
                row.target = self; row.action = #selector(activate)
                row.representedObject = action
            }
            row.isEnabled = entry["enabled"].bool ?? (row.action != nil)
            menu.addItem(row)
        }
    }
    func remove() { NSStatusBar.system.removeStatusItem(item) }
    func menuWillOpen(_ menu: NSMenu) { event(.object(["type": .string("status.open"), "status": .string(id)])) }
    @objc private func activate(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        event(.object(["type": .string("status.action"), "status": .string(id), "action": .string(action)]))
    }
}
