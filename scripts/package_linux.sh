#!/usr/bin/env bash
set -euo pipefail

# Build LinuxViewer and bundle it into a .tar.gz and a .deb, the Linux
# counterpart of scripts/package_app.sh. Run on Linux (or in a Linux container);
# it needs cargo, and dpkg-deb for the .deb. Output lands in dist/linux/.

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

latest_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
version="${LINUXVIEWER_VERSION:-${latest_tag#v}}"
version="${version:-0.0.0}"
arch="$(uname -m)"
case "$arch" in
  x86_64) deb_arch="amd64" ;;
  aarch64) deb_arch="arm64" ;;
  *) deb_arch="$arch" ;;
esac

echo "Building LinuxViewer $version ($arch)…"
( cd LinuxViewer && cargo build --release --locked )
binary="LinuxViewer/target/release/linuxviewer"
[ -x "$binary" ] || { echo "error: $binary not built" >&2; exit 1; }

out="$project_root/dist/linux"
rm -rf "$out"
mkdir -p "$out"

# --- staging tree shared by the tarball and the .deb ---
stage="$out/stage"
mkdir -p \
  "$stage/usr/bin" \
  "$stage/usr/share/applications" \
  "$stage/usr/share/icons/hicolor/256x256/apps" \
  "$stage/usr/share/doc/linuxviewer"

install -m 0755 "$binary" "$stage/usr/bin/linuxviewer"
cp LICENSE "$stage/usr/share/doc/linuxviewer/LICENSE"
cp LinuxViewer/README.md "$stage/usr/share/doc/linuxviewer/README.md"
cp docs/images/app-icon.png "$stage/usr/share/icons/hicolor/256x256/apps/linuxviewer.png"

cat > "$stage/usr/share/applications/linuxviewer.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=LinuxViewer
Comment=UltraViewer-compatible remote desktop
Exec=linuxviewer %U
Icon=linuxviewer
Terminal=false
Categories=Network;RemoteAccess;
Keywords=remote;desktop;ultraviewer;vnc;
DESKTOP

# --- tarball ---
tarball="$out/linuxviewer-${version}-${arch}.tar.gz"
tar -C "$stage" -czf "$tarball" .
echo "wrote $tarball"

# --- .deb ---
if command -v dpkg-deb >/dev/null 2>&1; then
  deb_root="$out/deb"
  rm -rf "$deb_root"
  mkdir -p "$deb_root/DEBIAN"
  cp -a "$stage/usr" "$deb_root/"
  installed_kb="$(du -ks "$deb_root/usr" | cut -f1)"
  cat > "$deb_root/DEBIAN/control" <<CONTROL
Package: linuxviewer
Version: ${version}
Section: net
Priority: optional
Architecture: ${deb_arch}
Maintainer: DeanOpen <279508589+DeanOpen@users.noreply.github.com>
Installed-Size: ${installed_kb}
Depends: libc6, libgcc-s1, libpipewire-0.3-0, libasound2t64 | libasound2
Recommends: libx11-6, libxcb1, libxkbcommon0, libwayland-client0, xdg-desktop-portal
Description: UltraViewer-compatible remote desktop for Linux
 LinuxViewer connects to and controls UltraViewer machines, and can share an
 X11 or Wayland desktop. It is the Linux counterpart of MacViewer.
 .
 The window works on any desktop (GNOME, Cinnamon, KDE, Xfce, ...) over X11 or
 Wayland, and draws on the CPU, so it needs no OpenGL and runs with NVIDIA, AMD,
 Intel or software rendering.
CONTROL
  deb="$out/linuxviewer_${version}_${deb_arch}.deb"
  dpkg-deb --build --root-owner-group "$deb_root" "$deb" >/dev/null
  echo "wrote $deb"
  # Fixed name so the README can link to releases/latest/download/.
  cp "$deb" "$out/linuxviewer-${deb_arch}.deb"
else
  echo "dpkg-deb not found; skipped .deb"
fi

# Fixed-name tarball copy for the stable download link.
cp "$tarball" "$out/linuxviewer-${arch}.tar.gz"

rm -rf "$stage" "$out/deb"
( cd "$out" && sha256sum linuxviewer-* 2>/dev/null || shasum -a 256 linuxviewer-* ) > "$out/SHA256SUMS-linux.txt" || true
echo "done: $out"
ls -la "$out"
