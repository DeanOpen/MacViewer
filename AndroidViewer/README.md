# AndroidViewer

Control a computer running UltraViewer from an Android phone: see its screen,
use touch as the mouse and type with the phone keyboard.

> [!IMPORTANT]
> Experimental draft. Not an official UltraViewer product. Only connect to
> computers you are allowed to access.

The protocol is LinuxViewer's Rust core (`../LinuxViewer`, built without its
desktop feature). `core/` is a small JNI bridge to it, and `app/` is the Kotlin
and Jetpack Compose app.

## Controls

| Gesture | On the computer |
|---|---|
| Tap | Left click (tap twice for a double-click) |
| Long press | Right click |
| Drag with one finger | Left-button drag |
| Two-finger swipe | Scroll wheel (when not zoomed in) |
| Pinch / two-finger drag | Zoom and pan the view; **Fit** resets it |

**Keyboard** opens the phone keyboard and a key row: Esc, Tab, arrows, Del,
Home/End, PgUp/PgDn and F1–F12. Ctrl, Alt, Win and Shift are sticky: tap one,
then a key or letter (Ctrl, then C sends Ctrl+C). Typed text is sent as Unicode,
so any language and input method works.

## Build

Requirements: Android SDK with NDK 28.2.13676358, JDK 17 or 21, and Rust from
rustup with the Android targets and cargo-ndk:

```sh
rustup target add aarch64-linux-android x86_64-linux-android
cargo install cargo-ndk
```

Then:

```sh
cd AndroidViewer
./gradlew assembleDebug    # app/build/outputs/apk/debug/app-debug.apk
```

Gradle runs `cargo ndk` for you (the `cargoBuild` task) and puts the libraries
in `app/src/main/jniLibs`. It uses `~/.cargo/bin/cargo` when present, so a
Homebrew Rust earlier on the PATH does not get in the way.

## Not done yet

- Remote cursor shape, sound, chat, clipboard and file transfer.
- Saved passwords and recent IDs (only the last ID is remembered).
- A trackpad mode for precise pointing.
- Same limits as LinuxViewer: Windows UltraViewer 6.0 or later in 16-bit
  colour mode, ASCII passwords, relay or LAN direct connections.
