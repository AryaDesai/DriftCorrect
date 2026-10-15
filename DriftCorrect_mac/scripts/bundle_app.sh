#!/bin/bash
# Build DriftCorrect.app and the `dc` command-line tool into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
APP=build/DriftCorrect.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DriftCorrectApp" "$APP/Contents/MacOS/DriftCorrect"
cp "$BIN/dc" build/dc
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DriftCorrect</string>
  <key>CFBundleDisplayName</key><string>Drift correction</string>
  <key>CFBundleIdentifier</key><string>local.driftcorrect</string>
  <key>CFBundleExecutable</key><string>DriftCorrect</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
# Ad-hoc signature so macOS runs the local build.
codesign --force --deep --sign - "$APP"
echo "Built $APP and build/dc"
