#!/usr/bin/env bash
# Render Resources/AppIcon.icns from Scripts/make_icon.swift.
#
# The icon is drawn in code rather than exported from a design tool, so every
# size comes off the same geometry. Run this after editing make_icon.swift:
#
#   bash Scripts/make-icon.sh
#
# Also writes Resources/AppIcon.png (512pt), which the README uses.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> rendering iconset"
rm -rf AppIcon.iconset
swift Scripts/make_icon.swift

if [[ ! -d AppIcon.iconset ]]; then
    echo "ERROR: make_icon.swift did not produce AppIcon.iconset" >&2
    exit 1
fi

echo "==> iconutil -> Resources/AppIcon.icns"
mkdir -p Resources
iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns

# make_icon.swift also drops loose previews next to the iconset for eyeballing
# the result at real sizes. Keep the 512 one as the README artwork, bin the rest.
if [[ -f icon-preview-512.png ]]; then
    mv icon-preview-512.png Resources/AppIcon.png
fi

rm -rf AppIcon.iconset icon-preview-*.png
ls -lh Resources/AppIcon.icns Resources/AppIcon.png 2>/dev/null
echo "==> Done"
