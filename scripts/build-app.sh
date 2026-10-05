#!/bin/zsh
set -eu
cd "${0:A:h}/.."
./scripts/swift.sh build -c release -debug-info-format none
app="$PWD/dist/Current.app"
# Start from an empty bundle so stale files are never signed into it.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
bin_dir=$(./scripts/swift.sh build -c release --show-bin-path)
cp "$bin_dir/Current" "$app/Contents/MacOS/Current"
cp LICENSE "$app/Contents/Resources/LICENSE"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Current</string>
<key>CFBundleDisplayName</key><string>Current</string>
<key>CFBundleIdentifier</key><string>org.traffic.local</string>
<key>CFBundleExecutable</key><string>Current</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>© 2026 Pierre-Olivier Carles. MIT license.</string>
</dict></plist>
PLIST
# Local ad-hoc signature, no account, service or certificate purchase.
codesign --force --sign - "$app"
print "$app"
