#!/bin/zsh
set -euo pipefail

# Build a drag-to-install DMG with a guide background.
# Requires dmgbuild: python3 -m pip install dmgbuild==1.6.5
project_root="${0:A:h:h}"
cd "$project_root"
if (( $# != 3 )); then
  print -u2 "Usage: scripts/make_dmg.sh <MacViewer.app> <version> <output.dmg>"
  exit 2
fi
app_path="${1:A}"
version="$2"
output_path="${3:A}"

work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT

swift scripts/make_dmg_background.swift "$work_directory"
# Combine 1x and 2x into one multi-resolution TIFF so Retina displays stay sharp.
tiffutil -cathidpicheck "$work_directory/background.png" "$work_directory/background@2x.png" \
  -out "$work_directory/background.tiff"

# Icon positions must match scripts/make_dmg_background.swift.
cat > "$work_directory/settings.py" <<SETTINGS
import os.path
application = "$app_path"
appname = os.path.basename(application)
format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
background = "$work_directory/background.tiff"
window_rect = ((200, 120), (660, 420))
icon_size = 112
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
show_icon_preview = False
# Park the background file outside the window for users who show hidden files.
icon_locations = {appname: (170, 190), "Applications": (490, 190), ".background.tiff": (170, 900)}
hide_extensions = [appname]
SETTINGS

rm -f "$output_path"
python3 -m dmgbuild -s "$work_directory/settings.py" "MacViewer $version" "$output_path"
print "DMG ready: $output_path"
