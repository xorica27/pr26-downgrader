#!/bin/bash
# Build PrprojDowngrader.app from the SwiftUI source and bundle the Python engine.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/PrprojDowngrader.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling SwiftUI app…"
swiftc -O -parse-as-library \
    -o "$APP/Contents/MacOS/PrprojDowngrader" \
    "$ROOT/PrprojDowngrader.swift"

echo "Bundling converter…"
cp "$ROOT/prproj_downgrade.py" "$APP/Contents/Resources/"
cp "$ROOT/schema42.json" "$APP/Contents/Resources/"
if [ -f "$ROOT/AppIcon.icns" ]; then
    cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Prproj Downgrader</string>
    <key>CFBundleDisplayName</key>
    <string>Prproj Downgrader</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.prprojdowngrader</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>PrprojDowngrader</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array><string>prproj</string></array>
            <key>CFBundleTypeName</key>
            <string>Premiere Pro Project</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper/launch services accept the local build.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built: $APP"
echo "Run with: open \"$APP\""
