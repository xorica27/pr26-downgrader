#!/bin/bash
# Build and zip a release of Pr26 Downgrader.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

./app/build_app.sh

VERSION="$(python3 - <<'PY'
import re
text = open("app/prproj_downgrade.py").read()
m = re.search(r'__version__\s*=\s*"([^"]+)"', text)
print(m.group(1) if m else "0.0.0")
PY
)"

mkdir -p dist
ZIP="dist/Pr26-Downgrader-${VERSION}-universal.zip"
rm -f "$ZIP"
ditto -c -k --keepParent --norsrc --noextattr --noqtn "app/Pr26 Downgrader.app" "$ZIP"
echo "Created $ZIP"

# Drag-to-Applications DMG.
STAGE="$ROOT/build/dmg"
DMG="dist/Pr26-Downgrader-${VERSION}-universal.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto --norsrc --noextattr --noqtn "app/Pr26 Downgrader.app" "$STAGE/Pr26 Downgrader.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Pr26 Downgrader" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG"
echo "Created $DMG"

shasum -a 256 "$ZIP" "$DMG" | tee "dist/SHA256SUMS.txt"
