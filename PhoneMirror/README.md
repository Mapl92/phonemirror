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

## Requirements

- iPhone with iOS 27 and Developer Mode on; for agent control also Settings › Developer › "Enable UI Automation".
- The iPhone is paired with this Mac. **Device › Set Up iPhone…** pairs it without Xcode (USB cable once, then
  Wi-Fi is enough) and shows the hidden Developer Mode switch on the iPhone. Pairing via Xcode/Device Hub works too.
- Apple's Developer Disk Image. PhoneMirror uses Xcode's copy in `/Library/Developer/DeveloperDiskImages` if present,
  otherwise its own copy in `~/Library/Application Support/PhoneMirror/DDI`. **Device › Set Up iPhone…** imports it
  from an Xcode download (`.xip`, Xcode does not have to be installed), an `Xcode.app`, `XcodeSystemResources.pkg`,
  `iOS_DDI.dmg` or an `iOS_DDI` folder; Apple's package signature is checked. An Xcode in /Applications is used
  automatically. The native mode mounts the image itself (no `devicectl`); the iPhone must be unlocked for that.
  A new major iOS version needs the DDI from a matching Xcode.
  The pymobiledevice3 mode and agent control (WebDriverAgent via `xcodebuild`) still use Xcode.
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
| Device › Share Clipboard | Mac ↔ iPhone clipboard sync on/off |
| Device › Connection | Native or pymobiledevice3 |
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
see live what the agent is doing. An "Agent in control" badge and the touched spot are shown, and you can step in at
any time.

- Address: `http://127.0.0.1:8765/mcp` (Streamable HTTP, local only), protected by a bearer token and an Origin check.
- Turn on/off: Device › Agent Control (MCP).
- **Adding it to Claude Code:** Device › Copy MCP Command for Claude Code puts the complete command on the Mac
  clipboard (not the iPhone's). Paste it into a terminal and run it:

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
   If they are missing, PhoneMirror mounts the Developer Disk Image as a cryptex: chip ID, ECID and nonce from
   `cryptexd`, a personalization ticket from Apple's signing server (`gs.apple.com`), then the install with the
   payloads as XPC file transfers (~3 s).
4. Video and audio arrive as RTP over UDP. The app sends RTCP receiver reports and requests a keyframe via PLI after
   packet loss.

**pymobiledevice3 (serve-web).** Runs `serve-web --native` as a local bridge on 127.0.0.1 with a random password.

Both modes share the tunnel with Apple's `remoted`. While PhoneMirror is running, Xcode and `devicectl` may
temporarily lose the iPhone.

`swift run native-probe ddi [status|unmount|mount]` checks, removes or mounts the Developer Disk Image, and
`native-probe ddi import <xip|app|pkg|dmg|folder>` imports one (not while the app is running).

## Architecture

| Module | Contents |
|---|---|
| `MirrorCore` | Transport interface, HEVC (Annex B, access units, sample builder, VideoToolbox decoder, collapse detection), RTP depacketizer, input (TouchMapper, KeyMapping, gestures, `InputActionEncoder`), serve-web transport, DDI preparation |
| `MirrorMCP` | MCP server: JSON-RPC 2.0, Streamable HTTP (NWListener), token/Origin protection |
| `MirrorNative` | Native transport: XPC wire format, HTTP/2, RemoteXPC, tunnel, RSD, CoreDevice services, media offer, RTP/RTCP, AAC-ELD |
| `PhoneMirror` | AppKit app: window, video layer (IOSurface + `contentsRect`), audio (AVAudioEngine), clipboard, menus, settings |
| `MirrorTestSupport`, `HEVCTestStream` | Synthetic HEVC streams (including resolution collapse) |
| `RTPDumpToH265`, `NativeProbe` | Tools: RTP capture → H.265, and layer tests of the native transport (`swift run native-probe rsd\|video\|audio`) |

## Releasing (maintainers)

`Scripts/release.sh <version>` builds, tests and signs the app with a Developer ID and the hardened runtime,
notarizes and staples the app and a DMG, writes `SHA256SUMS.txt` and creates a **draft** GitHub release
(`build/release/`). One-time setup:

1. Developer ID Application certificate in the login keychain (Xcode › Settings › Accounts › Manage Certificates).
2. Notarization credentials stored for `notarytool`:

   ```bash
   xcrun notarytool store-credentials phonemirror-notary --apple-id <apple-id> --team-id <team-id>
   ```

3. GitHub CLI logged in; the working tree must be clean and pushed.

`Scripts/release.sh <version> --dry-run` builds the same bundle with an ad-hoc signature and the hardened runtime,
without notarization or GitHub, to check that everything still works under the hardened runtime.
`--no-github` notarizes but skips the GitHub release.

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
