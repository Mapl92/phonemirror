# PhoneMirror

An open-source Mac client that shows the screen of a paired iPhone live and lets you control it with mouse,
keyboard or an AI agent (MCP). It uses the developer services Apple introduced with Xcode 27 and iOS 27 for
Device Hub.

## Features

- Live video at about 60 fps (HEVC, hardware decoding), audio, touch, keyboard, Home/Lock/Volume buttons
- Clipboard sync in both directions, including rich text
- Automatic reconnect and Developer Disk Image mounting
- MCP server for AI agents: accessibility tree, tap by label, text input, screenshots, app launching

Usage, setup and architecture: **[PhoneMirror/README.md](PhoneMirror/README.md)** ·
Protocol findings: **[FINDINGS.md](FINDINGS.md)**

## Download

Get the latest signed and notarized build from the
**[Releases page](https://github.com/Mapl92/phonemirror/releases/latest)**: open `PhoneMirror-<version>.dmg` and drag
PhoneMirror to Applications. SHA-256 checksums are attached to each release.

The download covers mirroring and control. For the agent accessibility tree you still need this repository once to
build WebDriverAgent (`PhoneMirror/Scripts/build-wda.sh`, see [PhoneMirror/README.md](PhoneMirror/README.md)).

## Requirements

- Mac with macOS 27 and Xcode 27 installed (PhoneMirror mounts the Developer Disk Image itself, but needs the image
  files Xcode installs; agent control also uses Xcode)
- iPhone with iOS 27, Developer Mode enabled and paired with this Mac
- For agent control: an Apple developer account to sign WebDriverAgent once

To build from source instead:

```bash
cd PhoneMirror
swift test
Scripts/bundle-app.sh
open build/PhoneMirror.app
```

## Disclaimer

- PhoneMirror is an **unofficial** project. It relies on undocumented Apple developer interfaces that may change or
  disappear with any iOS, macOS or Xcode update.
- The software is provided **without any warranty** (see sections 15 and 16 of the [license](LICENSE)). Use it at
  your own risk.
- Only use PhoneMirror with **your own devices** or devices you are authorized to use.
- **Agent control:** A connected AI agent can do anything on the iPhone that you can, including sending messages,
  making purchases or deleting data. The MCP server only listens on `127.0.0.1` and requires a token. Still, keep an
  eye on what the agent does, and turn agent control off when you don't need it.
- PhoneMirror neither uses Apple's iPhone Mirroring service nor circumvents its regional availability. It only talks
  to the developer services that iOS offers to paired Macs when Developer Mode is enabled.
- The protocols were determined for the purpose of interoperability: by observing the author's own device and by
  referring to the open-source project pymobiledevice3. This repository contains no Apple code.

## Trademarks

Apple, iPhone, iOS, macOS, Xcode and iPhone Mirroring are trademarks of Apple Inc., registered in the U.S. and other
countries. PhoneMirror is an independent project and is not affiliated with, endorsed by or reviewed by Apple Inc.
Trademarks are used only to describe compatibility.

## Acknowledgements

- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) (GPL-3.0): the tunnel, RemoteXPC and CoreDevice
  service implementations are closely modeled on it; it also serves as an alternative connection mode.
- [WebDriverAgent](https://github.com/appium/WebDriverAgent) (Appium, BSD-3-Clause): provides the accessibility
  tree. It is not included in this repository; `PhoneMirror/Scripts/build-wda.sh` clones and builds it.

## License

PhoneMirror is licensed under the **GNU General Public License v3.0 or later** (`GPL-3.0-or-later`), see
[LICENSE](LICENSE). Anyone who distributes PhoneMirror or derivative works must make the source code available under
the same license.
