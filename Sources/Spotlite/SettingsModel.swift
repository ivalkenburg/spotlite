import AppKit
import SpotliteCore

/// The one copy of the preferences every Settings tab edits. Each tab holding its own
/// copy would let one tab's save overwrite another's edits with stale values.
@MainActor
final class SettingsModel {
    var preferences: Preferences
    let library: AppLibrary
    private let savePreferences: (Preferences) -> Void

    var onChange: ((Preferences) -> Void)?
    var onHotKeyChange: ((UInt32, UInt32) -> Bool)?

    init(preferences: Preferences, library: AppLibrary,
         savePreferences: @escaping (Preferences) -> Void = { Storage.save($0) }) {
        self.preferences = preferences
        self.library = library
        self.savePreferences = savePreferences
    }

    func aliasWarning(for alias: String, excluding id: String?) -> String? {
        let ids = AliasConflicts.conflictingIDs(for: alias, excluding: id, aliases: preferences.aliases)
        guard !ids.isEmpty else { return nil }
        let names = ids.map { id in library.entries.first(where: { $0.id == id })?.name ?? id }
        return "Alias also used by " + names.joined(separator: ", ") + "."
    }

    func persist() {
        savePreferences(preferences)
        onChange?(preferences)
    }

    func set<T>(_ keyPath: WritableKeyPath<Preferences, T>, _ value: T) {
        preferences[keyPath: keyPath] = value
        persist()
    }
}

/// A Settings tab. Every tab edits the one shared model.
@MainActor
class SettingsPaneController: NSViewController {
    let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Building blocks for the form tabs: right-aligned labels, left-aligned controls, and
/// small secondary text under the control it explains.
@MainActor
enum SettingsForm {
    /// Every tab shares the width, so switching tabs only ever animates the height.
    static let width: CGFloat = 480
    private static let inset: CGFloat = 20
    /// Wide enough for the control column beside the longest label.
    private static let hintWidth: CGFloat = 280

    static func hint(_ text: String, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = color
        label.preferredMaxLayoutWidth = hintWidth
        return label
    }

    /// Controls stacked in one grid cell: a checkbox group, or a control and its hint.
    /// Hidden views drop out of the stack, so a warning takes no room until it shows.
    static func column(_ views: [NSView], spacing: CGFloat = 4) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = spacing
        return stack
    }

    /// Label and control pairs. The labels' first baselines line up with the first line
    /// of their controls, however tall the control's cell grows.
    static func grid(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { title, control in
            [NSTextField(labelWithString: title), control]
        })
        grid.rowSpacing = 16
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        return grid
    }

    /// A tab's root view: the grid centred, and an optional footer at the bottom right.
    static func page(_ grid: NSGridView, footer: NSView? = nil) -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(grid)
        var constraints = [
            root.widthAnchor.constraint(equalToConstant: width),
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            grid.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: inset),
        ]
        if let footer {
            footer.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(footer)
            constraints += [
                footer.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: inset),
                footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
                footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
            ]
        } else {
            constraints.append(grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset))
        }
        NSLayoutConstraint.activate(constraints)
        return root
    }
}
