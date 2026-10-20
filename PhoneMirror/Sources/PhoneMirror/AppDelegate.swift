// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import MirrorCore
import MirrorMCP
import MirrorNative
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MirrorWindowController?
    private let agentBridge = AgentBridge()
    private var mcpServer: MCPHTTPServer?
    private var wdaWarmup: Task<Void, Never>?
    private var setupAssistant: SetupAssistantController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let controller = MirrorWindowController(transport: makeTransport())
        agentBridge.controller = controller
        if AppSettings.shared.mcpEnabled { startMCPServer() }
        windowController = controller
        controller.onSetupNeeded = { [weak self] in self?.openSetupAssistant(nil) }
        controller.showWindow(nil)
        controller.connect()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// On quit, close the session first so pymobiledevice3 stops the device stream cleanly.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        wdaWarmup?.cancel()
        agentBridge.wda.stop()
        guard let windowController else { return .terminateNow }
        Task {
            await windowController.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Source from the launch arguments (NSUserDefaults argument domain):
    /// `-replay <file.h265>` plays back a file, otherwise live via pymobiledevice3
    /// (`-pymobiledevice3 <path>` overrides the search for the executable).
    private func makeTransport() -> any MirrorTransport {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: "replay") {
            return FileReplayTransport(fileURL: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        switch AppSettings.shared.connection {
        case .native:
            return NativeTransport()
        case .serveWeb:
            let executable = defaults.string(forKey: "pymobiledevice3").map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
            }
            return ServeWebTransport(executable: executable)
        }
    }

    // MARK: - Menu

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit PhoneMirror", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenu: appMenu, title: "PhoneMirror")

        let deviceMenu = NSMenu(title: "Device")
        // ⌘1/⌘2/⌘3 as in Apple's iPhone Mirroring.
        deviceMenu.addItem(buttonItem("Home Screen", .home, key: "1", modifiers: [.command]))
        let switcher = NSMenuItem(title: "App Switcher", action: #selector(AppDelegate.showAppSwitcher(_:)), keyEquivalent: "2")
        deviceMenu.addItem(switcher)
        deviceMenu.addItem(withTitle: "Spotlight", action: #selector(AppDelegate.openSpotlight(_:)), keyEquivalent: "3")
        deviceMenu.addItem(.separator())
        deviceMenu.addItem(buttonItem("Lock", .lock, key: "l", modifiers: [.command]))
        deviceMenu.addItem(.separator())
        deviceMenu.addItem(buttonItem("Volume Up", .volumeUp, key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.command]))
        deviceMenu.addItem(buttonItem("Volume Down", .volumeDown, key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.command]))
        deviceMenu.addItem(.separator())
        let sound = NSMenuItem(title: "Sound from iPhone", action: #selector(AppDelegate.toggleSound(_:)), keyEquivalent: "t")
        sound.keyEquivalentModifierMask = [.command, .option]
        deviceMenu.addItem(sound)
        deviceMenu.addItem(withTitle: "Share Clipboard", action: #selector(AppDelegate.toggleClipboard(_:)), keyEquivalent: "")
        deviceMenu.addItem(.separator())
        let connectionMenu = NSMenu(title: "Connection")
        for kind in ConnectionKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(AppDelegate.selectConnection(_:)), keyEquivalent: "")
            item.representedObject = kind.rawValue
            connectionMenu.addItem(item)
        }
        deviceMenu.addItem(submenu: connectionMenu, title: "Connection")
        deviceMenu.addItem(withTitle: "Set Up iPhone…", action: #selector(AppDelegate.openSetupAssistant(_:)), keyEquivalent: "")
        deviceMenu.addItem(.separator())
        deviceMenu.addItem(withTitle: "Agent Control (MCP)", action: #selector(AppDelegate.toggleMCP(_:)), keyEquivalent: "")
        deviceMenu.addItem(withTitle: "Copy MCP Command for Claude Code", action: #selector(AppDelegate.copyMCPCommand(_:)), keyEquivalent: "")
        mainMenu.addItem(submenu: deviceMenu, title: "Device")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Larger", action: #selector(AppDelegate.zoomIn(_:)), keyEquivalent: "+")
        windowMenu.addItem(withTitle: "Smaller", action: #selector(AppDelegate.zoomOut(_:)), keyEquivalent: "-")
        windowMenu.addItem(withTitle: "Actual Size", action: #selector(AppDelegate.actualSize(_:)), keyEquivalent: "0")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(submenu: windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    // The menu actions live here instead of on the window controller: the AppDelegate is always in the responder chain,
    // even when no window is active – otherwise Home/Lock would be greyed out in the background.
    @objc func pressHardwareButton(_ sender: NSMenuItem) { windowController?.pressHardwareButton(sender) }
    @objc func showAppSwitcher(_ sender: Any?) { windowController?.send(.gesture(.appSwitcher)) }
    /// ⌘-Space via the hardware keyboard opens search on iOS.
    @objc func openSpotlight(_ sender: Any?) {
        let command: UInt16 = 0xE3, space: UInt16 = 0x2C
        for event: InputEvent in [.key(usage: command, isDown: true), .key(usage: space, isDown: true),
                                  .key(usage: space, isDown: false), .key(usage: command, isDown: false)] {
            windowController?.send(event)
        }
    }
    // MARK: - MCP

    private func startMCPServer() {
        guard mcpServer == nil else { return }
        let settings = AppSettings.shared
        let server = MCPServer(
            name: "phonemirror", version: "0.3", instructions: AgentTools.instructions,
            provider: AgentTools(bridge: agentBridge)
        )
        do {
            let http = try MCPHTTPServer(port: settings.mcpPort, token: settings.mcpToken, server: server)
            http.start()
            mcpServer = http
            // Pre-warm WebDriverAgent and keep it alive so `ui_tree` answers immediately.
            wdaWarmup = Task { [agentBridge] in
                while !Task.isCancelled {
                    await agentBridge.prepareWDA()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        } catch {
            Logger(subsystem: "PhoneMirror", category: "mcp").error("MCP server: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopMCPServer() {
        mcpServer?.stop()
        mcpServer = nil
        wdaWarmup?.cancel()
        wdaWarmup = nil
        agentBridge.wda.stop()
    }

    @objc func toggleMCP(_ sender: Any?) {
        let settings = AppSettings.shared
        settings.mcpEnabled.toggle()
        if settings.mcpEnabled { startMCPServer() } else { stopMCPServer() }
    }

    /// Command for adding to Claude Code (with token) to the Mac clipboard – not to the iPhone.
    @objc func copyMCPCommand(_ sender: Any?) {
        let settings = AppSettings.shared
        let command = "claude mcp add --transport http phonemirror http://127.0.0.1:\(settings.mcpPort)/mcp "
            + "--header \"Authorization: Bearer \(settings.mcpToken)\""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        windowController?.ignoreCurrentMacClipboard()
    }

    @objc func selectConnection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = ConnectionKind(rawValue: raw),
              kind != AppSettings.shared.connection else { return }
        AppSettings.shared.connection = kind
        // A file being played back stays untouched by the switch.
        guard UserDefaults.standard.string(forKey: "replay") == nil else { return }
        windowController?.replaceTransport(makeTransport())
    }

    /// Pairing and Developer Mode without Xcode; pauses the mirror connection while open.
    @objc func openSetupAssistant(_ sender: Any?) {
        if let setupAssistant {
            setupAssistant.show()
            return
        }
        let assistant = SetupAssistantController()
        assistant.onClose = { [weak self] in
            self?.setupAssistant = nil
            self?.windowController?.connect()
        }
        setupAssistant = assistant
        Task {
            await windowController?.suspendConnection()
            assistant.show()
        }
    }

    @objc func toggleSound(_ sender: Any?) {
        guard let windowController else { return }
        windowController.soundEnabled.toggle()
    }

    @objc func toggleClipboard(_ sender: Any?) {
        guard let windowController else { return }
        windowController.clipboardSync.toggle()
    }

    @objc func zoomIn(_ sender: Any?) { windowController?.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { windowController?.zoomOut(sender) }
    @objc func actualSize(_ sender: Any?) { windowController?.actualSize(sender) }

    private func buttonItem(_ title: String, _ button: HardwareButton, key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(AppDelegate.pressHardwareButton(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.representedObject = button.rawValue
        return item
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        submenu.title = title
        item.submenu = submenu
        addItem(item)
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Checkmarks for the toggles in the Device menu.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleSound(_:)):
            menuItem.state = (windowController?.soundEnabled ?? AppSettings.shared.soundEnabled) ? .on : .off
        case #selector(selectConnection(_:)):
            menuItem.state = (menuItem.representedObject as? String) == AppSettings.shared.connection.rawValue ? .on : .off
        case #selector(toggleMCP(_:)):
            menuItem.state = AppSettings.shared.mcpEnabled ? .on : .off
        case #selector(copyMCPCommand(_:)):
            return AppSettings.shared.mcpEnabled
        case #selector(toggleClipboard(_:)):
            menuItem.state = (windowController?.clipboardSync ?? AppSettings.shared.clipboardSync) ? .on : .off
        default:
            break
        }
        return true
    }
}
