# PhoneMirror

Eigener Mac-Client für die iPhone-Spiegelung über das Device-Hub-Protokoll (CoreDevice, ab iOS 27).
Hintergrund und Reverse-Engineering-Befunde: [../FINDINGS.md](../FINDINGS.md).

Getestet mit iPhone 15 und iOS 27.0.1 auf macOS 27.0.1 mit Xcode 27.1:

| Funktion | Stand |
|---|---|
| Bild | ≈ 58 fps, Hardware-Dekodierung, Zuschnitt auf das echte Display |
| Touch, Tastatur, Tasten | funktionieren |
| Home-Balken und App-Umschalter | funktionieren |
| Ton und Zwischenablage | vorhanden |
| Wiederverbinden und DDI-Mount | automatisch |

## Voraussetzungen

- iPhone mit iOS 27, Developer Mode und Einstellungen › Entwickler › „UI-Automation aktivieren“.
- Das iPhone ist mit diesem Mac gekoppelt (Xcode/Device Hub).
- Xcode 27 für `devicectl`. Damit mountet die App das Developer Disk Image selbst; das iPhone muss dabei
  entsperrt sein.
- Nur für die Verbindungsart „pymobiledevice3“: `uv tool install pymobiledevice3` (≥ 11.36).

## Bauen und starten

```bash
swift test                     # Unit-, Pipeline- und Protokolltests
Scripts/bundle-app.sh          # → build/PhoneMirror.app (mit Icon)
open build/PhoneMirror.app
```

Ohne Gerät gibt es den Replay-Modus mit einer Testdatei. Die Datei sollte außerhalb von `~/Documents` liegen, sonst
fragt macOS bei jedem Neubau nach Ordnerzugriff:

```bash
swift run -c release hevc-test-stream /tmp/test.h265 4 1179 2556 collapse
open build/PhoneMirror.app --args -replay /tmp/test.h265
```

## Bedienung

| Eingabe | Wirkung |
|---|---|
| Klicken, Ziehen | Touch |
| Trackpad-Scrollen | Wischgeste (ohne doppelten Schwung) |
| Rechtsklick | Home |
| Tastatur | geht ans iPhone, Hardware-Tastatur-Usages |
| ⌘1 / ⌘2 / ⌘3 | Homescreen / App-Umschalter / Spotlight |
| ⌘L, ⌘↑ / ⌘↓ | Sperren, Lautstärke |
| ⌘⌥T | Ton an/aus |
| Gerät › Zwischenablage teilen | Abgleich Mac ↔ iPhone an/aus |
| Gerät › Verbindung | Nativ oder pymobiledevice3 |
| ⌘+ / ⌘− / ⌘0 | Fenstergröße; Größe und Position werden gespeichert |

Gesten am Rand:
- **Home-Balken:** Unten klicken und nach oben ziehen ergibt Home. Mit kurzem Innehalten vor dem Loslassen öffnet
  sich der App-Umschalter. iOS ignoriert injizierte Touches am unteren Rand, daher der Umweg über die Home-Taste.
- **Oben und links:** Touches, die bis 12 pt unter der Oberkante bzw. 8 pt neben der linken Kante beginnen,
  starten exakt auf der Kante. So funktionieren Mitteilungen, Kontrollzentrum und Zurück.

Zwischenablage:
- Was auf dem iPhone kopiert wird, landet nach etwa einer Sekunde am Mac. Formatierter Text (Safari, Mail,
  Notizen) kommt als HTML/RTF und zusätzlich als reiner Text.
- Kopien vom Mac gehen nur aufs iPhone, solange PhoneMirror aktiv ist.
- Was Apples Universelle Zwischenablage (Handoff) schon übertragen hat (Typ `com.apple.is-remote-clipboard`),
  schickt PhoneMirror nicht zurück. Sonst würden formatierte iPhone-Kopien zu reinem Text.

## Agent-Steuerung (MCP)

PhoneMirror enthält einen MCP-Server, über den KI-Agents das iPhone steuern. Er nutzt dieselbe Verbindung wie
das Fenster, du siehst also live, was der Agent tut. Ein Hinweis „Agent steuert“ und die berührte Stelle werden
eingeblendet, und du kannst jederzeit eingreifen.

- Adresse: `http://127.0.0.1:8765/mcp` (Streamable HTTP, nur lokal), geschützt per Bearer-Token und Origin-Prüfung.
- Ein- und ausschalten: Gerät › Agent-Steuerung (MCP).
- **Einbinden in Claude Code:** Gerät › „MCP-Befehl für Claude Code kopieren“ legt den fertigen Befehl in die
  Mac-Zwischenablage, nicht aufs iPhone. Dann im Terminal einfügen und ausführen:

  ```
  claude mcp add --transport http phonemirror http://127.0.0.1:8765/mcp --header "Authorization: Bearer <token>"
  ```

Werkzeuge mit Bedienelement-Baum (über WebDriverAgent, bevorzugt):

| Tool | Zweck |
|---|---|
| `ui_tree` | Nummerierte Liste der Bedienelemente der App im Vordergrund: Typ, Beschriftung, Wert, Position. Etwa 1.000–2.000 Tokens statt eines Bildes |
| `find_elements` | Suche nach Text und/oder Typ (Button, Cell, TextField …) |
| `tap_element` | Tippt per ID oder sichtbarem Text. Bedienbare Elemente gewinnen vor reinem Text; passt der Typ nicht, wird ohne Typ gesucht |
| `type_into` | Textfeld per Beschriftung/Platzhalter antippen und Text einfügen |

Weitere Werkzeuge:

| Tool | Zweck |
|---|---|
| `screenshot` | JPEG des Bildschirms; Bildgröße = Koordinatenraum in Punkten (iPhone 15: 393 × 852) |
| `device_info` | Verbindung, Bildschirmgröße, Alter des letzten Bildes |
| `tap`, `double_tap`, `long_press`, `swipe` | Touch-Gesten in Punkten |
| `type_text` | Text einfügen (Zwischenablage + ⌘V, beliebige Sprache), optional mit Return |
| `press_key` | Taste mit Modifiern (z. B. ⌘A) |
| `press_button` | Home, Sperren, Lautstärke, Siri |
| `system_action` | Home, App-Umschalter, Spotlight, Mitteilungszentrale, Kontrollzentrum |
| `list_apps`, `launch_app` | Apps auflisten bzw. per Bundle-ID starten (nur Verbindung „Nativ“) |
| `get_clipboard`, `set_clipboard` | Zwischenablage des iPhones |
| `wait` | Auf Animationen warten |

### WebDriverAgent (einmalig einrichten)

Den Bedienelement-Baum liefert [WebDriverAgent](https://github.com/appium/WebDriverAgent) (Appium, BSD-Lizenz).
Er läuft als UI-Test-Runner auf dem iPhone und muss einmal mit deinem Apple-Entwickler-Team gebaut werden:

```bash
Scripts/build-wda.sh <Team-ID> [Bundle-ID-Präfix]   # Team-ID z. B. aus `security find-identity -p codesigning -v`
```

Mit einem kostenlosen Account muss die Bundle-ID weltweit eindeutig sein; dann einen eigenen Präfix angeben
(z. B. `com.deinname.phonemirror`).

Danach startet PhoneMirror WDA selbst, sobald die Agent-Steuerung an und das iPhone verbunden ist (≈ 10 s):
- Mit `xcodebuild test-without-building` und **gebunden an die Tunnel-Adresse** (`TEST_RUNNER_USE_IP`). WDA ist
  also nicht im WLAN erreichbar, nur über den CoreDevice-Tunnel dieses Macs.
- Nach einem Tunnelwechsel startet PhoneMirror es neu; beim Beenden oder Abschalten stoppt es.
- Log: `~/Library/Logs/PhoneMirror/wda.log`
- Signaturdauer: Mit bezahltem Entwickler-Account gilt die Signatur ein Jahr, mit kostenlosem 7 Tage (dann
  Skript erneut ausführen).

Grenzen:
- Der Baum zeigt nur, was Apps an Bedienhilfen-Informationen liefern. Spiele, Canvas-Inhalte und unbeschriftete
  Symbole brauchen weiterhin `screenshot`.
- `type_text`/`type_into` überschreiben die iPhone-Zwischenablage. Bei aktiver Universeller Zwischenablage
  landet der Text auch am Mac.

## Verbindungsarten

**Nativ (Standard).** Läuft komplett in Swift, ohne Python:
1. `remotepairingd` (libxpc) liefert den bestehenden CoreDevice-Tunnel.
2. `nettop` findet den RSD-Port von `remoted`.
3. Über RemoteXPC (HTTP/2 + XPC) geht es zum Display-, HID- und Pasteboard-Dienst.
4. Video und Ton kommen per RTP über UDP. Die App schickt RTCP-Receiver-Reports und fordert bei Verlust per
   PLI ein Keyframe an.

**pymobiledevice3 (serve-web).** Startet `serve-web --native` als lokale Brücke auf 127.0.0.1 mit
Zufallspasswort.

Beide Wege teilen sich den Tunnel mit Apples `remoted`. Während PhoneMirror läuft, können Xcode und
`devicectl` das iPhone zeitweise verlieren.

## Aufbau

| Modul | Inhalt |
|---|---|
| `MirrorCore` | Transport-Schnittstelle, HEVC (Annex B, Access Units, SampleBuilder, VideoToolbox-Decoder, Collapse-Erkennung), RTP-Depacketizer, Eingabe (TouchMapper, KeyMapping, Gesten, `InputActionEncoder`), serve-web-Transport, DDI-Vorbereitung |
| `MirrorMCP` | MCP-Server: JSON-RPC 2.0, Streamable HTTP (NWListener), Token/Origin-Schutz |
| `MirrorNative` | Nativer Transport: XPC-Wire-Format, HTTP/2, RemoteXPC, Tunnel, RSD, CoreDevice-Dienste, Medienangebot, RTP/RTCP, AAC-ELD |
| `PhoneMirror` | AppKit-App: Fenster, Video-Layer (IOSurface + `contentsRect`), Ton (AVAudioEngine), Zwischenablage, Menüs, Einstellungen |
| `MirrorTestSupport`, `HEVCTestStream` | Synthetische HEVC-Streams (auch mit Resolution Collapse) |
| `RTPDumpToH265`, `NativeProbe` | Werkzeuge: RTP-Mitschnitt → H.265 und Schichttests des nativen Transports (`swift run native-probe rsd\|video\|audio`) |

## Lizenz

PhoneMirror steht vollständig unter der GPL-3.0-or-later (siehe [../LICENSE](../LICENSE)); die Dateien tragen
SPDX-Köpfe. `MirrorNative` ist eng an pymobiledevice3 (ebenfalls GPL-3.0) angelehnt. Haftungsausschluss und
Markenhinweis stehen im [Haupt-README](../README.md).

## Offen

- **Bild-Latenz:** Gefühlt messen und gegebenenfalls RCTL-Feedback ergänzen (in pymobiledevice3 standardmäßig aus).
- **Displaygröße:** Wird nicht vom Gerät gelesen; voreingestellt ist das iPhone 15.
- **Zwischenablage nativ:** Abfrage einmal pro Sekunde statt Darwin-Notification. Gelesen werden nur die primären
  Typen; der Abruf aller Darstellungen blockiert den iOS-Dienst (≥ 8 s, laut pymobiledevice3 bis 64 s).
- **Probe-Tool:** `native-probe` nicht parallel zur laufenden App benutzen. Die zweite RSD-Verbindung stört deren
  Streams; die App verbindet sich zwar neu, Tests sind dann aber verfälscht.
