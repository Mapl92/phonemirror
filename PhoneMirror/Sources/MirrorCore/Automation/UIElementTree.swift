// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// Ein Bedienelement aus dem Accessibility-Baum (WebDriverAgent `/source?format=json`).
/// Koordinaten in Bildschirmpunkten – derselbe Raum wie Screenshots und Touch-Werkzeuge.
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

    /// Baut einen Knoten aus WDAs JSON (Booleans kommen als "1"/"0").
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

    /// Anzeigetext: Label, sonst Name, sonst Identifier.
    public var title: String? { label ?? name ?? identifier }
    public var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}

/// Flache, nummerierte Sicht auf den Baum – so können Agents per ID auf Elemente zeigen.
public struct UIElementList: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var id: Int
        public var depth: Int
        public var element: UIElement
    }

    public var entries: [Entry]

    /// Container ohne eigene Beschriftung (Typ „Other“, Fenster, Gruppen) werden übersprungen, ihre Kinder
    /// rücken auf. Unsichtbare oder flächenlose Elemente fallen weg, wenn `visibleOnly` gesetzt ist.
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

    /// Sucht nach Text (Teilstring, ohne Groß/Klein) in Label, Name, Wert und Identifier, optional nach Typ.
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

    /// Bestes Ziel für „tippe auf X“: exakte Beschriftung vor Teiltreffer, aktive vor inaktiven,
    /// bedienbare Elemente (Button, Cell, …) vor reinem Text, dann die kleinste Fläche.
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

    /// Kompakte Textdarstellung, eine Zeile pro Element.
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
        if entries.count > limit { lines.append("… \(entries.count - limit) weitere Elemente") }
        return lines.joined(separator: "\n")
    }
}

extension UIElementList {
    public static let textInputTypes: Set<String> = ["TextField", "SecureTextField", "SearchField", "TextView"]

    /// Trefferliste wie im Outline-Format, ohne Einrückung.
    public static func describe(_ entries: [Entry]) -> String {
        UIElementList(entries: entries.map { Entry(id: $0.id, depth: 0, element: $0.element) }).outline()
    }

    init(entries: [Entry]) {
        self.entries = entries
    }
}
