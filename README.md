# PhoneMirror

Ein quelloffener Mac-Client, der den Bildschirm eines gekoppelten iPhones live zeigt und es per Maus, Tastatur
oder KI-Agent (MCP) steuert. Er nutzt die Entwicklerdienste, die Apple mit Xcode 27 und iOS 27 für den Device Hub
eingeführt hat.

> **English summary:** PhoneMirror is an unofficial, open-source macOS client that mirrors and controls a paired
> iPhone (iOS 27, Developer Mode) using the CoreDevice developer services that back Xcode's Device Hub: about
> 60 fps HEVC video, audio, touch, keyboard, hardware buttons and clipboard sync, written natively in Swift.
> A built-in MCP server lets AI agents operate the phone through an accessibility tree (via WebDriverAgent) and
> real HID input. Not affiliated with Apple. Use at your own risk. Licensed under GPL-3.0-or-later.

## Funktionen

- Live-Bild mit etwa 60 fps (HEVC, Hardware-Dekodierung), Ton, Touch, Tastatur, Home/Sperren/Lautstärke
- Zwischenablage in beide Richtungen, auch formatierter Text
- Automatisches Wiederverbinden und Mounten des Developer Disk Image
- MCP-Server für KI-Agents: Bedienelement-Baum, Tippen per Beschriftung, Texteingabe, Screenshots, Apps starten

Bedienung, Einrichtung und Aufbau: **[PhoneMirror/README.md](PhoneMirror/README.md)** ·
Protokoll-Befunde: **[FINDINGS.md](FINDINGS.md)**

## Voraussetzungen

- Mac mit macOS 27 und Xcode 27
- iPhone mit iOS 27, Developer Mode an und mit diesem Mac gekoppelt
- Für die Agent-Steuerung: ein Apple-Entwickler-Account, um WebDriverAgent einmalig zu signieren

```bash
cd PhoneMirror
swift test
Scripts/bundle-app.sh
open build/PhoneMirror.app
```

## Haftungsausschluss

- PhoneMirror ist ein **inoffizielles** Projekt. Es nutzt undokumentierte Entwicklerschnittstellen von Apple, die sich
  mit jedem iOS-, macOS- oder Xcode-Update ändern oder wegfallen können.
- Die Software wird **ohne jede Gewähr** bereitgestellt (siehe Abschnitte 15 und 16 der [Lizenz](LICENSE)). Die
  Nutzung erfolgt auf eigenes Risiko.
- Verwende PhoneMirror nur mit **eigenen Geräten** bzw. mit Geräten, für die du die Erlaubnis hast.
- **Agent-Steuerung:** Ein angebundener KI-Agent kann auf dem iPhone alles tun, was du auch tun kannst, also auch
  Nachrichten senden, Käufe auslösen oder Daten löschen. Der MCP-Server lauscht nur auf `127.0.0.1` und verlangt ein
  Token. Behalte trotzdem im Blick, was der Agent tut, und schalte die Agent-Steuerung ab, wenn du sie nicht brauchst.
- PhoneMirror nutzt weder Apples iPhone-Mirroring-Dienst noch umgeht es dessen regionale Verfügbarkeit. Es spricht
  ausschließlich die Entwicklerdienste an, die iOS gekoppelten Macs bei aktiviertem Developer Mode anbietet.
- Die Protokolle wurden zur Herstellung der Interoperabilität ermittelt: durch Beobachtung des eigenen Geräts und
  anhand des quelloffenen Projekts pymobiledevice3. Das Repository enthält keinen Code von Apple.

## Marken

Apple, iPhone, iOS, macOS, Xcode und iPhone Mirroring sind Marken von Apple Inc., eingetragen in den USA und
anderen Ländern. PhoneMirror ist ein unabhängiges Projekt und steht in keiner Verbindung zu Apple Inc.; es wird
von Apple weder unterstützt noch geprüft. Markennamen werden nur verwendet, um die Kompatibilität zu beschreiben.

## Danksagung

- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) (GPL-3.0): Tunnel, RemoteXPC und die
  CoreDevice-Dienste sind daran angelehnt; außerdem dient es als alternative Verbindungsart.
- [WebDriverAgent](https://github.com/appium/WebDriverAgent) (Appium, BSD-3-Clause): liefert den
  Bedienelement-Baum. Es ist nicht im Repository enthalten; `PhoneMirror/Scripts/build-wda.sh` klont und baut es.

## Lizenz

PhoneMirror steht unter der **GNU General Public License v3.0 oder später** (`GPL-3.0-or-later`), siehe
[LICENSE](LICENSE). Wer PhoneMirror oder abgeleitete Werke weitergibt, muss den Quelltext unter derselben Lizenz
zugänglich machen.
