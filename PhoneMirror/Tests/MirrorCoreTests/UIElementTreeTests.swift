// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import MirrorCore
import Testing

@Suite struct UIElementTreeTests {
    let screen = CGRect(x: 0, y: 0, width: 393, height: 852)

    /// Synthetic WDA tree as from `/source?format=json` (booleans as "1"/"0").
    let json: [String: Any] = [
        "type": "Application", "label": "Settings", "isVisible": "1", "isEnabled": "1",
        "rect": ["x": 0, "y": 0, "width": 393, "height": 852],
        "children": [
            ["type": "Window", "isVisible": "1", "rect": ["x": 0, "y": 0, "width": 393, "height": 852], "children": [
                ["type": "Other", "isVisible": "1", "rect": ["x": 0, "y": 0, "width": 393, "height": 852], "children": [
                    ["type": "StaticText", "label": "Settings", "isVisible": "1", "rect": ["x": 20, "y": 100, "width": 200, "height": 40]],
                    ["type": "Cell", "label": "Wi-Fi", "value": "Home Network", "isVisible": "1", "isEnabled": "1", "rect": ["x": 0, "y": 300, "width": 393, "height": 44]],
                    ["type": "Button", "label": "Wi-Fi Info", "isVisible": "1", "isEnabled": "0", "rect": ["x": 350, "y": 305, "width": 30, "height": 30]],
                    ["type": "Cell", "label": "Bluetooth", "isVisible": "0", "rect": ["x": 0, "y": 900, "width": 393, "height": 44]],
                    ["type": "SearchField", "name": "Search", "isVisible": "1", "rect": ["x": 16, "y": 790, "width": 361, "height": 36]],
                ]],
            ]],
        ],
    ]

    var list: UIElementList {
        UIElementList(root: UIElement(wdaJSON: json)!, screen: screen)
    }

    @Test func parsesWDAJSON() throws {
        let root = try #require(UIElement(wdaJSON: json))
        #expect(root.type == "Application")
        let cell = root.children[0].children[0].children[1]
        #expect(cell.label == "Wi-Fi" && cell.value == "Home Network")
        #expect(cell.rect == CGRect(x: 0, y: 300, width: 393, height: 44))
        #expect(root.children[0].children[0].children[2].isEnabled == false)
    }

    @Test func flattensAndSkipsStructureAndHidden() {
        let types = list.entries.map(\.element.type)
        // Application has a label and stays; Window/Other without a label are dropped; Bluetooth is invisible.
        #expect(types == ["Application", "StaticText", "Cell", "Button", "SearchField"])
        #expect(list.entries.map(\.id) == [1, 2, 3, 4, 5])
        #expect(!list.outline().contains("Bluetooth"))
        #expect(list.outline().contains("[3] Cell \"Wi-Fi\" value=\"Home Network\" @(0,300 393×44)"))
        #expect(list.outline().contains("(disabled)"))
    }

    @Test func searchAndBestMatch() throws {
        #expect(list.search(text: "wi-fi").count == 2)
        #expect(list.search(text: "wi-fi", type: "button").count == 1)
        let best = try #require(list.bestMatch(text: "Wi-Fi"))
        #expect(best.element.type == "Cell") // exact label beats partial match
        #expect(best.element.center == CGPoint(x: 196.5, y: 322))
        #expect(list.bestMatch(text: "Search")?.element.type == "SearchField")
        #expect(list.element(id: 2)?.label == "Settings")
    }

    /// As in the iOS 27 Settings app: “General” is a button with a StaticText of the same name inside –
    /// the button should be tapped, not the (smaller) text.
    @Test func interactiveElementWinsOverText() throws {
        let root = UIElement(type: "Application", rect: screen, children: [
            UIElement(type: "Button", label: "General", rect: CGRect(x: 16, y: 404, width: 361, height: 53), children: [
                UIElement(type: "StaticText", label: "General", rect: CGRect(x: 30, y: 416, width: 117, height: 28)),
            ]),
        ])
        let list = UIElementList(root: root, screen: screen)
        #expect(list.bestMatch(text: "general")?.element.type == "Button")
        #expect(list.bestMatch(text: "General", type: "Cell") == nil)
    }

    @Test func clientBuildsIPv6URL() {
        #expect(WebDriverAgentClient(host: "fd00:1234:5678::1").baseURL.absoluteString == "http://[fd00:1234:5678::1]:8100")
        #expect(WebDriverAgentClient(host: "192.168.0.2", port: 9000).baseURL.absoluteString == "http://192.168.0.2:9000")
    }
}
