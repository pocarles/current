#!/bin/zsh
set -eu
cd "${0:A:h}/.."
version=0.1.3
build=4
# CURRENT_UNIVERSAL=1 builds Apple silicon and Intel slices; CURRENT_SIGN_IDENTITY signs for distribution.
archs=()
[[ "${CURRENT_UNIVERSAL:-0}" == 1 ]] && archs=(--arch arm64 --arch x86_64)
identity=${CURRENT_SIGN_IDENTITY:--}
./scripts/swift.sh build -c release -debug-info-format none "${archs[@]}"
app="$PWD/dist/Current.app"
# Start from an empty bundle so stale files are never signed into it.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
bin_dir=$(./scripts/swift.sh build -c release --show-bin-path "${archs[@]}")
cp "$bin_dir/Current" "$app/Contents/MacOS/Current"
cp LICENSE "$app/Contents/Resources/LICENSE"
# Rendered from assets/AppIcon.svg; regenerate with iconutil when the artwork changes.
cp assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Current</string>
<key>CFBundleDisplayName</key><string>Current</string>
<key>CFBundleIdentifier</key><string>org.traffic.local</string>
<key>CFBundleExecutable</key><string>Current</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>© 2026 Pierre-Olivier Carles. MIT license.</string>
</dict></plist>
PLIST
if [[ "$identity" == - ]]; then
  # Local ad-hoc signature, no account, service or certificate purchase.
  codesign --force --sign - "$app"
else
  # Distribution: hardened runtime and a secure timestamp, as notarization requires.
  codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
print "$app"
