#!/usr/bin/env bash
# ---
# asset: kuku-h4-updater-marker-check
# type: test-script
# description: Prove a built H4 Kuku app contains only the disabled-updater production marker.
# owner: michael
# status: active
# ---

set -euo pipefail

app_path=${1:-}
[[ -d "$app_path" ]] || {
  printf 'usage: check_updater_marker.sh <Kuku.app>\n' >&2
  exit 2
}
assets="$app_path/Contents/Resources"
[[ -d "$assets" ]] || {
  printf 'check_updater_marker: resources missing: %s\n' "$assets" >&2
  exit 1
}

disabled=$( { rg -a -o 'kuku-updater-disabled' "$assets" 2>/dev/null || true; } | wc -l | tr -d ' ')
enabled=$( { rg -a -o 'kuku-updater-enabled' "$assets" 2>/dev/null || true; } | wc -l | tr -d ' ')
printf 'UPDATER_MARKERS disabled=%s enabled=%s\n' "$disabled" "$enabled"
[[ "$disabled" == "1" && "$enabled" == "0" ]] || {
  printf 'check_updater_marker: expected disabled=1 enabled=0\n' >&2
  exit 1
}
