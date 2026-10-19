# iPhone Mirroring – Reverse-Engineering-Befunde

Stand: 2026-10-19 · macOS 26.5.2 (25F84), arm64 · iPhone Mirroring 1.6 (98.5) · Xcode 26.4
Methode (Abschnitte 1–3): rein statisch (Bundle, Entitlements, `dyld_info`-Exports/Strings aus dem Shared Cache) plus
lesende Abfragen (`dns-sd -B`, `devicectl device info details`). Ab Abschnitt 4: Tests am eigenen, gekoppelten iPhone
und Vergleich mit dem quelloffenen pymobiledevice3. Ziel ist Interoperabilität; Apple-Code wird weder wiedergegeben
noch verändert.

Dieses Dokument ist ein chronologisches Forschungsprotokoll. Frühe Abschnitte geben den damaligen Stand wieder und sind
teils durch spätere überholt.

Legende: **[B]** beobachtet · **[I]** abgeleitet · **[?]** offen

## 1. Bausteine auf dem Mac

| Schicht | Komponente | Rolle |
|---|---|---|
| App | `/System/Applications/iPhone Mirroring.app` (`com.apple.ScreenContinuity`), dünne SwiftUI-Hülle | [B] Linkt nur `ScreenContinuityUI` (gebündelt), `ScreenSharingKit`, `ScreenContinuityServices` |
| Engine | `ScreenSharingKit.framework` (privat) | [B] Session, Medien-Transport, HID, Texteingabe, Auth, Telemetrie |
| Geräte/Pairing | `ScreenContinuityServices.framework` | [B] `CompanionDeviceManager` (`startSession`, `pairDevice`), `CompanionDevice` (`remoteScreenPairing`, `deviceScreen`, `proximity`), `ContinuityEligibility.isiPhoneMirroringEligible`, `ContinuityLaunchRequest` (App/Benachrichtigung/Widget/Live Activity) |
| Daemon | `/usr/libexec/rapportd`, Klasse `RPRemoteDisplayDaemon`, Mach-Service `com.apple.RemoteDisplay` | [B] Discovery, Pairing, Verbindungsaufbau |
| Medien | `AVConference.framework` (FaceTime-Medien-Engine), Modus `NearbyScreenSharing` | [B] Codecs H264/HEVC, OPUS; RTP/RTCP |
| Eingabe | `UniversalHID`/`UniversalHIDKit` | [B] virtuelle Geräte „iPhone Mirroring Mouse“ / „iPhone Mirroring Keyboard“, HID-Reports an das iPhone |
| Text | `RemoteTextInput` (`com.apple.rti-screencontinuity`) | [B] Texteingabe-Sessions |
| Mitteilungen | `ReplicatorServices` | [B] gespiegelte iPhone-Mitteilungen |

## 2. Ablauf (rekonstruiert)

1. **Eligibility** [B]: `LSEligibilityInstallPredicate` (Domain 27) und os_eligibility-Datei. Fehlertext:
   „not available in your country or region“. MDM-Schalter `com.apple.applicationaccess` → `allowiPhoneMirroring`.
2. **Discovery** [B]: BLE `NearbyActionV2` (Advertiser/Scanner), BLE-„NeedsAWDL“-Signal, Bonjour `_rdlink._tcp`
   (Infrastruktur-WLAN und AWDL). Auth-Tag in Bonjour-TXT (`_serverBonjourAuthTagString`).
3. **Vertrauen/Pairing** [B]: Rapport Pair-Verify (`RPPairingDistributedActor.startPairVerify`, LTPK),
   `remoteScreenPairing`, Octagon/iCloud-Keychain (`com.apple.private.octagon`, Fehler `iCloudNeedsRepair`).
   Mac-Login über Sharing-Unlock-Manager (`pairDeviceForMacUnlock`, `unlockWithAuthenticationToken`).
4. **Transport** [B]: Rapport-Stream mit Typen `UDPSocket` / `RPCnx` / `UDPNWPath`; Kontrollkanal
   (`com.apple.oneness.sessionAndHIDMessages`); Modi `wired` / `wirelessly`.
5. **Medien** [B]: AVConference-Streams `com.apple.MediaTransport.video` / `.audio`. Offer/Answer
   (`negotiationOffer`/`negotiationAnswer`) laufen über den Kontrollkanal.
6. **iPhone-Seite** [I]: `com.apple.ScreenContinuityShell` rendert eine eigene Szene/Anzeige, während das Telefon
   gesperrt bleibt (Fehler `springBoardInvalidated`, `deviceUnlockedDuringSession`, `missingDisplayConfiguration`).
7. **Eingabe** [B]: HID-Reports, Tap-/Drag-Gesten, Drag & Drop, RTI-Text, Accessibility-Übersetzung, Orientierung.

## 3. Zweiter Pfad: Xcode/CoreDevice „View Device Screen“

- [B] `CoreDevice.framework` bietet die Actions `com.apple.coredevice.action.mediastream{getsupportinfo,start,status,stop}`
  und die Features `remote.hid.digitizer`, `remote.hid.button`, `remote.hid.scroll`, `remote.universalhid`,
  `devicecontrol.orientation`.
- [B] AVConference kennt den Modus `CoreDeviceScreenSharing` mit dem Gerätedienst `com.apple.CoreDevice.dtremotedisplayd`.
- [B] Das iPhone 15 (iOS 26.5, Developer Mode an, über `localNetwork` verbunden) meldet
  `com.apple.coredevice.feature.viewdevicescreen`; `screenViewingURL = devices://device/open?id=…`.
- [B] `CoreDeviceService.xpc` trägt `com.apple.private.CoreDevice.canViewDeviceDisplay` und `…CoreDevice.hid`.
  `devicectl` hat keine Entitlements und kein Mediastream-Kommando.
- [?] Ob ein fremder Client `mediastreamstart` über CoreDeviceService aufrufen darf, ist ungeprüft.
- [?] Ebenso ungeprüft: `dtremotedisplayd` direkt per RemoteXPC/RSD-Tunnel ansprechen.

## 4. Probe: CoreDevice-Media-Stream aus eigenem Tool (2026-10-19)

Werkzeug: eine kleine Probe (nicht im Repository). Ein handgeschriebenes Swift-Interface bildet die benötigten
exportierten Symbole nach. Das Tool ruft nur `getMediaStreamSupportInfo` und `getMediaStreamServerStatus` auf.

- [B] Ein eigenes, ad-hoc signiertes Tool ohne Entitlements kann `DeviceManager.shared` nutzen. Der XPC-Check-in bei
  `com.apple.CoreDevice.CoreDeviceService` gelingt, und die Geräteliste kommt an (iPhone + Watch).
- [B] Beide Media-Stream-Aufrufe enden mit `CoreDeviceError 9011`: „Unable to complete operation as this is using
  obsolete functionality … CoreDevice, DeviceKit, and Devices.app“.
- [B] Der Fehler entsteht **im Client** (`CoreDevice.framework`). Der Text steht nur dort, und das Service-Log
  zeigt für beide Läufe nur Check-in und Disconnect, keine Action.
- [B] Das iPhone meldet keine `mediastream*`- und keine `remote.hid.*`-Capability, nur `viewdevicescreen` und
  generisch `com.apple.dt.serviceconnection.create` / `servicesocket.create`.
- [B] Unter den 75 RSD-Diensten des iPhones (`/usr/libexec/remotectl show`) ist kein Display-, HID- oder Media-Dienst.
- [B] Das iOS-DDI (CoreDevice-518.27) enthält zwar `CoreDeviceMediaStreamSupport.framework`, aber keinen
  `dtremotedisplayd`-LaunchDaemon, und kein anderes DDI-Binary referenziert das Framework.
- [B] Der Handler für `devices://` („Devices.app“, `com.apple.dt.Devices`) ist auf diesem System nicht installiert.
  Xcode 26.4 referenziert die URL nicht.
- [I] Der alte Weg (CoreDevice-Actions + AVConference-Modus `CoreDeviceScreenSharing`) ist in dieser Version
  stillgelegt. Er wird offenbar durch einen Nachfolger aus „DeviceKit + Devices.app“ ersetzt, der hier noch nicht ausgeliefert ist.
- [B] Nebenbefund: Laut `remotectl` (`RegionInfo`) ist das Testgerät ein EU-Gerät. Das passt zur Region-Sperre aus
  Abschnitt 2.

## 5. Recherche: Device Hub („Devices.app“) – Stand 2026-10-19

Quellen (Web, nicht lokal verifiziert):
WWDC26 Session 260 „Get the most out of Device Hub“; Michael Tsai, „Xcode 27’s Device Hub“ (25.06.2026);
Apple Personal Safety Guide „Manage Device Hub access“; GitHub: getsentry/MobileBuildMCP#519,
JaviSoto/device-hub-ios, ALEXoicu/iPhone-Mirroring-Device-Hub, Jakeelamb/iphone-mirror-rs, boa-z/devicehub-mask.

- **Device Hub** ist eine eigenständige Mac-App, die mit **Xcode 27** ausgeliefert wird und die Simulator-App ersetzt
  (WWDC26). Kompaktfenster und Vollfenster zeigen einen Live-Bildschirm mit Klick, Drag, Scroll, Trackpad-Gesten,
  „Capture Keyboard“, Home/Rotation/Screenshot sowie Wireless-Pairing („Pair Nearby Device“, PIN).
- [I] „Devices.app“ / `com.apple.dt.Devices` aus der 9011-Fehlermeldung ist sehr wahrscheinlich Device Hub. Der
  Bundle-Name ist in den Quellen nicht bestätigt.
- **Bildschirm-Fernsteuerung nur mit iOS 27 auf dem Zielgerät** (Tsai, unter Berufung auf Troughton-Smith; dieser
  wünscht sich einen Backport auf iOS 26/18 per DDI). Das passt zu Abschnitt 4: Unter Xcode 26.4 und iOS 26.5 ist
  der alte Pfad stillgelegt und der neue nicht vorhanden.
- Voraussetzungen laut Quellen: Developer Mode, Pairing (USB oder lokales Netz).
  - Laut MobileBuildMCP#519 (unbestätigt) zusätzlich ab iOS 26+: Settings › Developer › UI Automation › „Enable UI Automation“
    bzw. „Paired Mac computers can remotely view and control this iPhone“.
  - Apple führt Sitzungsprotokolle unter Safety Check; abschalten lässt sich der Zugriff über Developer Mode aus.
- Neue CoreDevice-Features (iOS 27): `remote.hid.digitizer`, `remote.hid.keyboard`, `remote.hid.button`,
  `remote.hid.scroll`, `remote.universalhid`, `viewdevicescreen`. Video läuft als HEVC-Stream über den
  CoreDevice/RemoteXPC-Tunnel (laut Community-Projekten), nicht über AVConference/Rapport wie bei iPhone Mirroring.
- Keine offizielle API: `devicectl` (Xcode 27 Beta) hat `capture`/`appResize`, aber kein Input- oder Stream-Kommando.
- **Drittimplementierungen existieren bereits:**
  - `idevice` (Rust) bzw. `pymobiledevice3` implementieren Tunnel, RSD, Display-Transport und Universal HID, z. B.
    `pymobiledevice3 developer core-device universal-hid-service tap -- 32768 32768`.
  - `iphone-mirror-rs` ist ein Linux-Viewer (GPL-3.0), getestet mit iPhone 15 / iOS 27 über WLAN: rund 60 fps und
    ca. 59 ms synthetische Latenz, ohne Audio.
  - `device-hub-ios` (iOS-Client, Xcode 27.1) und `devicehub-mask` (AGPL-3.0, Browser/WebCodecs).
  - `iPhone-Mirroring-Device-Hub` ist nur ein AppleScript-Wrapper um Apples Device Hub, ausdrücklich als Ersatz für
    Regionen ohne iPhone Mirroring gedacht.
- Unterschiede zu iPhone Mirroring:
  - Device Hub braucht Developer Mode und Pairing.
  - Mitteilungs-Spiegelung und App-Start aus dem Mac-Dock fehlen.
  - Ein Hinweis auf eine Regionssperre fand sich in den Quellen nicht. Laut ALEXoicu verbindet Device Hub auch bei
    gesperrtem iPhone, und die Entsperrung per Code ist über den Mirror möglich.

### Dienstnamen laut pymobiledevice3 11.36.0 (lokal installiert, Hilfetexte)

- Display: `com.apple.coredevice.displayservice` mit den Kommandos `get-media-support-info`,
  `get-media-stream-server-status`, `start-video-stream` (RTP/HEVC), `start-audio-stream`, `serve-web` und `serve-vnc`.
  Auf dem iPhone läuft dafür der Daemon `dtremotedisplayd`.
- Eingabe: `com.apple.coredevice.hid.universalhidservice` (Kommando `universal-hid-service`) sowie `hid` für Tasten.
- Weitere nützliche Funktionen: `launch-application`, `list-apps`, `fetch-app-icon`, `paste`/`copy` (Zwischenablage),
  `get-lockstate`, `rotate`, `screen-capture`.
- [B] Unter iOS 26.5 ist `com.apple.coredevice.displayservice` nicht in der RSD-Liste des iPhones (Abschnitt 4).

### Geräteseite unter iOS 27 (DDI aus Xcode 27.1, Build 27A9275) – lokal geprüft

- [B] Das iPhone 15 läuft mit iOS 27.0.1 (24A446), Developer Mode an. Der Tunnel läuft über `localNetwork`,
  mit einer IPv6-ULA-Adresse als Tunnel-IP (`fdxx:…::1`).
- [B] Ohne gemountetes DDI fehlen Display/HID im RSD-Verzeichnis (65 Dienste). Das Mounten schlägt bei gesperrtem
  iPhone fehl (CoreDeviceError 12040 bzw. 10003 „device was still locked“).
- [B] Das DDI enthält drei neue LaunchDaemons (alle `UserName mobile`, `UsesRemoteXPC`):

| Daemon | RemoteService | RequireEntitlement | Features |
|---|---|---|---|
| `dtremotedisplayd` | `com.apple.coredevice.displayservice` | `com.apple.private.CoreDevice.canViewDeviceDisplay` | getmediasupportinfo, getmediastreamserverstatus, startaudiooutput, startvideooutput, startmediastream, stopmediastream |
| `dtuhidd` | `com.apple.coredevice.hid.indigo` | `com.apple.private.CoreDevice.hid` | remote.hid.button, .scroll, .digitizer, .vendordefined |
| `dtuhidd` | `com.apple.coredevice.hid.universalhid` | `com.apple.private.CoreDevice.hid` | remote.hid.keyboard, remote.universalhid |
| `dtuhidd` | `com.apple.coredevice.hid.universalhidservice` | `com.apple.private.CoreDevice.hid` | remote.universalhidservice |
| `dthidd` | `com.apple.coredevice.devicecontrol` | `com.apple.private.CoreDevice.devicecontrol` | remote.devicecontrol.orientation |

- [B] Nach dem Entsperren mountet `devicectl device info ddiServices` das DDI (`isCryptexDDI: true`). Danach meldet
  das RSD-Verzeichnis 86 Dienste, darunter alle fünf aus der Tabelle.

### Erster echter Stream (2026-10-19, iPhone 15 / iOS 27.0.1, WLAN)

- [B] Der System-Tunnel (`fdxx:…::1`) ist für normale Prozesse nicht erreichbar (`Errno 51`).
- [B] `pymobiledevice3 … --native` (über Apples `remotepairingd`, ohne Root, ohne Entitlements, ohne neue Kopplung)
  funktioniert. `RequireEntitlement` blockiert also keine gekoppelten Hosts.
- [B] `get-media-support-info`: `avcFrameworkVersion 2235.63.1.2`, `supportedFeatures 972` (gespiegeltes
  Hauptdisplay, System-Audio, virtuelles externes Display, Stream nach Display-ID, Display-Info, Screenshot).
- [B] `start-video-stream --duration 5`: 728 RTP-Pakete, daraus 264 Bilder, 0 verloren, ffmpeg dekodiert fehlerfrei.
  - RTP nach RFC 7798, PT 100. Am Anfang ein Aggregation Packet (VPS/SPS/PPS), sonst FUs. Header-Extensions
    (Profile `0x9001`/`0x9011`) und rtcp-mux (PT 72 = Sender Report).
  - **Videotakt 24 kHz**: ≈ 400 Ticks pro Bild, ≈ 55–60 fps.
  - **Nur ein IDR zu Beginn**, danach ausschließlich TRAIL_R. Bei Paketverlust braucht es eine Wiederanlauf-Strategie
    (neuer Stream oder Keyframe-Anforderung, noch offen).
  - **Kodiert 1184 × 2576** (HEVC Main, yuvj420p) für ein Display von 1179 × 2556 (`get-display-info`:
    `nativeSize 1179×2556`, `pointScale 3`). Aufgefüllt wird rechts/unten (Inhalt endet in Zeile 2555), daher schneidet
    PhoneMirror auf den Displaybereich zu.
- [B] `get-display-info` listet zusätzlich ein externes „Wireless-4“-Display (displayId 7).
- [B] PhoneMirror spielt den echten Mitschnitt korrekt zugeschnitten ab (`rtp-dump-to-h265` → `-replay`).

### Live-Betrieb über serve-web (2026-10-19)

- [B] PhoneMirror startet `serve-web --native` als Brücke. Bis zum ersten Bild vergehen ≈ 4 s.
  - Home (Indigo-HID), Touch (`/touch` contact/release, 0…65535) und Tastatur (`/key` mit der Menge gehaltener
    HID-Usages) wirken am iPhone: Home-Wechsel, Spotlight per Tipp, Texteingabe.
  - Beim Beenden stoppt der Prozess sauber (Status 0).
- [B] Laut pymobiledevice3-Quelltext:
  - Ohne RTCP-Receiver-Reports beendet das iPhone die Session nach ≈ 20 s.
  - PLI fordert einen neuen IDR an.
  - Bei Bewegung tritt ein „Resolution Collapse“ auf (Inhalt kleiner, grauer Rand).
  - An Slice-NALs kann ein 14-Byte-Anhang `04f00ac0000003000004ec0ab003` hängen; in unserem Mitschnitt kam er nicht vor.

### Systemgesten per HID (iPhone 15, iOS 27.0.1, `mainTouchscreen` 257) – am Gerät getestet

- [B] **Wischen vom unteren Rand (y = 65535) wirkt nicht**: kein Home, kein App-Umschalter, und auch die App bekommt
  den Touch nicht. Der gleiche Zug aus der Bildmitte scrollt normal.
- [B] **Wischen vom oberen Rand (y = 0) wirkt**: Die Mitteilungszentrale öffnet sich.
- [B] **Home zweimal schnell** (`/button home` down/up, 80 ms Pause, down/up) öffnet den App-Umschalter.
- [B] Bei ruhendem Bildschirm sendet das iPhone keine neuen Bilder; ein POST auf `/pli` erzwingt einen frischen Keyframe.
- Umsetzung in PhoneMirror:
  - Mausgesten, die am Home-Balken beginnen, werden ausgewertet statt gesendet: kurz nach oben = Home,
    mit Innehalten (≥ 0,3 s) = Home zweimal.
  - ⌘2 = Home zweimal.
  - Kantenfang nur noch oben und links.
- [?] Wie Device Hub die Home-Balken-Geste umsetzt, ist unbekannt (eventuell über Indigo-Digitizer/Mercury-Envelope,
  den pymobiledevice3 noch nicht kennt).

### Nativer Transport in Swift (2026-10-19) – am Gerät getestet

- [B] `remotepairingd` per libxpc (`RemotePairing.BrowseRequest`, `InitiatePairingCommand`,
  `CreateAssertionCommand`) liefert die Tunnel-IPv6. Das funktioniert ohne Root und ohne Entitlement in einer
  ad-hoc signierten App.
- [B] `nettop -n -x -L 1 -m tcp` zeigt `remoted`s RSD-Verbindung (Port). Die Handshake-UUID kommt aus
  `remotectl dumpstate` („Local device“).
- [B] Eigener HTTP/2- und XPC-Codec, Handshake in devicectl-Reihenfolge: RSD liefert 85 Dienste.
- [B] Das Medienangebot (bplist + zlib-9-Protobuf) ist byte-identisch zum Xcode-Mitschnitt (Unit-Test).
- [B] 5 s Video: 1428 RTP-Pakete, 290 Bilder, 58 fps, 0 verloren. 5 s Ton: 498 Pakete AAC-ELD, 0 Fehler.
- [B] Beim AAC-ELD-Decoder meldet `AudioConverterSetProperty` für das Magic Cookie `!dat`. Dekodiert wird
  trotzdem korrekt; pymobiledevice3 ignoriert den Wert ebenfalls.
- [B] Touch (`mainTouchscreen` 257), virtuelle Tastatur (`createService` 0x100002001) und Indigo-Tasten
  funktionieren in der App: Spotlight per Tipp, Texteingabe, App-Umschalter.
- [B] Screenshots von Fenstern auf einem anderen Space zeigen teils Bilder, die Sekunden alt sind. Das betrifft
  das Testwerkzeug, nicht die App.

### Zwischenablage nativ (2026-10-19)

- [B] `PULL` mit `promiseSecondary` liefert nur den primären Typ inline. Eine nachgestellte Safari-Kopie
  (HTML + Text) zeigt: iOS ergänzt `public.rtf`, Text und RTF sind nur versprochen.
- [B] `allResolved` braucht dafür > 8 s (Umrechnung auf dem Gerät). PhoneMirror übernimmt deshalb HTML/RTF direkt.
- [B] Fehler 26006 (`com.apple.dt.CoreDeviceError`): Der Inhalt trägt `com.apple.is-remote-clipboard` (kam per
  Universeller Zwischenablage) und wird nicht herausgegeben.
- [B] Am Mac tragen per Handoff übertragene Kopien ebenfalls `com.apple.is-remote-clipboard`. PhoneMirror schickt
  sie nicht zurück.
- [B] Eine zweite RSD-Verbindung (Probe-Tool) während die App läuft unterbricht deren Streams. Danach kam einmal
  bis zu 75 s kein Keyframe. Seitdem fordert der Watchdog per PLI nach, solange nach dem Start kein Keyframe kam.

### Bedienelement-Baum über WebDriverAgent (2026-10-19)

- [B] WebDriverAgent v16.15.3 lässt sich mit einem eigenen Entwickler-Team signieren und läuft unter iOS 27.0.1.
  `/source?format=json` liefert z. B. in den Einstellungen 171 Knoten in ≈ 3 s, `rect` in Punkten (393 × 852).
- [B] `TEST_RUNNER_USE_IP=<Tunnel-IP>` bindet WDA an den CoreDevice-Tunnel. Erreichbar ist es dann über
  `[fdxx::1]:8100` vom Mac; über die WLAN-IP war das iPhone vom Mac ohnehin nicht erreichbar.
- [B] xcodebuild/WDA und PhoneMirror (nativer RSD-Zugang) laufen parallel, ohne sich zu stören.
- [B] In iOS 27 sind die Einträge der Einstellungen `Button`s mit innerem `StaticText`, nicht `Cell`s.
- [B] Live per MCP getestet: `list_apps` (197 Apps), `launch_app`, `ui_tree`, `tap_element` (Navigation zu
  „Allgemein“), `type_into` (Suche in den Einstellungen).
- [B] Ad-hoc signierte App + Dateizugriff unter ~/Documents → TCC-Dialog blockiert den Aufruf. Daher liegen
  WDA-Build und Testdateien außerhalb von ~/Documents.

## 6. Offene Punkte

- Ob ein nicht gelisteter Dienst über `serviceconnection.create` erreichbar ist (nicht getestet: schreibender Eingriff).
- iOS-Binaries (ScreenContinuityShell, iOS-rapportd) wurden nicht untersucht.
- Wire-Format von Kontrollnachrichten und AVConference-Offer/Answer: nicht dekompiliert.
- Discovery per `dns-sd -B _rdlink._tcp`: Der Lauf brachte keine Ausgabe, daher ist die Sichtbarkeit ungeklärt.
- Ob „View Device Screen“ in Xcode 26.4 auf diesem Mac funktioniert, wurde nicht ausprobiert.

### Kamera-App per Agent (2026-10-19)

- [B] `launch_app com.apple.camera` startet die Kamera; Umschalten auf die Frontkamera und Auslösen per Touch
  funktionieren.
- [B] Im Spiegelbild bleibt die Kamera-Vorschau schwarz.
- [B] WebDriverAgent erkennt die Kamera nicht als aktive App (`bundleId local.pid.0`, `pid 0`); `/source` scheitert.
  Agents müssen dort mit Screenshot und Koordinaten arbeiten.
- [B] Während die Kamera lief, schloss das iPhone die HID-Verbindungen, das Video lief weiter. PhoneMirror verbindet
  HID seitdem bei einem Sendefehler neu und wiederholt die Eingabe.
