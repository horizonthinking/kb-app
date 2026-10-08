#!/usr/bin/env bash
# ---
# asset: kuku-h4-build
# type: packaging-script
# description: Build the unsigned H4 fork app from the reviewed Tauri configuration and print its three release identities.
# owner: michael
# status: active
# ---

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"
export TMPDIR=/private/tmp

pnpm moon run desktop:tauri-build-h4

app_path="$repo_root/target/release/bundle/macos/Kuku.app"
[[ -d "$app_path" ]] || {
  printf 'build_h4: Kuku.app not found at %s\n' "$app_path" >&2
  exit 1
}
short_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")
[[ "$short_version" == "0.5.8" ]] || {
  printf 'build_h4: expected app version 0.5.8, observed %s\n' "$short_version" >&2
  exit 1
}
[[ "$bundle_version" == "5.8.1" ]] || {
  printf 'build_h4: expected bundle version 5.8.1, observed %s\n' "$bundle_version" >&2
  exit 1
}

printf 'RESULT app_path=%s\n' "$app_path"
printf 'RESULT app_version=%s\n' "$short_version"
printf 'RESULT bundle_version=%s\n' "$bundle_version"
printf 'RESULT release_version=0.5.8-h4.1\n'
