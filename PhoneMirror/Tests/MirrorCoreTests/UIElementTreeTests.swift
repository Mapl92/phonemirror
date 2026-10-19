// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import MirrorCore
import Testing

@Suite struct UIElementTreeTests {
    let screen = CGRect(x: 0, y: 0, width: 393, height: 852)

    /// Synthetischer WDA-Baum wie von `/source?format=json` (Booleans als "1"/"0").
    let json: [String: Any] = [
        "type": "Application", "label": "Einstellungen", "isVisible": "1", "isEnabled": "1",
        "rect": ["x": 0, "y": 0, "width": 393, "height": 852],
        "children": [
            ["type": "Window", "isVisible": "1", "rect": ["x": 0, "y": 0, "width": 393, "height": 852], "children": [
                ["type": "Other", "isVisible": "1", "rect": ["x": 0, "y": 0, "width": 393, "height": 852], "children": [
                    ["type": "StaticText", "label": "Einstellungen", "isVisible": "1", "rect": ["x": 20, "y": 100, "width": 200, "height": 40]],
                    ["type": "Cell", "label": "WLAN", "value": "Heimnetz", "isVisible": "1", "isEnabled": "1", "rect": ["x": 0, "y": 300, "width": 393, "height": 44]],
                    ["type": "Button", "label": "WLAN Info", "isVisible": "1", "isEnabled": "0", "rect": ["x": 350, "y": 305, "width": 30, "height": 30]],
                    ["type": "Cell", "label": "Bluetooth", "isVisible": "0", "rect": ["x": 0, "y": 900, "width": 393, "height": 44]],
                    ["type": "SearchField", "name": "Suchen", "isVisible": "1", "rect": ["x": 16, "y": 790, "width": 361, "height": 36]],
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
        #expect(cell.label == "WLAN" && cell.value == "Heimnetz")
        #expect(cell.rect == CGRect(x: 0, y: 300, width: 393, height: 44))
        #expect(root.children[0].children[0].children[2].isEnabled == false)
    }

    @Test func flattensAndSkipsStructureAndHidden() {
        let types = list.entries.map(\.element.type)
        // Application hat ein Label und bleibt; Window/Other ohne Label fallen weg; Bluetooth ist unsichtbar.
        #expect(types == ["Application", "StaticText", "Cell", "Button", "SearchField"])
        #expect(list.entries.map(\.id) == [1, 2, 3, 4, 5])
        #expect(!list.outline().contains("Bluetooth"))
        #expect(list.outline().contains("[3] Cell \"WLAN\" value=\"Heimnetz\" @(0,300 393×44)"))
        #expect(list.outline().contains("(disabled)"))
    }

    @Test func searchAndBestMatch() throws {
        #expect(list.search(text: "wlan").count == 2)
        #expect(list.search(text: "wlan", type: "button").count == 1)
        let best = try #require(list.bestMatch(text: "WLAN"))
        #expect(best.element.type == "Cell") // exakte Beschriftung schlägt Teiltreffer
        #expect(best.element.center == CGPoint(x: 196.5, y: 322))
        #expect(list.bestMatch(text: "Suchen")?.element.type == "SearchField")
        #expect(list.element(id: 2)?.label == "Einstellungen")
    }

    /// Wie in den iOS-27-Einstellungen: „Allgemein“ ist ein Button mit gleichnamigem StaticText darin –
    /// getippt werden soll der Button, nicht der (kleinere) Text.
    @Test func interactiveElementWinsOverText() throws {
        let root = UIElement(type: "Application", rect: screen, children: [
            UIElement(type: "Button", label: "Allgemein", rect: CGRect(x: 16, y: 404, width: 361, height: 53), children: [
                UIElement(type: "StaticText", label: "Allgemein", rect: CGRect(x: 30, y: 416, width: 117, height: 28)),
            ]),
        ])
        let list = UIElementList(root: root, screen: screen)
        #expect(list.bestMatch(text: "allgemein")?.element.type == "Button")
        #expect(list.bestMatch(text: "Allgemein", type: "Cell") == nil)
    }

    @Test func clientBuildsIPv6URL() {
        #expect(WebDriverAgentClient(host: "fd00:1234:5678::1").baseURL.absoluteString == "http://[fd00:1234:5678::1]:8100")
        #expect(WebDriverAgentClient(host: "192.168.0.2", port: 9000).baseURL.absoluteString == "http://192.168.0.2:9000")
    }
}
