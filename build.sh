#!/bin/zsh
# Release build alır ve build/InstaIndir.app paketini oluşturur.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/InstaIndir.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/InstaIndir "$APP/Contents/MacOS/InstaIndir"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>İnsta İndir</string>
    <key>CFBundleDisplayName</key><string>İnsta İndir</string>
    <key>CFBundleIdentifier</key><string>com.eyupcimen.instaindir</string>
    <key>CFBundleExecutable</key><string>InstaIndir</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Hazır: $PWD/$APP"
