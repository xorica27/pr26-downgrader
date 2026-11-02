#!/bin/bash
# Build and zip a release of PrprojDowngrader.app.
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
ZIP="dist/PrprojDowngrader-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent --norsrc --noextattr --noqtn "app/PrprojDowngrader.app" "$ZIP"
echo "Created $ZIP"
shasum -a 256 "$ZIP"
