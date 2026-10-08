#!/usr/bin/env bash
# ---
# asset: kuku-h4-sign-notarize-dmg
# type: packaging-script
# description: Deep-sign Kuku.app with hardened runtime, notarize and staple the app and DMG, and print notarization provenance.
# owner: michael
# status: active
# ---

set -euo pipefail

app_path=${1:?usage: sign_notarize_dmg.sh <Kuku.app> [out-dir] [release-version]}
app_path=$(cd "$(dirname "$app_path")" && pwd)/$(basename "$app_path")
out_dir=${2:-$(dirname "$app_path")}
release=${3:-0.5.8-h4.1}
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
entitlements=${ENTITLEMENTS:-$repo_root/apps/desktop/src-tauri/entitlements.plist}
sign_identity=${SIGN_IDENTITY:-Developer ID Application: Michael Anthony Smith (8P9788YC9P)}
asc_key_id=${ASC_KEY_ID:-CABZCFW333}
asc_issuer=${ASC_ISSUER:-06323f71-5ffa-49d3-8192-aed14361258a}
asc_key_path=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_CABZCFW333.p8}
team_id=${TEAM_ID:-8P9788YC9P}
dmg_path="$out_dir/Kuku-$release.dmg"
zip_path="$out_dir/Kuku-$release-notarize.zip"
stage_dir="$out_dir/Kuku-$release-dmg-stage"

fail() { printf 'sign_notarize_dmg: %s\n' "$*" >&2; exit 1; }
[[ -d "$app_path" ]] || fail "app bundle missing: $app_path"
[[ -f "$entitlements" ]] || fail "entitlements missing: $entitlements"
[[ -f "$asc_key_path" ]] || fail "App Store Connect key missing: $asc_key_path"
security find-identity -v -p codesigning | grep -qF "$sign_identity" || fail "Developer ID identity unavailable"
mkdir -p "$out_dir"

if [[ -n "${KEYCHAIN_PASSWORD:-}" ]]; then
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$HOME/Library/Keychains/login.keychain-db"
  security set-keychain-settings "$HOME/Library/Keychains/login.keychain-db"
fi

common=(--force --options runtime --timestamp --sign "$sign_identity")
while IFS= read -r -d '' item; do
  codesign "${common[@]}" "$item"
done < <(find "$app_path/Contents" -depth \( -path '*/Contents/MacOS/*' -type f -o -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' -o -name '*.appex' -o -name '*.xpc' -o -name '*.app' \) -print0)
codesign "${common[@]}" --entitlements "$entitlements" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

rm -f "$zip_path"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --keepParent "$app_path" "$zip_path"
app_notary=$(mktemp /private/tmp/kuku-app-notary.XXXXXX)
xcrun notarytool submit "$zip_path" --key "$asc_key_path" --key-id "$asc_key_id" --issuer "$asc_issuer" --wait | tee "$app_notary"
app_submission=$(awk '/^[[:space:]]*id:/{print $2; exit}' "$app_notary")
app_status=$(awk '/^[[:space:]]*status:/{status=$2} END{print status}' "$app_notary")
[[ "$app_status" == "Accepted" ]] || fail "app notarization was $app_status (id=${app_submission:-unknown})"
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl -a -vv -t exec "$app_path"

rm -rf "$stage_dir" "$dmg_path"
mkdir -p "$stage_dir"
/usr/bin/ditto "$app_path" "$stage_dir/Kuku.app"
ln -s /Applications "$stage_dir/Applications"
hdiutil create -volname Kuku -srcfolder "$stage_dir" -fs HFS+ -format UDZO -ov "$dmg_path" >/dev/null
rm -rf "$stage_dir"
codesign --force --timestamp --sign "$sign_identity" "$dmg_path"
codesign --verify --verbose=2 "$dmg_path"
dmg_notary=$(mktemp /private/tmp/kuku-dmg-notary.XXXXXX)
xcrun notarytool submit "$dmg_path" --key "$asc_key_path" --key-id "$asc_key_id" --issuer "$asc_issuer" --wait | tee "$dmg_notary"
dmg_submission=$(awk '/^[[:space:]]*id:/{print $2; exit}' "$dmg_notary")
dmg_status=$(awk '/^[[:space:]]*status:/{status=$2} END{print status}' "$dmg_notary")
[[ "$dmg_status" == "Accepted" ]] || fail "DMG notarization was $dmg_status (id=${dmg_submission:-unknown})"
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl -a -t open --context context:primary-signature -vv "$dmg_path"

dmg_sha256=$(shasum -a 256 "$dmg_path" | awk '{print $1}')
printf 'RESULT dmg_path=%s\n' "$dmg_path"
printf 'RESULT dmg_sha256=%s\n' "$dmg_sha256"
printf 'RESULT app_notary_submission_id=%s\n' "$app_submission"
printf 'RESULT dmg_notary_submission_id=%s\n' "$dmg_submission"
printf 'RESULT team_id=%s\n' "$team_id"
