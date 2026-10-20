# iPhone Mirroring – Reverse-Engineering Findings

As of 2026-10-19 · macOS 26.5.2 (25F84), arm64 · iPhone Mirroring 1.6 (98.5) · Xcode 26.4
Method (sections 1–3): purely static (bundle, entitlements, `dyld_info` exports/strings from the shared cache) plus
read-only queries (`dns-sd -B`, `devicectl device info details`). From section 4 on: tests against the author's own
paired iPhone and comparison with the open-source pymobiledevice3. The goal is interoperability; no Apple code is
reproduced or modified.

This document is a chronological research log. Early sections reflect the state at the time and are partly
superseded by later ones.

Legend: **[O]** observed · **[D]** derived · **[?]** open

## 1. Building blocks on the Mac

| Layer | Component | Role |
|---|---|---|
| App | `/System/Applications/iPhone Mirroring.app` (`com.apple.ScreenContinuity`), thin SwiftUI shell | [O] Links only `ScreenContinuityUI` (bundled), `ScreenSharingKit`, `ScreenContinuityServices` |
| Engine | `ScreenSharingKit.framework` (private) | [O] Session, media transport, HID, text input, auth, telemetry |
| Devices/pairing | `ScreenContinuityServices.framework` | [O] `CompanionDeviceManager` (`startSession`, `pairDevice`), `CompanionDevice` (`remoteScreenPairing`, `deviceScreen`, `proximity`), `ContinuityEligibility.isiPhoneMirroringEligible`, `ContinuityLaunchRequest` (app/notification/widget/Live Activity) |
| Daemon | `/usr/libexec/rapportd`, class `RPRemoteDisplayDaemon`, Mach service `com.apple.RemoteDisplay` | [O] Discovery, pairing, connection setup |
| Media | `AVConference.framework` (FaceTime media engine), mode `NearbyScreenSharing` | [O] Codecs H264/HEVC, OPUS; RTP/RTCP |
| Input | `UniversalHID`/`UniversalHIDKit` | [O] Virtual devices "iPhone Mirroring Mouse" / "iPhone Mirroring Keyboard", HID reports to the iPhone |
| Text | `RemoteTextInput` (`com.apple.rti-screencontinuity`) | [O] Text input sessions |
| Notifications | `ReplicatorServices` | [O] Mirrored iPhone notifications |

## 2. Flow (reconstructed)

1. **Eligibility** [O]: `LSEligibilityInstallPredicate` (domain 27) and an os_eligibility file. Error text:
   "not available in your country or region". MDM switch `com.apple.applicationaccess` → `allowiPhoneMirroring`.
2. **Discovery** [O]: BLE `NearbyActionV2` (advertiser/scanner), BLE "NeedsAWDL" signal, Bonjour `_rdlink._tcp`
   (infrastructure Wi-Fi and AWDL). Auth tag in the Bonjour TXT record (`_serverBonjourAuthTagString`).
3. **Trust/pairing** [O]: Rapport pair-verify (`RPPairingDistributedActor.startPairVerify`, LTPK),
   `remoteScreenPairing`, Octagon/iCloud Keychain (`com.apple.private.octagon`, error `iCloudNeedsRepair`).
   Mac login via the Sharing unlock manager (`pairDeviceForMacUnlock`, `unlockWithAuthenticationToken`).
4. **Transport** [O]: Rapport stream with types `UDPSocket` / `RPCnx` / `UDPNWPath`; control channel
   (`com.apple.oneness.sessionAndHIDMessages`); modes `wired` / `wirelessly`.
5. **Media** [O]: AVConference streams `com.apple.MediaTransport.video` / `.audio`. Offer/answer
   (`negotiationOffer`/`negotiationAnswer`) go over the control channel.
6. **iPhone side** [D]: `com.apple.ScreenContinuityShell` renders its own scene/display while the phone stays locked
   (errors `springBoardInvalidated`, `deviceUnlockedDuringSession`, `missingDisplayConfiguration`).
7. **Input** [O]: HID reports, tap/drag gestures, drag & drop, RTI text, accessibility translation, orientation.

## 3. Second path: Xcode/CoreDevice "View Device Screen"

- [O] `CoreDevice.framework` offers the actions `com.apple.coredevice.action.mediastream{getsupportinfo,start,status,stop}`
  and the features `remote.hid.digitizer`, `remote.hid.button`, `remote.hid.scroll`, `remote.universalhid`,
  `devicecontrol.orientation`.
- [O] AVConference knows the mode `CoreDeviceScreenSharing` with the device service `com.apple.CoreDevice.dtremotedisplayd`.
- [O] The iPhone 15 (iOS 26.5, Developer Mode on, connected via `localNetwork`) reports
  `com.apple.coredevice.feature.viewdevicescreen`; `screenViewingURL = devices://device/open?id=…`.
- [O] `CoreDeviceService.xpc` carries `com.apple.private.CoreDevice.canViewDeviceDisplay` and `…CoreDevice.hid`.
  `devicectl` has no entitlements and no media stream command.
- [?] Whether a third-party client may call `mediastreamstart` through CoreDeviceService is untested.
- [?] Also untested: talking to `dtremotedisplayd` directly over RemoteXPC/the RSD tunnel.

## 4. Probe: CoreDevice media stream from a custom tool (2026-10-19)

Tool: a small probe (not included in the repository). A hand-written Swift interface declares the required exported
symbols. The tool only calls `getMediaStreamSupportInfo` and `getMediaStreamServerStatus`.

- [O] A custom, ad-hoc signed tool without entitlements can use `DeviceManager.shared`. The XPC check-in with
  `com.apple.CoreDevice.CoreDeviceService` succeeds and the device list arrives (iPhone + Watch).
- [O] Both media stream calls fail with `CoreDeviceError 9011`: "Unable to complete operation as this is using
  obsolete functionality … CoreDevice, DeviceKit, and Devices.app".
- [O] The error is raised **in the client** (`CoreDevice.framework`). The text only exists there, and the service log
  shows only check-in and disconnect for both runs, no action.
- [O] The iPhone reports no `mediastream*` and no `remote.hid.*` capability, only `viewdevicescreen` and the generic
  `com.apple.dt.serviceconnection.create` / `servicesocket.create`.
- [O] Among the iPhone's 75 RSD services (`/usr/libexec/remotectl show`) there is no display, HID or media service.
- [O] The iOS DDI (CoreDevice-518.27) does contain `CoreDeviceMediaStreamSupport.framework`, but no
  `dtremotedisplayd` launch daemon, and no other DDI binary references the framework.
- [O] The handler for `devices://` ("Devices.app", `com.apple.dt.Devices`) is not installed on this system.
  Xcode 26.4 does not reference the URL.
- [D] The old path (CoreDevice actions + AVConference mode `CoreDeviceScreenSharing`) is disabled in this version.
  It is apparently being replaced by a successor made of "DeviceKit + Devices.app" that has not shipped here yet.
- [O] Side note: according to `remotectl` (`RegionInfo`), the test device is an EU device. That matches the regional
  restriction from section 2.

## 5. Research: Device Hub ("Devices.app") – as of 2026-10-19

Sources (web, not verified locally):
WWDC26 session 260 "Get the most out of Device Hub"; Michael Tsai, "Xcode 27's Device Hub" (2026-06-25);
Apple Personal Safety Guide "Manage Device Hub access"; GitHub: getsentry/MobileBuildMCP#519,
JaviSoto/device-hub-ios, ALEXoicu/iPhone-Mirroring-Device-Hub, Jakeelamb/iphone-mirror-rs, boa-z/devicehub-mask.

- **Device Hub** is a standalone Mac app that ships with **Xcode 27** and replaces the Simulator app (WWDC26).
  Compact and full windows show a live screen with click, drag, scroll, trackpad gestures, "Capture Keyboard",
  Home/rotation/screenshot, and wireless pairing ("Pair Nearby Device", PIN).
- [D] "Devices.app" / `com.apple.dt.Devices` from the 9011 error message is very likely Device Hub. The bundle name
  is not confirmed by the sources.
- **Remote screen control only with iOS 27 on the target device** (Tsai, citing Troughton-Smith, who hopes for a
  backport to iOS 26/18 via the DDI). This matches section 4: with Xcode 26.4 and iOS 26.5 the old path is disabled
  and the new one is missing.
- Requirements according to the sources: Developer Mode, pairing (USB or local network).
  - According to MobileBuildMCP#519 (unconfirmed), additionally from iOS 26+: Settings › Developer › UI Automation ›
    "Enable UI Automation" or "Paired Mac computers can remotely view and control this iPhone".
  - Apple records session logs under Safety Check; access can be turned off by disabling Developer Mode.
- New CoreDevice features (iOS 27): `remote.hid.digitizer`, `remote.hid.keyboard`, `remote.hid.button`,
  `remote.hid.scroll`, `remote.universalhid`, `viewdevicescreen`. Video runs as an HEVC stream over the
  CoreDevice/RemoteXPC tunnel (according to community projects), not over AVConference/Rapport like iPhone Mirroring.
- No official API: `devicectl` (Xcode 27 beta) has `capture`/`appResize`, but no input or stream command.
- **Third-party implementations already exist:**
  - `idevice` (Rust) and `pymobiledevice3` implement the tunnel, RSD, display transport and Universal HID, e.g.
    `pymobiledevice3 developer core-device universal-hid-service tap -- 32768 32768`.
  - `iphone-mirror-rs` is a Linux viewer (GPL-3.0), tested with iPhone 15 / iOS 27 over Wi-Fi: about 60 fps and
    about 59 ms synthetic latency, without audio.
  - `device-hub-ios` (iOS client, Xcode 27.1) and `devicehub-mask` (AGPL-3.0, browser/WebCodecs).
  - `iPhone-Mirroring-Device-Hub` is only an AppleScript wrapper around Apple's Device Hub, explicitly meant as a
    substitute in regions without iPhone Mirroring.
- Differences from iPhone Mirroring:
  - Device Hub requires Developer Mode and pairing.
  - Notification mirroring and launching apps from the Mac Dock are missing.
  - The sources mention no regional restriction. According to ALEXoicu, Device Hub also connects to a locked
    iPhone, and unlocking with the passcode works through the mirror.

### Service names according to pymobiledevice3 11.36.0 (installed locally, help texts)

- Display: `com.apple.coredevice.displayservice` with the commands `get-media-support-info`,
  `get-media-stream-server-status`, `start-video-stream` (RTP/HEVC), `start-audio-stream`, `serve-web` and `serve-vnc`.
  On the iPhone, the daemon `dtremotedisplayd` handles it.
- Input: `com.apple.coredevice.hid.universalhidservice` (command `universal-hid-service`) and `hid` for buttons.
- Other useful functions: `launch-application`, `list-apps`, `fetch-app-icon`, `paste`/`copy` (clipboard),
  `get-lockstate`, `rotate`, `screen-capture`.
- [O] On iOS 26.5, `com.apple.coredevice.displayservice` is not in the iPhone's RSD list (section 4).

### Device side on iOS 27 (DDI from Xcode 27.1, build 27A9275) – checked locally

- [O] The iPhone 15 runs iOS 27.0.1 (24A446) with Developer Mode on. The tunnel runs over `localNetwork`, with an
  IPv6 ULA address as tunnel IP (`fdxx:…::1`).
- [O] Without a mounted DDI, display/HID are missing from the RSD directory (65 services). Mounting fails while the
  iPhone is locked (CoreDeviceError 12040 or 10003 "device was still locked").
- [O] The DDI contains three new launch daemons (all `UserName mobile`, `UsesRemoteXPC`):

| Daemon | RemoteService | RequireEntitlement | Features |
|---|---|---|---|
| `dtremotedisplayd` | `com.apple.coredevice.displayservice` | `com.apple.private.CoreDevice.canViewDeviceDisplay` | getmediasupportinfo, getmediastreamserverstatus, startaudiooutput, startvideooutput, startmediastream, stopmediastream |
| `dtuhidd` | `com.apple.coredevice.hid.indigo` | `com.apple.private.CoreDevice.hid` | remote.hid.button, .scroll, .digitizer, .vendordefined |
| `dtuhidd` | `com.apple.coredevice.hid.universalhid` | `com.apple.private.CoreDevice.hid` | remote.hid.keyboard, remote.universalhid |
| `dtuhidd` | `com.apple.coredevice.hid.universalhidservice` | `com.apple.private.CoreDevice.hid` | remote.universalhidservice |
| `dthidd` | `com.apple.coredevice.devicecontrol` | `com.apple.private.CoreDevice.devicecontrol` | remote.devicecontrol.orientation |

- [O] After unlocking, `devicectl device info ddiServices` mounts the DDI (`isCryptexDDI: true`). The RSD directory
  then reports 86 services, including all five from the table.

### First real stream (2026-10-19, iPhone 15 / iOS 27.0.1, Wi-Fi)

- [O] The system tunnel (`fdxx:…::1`) is not reachable for ordinary processes (`Errno 51`).
- [O] `pymobiledevice3 … --native` (through Apple's `remotepairingd`, without root, without entitlements, without
  new pairing) works. So `RequireEntitlement` does not block paired hosts.
- [O] `get-media-support-info`: `avcFrameworkVersion 2235.63.1.2`, `supportedFeatures 972` (mirrored main display,
  system audio, virtual external display, stream by display ID, display info, screenshot).
- [O] `start-video-stream --duration 5`: 728 RTP packets, yielding 264 frames, 0 lost; ffmpeg decodes without errors.
  - RTP per RFC 7798, PT 100. One aggregation packet (VPS/SPS/PPS) at the start, FUs otherwise. Header extensions
    (profiles `0x9001`/`0x9011`) and rtcp-mux (PT 72 = sender report).
  - **24 kHz video clock**: ≈ 400 ticks per frame, ≈ 55–60 fps.
  - **Only one IDR at the start**, then exclusively TRAIL_R. Packet loss needs a recovery strategy (new stream or
    keyframe request, still open at that point).
  - **Encoded at 1184 × 2576** (HEVC Main, yuvj420p) for a 1179 × 2556 display (`get-display-info`:
    `nativeSize 1179×2556`, `pointScale 3`). Padding is on the right/bottom (content ends at row 2555), so
    PhoneMirror crops to the display area.
- [O] `get-display-info` additionally lists an external "Wireless-4" display (displayId 7).
- [O] PhoneMirror plays the real capture back correctly cropped (`rtp-dump-to-h265` → `-replay`).

### Live operation via serve-web (2026-10-19)

- [O] PhoneMirror launches `serve-web --native` as a bridge. The first frame arrives after ≈ 4 s.
  - Home (Indigo HID), touch (`/touch` contact/release, 0…65535) and keyboard (`/key` with the set of held HID
    usages) work on the iPhone: switching Home, Spotlight by tap, text input.
  - On quit, the process stops cleanly (status 0).
- [O] According to the pymobiledevice3 source:
  - Without RTCP receiver reports, the iPhone ends the session after ≈ 20 s.
  - PLI requests a new IDR.
  - During motion a "resolution collapse" occurs (smaller content, gray border).
  - Slice NALs may carry a 14-byte trailer `04f00ac0000003000004ec0ab003`; it did not occur in our capture.

### System gestures via HID (iPhone 15, iOS 27.0.1, `mainTouchscreen` 257) – tested on device

- [O] **Swiping up from the bottom edge (y = 65535) has no effect**: no Home, no App Switcher, and the app doesn't
  receive the touch either. The same swipe from the middle of the screen scrolls normally.
- [O] **Swiping down from the top edge (y = 0) works**: Notification Center opens.
- [O] **Pressing Home twice quickly** (`/button home` down/up, 80 ms pause, down/up) opens the App Switcher.
- [O] While the screen is idle, the iPhone sends no new frames; a POST to `/pli` forces a fresh keyframe.
- Implementation in PhoneMirror:
  - Mouse gestures starting at the Home indicator are interpreted instead of sent: short swipe up = Home,
    with a pause (≥ 0.3 s) = Home twice.
  - ⌘2 = Home twice.
  - Edge snapping only at the top and left.
- [?] How Device Hub implements the Home indicator gesture is unknown (possibly via the Indigo digitizer/Mercury
  envelope, which pymobiledevice3 doesn't support yet).

### Native transport in Swift (2026-10-19) – tested on device

- [O] `remotepairingd` via libxpc (`RemotePairing.BrowseRequest`, `InitiatePairingCommand`,
  `CreateAssertionCommand`) returns the tunnel IPv6 address. This works without root and without entitlements in an
  ad-hoc signed app.
- [O] `nettop -n -x -L 1 -m tcp` shows `remoted`'s RSD connection (port). The handshake UUID comes from
  `remotectl dumpstate` ("Local device").
- [O] Custom HTTP/2 and XPC codecs, handshake in devicectl order: RSD returns 85 services.
- [O] The media offer (bplist + zlib-9 protobuf) is byte-identical to the Xcode capture (unit test).
- [O] 5 s of video: 1428 RTP packets, 290 frames, 58 fps, 0 lost. 5 s of audio: 498 AAC-ELD packets, 0 errors.
- [O] For the AAC-ELD decoder, `AudioConverterSetProperty` reports `!dat` for the magic cookie. Decoding still works
  correctly; pymobiledevice3 ignores the value as well.
- [O] Touch (`mainTouchscreen` 257), virtual keyboard (`createService` 0x100002001) and Indigo buttons work in the
  app: Spotlight by tap, text input, App Switcher.
- [O] Screenshots of windows on another Space sometimes show frames that are seconds old. This affects the test
  tooling, not the app.

### Native clipboard (2026-10-19)

- [O] `PULL` with `promiseSecondary` returns only the primary type inline. A reproduced Safari copy (HTML + text)
  shows: iOS adds `public.rtf`; text and RTF are only promised.
- [O] `allResolved` takes > 8 s for that (conversion on the device). PhoneMirror therefore takes HTML/RTF directly.
- [O] Error 26006 (`com.apple.dt.CoreDeviceError`): the content carries `com.apple.is-remote-clipboard` (it arrived
  via Universal Clipboard) and is not handed out.
- [O] On the Mac, copies transferred via Handoff also carry `com.apple.is-remote-clipboard`. PhoneMirror doesn't send
  them back.
- [O] A second RSD connection (probe tool) while the app is running interrupts its streams. Once, no keyframe arrived
  for up to 75 s afterwards. Since then the watchdog keeps requesting via PLI as long as no keyframe has arrived after
  the start.

### Accessibility tree via WebDriverAgent (2026-10-19)

- [O] WebDriverAgent v16.15.3 can be signed with one's own developer team and runs on iOS 27.0.1.
  `/source?format=json` returns e.g. 171 nodes in ≈ 3 s in Settings, with `rect` in points (393 × 852).
- [O] `TEST_RUNNER_USE_IP=<tunnel IP>` binds WDA to the CoreDevice tunnel. It is then reachable from the Mac at
  `[fdxx::1]:8100`; the iPhone wasn't reachable from the Mac via its Wi-Fi IP anyway.
- [O] xcodebuild/WDA and PhoneMirror (native RSD access) run in parallel without interfering.
- [O] In iOS 27, Settings rows are `Button`s with an inner `StaticText`, not `Cell`s.
- [O] Tested live via MCP: `list_apps` (197 apps), `launch_app`, `ui_tree`, `tap_element` (navigating to
  "General"), `type_into` (search in Settings).
- [O] Ad-hoc signed app + file access under ~/Documents → a TCC prompt blocks the call. That's why the WDA build and
  test files live outside ~/Documents.

### Camera app via agent (2026-10-19)

- [O] `launch_app com.apple.camera` starts the Camera; switching to the front camera and taking a photo by touch work.
- [O] In the mirrored image, the camera preview stays black.
- [O] WebDriverAgent doesn't recognize the Camera as the active app (`bundleId local.pid.0`, `pid 0`); `/source`
  fails. Agents have to work with screenshots and coordinates there.
- [O] While the Camera was running, the iPhone closed the HID connections while video kept running. Since then
  PhoneMirror reconnects HID on a send error and retries the input.

### Native DDI mount without devicectl (2026-10-20)

- [O] `com.apple.security.cryptexd.remote` installs the DDI as a Cryptex1 (`com.apple.MobileAsset.DDI`) on iOS 27.0.1:
  `read-personalization-id` (chip ID, ECID, production mode), `get-nonce` with the identity's
  `Cryptex1,NonceDomain` handle (4), TSS request `@Cryptex1,Ticket` to `https://gs.apple.com/TSS/controller?action=2`,
  then `install` with five XPC file transfers (image, trust cache, IM4M, info, root hash). Took ≈ 2.6 s.
- [O] File transfers: XPC type `0x1A000` (message ID + `{"s": size}`) in the request; each payload on its own odd
  HTTP/2 stream, first frame a wrapper with flag `0x00100000` and the transfer ID as message ID. Outbound HTTP/2 flow
  control is required for the 32 MB image.
- [O] `uninstall` with `remote-cryptex-identifier` removes the DDI immediately; the display service disappears from RSD,
  and a new RSD handshake is needed to see it again after mounting.
- [O] The DDI files come from Xcode's `XcodeSystemResources.pkg` (`/Library/Developer/DeveloperDiskImages/iOS_DDI`,
  `/Library/Developer/CoreDevice/CandidateDDIs`). `remotepairingd`, `remoted`, `CryptexKitHost` and MobileDevice are
  part of macOS (`/Library/Apple/System`, `/System`).

### Pairing without Xcode tools (2026-10-20)

- [O] `remotepairingd` (part of macOS, `/Library/Apple/System/.../RemotePairing.framework`, registered by launchd as
  `com.apple.CoreDevice.remotepairingd`) handles pairing on its own. `RemotePairing.UnpairRequest` with
  `deviceUDID` on the device connection unpairs (`authState` → `unauthenticated`); `RemotePairing.InitiatePairingCommand`
  with `requireNonInteractive = false` shows "Trust this computer" plus the passcode prompt on the iPhone and replies
  with `authState = authenticated` once confirmed.
- [O] After re-pairing this way (iPhone on USB), the tunnel, RSD, the already mounted DDI and PhoneMirror's mirroring
  worked unchanged. No Xcode process was involved in pairing.
- [O] The iPhone reports `isWirelesslyPairableDevice = false`: initial pairing needs a USB cable.
- [O] After unplugging the cable, the running mirror session continued over Wi-Fi, and a fresh start (new assertion,
  RSD, video and audio) worked without the cable too: `wirelessConnectivity = 1`, `networkAdvertActive = true`. So
  pairing once over USB with PhoneMirror is enough for wireless use afterwards.
- [O] Lockdown services over RSD (`*.shim.remote`, `com.apple.mobile.lockdown.remote.trusted`): plain TCP, plists with a
  4-byte big-endian length; `{"Request": "RSDCheckin", "ProtocolVersion": "2"}` is answered with `RSDCheckin` and
  `StartService`. `GetValue` in domain `com.apple.security.mac.amfi`, key `DeveloperModeStatus`, returns the state;
  `com.apple.amfi.lockdown.shim.remote` with `{"action": 0}` reveals the Developer Mode switch (`success: true`).
  PhoneMirror's setup assistant uses both.

### Developer Disk Image without an installed Xcode (2026-10-20)

- [O] No separate public download: `devicectl manage ddis update` only copies DDIs from Xcode.app or
  `/Library/Developer/CoreDevice/CandidateDDIs`. Xcode's MobileAsset type `com.apple.MobileAsset.XcodeDeviceSupport`
  (Pallas, `gdmf.apple.com/v2/assets`) currently returns no assets for the external audience.
- [O] The DDI ships inside Xcode as `Contents/Resources/Packages/XcodeSystemResources.pkg` (148 MB, "signed Apple
  Software") → `Library/Developer/CoreDevice/CandidateDDIs/iOS_DDI.dmg` (32 MB, UDZO) → `Restore/` with the
  BuildManifest and cryptex payloads, the same layout as `/Library/Developer/DeveloperDiskImages/iOS_DDI`.
- [O] PhoneMirror imports it from the user's own Xcode download without expanding Xcode: the `.xip` is a xar archive
  whose `Content` is pbzx (chunks of XZ or stored data) around a cpio stream; reading it sequentially yields just the
  package. `pkgutil --check-signature` verifies Apple's signature on the `.xip` and the package.
- [O] Import from Xcode.app took 2.2 s; mounting from PhoneMirror's own copy (`~/Library/Application Support/
  PhoneMirror/DDI`) worked the same as from Xcode's (2.0 s).
- [?] Import from a real Xcode `.xip` is covered by a synthetic test only (no `.xip` on this Mac).

## 6. Open points

- Whether an unlisted service is reachable via `serviceconnection.create` (not tested: invasive).
- iOS binaries (ScreenContinuityShell, iOS rapportd) were not examined.
- Wire format of control messages and AVConference offer/answer: not decompiled.
- Discovery via `dns-sd -B _rdlink._tcp`: the run produced no output, so visibility is unclear.
- Whether "View Device Screen" in Xcode 26.4 works on this Mac was not tried.
