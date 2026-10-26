#!/bin/bash
# Builds ContinueTimer.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"
app=ContinueTimer.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  ContinueTimer.swift -o "$app/Contents/MacOS/ContinueTimer"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.continuetimer</string>
  <key>CFBundleName</key><string>ContinueTimer</string>
  <key>CFBundleExecutable</key><string>ContinueTimer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force -s - "$app"
echo "Built $(pwd)/$app"
