<div align="center">

<img src="docs/images/app-icon.png" width="128" alt="MacViewer icon">

# MacViewer

**A native macOS client for UltraViewer: control another computer from your Mac, or share your Mac.**

[Tiếng Việt](README.md) · **English**

### [Download MacViewer for macOS](https://github.com/DeanOpen/MacViewer/releases/latest/download/MacViewer.dmg)

Latest version, DMG, macOS 14 or later · [All releases](https://github.com/DeanOpen/MacViewer/releases/latest)

[![CI](https://github.com/DeanOpen/MacViewer/actions/workflows/ci.yml/badge.svg)](https://github.com/DeanOpen/MacViewer/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/DeanOpen/MacViewer?sort=semver)](https://github.com/DeanOpen/MacViewer/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6-orange)

<img src="docs/images/main-window.png" width="820" alt="MacViewer main window">

</div>

---

MacViewer connects to other computers running [**UltraViewer**](https://ultraviewer.net) (or MacViewer)
and accepts approved connections from them. It's built with SwiftUI and AppKit on
top of a Swift/C protocol engine. It doesn't use Wine, and it doesn't run any
Windows executable code.

> [!IMPORTANT]
> MacViewer is an independent, community-built implementation. It's **not**
> an official UltraViewer product and isn't affiliated with or endorsed by the
> UltraViewer developers. Only connect to computers you're authorized to access.

## Features

### Connect (control another computer)

- Connect with the partner **ID and password** shown in UltraViewer on the other computer
- Encrypted partner lookup and login, TLS relay with certificate validation,
  and a **direct LAN connection** that falls back to the relay when needed
- Fast screen decoding (Zstandard dictionary, RGB555/JPEG, scroll/copy, tile cache)
- Keyboard and mouse control that you turn on yourself:
  <kbd>⌘</kbd> → Win, <kbd>⌥</kbd> → Alt, <kbd>⌃</kbd> → Ctrl,
  with trackpad and wheel scrolling
- Toolbar with monitor selection, scaling, quality, wallpaper, remote cursor
  and **remote computer audio**
- Screenshots with region selection and annotations, and **video recording**
- Floating **chat** panel and opt-in two-way **clipboard** sharing
- Optional password storage in the macOS **Keychain**

### Share (share this Mac)

- Share the Mac's screen with another UltraViewer user, after you approve
  each connection on the Mac
- A built-in guide for granting **Screen Recording** and **Accessibility**
  permissions
- You approve viewing or control separately. You can end a session or pause
  incoming access at any time.

### General

- English and Tiếng Việt UI, or follow the system language
- Universal binary (Apple silicon + Intel), macOS 14 Sonoma or later

### Not supported yet

File transfer, microphone/voice chat, Mac-host audio, sharing more than one Mac
display, and unattended Mac access. Older Windows UltraViewer versions,
non-US keyboard layouts/IME and 8-bit screen mode haven't been validated.

## Installation

1. [**Download MacViewer.dmg**](https://github.com/DeanOpen/MacViewer/releases/latest/download/MacViewer.dmg) (latest version), or pick another
   version on the [Releases](https://github.com/DeanOpen/MacViewer/releases/latest) page.
2. Open the DMG and drag **MacViewer** into **Applications**.
3. If the release isn't notarized, macOS will block the first launch. Right-click
   the app, choose **Open**, then confirm. You can also run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/MacViewer.app
   ```

MacViewer shows an **Update to …** button in its title bar when a new version
is out. Click it, read what's new, then click **Update and Restart**: the app
downloads the update, checks its signature, installs it and reopens. You can
also choose **MacViewer → Check for Updates…** from the menu bar.

## Usage

**Connect to another computer:** Type the partner's **ID** and **password**
shown in UltraViewer, then click **Connect to another computer**. To send
keyboard and mouse input, turn on **Control** in the session toolbar.

**Share this Mac:** Click **Start sharing this Mac** and follow the permission
guide:

| Permission | Required for |
| --- | --- |
| Screen Recording | Letting the other computer see your screen |
| Accessibility | Letting the other computer control the keyboard and mouse |

Enter the Mac's ID and password on the other computer, then approve the request
on the Mac. If macOS asks, reopen MacViewer after you change Screen Recording.

## Building from source

Requirements: macOS 14+, Xcode 16+ / Swift 6+.

```sh
git clone https://github.com/DeanOpen/MacViewer.git
cd MacViewer

swift test                       # run the test suite
scripts/package_app.sh release   # build dist/MacViewer.app
open dist/MacViewer.app
```

## Project layout

```
Sources/
  MacViewer/              SwiftUI/AppKit app (UI, capture, input, hosting)
  UltraViewerProtocol/    Protocol engine: crypto, relay, screen codec, audio
ThirdParty/
  zstd/                   Zstandard 1.5.7 (BSD / GPLv2)
  g722/                   WebRTC G.722 decoder
Tests/                    Protocol and app unit tests
scripts/                  App packaging, icon and DMG generation
```

## Contributing

Issues and pull requests are welcome. Before you open a PR, please:

1. Run `swift test` and make sure it passes.
2. Keep new user-facing strings in both `en.lproj` and `vi.lproj`.
3. Never commit credentials, partner IDs, session tokens or UltraViewer binaries.

## Privacy

MacViewer doesn't collect telemetry. The update check only reads public
release information from GitHub, and you can turn it off in Settings. Passwords are saved only when you choose
to remember them, and only in the macOS Keychain. They're never written to
recent-partner history, UserDefaults or registration profiles.

## License

MacViewer is released under the [MIT License](LICENSE).

Bundled third-party components keep their own licenses. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The `8bit.dat` screen
dictionary is an UltraViewer-supplied data asset and is **not** covered by the
MIT license.

UltraViewer is a trademark of its respective owner and is used here only to
describe compatibility.
