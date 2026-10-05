#!/bin/zsh
# Build, sign, notarize and verify dist/release/Current.dmg for a GitHub release.
# Needs a "Developer ID Application" identity in the keychain. Notarization needs an
# App Store Connect team API key in APPLE_API_KEY_PATH, APPLE_API_KEY_ID and
# APPLE_API_ISSUER_ID. `--sign-only` stops before notarization.
set -euo pipefail
cd "${0:A:h}/.."
mode=${1:---release}
[[ "$mode" == --release || "$mode" == --sign-only ]] || { echo "Use --release or --sign-only" >&2; exit 64; }
# The certificate's SHA-1, which survives non-ASCII team names that break name lookup.
identity=${CURRENT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ { print $2; exit }')}
[[ -n "$identity" ]] || { echo "No Developer ID Application identity in the keychain" >&2; exit 1; }
if [[ "$mode" == --release ]]; then
  : "${APPLE_API_KEY_PATH:?Set APPLE_API_KEY_PATH}" "${APPLE_API_KEY_ID:?Set APPLE_API_KEY_ID}" "${APPLE_API_ISSUER_ID:?Set APPLE_API_ISSUER_ID}"
fi

out="$PWD/dist/release"
stage=$(mktemp -d "${TMPDIR:-/tmp}/current-release.XXXXXX")
mounted=""
cleanup() { [[ -n "$mounted" ]] && hdiutil detach -quiet "$mounted" || true; rm -rf "$stage"; }
trap cleanup EXIT
rm -rf "$out"; mkdir -p "$out"

CURRENT_UNIVERSAL=1 CURRENT_SIGN_IDENTITY="$identity" ./scripts/build-app.sh >/dev/null
app="$PWD/dist/Current.app"
archs=$(lipo -archs "$app/Contents/MacOS/Current")
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "Universal slices missing: $archs" >&2; exit 65; }
codesign --verify --strict --deep "$app"

mkdir "$stage/dmg"
ditto "$app" "$stage/dmg/Current.app"
ln -s /Applications "$stage/dmg/Applications"
hdiutil create -quiet -volname Current -srcfolder "$stage/dmg" -format UDZO -ov "$out/Current.dmg"
codesign --force --timestamp --sign "$identity" "$out/Current.dmg"

if [[ "$mode" == --release ]]; then
  xcrun notarytool submit "$out/Current.dmg" --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" --wait --timeout 30m --output-format json > "$stage/notary.json"
  status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$stage/notary.json")
  [[ "$status" == Accepted ]] || { echo "Notarization status: $status" >&2; exit 1; }
  xcrun stapler staple "$out/Current.dmg"
  xcrun stapler validate "$out/Current.dmg"
  spctl --assess --type open --context context:primary-signature "$out/Current.dmg"
  mounted="$stage/mount"; mkdir "$mounted"
  hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mounted" "$out/Current.dmg"
  spctl --assess --type execute "$mounted/Current.app"
fi

(cd "$out" && shasum -a 256 Current.dmg > Current.dmg.sha256)
print "$out/Current.dmg ($mode, $archs)"
