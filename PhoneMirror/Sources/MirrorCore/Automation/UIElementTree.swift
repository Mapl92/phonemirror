// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// A UI element from the accessibility tree (WebDriverAgent `/source?format=json`).
/// Coordinates in screen points – the same space as screenshots and touch tools.
public struct UIElement: Sendable, Equatable {
    public var type: String
    public var label: String?
    public var name: String?
    public var value: String?
    public var identifier: String?
    public var rect: CGRect
    public var isEnabled: Bool
    public var isVisible: Bool
    public var children: [UIElement]

    public init(type: String, label: String? = nil, name: String? = nil, value: String? = nil, identifier: String? = nil,
                rect: CGRect, isEnabled: Bool = true, isVisible: Bool = true, children: [UIElement] = []) {
        self.type = type
        self.label = label
        self.name = name
        self.value = value
        self.identifier = identifier
        self.rect = rect
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.children = children
    }

    /// Builds a node from WDA's JSON (booleans arrive as "1"/"0").
    public init?(wdaJSON node: [String: Any]) {
        guard let type = node["type"] as? String else { return nil }
        func text(_ key: String) -> String? {
            guard let value = node[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        func flag(_ key: String) -> Bool {
            switch node[key] {
            case let string as String: string == "1" || string.lowercased() == "true"
            case let bool as Bool: bool
            case let number as NSNumber: number.boolValue
            default: true
            }
        }
        let rect = node["rect"] as? [String: Any] ?? [:]
        func number(_ key: String) -> Double { (rect[key] as? NSNumber)?.doubleValue ?? 0 }
        self.init(
            type: type,
            label: text("label"),
            name: text("name"),
            value: text("value"),
            identifier: text("rawIdentifier"),
            rect: CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height")),
            isEnabled: flag("isEnabled"),
            isVisible: flag("isVisible"),
            children: (node["children"] as? [[String: Any]] ?? []).compactMap(UIElement.init(wdaJSON:))
        )
    }

    /// Display text: label, otherwise name, otherwise identifier.
    public var title: String? { label ?? name ?? identifier }
    public var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}

/// Flat, numbered view of the tree – lets agents point at elements by ID.
public struct UIElementList: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var id: Int
        public var depth: Int
        public var element: UIElement
    }

    public var entries: [Entry]

    /// Containers without their own label (type “Other”, windows, groups) are skipped; their children
    /// move up. Invisible or zero-area elements are dropped when `visibleOnly` is set.
    public init(root: UIElement, screen: CGRect, visibleOnly: Bool = true) {
        var entries: [Entry] = []
        func visit(_ element: UIElement, depth: Int) {
            let onScreen = element.isVisible && element.rect.width > 0 && element.rect.height > 0 && element.rect.intersects(screen)
            let meaningful = element.title != nil || element.value != nil || Self.interactiveTypes.contains(element.type)
            let structural = Self.structuralTypes.contains(element.type) && element.title == nil
            let include = meaningful && !structural && (!visibleOnly || onScreen)
            if include {
                entries.append(Entry(id: entries.count + 1, depth: depth, element: element))
            }
            for child in element.children {
                visit(child, depth: include ? depth + 1 : depth)
            }
        }
        visit(root, depth: 0)
        self.entries = entries
    }

    static let structuralTypes: Set<String> = ["Application", "Window", "Other", "Group", "ScrollView", "Table", "CollectionView", "LayoutArea", "LayoutItem"]
    static let interactiveTypes: Set<String> = [
        "Button", "TextField", "SecureTextField", "SearchField", "TextView", "Switch", "Slider", "Cell", "Link",
        "Icon", "Key", "Tab", "SegmentedControl", "Stepper", "Picker", "PickerWheel", "MenuItem", "Toggle",
    ]

    public func element(id: Int) -> UIElement? {
        entries.first { $0.id == id }?.element
    }

    /// Searches for text (substring, case-insensitive) in label, name, value and identifier, optionally by type.
    public func search(text: String?, type: String? = nil) -> [Entry] {
        let needle = text?.lowercased()
        return entries.filter { entry in
            let element = entry.element
            if let type, element.type.lowercased() != type.lowercased() { return false }
            guard let needle, !needle.isEmpty else { return true }
            return [element.label, element.name, element.value, element.identifier]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(needle) }
        }
    }

    /// Best target for “tap on X”: exact label before partial match, enabled before disabled,
    /// operable elements (Button, Cell, …) before plain text, then the smallest area.
    public func bestMatch(text: String, type: String? = nil) -> Entry? {
        let lower = text.lowercased()
        return search(text: text, type: type).min { a, b in
            func score(_ entry: Entry) -> (Int, Int, Int, Double) {
                let e = entry.element
                let exact = [e.label, e.name, e.value].contains { $0?.lowercased() == lower } ? 0 : 1
                let interactive = Self.interactiveTypes.contains(e.type) ? 0 : 1
                return (exact, e.isEnabled ? 0 : 1, interactive, Double(e.rect.width * e.rect.height))
            }
            return score(a) < score(b)
        }
    }

    /// Compact text representation, one line per element.
    public func outline(limit: Int = 400) -> String {
        var lines = entries.prefix(limit).map { entry -> String in
            let e = entry.element
            var line = String(repeating: "  ", count: min(entry.depth, 8)) + "[\(entry.id)] \(e.type)"
            if let title = e.title { line += " \"\(title)\"" }
            if let value = e.value, value != e.title { line += " value=\"\(value)\"" }
            if !e.isEnabled { line += " (disabled)" }
            line += " @(\(Int(e.rect.minX)),\(Int(e.rect.minY)) \(Int(e.rect.width))×\(Int(e.rect.height)))"
            return line
        }
        if entries.count > limit { lines.append("… \(entries.count - limit) more elements") }
        return lines.joined(separator: "\n")
    }
}

extension UIElementList {
    public static let textInputTypes: Set<String> = ["TextField", "SecureTextField", "SearchField", "TextView"]

    /// Match list in the outline format, without indentation.
    public static func describe(_ entries: [Entry]) -> String {
        UIElementList(entries: entries.map { Entry(id: $0.id, depth: 0, element: $0.element) }).outline()
    }

    init(entries: [Entry]) {
        self.entries = entries
    }
}
