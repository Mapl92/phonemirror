# PhoneMirror

A native Mac client for iPhone screen mirroring and control via the Device Hub protocol (CoreDevice, iOS 27 and
later). Background and reverse-engineering findings: [../FINDINGS.md](../FINDINGS.md).

Tested with an iPhone 15 on iOS 27.0.1, macOS 27.0.1 and Xcode 27.1:

| Feature | Status |
|---|---|
| Video | ≈ 58 fps, hardware decoding, cropped to the actual display |
| Touch, keyboard, buttons | working |
| Home indicator and App Switcher | working |
| Audio and clipboard | available |
| Reconnect and DDI mount | automatic |

> The app's menus are currently in German. Below, menu items are given in English with the German label in
> parentheses.

## Requirements

- iPhone with iOS 27, Developer Mode, and Settings › Developer › "Enable UI Automation" turned on.
- The iPhone is paired with this Mac (Xcode/Device Hub).
- Xcode 27 for `devicectl`. The app uses it to mount the Developer Disk Image itself; the iPhone must be unlocked
  for that.
- Only for the "pymobiledevice3" connection mode: `uv tool install pymobiledevice3` (≥ 11.36).

## Build and run

```bash
swift test                     # unit, pipeline and protocol tests
Scripts/bundle-app.sh          # → build/PhoneMirror.app (with icon)
open build/PhoneMirror.app
```

Without a device, there is a replay mode that plays a test file. Keep the file outside `~/Documents`, otherwise
macOS asks for folder access after every rebuild:

```bash
swift run -c release hevc-test-stream /tmp/test.h265 4 1179 2556 collapse
open build/PhoneMirror.app --args -replay /tmp/test.h265
```

## Usage

| Input | Effect |
|---|---|
| Click, drag | Touch |
| Trackpad scrolling | Swipe gesture (without double momentum) |
| Right-click | Home |
| Keyboard | Sent to the iPhone as hardware keyboard usages |
| ⌘1 / ⌘2 / ⌘3 | Home Screen / App Switcher / Spotlight |
| ⌘L, ⌘↑ / ⌘↓ | Lock, volume |
| ⌘⌥T | Audio on/off |
| Device (Gerät) › Share Clipboard (Zwischenablage teilen) | Mac ↔ iPhone clipboard sync on/off |
| Device (Gerät) › Connection (Verbindung) | Native or pymobiledevice3 |
| ⌘+ / ⌘− / ⌘0 | Window size; size and position are remembered |

Edge gestures:
- **Home indicator:** Clicking at the bottom and dragging up goes Home. Pausing briefly before releasing opens the
  App Switcher. iOS ignores injected touches at the bottom edge, so PhoneMirror uses the Home button instead.
- **Top and left:** Touches starting within 12 pt of the top edge or 8 pt of the left edge are snapped exactly onto
  the edge. That makes Notification Center, Control Center and the back gesture work.

Clipboard:
- Whatever you copy on the iPhone arrives on the Mac after about one second. Rich text (Safari, Mail, Notes) comes
  as HTML/RTF plus plain text.
- Copies made on the Mac are only sent to the iPhone while PhoneMirror is the active app.
- Content that Apple's Universal Clipboard (Handoff) has already transferred (type `com.apple.is-remote-clipboard`)
  is not sent back. Otherwise rich-text copies from the iPhone would be turned into plain text.

## Agent control (MCP)

PhoneMirror includes an MCP server that lets AI agents control the iPhone. It shares the window's connection, so you
see live what the agent is doing. An "Agent steuert" (agent in control) badge and the touched spot are shown, and you can step in
at any time.

- Address: `http://127.0.0.1:8765/mcp` (Streamable HTTP, local only), protected by a bearer token and an Origin check.
- Turn on/off: Device (Gerät) › Agent Control (Agent-Steuerung (MCP)).
- **Adding it to Claude Code:** Device (Gerät) › "Copy MCP command for Claude Code" (MCP-Befehl für Claude Code
  kopieren) puts the complete command on the Mac clipboard (not the iPhone's). Paste it into a terminal and run it:

  ```
  claude mcp add --transport http phonemirror http://127.0.0.1:8765/mcp --header "Authorization: Bearer <token>"
  ```

Tools based on the accessibility tree (via WebDriverAgent, preferred):

| Tool | Purpose |
|---|---|
| `ui_tree` | Numbered list of the foreground app's UI elements: type, label, value, frame. Roughly 1,000–2,000 tokens instead of an image |
| `find_elements` | Search by text and/or type (Button, Cell, TextField …) |
| `tap_element` | Tap by ID or visible text. Interactive elements win over plain text; if the type doesn't match, the search falls back to any type |
| `type_into` | Tap a text field by label/placeholder and insert text |

Other tools:

| Tool | Purpose |
|---|---|
| `screenshot` | JPEG of the screen; image size = coordinate space in points (iPhone 15: 393 × 852) |
| `device_info` | Connection, screen size, age of the latest frame |
| `tap`, `double_tap`, `long_press`, `swipe` | Touch gestures in points |
| `type_text` | Insert text (clipboard + ⌘V, any language), optionally followed by Return |
| `press_key` | Key with modifiers (e.g. ⌘A) |
| `press_button` | Home, Lock, volume, Siri |
| `system_action` | Home, App Switcher, Spotlight, Notification Center, Control Center |
| `list_apps`, `launch_app` | List apps or launch one by bundle ID (native connection only) |
| `get_clipboard`, `set_clipboard` | The iPhone's clipboard |
| `wait` | Wait for animations |

### WebDriverAgent (one-time setup)

The accessibility tree comes from [WebDriverAgent](https://github.com/appium/WebDriverAgent) (Appium, BSD
license). It runs as a UI test runner on the iPhone and has to be built once with your Apple developer team:

```bash
Scripts/build-wda.sh <Team-ID> [bundle-ID-prefix]   # Team ID e.g. from `security find-identity -p codesigning -v`
```

With a free account, the bundle ID must be globally unique, so pass your own prefix (e.g.
`com.yourname.phonemirror`).

After that, PhoneMirror starts WDA itself as soon as agent control is on and the iPhone is connected (≈ 10 s):
- It uses `xcodebuild test-without-building` and **binds WDA to the tunnel address** (`TEST_RUNNER_USE_IP`), so WDA
  is not reachable over Wi-Fi, only through this Mac's CoreDevice tunnel.
- After a tunnel change, PhoneMirror restarts it; quitting the app or turning agent control off stops it.
- Log: `~/Library/Logs/PhoneMirror/wda.log`
- Signing lifetime: one year with a paid developer account, 7 days with a free one (then run the script again).
- After WDA restarts, iOS may ask for the device passcode to "Enable UI Automation" on the iPhone.

Limitations:
- The tree only shows the accessibility information apps provide. Games, canvas content and unlabeled icons still
  need `screenshot`. Some system apps (e.g. Camera) are not visible to WDA at all.
- `type_text`/`type_into` overwrite the iPhone clipboard. With Universal Clipboard enabled, the text also ends up on
  the Mac.

## Connection modes

**Native (default).** Pure Swift, no Python:
1. `remotepairingd` (libxpc) provides the existing CoreDevice tunnel.
2. `nettop` finds `remoted`'s RSD port.
3. RemoteXPC (HTTP/2 + XPC) connects to the display, HID and pasteboard services.
4. Video and audio arrive as RTP over UDP. The app sends RTCP receiver reports and requests a keyframe via PLI after
   packet loss.

**pymobiledevice3 (serve-web).** Runs `serve-web --native` as a local bridge on 127.0.0.1 with a random password.

Both modes share the tunnel with Apple's `remoted`. While PhoneMirror is running, Xcode and `devicectl` may
temporarily lose the iPhone.

## Architecture

| Module | Contents |
|---|---|
| `MirrorCore` | Transport interface, HEVC (Annex B, access units, sample builder, VideoToolbox decoder, collapse detection), RTP depacketizer, input (TouchMapper, KeyMapping, gestures, `InputActionEncoder`), serve-web transport, DDI preparation |
| `MirrorMCP` | MCP server: JSON-RPC 2.0, Streamable HTTP (NWListener), token/Origin protection |
| `MirrorNative` | Native transport: XPC wire format, HTTP/2, RemoteXPC, tunnel, RSD, CoreDevice services, media offer, RTP/RTCP, AAC-ELD |
| `PhoneMirror` | AppKit app: window, video layer (IOSurface + `contentsRect`), audio (AVAudioEngine), clipboard, menus, settings |
| `MirrorTestSupport`, `HEVCTestStream` | Synthetic HEVC streams (including resolution collapse) |
| `RTPDumpToH265`, `NativeProbe` | Tools: RTP capture → H.265, and layer tests of the native transport (`swift run native-probe rsd\|video\|audio`) |

## License

PhoneMirror is licensed entirely under GPL-3.0-or-later (see [../LICENSE](../LICENSE)); source files carry SPDX
headers. `MirrorNative` is closely modeled on pymobiledevice3 (also GPL-3.0). The disclaimer and trademark notice are
in the [main README](../README.md).

## Open issues

- **Video latency:** Measure it properly and add RCTL feedback if needed (disabled by default in pymobiledevice3).
- **Display size:** Not read from the device; the iPhone 15 is the default.
- **Native clipboard:** Polled once per second instead of using a Darwin notification. Only the primary types are
  read; fetching all representations blocks the iOS service (≥ 8 s, up to 64 s according to pymobiledevice3).
- **Probe tool:** Don't run `native-probe` while the app is running. The second RSD connection disrupts the app's
  streams; the app reconnects, but the measurements are skewed.
- **UI language:** Menus and in-app text are German only so far.
