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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let controller = MirrorWindowController(transport: makeTransport())
        agentBridge.controller = controller
        if AppSettings.shared.mcpEnabled { startMCPServer() }
        windowController = controller
        controller.showWindow(nil)
        controller.connect()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Beim Beenden erst die Session schließen, damit pymobiledevice3 den Gerätestream sauber stoppt.
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

    /// Quelle aus den Startargumenten (NSUserDefaults-Argumentdomäne):
    /// `-replay <datei.h265>` spielt eine Datei ab, sonst live über pymobiledevice3
    /// (`-pymobiledevice3 <pfad>` überschreibt die Suche nach dem Programm).
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

    // MARK: - Menü

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "PhoneMirror beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenu: appMenu, title: "PhoneMirror")

        let deviceMenu = NSMenu(title: "Gerät")
        // ⌘1/⌘2/⌘3 wie bei Apples iPhone-Mirroring.
        deviceMenu.addItem(buttonItem("Homescreen", .home, key: "1", modifiers: [.command]))
        let switcher = NSMenuItem(title: "App-Umschalter", action: #selector(AppDelegate.showAppSwitcher(_:)), keyEquivalent: "2")
        deviceMenu.addItem(switcher)
        deviceMenu.addItem(withTitle: "Spotlight", action: #selector(AppDelegate.openSpotlight(_:)), keyEquivalent: "3")
        deviceMenu.addItem(.separator())
        deviceMenu.addItem(buttonItem("Sperren", .lock, key: "l", modifiers: [.command]))
        deviceMenu.addItem(.separator())
        deviceMenu.addItem(buttonItem("Lauter", .volumeUp, key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.command]))
        deviceMenu.addItem(buttonItem("Leiser", .volumeDown, key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.command]))
        deviceMenu.addItem(.separator())
        let sound = NSMenuItem(title: "Ton vom iPhone", action: #selector(AppDelegate.toggleSound(_:)), keyEquivalent: "t")
        sound.keyEquivalentModifierMask = [.command, .option]
        deviceMenu.addItem(sound)
        deviceMenu.addItem(withTitle: "Zwischenablage teilen", action: #selector(AppDelegate.toggleClipboard(_:)), keyEquivalent: "")
        deviceMenu.addItem(.separator())
        let connectionMenu = NSMenu(title: "Verbindung")
        for kind in ConnectionKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(AppDelegate.selectConnection(_:)), keyEquivalent: "")
            item.representedObject = kind.rawValue
            connectionMenu.addItem(item)
        }
        deviceMenu.addItem(submenu: connectionMenu, title: "Verbindung")
        deviceMenu.addItem(.separator())
        deviceMenu.addItem(withTitle: "Agent-Steuerung (MCP)", action: #selector(AppDelegate.toggleMCP(_:)), keyEquivalent: "")
        deviceMenu.addItem(withTitle: "MCP-Befehl für Claude Code kopieren", action: #selector(AppDelegate.copyMCPCommand(_:)), keyEquivalent: "")
        mainMenu.addItem(submenu: deviceMenu, title: "Gerät")

        let windowMenu = NSMenu(title: "Fenster")
        windowMenu.addItem(withTitle: "Größer", action: #selector(AppDelegate.zoomIn(_:)), keyEquivalent: "+")
        windowMenu.addItem(withTitle: "Kleiner", action: #selector(AppDelegate.zoomOut(_:)), keyEquivalent: "-")
        windowMenu.addItem(withTitle: "Tatsächliche Größe", action: #selector(AppDelegate.actualSize(_:)), keyEquivalent: "0")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(submenu: windowMenu, title: "Fenster")
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    // Die Menüaktionen liegen hier statt am Window-Controller: Der AppDelegate ist immer im Responder-Chain,
    // auch wenn kein Fenster aktiv ist – sonst wären Home/Sperren im Hintergrund ausgegraut.
    @objc func pressHardwareButton(_ sender: NSMenuItem) { windowController?.pressHardwareButton(sender) }
    @objc func showAppSwitcher(_ sender: Any?) { windowController?.send(.gesture(.appSwitcher)) }
    /// ⌘-Leertaste über die Hardwaretastatur öffnet auf iOS die Suche.
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
            // WebDriverAgent vorwärmen und am Leben halten, damit `ui_tree` sofort antwortet.
            wdaWarmup = Task { [agentBridge] in
                while !Task.isCancelled {
                    await agentBridge.prepareWDA()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        } catch {
            Logger(subsystem: "PhoneMirror", category: "mcp").error("MCP-Server: \(error.localizedDescription, privacy: .public)")
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

    /// Befehl zum Einbinden in Claude Code (mit Token) in die Mac-Zwischenablage – nicht aufs iPhone.
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
        // Eine abgespielte Datei bleibt beim Wechsel unberührt.
        guard UserDefaults.standard.string(forKey: "replay") == nil else { return }
        windowController?.replaceTransport(makeTransport())
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
    /// Häkchen für die Schalter im Gerät-Menü.
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
