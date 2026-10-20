// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreImage
import MirrorCore
import MirrorMCP

/// MCP tools with which agents control the mirrored iPhone. All calls go through the window's
/// session – agent and human share the same connection and the same picture.
struct AgentTools: MCPToolProvider {
    let bridge: AgentBridge

    static let instructions = """
    Controls a real iPhone that is mirrored on this Mac. Preferred workflow: call `ui_tree` to get the accessibility \
    elements of the foreground app (numbered, with type, label, value and frame), then act with `tap_element` / \
    `type_into` by id or by visible text, and call `ui_tree` again to verify. Element ids are only valid until the \
    next `ui_tree`/`find_elements` call. Use `screenshot` when visual appearance matters or an element has no label \
    (icons, games, canvas content). All coordinates are in screen points with (0,0) at the top-left; the screenshot \
    image has exactly that size. UI animations take ~0.3–0.5 s; use `wait` if needed. Use \
    `system_action` for Home, App Switcher, Spotlight, Notification Center and Control Center (iOS ignores \
    injected swipes that start at the bottom edge). `type_text` pastes via the iPhone clipboard into the focused \
    text field. Prefer `launch_app` over searching the home screen when you know the bundle identifier.
    """

    func tools() async -> [MCPTool] {
        let point: [String: JSONValue] = [
            "x": ["type": "number", "description": "X in screen points (0 = left edge)"],
            "y": ["type": "number", "description": "Y in screen points (0 = top edge)"],
        ]
        return [
            MCPTool(name: "ui_tree", description: "Accessibility elements of the foreground app as a numbered outline: [id] Type \"label\" value=… @(x,y w×h). First call starts WebDriverAgent on the iPhone (up to ~40 s).",
                    properties: ["include_hidden": ["type": "boolean", "description": "Also list elements that are off-screen or invisible (default false)"]]),
            MCPTool(name: "find_elements", description: "Search the accessibility tree by text (substring of label/name/value/identifier) and/or element type (Button, Cell, TextField, Switch, …).",
                    properties: ["text": ["type": "string"], "type": ["type": "string"]]),
            MCPTool(name: "tap_element", description: "Tap the center of an element, given by id from the last ui_tree/find_elements or by visible text (best match).",
                    properties: ["id": ["type": "integer"], "text": ["type": "string"], "type": ["type": "string", "description": "Optional element type to disambiguate"]]),
            MCPTool(name: "type_into", description: "Tap a text field/search field (by id or text) and insert text.",
                    properties: [
                        "id": ["type": "integer"], "field": ["type": "string", "description": "Visible text/placeholder of the field"],
                        "text": ["type": "string"], "submit": ["type": "boolean"],
                    ], required: ["text"]),
            MCPTool(name: "screenshot", description: "Current iPhone screen as JPEG. Image size equals the coordinate space (screen points).",
                    properties: ["quality": ["type": "number", "description": "JPEG quality 0.1–1 (default 0.7)"]]),
            MCPTool(name: "device_info", description: "Connection state, screen size in points/pixels and orientation."),
            MCPTool(name: "tap", description: "Tap at a point.", properties: point, required: ["x", "y"]),
            MCPTool(name: "double_tap", description: "Double-tap at a point.", properties: point, required: ["x", "y"]),
            MCPTool(name: "long_press", description: "Touch and hold at a point (context menus, rearranging icons).",
                    properties: point.merging(["duration_ms": ["type": "number", "description": "Hold time, default 800"]]) { $1 },
                    required: ["x", "y"]),
            MCPTool(name: "swipe", description: "Drag from one point to another (scrolling, paging, sliders). Swipes starting at the very bottom edge are ignored by iOS – use system_action instead.",
                    properties: [
                        "from_x": ["type": "number"], "from_y": ["type": "number"],
                        "to_x": ["type": "number"], "to_y": ["type": "number"],
                        "duration_ms": ["type": "number", "description": "Default 300; longer = slower drag without momentum"],
                    ], required: ["from_x", "from_y", "to_x", "to_y"]),
            MCPTool(name: "type_text", description: "Insert text into the focused text field (any language/emoji; pastes via the iPhone clipboard, which is overwritten).",
                    properties: [
                        "text": ["type": "string"],
                        "submit": ["type": "boolean", "description": "Press Return afterwards (default false)"],
                    ], required: ["text"]),
            MCPTool(name: "press_key", description: "Press a hardware-keyboard key, optionally with modifiers (e.g. key=a, modifiers=[command] selects all).",
                    properties: [
                        "key": ["type": "string", "description": "return, escape, delete, forward_delete, tab, space, up, down, left, right, page_up, page_down, or a single letter/digit"],
                        "modifiers": ["type": "array", "items": ["type": "string", "enum": ["command", "shift", "option", "control"]]],
                    ], required: ["key"]),
            MCPTool(name: "press_button", description: "Press a hardware button.",
                    properties: ["button": ["type": "string", "enum": ["home", "lock", "volume_up", "volume_down", "siri"]]],
                    required: ["button"]),
            MCPTool(name: "system_action", description: "Reliable system navigation.",
                    properties: ["action": ["type": "string", "enum": ["home", "app_switcher", "spotlight", "notification_center", "control_center"]]],
                    required: ["action"]),
            MCPTool(name: "list_apps", description: "Installed apps (name and bundle identifier). Native connection only.",
                    properties: ["include_system": ["type": "boolean", "description": "Include Apple system apps (default true)"]]),
            MCPTool(name: "launch_app", description: "Open an app by bundle identifier (e.g. com.apple.Preferences). Native connection only.",
                    properties: ["bundle_id": ["type": "string"]], required: ["bundle_id"]),
            MCPTool(name: "get_clipboard", description: "Read the iPhone clipboard (text)."),
            MCPTool(name: "set_clipboard", description: "Write text to the iPhone clipboard.",
                    properties: ["text": ["type": "string"]], required: ["text"]),
            MCPTool(name: "wait", description: "Wait for animations or loading (max 10000 ms).",
                    properties: ["ms": ["type": "number"]], required: ["ms"]),
        ]
    }

    func call(_ name: String, arguments: JSONValue) async -> MCPToolResult {
        do {
            return try await perform(name, arguments)
        } catch {
            return .error("\(name) failed: \(error.localizedDescription)")
        }
    }

    private func perform(_ name: String, _ args: JSONValue) async throws -> MCPToolResult {
        switch name {
        case "screenshot":
            let quality = min(max(args["quality"]?.doubleValue ?? 0.7, 0.1), 1)
            let shot = try await bridge.screenshot(quality: quality)
            return MCPToolResult([
                .image(base64: shot.jpeg.base64EncodedString(), mimeType: "image/jpeg"),
                .text("Screenshot \(shot.width)×\(shot.height) points (= coordinate space), frame age \(shot.ageMilliseconds) ms."),
            ])
        case "device_info":
            return .text(await bridge.deviceInfo())
        case "ui_tree":
            let list = try await bridge.refreshTree(visibleOnly: !(args["include_hidden"]?.boolValue ?? false))
            return .text("\(list.entries.count) elements (ids valid until the next ui_tree/find_elements):\n" + list.outline())
        case "find_elements":
            let text = args["text"]?.stringValue, type = args["type"]?.stringValue
            guard text != nil || type != nil else { return .error("Specify text or type.") }
            let matches = try await bridge.refreshTree(visibleOnly: true).search(text: text, type: type)
            guard !matches.isEmpty else { return .text("No matching elements.") }
            return .text(UIElementList.describe(matches))
        case "tap_element":
            let entry = try await bridge.resolveElement(id: args["id"]?.intValue, text: args["text"]?.stringValue, type: args["type"]?.stringValue)
            try await bridge.tap(entry.element.center)
            return .text("Tapped [\(entry.id)] \(entry.element.type) \"\(entry.element.title ?? "")\" at (\(Int(entry.element.center.x)), \(Int(entry.element.center.y))).")
        case "type_into":
            guard let text = args["text"]?.stringValue else { return .error("text is missing.") }
            let entry = try await bridge.resolveElement(id: args["id"]?.intValue, text: args["field"]?.stringValue, type: nil, preferTextInput: true)
            try await bridge.tap(entry.element.center)
            try await Task.sleep(for: .milliseconds(400))
            try await bridge.typeText(text, submit: args["submit"]?.boolValue ?? false)
            return .text("Inserted \(text.count) characters into [\(entry.id)] \(entry.element.type) \"\(entry.element.title ?? "")\".")
        case "tap":
            let p = try point(args)
            try await bridge.tap(p)
            return .text("Tapped (\(Int(p.x)), \(Int(p.y))).")
        case "double_tap":
            let p = try point(args)
            try await bridge.tap(p)
            try await Task.sleep(for: .milliseconds(90))
            try await bridge.tap(p)
            return .text("Double-tapped (\(Int(p.x)), \(Int(p.y))).")
        case "long_press":
            let p = try point(args)
            try await bridge.tap(p, hold: Double(args["duration_ms"]?.doubleValue ?? 800) / 1000)
            return .text("Long-pressed (\(Int(p.x)), \(Int(p.y))).")
        case "swipe":
            guard let fx = args["from_x"]?.doubleValue, let fy = args["from_y"]?.doubleValue,
                  let tx = args["to_x"]?.doubleValue, let ty = args["to_y"]?.doubleValue
            else { return .error("from_x, from_y, to_x and to_y are required.") }
            let duration = min(max(args["duration_ms"]?.doubleValue ?? 300, 50), 5000) / 1000
            try await bridge.swipe(from: CGPoint(x: fx, y: fy), to: CGPoint(x: tx, y: ty), duration: duration)
            return .text("Swiped (\(Int(fx)), \(Int(fy))) → (\(Int(tx)), \(Int(ty))).")
        case "type_text":
            guard let text = args["text"]?.stringValue else { return .error("text is missing.") }
            try await bridge.typeText(text, submit: args["submit"]?.boolValue ?? false)
            return .text("Inserted \(text.count) characters.")
        case "press_key":
            guard let key = args["key"]?.stringValue, let usage = AgentKeys.usage(for: key) else {
                return .error("Unknown key. Allowed: \(AgentKeys.names.joined(separator: ", ")) or a single letter/digit.")
            }
            let modifiers = try (args["modifiers"]?.arrayValue ?? []).map { value -> UInt16 in
                guard let name = value.stringValue, let usage = AgentKeys.modifiers[name] else { throw AgentError("Unknown modifier.") }
                return usage
            }
            try await bridge.pressKey(usage, modifiers: modifiers)
            return .text("Pressed \(key).")
        case "press_button":
            guard let raw = args["button"]?.stringValue, let button = AgentKeys.buttons[raw] else { return .error("Unknown button.") }
            try await bridge.send([.button(button, isDown: true), .button(button, isDown: false)])
            return .text("Pressed \(raw).")
        case "system_action":
            guard let action = args["action"]?.stringValue else { return .error("action is missing.") }
            try await bridge.systemAction(action)
            return .text("Performed \(action).")
        case "list_apps":
            let includeSystem = args["include_system"]?.boolValue ?? true
            let apps = try await bridge.installedApps().filter { includeSystem || !$0.isSystemApp }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return .text(apps.map { "\($0.name) — \($0.bundleID)" }.joined(separator: "\n"))
        case "launch_app":
            guard let bundleID = args["bundle_id"]?.stringValue else { return .error("bundle_id is missing.") }
            try await bridge.launchApp(bundleID)
            return .text("Launched \(bundleID).")
        case "get_clipboard":
            switch try await bridge.clipboard() {
            case .text(let text): return .text(text)
            case .html, .rtf: return .text("(formatted text – not available as plain text)")
            case .png: return .text("(image in clipboard)")
            case nil: return .text("(empty)")
            }
        case "set_clipboard":
            guard let text = args["text"]?.stringValue else { return .error("text is missing.") }
            try await bridge.setClipboard(text)
            return .text("Clipboard set.")
        case "wait":
            let ms = min(max(args["ms"]?.doubleValue ?? 500, 0), 10_000)
            try await Task.sleep(for: .milliseconds(Int(ms)))
            return .text("Waited \(Int(ms)) ms.")
        default:
            return .error("Unknown tool \(name).")
        }
    }

    private func point(_ args: JSONValue) throws -> CGPoint {
        guard let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue else { throw AgentError("x and y are required.") }
        return CGPoint(x: x, y: y)
    }
}

struct AgentError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Key names → HID usages (keyboard page) for `press_key`.
enum AgentKeys {
    static let named: [String: UInt16] = [
        "return": 0x28, "enter": 0x28, "escape": 0x29, "delete": 0x2A, "backspace": 0x2A, "tab": 0x2B, "space": 0x2C,
        "forward_delete": 0x4C, "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52, "page_up": 0x4B, "page_down": 0x4E,
    ]
    static var names: [String] { named.keys.sorted() }
    static let modifiers: [String: UInt16] = ["control": 0xE0, "shift": 0xE1, "option": 0xE2, "command": 0xE3]
    static let buttons: [String: HardwareButton] = [
        "home": .home, "lock": .lock, "volume_up": .volumeUp, "volume_down": .volumeDown, "siri": .siri,
    ]

    static func usage(for key: String) -> UInt16? {
        let lower = key.lowercased()
        if let usage = named[lower] { return usage }
        guard lower.count == 1, let scalar = lower.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x61...0x7A: return UInt16(scalar.value - 0x61 + 0x04) // a–z
        case 0x31...0x39: return UInt16(scalar.value - 0x31 + 0x1E) // 1–9
        case 0x30: return 0x27 // 0
        default: return nil
        }
    }
}

/// Main-actor bridge between MCP tools and the window (session, latest frame, indicator).
@MainActor
final class AgentBridge {
    weak var controller: MirrorWindowController?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    struct Screenshot {
        var jpeg: Data
        var width: Int
        var height: Int
        var ageMilliseconds: Int
    }

    let wda = WDARunner()
    private var lastList: UIElementList?

    /// Tunnel address/UDID: from the native transport, otherwise via devicectl.
    private func endpoint() async throws -> DeviceEndpoint {
        if let endpoint = await controller?.activeSession?.deviceEndpoint() { return endpoint }
        guard let endpoint = await DevicePreparation.currentEndpoint() else {
            throw AgentError("Could not determine the iPhone's tunnel address (connected?).")
        }
        return endpoint
    }

    /// Start WDA if needed; for pre-warming in the background.
    func prepareWDA() async {
        guard controller?.activeSession != nil, let endpoint = try? await endpoint() else { return }
        _ = try? await wda.client(for: endpoint)
    }

    func refreshTree(visibleOnly: Bool) async throws -> UIElementList {
        controller?.noteAgentActivity(at: nil)
        let client = try await wda.client(for: try await endpoint())
        let root = try await client.source()
        let size = screen.pointSize
        let list = UIElementList(root: root, screen: CGRect(origin: .zero, size: size), visibleOnly: visibleOnly)
        lastList = list
        return list
    }

    func resolveElement(id: Int?, text: String?, type: String?, preferTextInput: Bool = false) async throws -> UIElementList.Entry {
        if let id {
            guard let entry = lastList?.entries.first(where: { $0.id == id }) else {
                throw AgentError("Element [\(id)] unknown – call ui_tree or find_elements first.")
            }
            return entry
        }
        let list = try await refreshTree(visibleOnly: true)
        if preferTextInput {
            let fields = list.entries.filter { UIElementList.textInputTypes.contains($0.element.type) }
            if let text, let match = fields.first(where: { [$0.element.label, $0.element.name, $0.element.value, $0.element.identifier].contains { $0?.localizedCaseInsensitiveContains(text) == true } }) {
                return match
            }
            if text == nil, let focused = fields.first { return focused }
        }
        guard let text else { throw AgentError("Specify id or text.") }
        if let match = list.bestMatch(text: text, type: type) { return match }
        // Type doesn't match (e.g. Button instead of Cell in iOS 27): search again without the type filter.
        if type != nil, let match = list.bestMatch(text: text) { return match }
        throw AgentError("No element with “\(text)” visible. Tip: call ui_tree, scroll if needed, then tap by id.")
    }

    private func session() throws -> any MirrorSession {
        guard let session = controller?.activeSession else { throw AgentError("Not connected to the iPhone.") }
        return session
    }

    /// The screen as the agent sees it (upright; width and height swapped in landscape).
    private var screen: DeviceScreen { controller?.displayedScreen ?? .iPhone15 }
    private var orientation: DeviceOrientation { controller?.orientation ?? .portrait }

    func deviceInfo() -> String {
        let screen = screen
        let connected = controller?.activeSession != nil
        let age = controller?.latestFrame.map { Int(Date().timeIntervalSince($0.time) * 1000) }
        return """
        connected: \(connected)
        connection: \(controller?.transportName ?? "-")
        screen: \(Int(screen.pointSize.width))×\(Int(screen.pointSize.height)) points (@\(Int(screen.scale))x, \(screen.pixelWidth)×\(screen.pixelHeight) px), \(orientation.rawValue)
        last frame: \(age.map { "\($0) ms ago" } ?? "none")
        accessibility (WebDriverAgent): \(wda.statusDescription)
        """
    }

    func screenshot(quality: Double) async throws -> Screenshot {
        guard let frame = controller?.latestFrame else { throw AgentError("No image from the iPhone yet.") }
        let size = screen.pointSize
        let upright = FrameRenderer.upright(frame.pixelBuffer, visible: frame.visible, orientation: orientation)
        let scaled = upright.transformed(by: CGAffineTransform(scaleX: size.width / upright.extent.width, y: size.height / upright.extent.height))
        guard let jpeg = ciContext.jpegRepresentation(
            of: scaled, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        ) else { throw AgentError("Screenshot could not be encoded.") }
        controller?.noteAgentActivity(at: nil)
        return Screenshot(jpeg: jpeg, width: Int(size.width), height: Int(size.height),
                          ageMilliseconds: Int(Date().timeIntervalSince(frame.time) * 1000))
    }

    func touchPoint(_ point: CGPoint) -> TouchPoint {
        let size = screen.pointSize
        let max = Double(TouchPoint.maxValue)
        return orientation.native(TouchPoint(
            x: UInt16((min(Swift.max(point.x / size.width, 0), 1) * max).rounded()),
            y: UInt16((min(Swift.max(point.y / size.height, 0), 1) * max).rounded())
        ))
    }

    func send(_ events: [InputEvent]) async throws {
        let session = try session()
        controller?.noteAgentActivity(at: nil)
        for event in events { try await session.send(event) }
    }

    func tap(_ point: CGPoint, hold: Double = 0.06) async throws {
        let session = try session()
        let touch = touchPoint(point)
        controller?.noteAgentActivity(at: touch)
        try await session.send(.touch(.began, touch))
        try await Task.sleep(for: .seconds(hold))
        try await session.send(.touch(.ended, touch))
    }

    func swipe(from: CGPoint, to: CGPoint, duration: Double) async throws {
        let session = try session()
        let steps = max(6, Int(duration / 0.016))
        let start = touchPoint(from)
        controller?.noteAgentActivity(at: start)
        try await session.send(.touch(.began, start))
        for step in 1...steps {
            try await Task.sleep(for: .seconds(duration / Double(steps)))
            let t = Double(step) / Double(steps)
            let point = touchPoint(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            try await session.send(.touch(step == steps ? .ended : .moved, point))
            controller?.noteAgentActivity(at: point)
        }
    }

    func pressKey(_ usage: UInt16, modifiers: [UInt16]) async throws {
        let down = modifiers.map { InputEvent.key(usage: $0, isDown: true) } + [.key(usage: usage, isDown: true)]
        let up = [InputEvent.key(usage: usage, isDown: false)] + modifiers.reversed().map { .key(usage: $0, isDown: false) }
        try await send(down)
        try await Task.sleep(for: .milliseconds(40))
        try await send(up)
    }

    /// Insert text via the clipboard (⌘V) – works for every language and keyboard layout.
    func typeText(_ text: String, submit: Bool) async throws {
        let session = try session()
        controller?.noteAgentActivity(at: nil)
        try await session.setClipboard(.text(text))
        try await Task.sleep(for: .milliseconds(250))
        try await pressKey(0x19, modifiers: [0xE3]) // ⌘V
        if submit {
            try await Task.sleep(for: .milliseconds(150))
            try await pressKey(0x28, modifiers: [])
        }
    }

    func systemAction(_ action: String) async throws {
        let size = screen.pointSize
        switch action {
        case "home":
            try await send([.button(.home, isDown: true), .button(.home, isDown: false)])
        case "app_switcher":
            try await send([.gesture(.appSwitcher)])
        case "spotlight":
            try await pressKey(0x2C, modifiers: [0xE3]) // ⌘Space
        case "notification_center":
            try await swipe(from: CGPoint(x: size.width / 2, y: 0), to: CGPoint(x: size.width / 2, y: size.height * 0.6), duration: 0.25)
        case "control_center":
            try await swipe(from: CGPoint(x: size.width - 20, y: 0), to: CGPoint(x: size.width - 20, y: size.height * 0.5), duration: 0.25)
        default:
            throw AgentError("Unknown action \(action).")
        }
    }

    func installedApps() async throws -> [InstalledApp] {
        try await session().installedApps()
    }

    func launchApp(_ bundleID: String) async throws {
        controller?.noteAgentActivity(at: nil)
        try await session().launchApp(bundleID: bundleID)
    }

    func clipboard() async throws -> ClipboardContent? {
        try await session().clipboardContent()
    }

    func setClipboard(_ text: String) async throws {
        try await session().setClipboard(.text(text))
    }
}
