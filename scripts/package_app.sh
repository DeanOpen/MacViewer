#!/bin/zsh
set -euo pipefail

# Produce the local signed Mac app without executing supplied Windows code.
project_root="${0:A:h:h}"
cd "$project_root"
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
  print -u2 "Usage: scripts/package_app.sh [release|debug]"
  exit 2
fi

# Pin the chosen local identity so a later update cannot silently switch back
# to an ad-hoc signature and invalidate the user's privacy grants.
signing_identity="${MACVIEWER_SIGNING_IDENTITY:-}"
identity_file="$project_root/dist/.macviewer-signing-identity"
if [[ -z "$signing_identity" && -f "$identity_file" ]]; then
  signing_identity="$(cat "$identity_file")"
fi
if [[ -z "$signing_identity" ]]; then
  development_identities=("${(@f)$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/{print $2}')}" )
  if (( ${#development_identities[@]} == 1 )) && [[ "${development_identities[1]}" =~ '^[A-Fa-f0-9]{40}$' ]]; then
    signing_identity="${development_identities[1]}"
  else
    signing_identity="-"
  fi
fi

# CI sets these; local builds keep the current development values.
latest_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
app_version="${MACVIEWER_VERSION:-${${latest_tag#v}:-0.0.0}}"
build_number="${MACVIEWER_BUILD_NUMBER:-5}"
minimum_system_version="${MACVIEWER_MIN_MACOS:-12}.0"
build_flags=(--configuration "$configuration")
if [[ "${MACVIEWER_UNIVERSAL:-0}" == "1" ]]; then
  build_flags+=(--arch arm64 --arch x86_64)
fi

swift build "${build_flags[@]}" --product MacViewer
swift build "${build_flags[@]}" --product macviewer-mcp
binary_directory="$(swift build "${build_flags[@]}" --show-bin-path)"
app_directory="$project_root/dist/MacViewer.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
icon_directory="$project_root/.build/MacViewer.iconset"
swift scripts/make_app_icon.swift "$icon_directory"
iconutil -c icns "$icon_directory" -o "$app_directory/Contents/Resources/MacViewer.icns"
for language in en vi; do
  mkdir -p "$app_directory/Contents/Resources/$language.lproj"
  cp "Sources/MacViewer/Resources/$language.lproj/Localizable.strings" "$app_directory/Contents/Resources/$language.lproj/Localizable.strings"
done
cp -R "$binary_directory/MacViewer_MacViewer.bundle" "$app_directory/Contents/Resources/"
mkdir -p "$app_directory/Contents/Resources/Licenses/Zstandard"
cp ThirdParty/zstd/LICENSE "$app_directory/Contents/Resources/Licenses/Zstandard/LICENSE"
cp ThirdParty/zstd/COPYING "$app_directory/Contents/Resources/Licenses/Zstandard/COPYING"
mkdir -p "$app_directory/Contents/Resources/Licenses/G722"
cp ThirdParty/g722/LICENSE "$app_directory/Contents/Resources/Licenses/G722/LICENSE"
cp ThirdParty/g722/WEBRTC_LICENSE "$app_directory/Contents/Resources/Licenses/G722/WEBRTC_LICENSE"
# Replace the executable atomically so an already-running development app keeps
# its original mapped inode while a newly launched process gets the new build.
cp "$binary_directory/MacViewer" "$app_directory/Contents/MacOS/MacViewer.new"
mv -f "$app_directory/Contents/MacOS/MacViewer.new" "$app_directory/Contents/MacOS/MacViewer"
# The stdio MCP server that AI apps launch; it relays to the running app.
cp "$binary_directory/macviewer-mcp" "$app_directory/Contents/MacOS/macviewer-mcp.new"
mv -f "$app_directory/Contents/MacOS/macviewer-mcp.new" "$app_directory/Contents/MacOS/macviewer-mcp"
cp Sources/UltraViewerProtocol/Resources/8bit.dat "$app_directory/Contents/Resources/8bit.dat"
# macOS 11 has no Swift concurrency runtime; ship the toolchain's back-deployed copy.
if [[ "${MACVIEWER_MIN_MACOS:-12}" == "11" ]]; then
  concurrency_library="$(dirname "$(xcrun --find swift)")/../lib/swift-5.5/macosx/libswift_Concurrency.dylib"
  mkdir -p "$app_directory/Contents/Frameworks"
  cp "$concurrency_library" "$app_directory/Contents/Frameworks/"
  codesign --force --sign "$signing_identity" --timestamp=none "$app_directory/Contents/Frameworks/libswift_Concurrency.dylib"
  for executable in MacViewer macviewer-mcp; do
    install_name_tool -add_rpath @executable_path/../Frameworks "$app_directory/Contents/MacOS/$executable" 2>/dev/null || true
  done
fi
cat > "$app_directory/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MacViewer</string>
  <key>CFBundleIdentifier</key><string>dev.macviewer.app</string>
  <key>CFBundleName</key><string>MacViewer</string>
  <key>CFBundleDisplayName</key><string>MacViewer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>MacViewer.icns</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>vi</string></array>
  <key>CFBundleShortVersionString</key><string>$app_version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>LSMinimumSystemVersion</key><string>$minimum_system_version</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 DeanOpen · MIT License</string>
</dict>
</plist>
PLIST
# Finder metadata (com.apple.FinderInfo) on the bundle fails strict signature checks.
xattr -cr "$app_directory"
codesign --force --sign "$signing_identity" --timestamp=none "$app_directory/Contents/MacOS/macviewer-mcp"
codesign --force --sign "$signing_identity" --timestamp=none "$app_directory"
codesign --verify --deep --strict "$app_directory"
# Updating nested resources leaves the bundle directory's timestamp unchanged.
# Finder/Launch Services can then retain the first build's generic app icon.
# Refresh the package metadata after signing; timestamps are not signed content.
touch "$app_directory/Contents" "$app_directory"
registration_tool="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ "${CI:-}" != "true" && -x "$registration_tool" ]]; then
  "$registration_tool" -f "$app_directory"
fi
print -r -- "$signing_identity" > "$identity_file"
print "App ready: $app_directory"
