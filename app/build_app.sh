#!/bin/bash
# Build a universal (Apple Silicon + Intel) PrprojDowngrader.app with the
# Python engine and its own Python runtime bundled inside.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
APP="$ROOT/PrprojDowngrader.app"
BUILD="$REPO/build"
MIN_MACOS="13.0"

VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$ROOT/prproj_downgrade.py")"
[ -n "$VERSION" ] || { echo "error: could not read __version__" >&2; exit 1; }

"$REPO/scripts/fetch_python.sh"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/swift"

echo "Compiling SwiftUI app (arm64 + x86_64)…"
for arch in arm64 x86_64; do
    swiftc -O -parse-as-library \
        -target "$arch-apple-macos$MIN_MACOS" \
        -o "$BUILD/swift/PrprojDowngrader-$arch" \
        "$ROOT/PrprojDowngrader.swift"
done
lipo -create "$BUILD/swift/PrprojDowngrader-arm64" "$BUILD/swift/PrprojDowngrader-x86_64" \
    -output "$APP/Contents/MacOS/PrprojDowngrader"

echo "Bundling converter and Python runtime…"
cp "$ROOT/prproj_downgrade.py" "$ROOT/schema42.json" "$ROOT/AppIcon.icns" "$APP/Contents/Resources/"
cp -R "$BUILD/python-universal" "$APP/Contents/Resources/python"
rm -f "$APP/Contents/Resources/python/.stamp"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Prproj Downgrader</string>
    <key>CFBundleDisplayName</key>
    <string>Prproj Downgrader</string>
    <key>CFBundleIdentifier</key>
    <string>com.xorica27.prprojdowngrader</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>PrprojDowngrader</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License. Not affiliated with Adobe.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array><string>prproj</string></array>
            <key>CFBundleTypeName</key>
            <string>Premiere Pro Project</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc sign inside-out: every Mach-O in the runtime, then the app itself.
echo "Signing (ad-hoc)…"
find "$APP/Contents/Resources/python" -type f | while read -r f; do
    if file "$f" | grep -q 'Mach-O'; then
        codesign --force --sign - "$f" 2>/dev/null
    fi
done
codesign --force --sign - "$APP" 2>/dev/null
codesign --verify --strict "$APP"

echo "Built: $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/PrprojDowngrader"), $(du -sh "$APP" | cut -f1))"
