#!/usr/bin/env bash
set -euo pipefail

# Build LinuxViewer and bundle it into .tar.gz and .deb packages, the Linux
# counterpart of scripts/package_app.sh. Run on Linux (or in a Linux container);
# it needs cargo, and dpkg-deb for the .deb. Output lands in dist/linux/.
#
# Two variants are produced:
#   linuxviewer           lean (default): no PipeWire, installs anywhere.
#                         Viewer, control, X11 hosting, audio, chat, files.
#   linuxviewer-wayland   adds Wayland hosting; needs libpipewire-0.3-0.

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

out="$project_root/dist/linux"
rm -rf "$out"
mkdir -p "$out"

# Build one variant and emit its tarball + .deb.
#   $1 package name   $2 cargo flags   $3 extra Depends   $4 control extras
build_variant() {
  local pkg="$1" cargo_flags="$2" extra_deps="$3" control_extra="$4"
  echo "Building $pkg $version ($arch)…"
  ( cd LinuxViewer && cargo build --release --locked $cargo_flags )
  local binary="LinuxViewer/target/release/linuxviewer"
  [ -x "$binary" ] || { echo "error: $binary not built" >&2; exit 1; }

  local stage="$out/stage"
  rm -rf "$stage"
  mkdir -p \
    "$stage/usr/bin" \
    "$stage/usr/share/applications" \
    "$stage/usr/share/icons/hicolor/256x256/apps" \
    "$stage/usr/share/doc/$pkg"
  install -m 0755 "$binary" "$stage/usr/bin/linuxviewer"
  cp LICENSE "$stage/usr/share/doc/$pkg/LICENSE"
  cp LinuxViewer/README.md "$stage/usr/share/doc/$pkg/README.md"
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

  # Tarball (named + fixed-name for the stable download link).
  local tag
  if [ "$pkg" = "linuxviewer" ]; then tag="linuxviewer"; else tag="linuxviewer-wayland"; fi
  tar -C "$stage" -czf "$out/${tag}-${version}-${arch}.tar.gz" .
  cp "$out/${tag}-${version}-${arch}.tar.gz" "$out/${tag}-${arch}.tar.gz"
  echo "wrote ${tag}-${version}-${arch}.tar.gz"

  if command -v dpkg-deb >/dev/null 2>&1; then
    local deb_root="$out/deb"
    rm -rf "$deb_root"; mkdir -p "$deb_root/DEBIAN"
    cp -a "$stage/usr" "$deb_root/"
    local installed_kb; installed_kb="$(du -ks "$deb_root/usr" | cut -f1)"
    {
      echo "Package: $pkg"
      echo "Version: ${version}"
      echo "Section: net"
      echo "Priority: optional"
      echo "Architecture: ${deb_arch}"
      echo "Maintainer: DeanOpen <279508589+DeanOpen@users.noreply.github.com>"
      echo "Installed-Size: ${installed_kb}"
      echo "Depends: libc6, libgcc-s1, libasound2t64 | libasound2${extra_deps}"
      echo "Recommends: libx11-6, libxcb1, libxkbcommon0, libwayland-client0, xdg-desktop-portal"
      printf '%s' "$control_extra"
      echo "Description: UltraViewer-compatible remote desktop for Linux"
      echo " LinuxViewer connects to and controls UltraViewer machines, and can share a"
      echo " desktop. It is the Linux counterpart of MacViewer."
      echo " ."
      echo " The window works on any desktop (GNOME, Cinnamon, KDE, Xfce, ...) over X11 or"
      echo " Wayland, and draws on the CPU, so it needs no OpenGL and runs with NVIDIA, AMD,"
      echo " Intel or software rendering."
    } > "$deb_root/DEBIAN/control"
    dpkg-deb --build --root-owner-group "$deb_root" "$out/${pkg}_${version}_${deb_arch}.deb" >/dev/null
    cp "$out/${pkg}_${version}_${deb_arch}.deb" "$out/${pkg}-${deb_arch}.deb"
    echo "wrote ${pkg}_${version}_${deb_arch}.deb"
    rm -rf "$deb_root"
  else
    echo "dpkg-deb not found; skipped .deb for $pkg"
  fi
  rm -rf "$stage"
}

# Lean default: installs anywhere.
build_variant linuxviewer "--no-default-features" "" ""
# Wayland variant: adds PipeWire. Conflicts with the lean package (same binary).
build_variant linuxviewer-wayland "" ", libpipewire-0.3-0" \
"Conflicts: linuxviewer
Provides: linuxviewer
Replaces: linuxviewer
"

( cd "$out" && { sha256sum linuxviewer* 2>/dev/null || shasum -a 256 linuxviewer*; } ) > "$out/SHA256SUMS-linux.txt" || true
echo "done: $out"
ls -la "$out"
