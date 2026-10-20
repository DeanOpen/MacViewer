# LinuxViewer

UltraViewer-compatible remote desktop for Linux, written in Rust. It is the
Linux counterpart of MacViewer and speaks the same protocol, ported from
`Sources/UltraViewerProtocol`.

> [!IMPORTANT]
> Experimental. LinuxViewer is a personal open-source project, **not** an
> official UltraViewer product. Only connect to computers you are allowed to
> access.

## Features

- **Connect:** enter the ID and password shown by UltraViewer (or MacViewer)
  on the other computer to view and control it. TLS relay, zstd and JPEG
  screen updates, mouse, wheel and keyboard (Windows key codes, Unicode text
  through VK_PACKET), and the remote cursor shape.
- **Host:** let a Windows UltraViewer user view or control this Linux
  desktop. You approve each connection in the terminal. Supports a fixed master
  password and a lockout after 5 wrong passwords. **X11 only** for now: under
  Wayland, log in to an X11 session.

Not supported yet: chat, clipboard, file transfer, audio, LAN direct and
Wayland hosting.

## Install

Debian, Ubuntu, Linux Mint (x86_64):

```sh
curl -L -o linuxviewer.deb https://github.com/DeanOpen/MacViewer/releases/latest/download/linuxviewer-amd64.deb
sudo apt install ./linuxviewer.deb
```

Or the portable tarball (any distro, no install):

```sh
curl -L https://github.com/DeanOpen/MacViewer/releases/latest/download/linuxviewer-x86_64.tar.gz | sudo tar -xz -C /
```

Then run `linuxviewer`.

## Build from source

Requirements: Rust 1.80+, plus on Linux `libxkbcommon-dev`, `libx11-dev`,
`libxcb1-dev`, `libasound2-dev`, `libpipewire-0.3-dev` and `libclang-dev` (drop
PipeWire with `--no-default-features`, which also removes Wayland hosting). The
crate reads `../Sources/UltraViewerProtocol/Resources/8bit.dat`, so build it
inside a full checkout of this repository.

```sh
cd LinuxViewer
cargo test
cargo build --release
```

The binary is `target/release/linuxviewer`.

## Usage

```sh
linuxviewer connect 123456789          # asks for the password
linuxviewer connect 123456789 --password 1234
linuxviewer host                       # share this X11 desktop
linuxviewer id [--host]                # register and print this machine's ID/password
linuxviewer master-password [--clear]  # set a fixed password for hosting
```

In the viewer window:

| Key | Action |
|---|---|
| <kbd>F12</kbd> or <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>C</kbd> | Turn Control on/off |
| Close the window | Disconnect |

While hosting, a viewer that connects is shown in the terminal:

| Key | Action |
|---|---|
| `y` | Allow view and control |
| `v` | Allow view only |
| `n` | Refuse |
| `c` + Enter | Turn the viewer's control on/off during the session |
| `x` + Enter | End the session |

Settings are stored in `$XDG_CONFIG_HOME/linuxviewer/` (normally
`~/.config/linuxviewer/`). Set `LINUXVIEWER_NAME` to change the display name
the other side sees.

## Layout

```
src/
  wire.rs, messages.rs   Framing, envelopes, legacy cipher, registration/lookup/login text
  tls.rs, command.rs     Relay TLS and the functions3 command channel
  profile.rs             Stable ID, password and device identity
  client.rs, ui.rs       Viewer session and winit/softbuffer window
  screen/                Screen init/frame parsing, zstd + JPEG renderer
  input.rs, cursor.rs    Mouse/keyboard messages and remote cursor
  host/                  Hosting session, encoder, X11 capture and XTEST input
```

## License

MIT, see [LICENSE](../LICENSE).
