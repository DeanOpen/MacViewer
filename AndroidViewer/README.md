# AndroidViewer

Control a computer running UltraViewer from an Android phone (Android 10 or
later): see its screen, use touch as the mouse and type with the phone keyboard.

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

The **⋮** menu, as in MacViewer:

- **Actions:** Send Ctrl-Alt-Delete, Lock remote screen, Restart remote computer
  (asks first), Release pressed keys and buttons, Save screenshot (to
  Pictures/AndroidViewer).
- **Monitor:** show all monitors or one of them (shown when there are several).
- **Image quality:** Automatic, Prefer speed (less mobile data), Prefer image quality.
- **Show remote wallpaper** and **Show remote pointer**.

The app is in English and Vietnamese and follows the phone's language; **⚙**
on the connect screen picks one instead.

Successful connections are listed under **Recent**. With **Remember password**
ticked, the password is stored encrypted with a key kept in the Android
Keystore; app backups are off, so it never leaves the phone.

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
./gradlew testDebugUnitTest assembleDebug   # app/build/outputs/apk/debug/app-debug.apk
```

Gradle runs `cargo ndk` for you (the `cargoBuild` task) and puts the libraries
in `app/src/main/jniLibs`. It uses `~/.cargo/bin/cargo` when present, so a
Homebrew Rust earlier on the PATH does not get in the way.

## GitHub Actions: build and sign

`.github/workflows/android.yml` runs the Rust core and app tests, builds a
release APK and uploads it as the `androidviewer-apk` artifact on every push
that touches `AndroidViewer/` or `LinuxViewer/`. Pushing a tag such as
`android-v0.2.0` also publishes `androidviewer-0.2.0.apk` as a GitHub Release.

To sign with your own key, create it once and keep the file and passwords
somewhere safe (losing it means users must uninstall to update):

```sh
keytool -genkeypair -keystore androidviewer-release.jks -alias androidviewer \
  -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=AndroidViewer"
```

Then add four repository secrets (Settings → Secrets and variables → Actions):

```sh
base64 -i androidviewer-release.jks | gh secret set ANDROID_KEYSTORE_BASE64
gh secret set ANDROID_KEYSTORE_PASSWORD
gh secret set ANDROID_KEY_ALIAS        # androidviewer
gh secret set ANDROID_KEY_PASSWORD
```

Never commit the `.jks` file. Without the secrets, CI signs with a throwaway
debug key: the APK installs, but cannot update a copy signed with another key.

## Not done yet

- Sound, chat, clipboard and file transfer (the Rust core already has them).
- A trackpad mode for precise pointing.
- Same limits as LinuxViewer: Windows UltraViewer 6.0 or later in 16-bit
  colour mode, ASCII passwords, relay or LAN direct connections.
