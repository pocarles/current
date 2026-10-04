#!/bin/bash
set -euo pipefail
set +x
umask 077
mode=${1:---verify-only}
case "$mode" in --verify-only|--release) ;; *) echo 'Use --verify-only or --release' >&2; exit 64 ;; esac
input=${CURRENT_INPUT_DMG:?Set CURRENT_INPUT_DMG to the reviewed signed installer}
output=${CURRENT_OUTPUT_DIR:?Set CURRENT_OUTPUT_DIR to an empty absolute directory}
[[ -f "$input" && "$output" = /* && ! -L "$output" ]] || { echo 'Invalid input or output path' >&2; exit 64; }
[[ ! -e "$output" || -z "$(ls -A "$output")" ]] || { echo 'Output is nonempty; nothing overwritten' >&2; exit 64; }
expected_dmg=bfafc0f136c327e5ce2be958369c93d9fa4c530ff26adbda78f095f753355563
expected_binary=86882854c6764aa43dec2026dd2311fd9e51eb4340401ed5015a6b304667e153
[[ "$(shasum -a 256 "$input" | awk '{print $1}')" = "$expected_dmg" ]] || { echo 'Installer does not match the reviewed artifact' >&2; exit 65; }
if [[ "$mode" == --release ]]; then
  : "${APPLE_API_KEY_PATH:?Existing notarization P8 path required}"
  : "${APPLE_API_KEY_ID:?Existing notarization Key ID required}"
  : "${APPLE_API_ISSUER_ID:?Existing Team API key Issuer UUID required}"
  [[ -s "$APPLE_API_KEY_PATH" && "$APPLE_API_KEY_ID" =~ ^[A-Za-z0-9]+$ ]] || { echo 'API credential file or key metadata unavailable' >&2; exit 78; }
  [[ "$APPLE_API_ISSUER_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || { echo 'Team key requires an issuer UUID' >&2; exit 78; }
fi
temp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/current-notary.XXXXXX")
mounted=false
cleanup() {
  if [[ "$mounted" = true ]]; then hdiutil detach -quiet "$temp/mount" || true; fi
  rm -rf "$temp"
}
trap cleanup EXIT
mkdir -p "$output" "$temp/mount"
cp "$input" "$output/Current.dmg"
dmg="$output/Current.dmg"
verify_app() {
  hdiutil attach -quiet -readonly -nobrowse -mountpoint "$temp/mount" "$dmg"
  mounted=true
  app="$temp/mount/Current.app"
  [[ -d "$app" && -L "$temp/mount/Applications" && "$(readlink "$temp/mount/Applications")" = /Applications ]]
  [[ "$(shasum -a 256 "$app/Contents/MacOS/Current" | awk '{print $1}')" = "$expected_binary" ]]
  architectures=$(lipo "$app/Contents/MacOS/Current" -archs)
  [[ "$architectures" = 'x86_64 arm64' || "$architectures" = 'arm64 x86_64' ]] || { echo 'Universal 2 slices missing' >&2; exit 65; }
  codesign --verify --strict "$app"
  codesign --display --verbose=4 "$app" 2> "$temp/app-signature.txt"
  grep -Fxq 'TeamIdentifier=UVTJ336J2D' "$temp/app-signature.txt"
  grep -Eq '^Timestamp=' "$temp/app-signature.txt"
  grep -Eq '^CodeDirectory .*flags=.*runtime' "$temp/app-signature.txt"
  [[ "$(shasum -a 256 "$app/Contents/Resources/LICENSE" | awk '{print $1}')" = f50974873e8d10668e666f78171e467d1bf117c003c69844a9ca1f96e960538f ]]
  python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as stream:
    info = plistlib.load(stream)
for key, value in {'CFBundleName':'Current','CFBundleExecutable':'Current','CFBundleIdentifier':'org.traffic.local','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1','LSMinimumSystemVersion':'14.0'}.items():
    assert info[key] == value, key
PY
  if [[ "$mode" == --release && -f "$temp/accepted.json" ]]; then
    spctl --assess --type execute --verbose=2 "$app"
  fi
  hdiutil detach -quiet "$temp/mount"
  mounted=false
}
codesign --verify --strict "$dmg"
codesign --display --verbose=4 "$dmg" 2> "$temp/dmg-signature.txt"
grep -Fxq 'TeamIdentifier=UVTJ336J2D' "$temp/dmg-signature.txt"
grep -Eq '^Timestamp=' "$temp/dmg-signature.txt"
hdiutil verify -quiet "$dmg"
verify_app
if [[ "$mode" == --release ]]; then
  xcrun notarytool submit "$dmg" --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" \
    --wait --timeout 20m --output-format json > "$temp/accepted.json"
  python3 - "$temp/accepted.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    report = json.load(stream)
if report.get('status') != 'Accepted':
    raise SystemExit('Apple did not accept notarization; publication is blocked')
PY
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  codesign --verify --strict "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
  verify_app
fi
cd "$output"
shasum -a 256 Current.dmg > Current.dmg.sha256
python3 - "$mode" "$temp/accepted.json" <<'PY'
import hashlib, json, sys
from pathlib import Path
released = sys.argv[1] == '--release'
submission = json.loads(Path(sys.argv[2]).read_text()).get('id') if released else None
manifest = dict(name='Current', version='0.1.0', build='1', bundle_identifier='org.traffic.local',
    architectures=['arm64','x86_64'], minimum_macos='14.0', license='MIT',
    signed_source_commit='08e954b4a510b4850265002215c7a14875d795a5',
    public_source_commit='304fe8a4ff7ead98901d9b3556b9acc01f085f6a',
    developer_id_signed=True, secure_timestamp=True, hardened_runtime=True,
    notarized=released, dmg_stapled=released, gatekeeper_verified=released,
    notarization_submission_id=submission,
    dmg_sha256=hashlib.sha256(Path('Current.dmg').read_bytes()).hexdigest())
Path('Current-manifest.json').write_text(json.dumps(manifest, indent=2))
PY
echo "Current reviewed installer verified ($mode)."
