#!/usr/bin/env bash
# ---
# asset: kuku-private-release-consumer-access-check
# type: release-script
# description: Verify that the current Mac can read Kuku release metadata and download the expected private DMG without exposing its token.
# owner: michael
# status: active
# ---

set -euo pipefail

mode=draft
identifier=${1:-}
if [[ "$identifier" == "--published" ]]; then
  mode=published
  identifier=${2:-}
  shift
fi
[[ -n "$identifier" ]] || { printf 'usage: consumer_access_check.sh <draft-id> | --published <tag>\n' >&2; exit 2; }
[[ -n "${HOMEBREW_GITHUB_API_TOKEN:-}" ]] || { printf 'consumer_access_check: HOMEBREW_GITHUB_API_TOKEN is required\n' >&2; exit 1; }
curl_cmd=${RELEASE_H4_CURL_CMD:-curl}
host=$(scutil --get LocalHostName 2>/dev/null || hostname)
root=$(mktemp -d "${TMPDIR:-/private/tmp}/kuku-consumer.XXXXXX")
trap 'rm -rf "$root"' EXIT

request_json() {
  local endpoint=$1 output=$2 status
  status=$("$curl_cmd" --silent --show-error --location --output "$output" --write-out '%{http_code}' \
    --header 'Accept: application/vnd.github+json' \
    --header "Authorization: token ${HOMEBREW_GITHUB_API_TOKEN}" \
    --header 'X-GitHub-Api-Version: 2022-11-28' "https://api.github.com$endpoint")
  printf '%s %s %s\n' "$host" "$endpoint" "$status"
  [[ "$status" == 200 ]]
}

request_json '/repos/horizonthinking/kuku-releases' "$root/repo.json"
if [[ "$mode" == published ]]; then
  release_endpoint="/repos/horizonthinking/kuku-releases/releases/tags/$identifier"
else
  release_endpoint="/repos/horizonthinking/kuku-releases/releases/$identifier"
fi
request_json "$release_endpoint" "$root/release.json"
python3 - "$root/release.json" "$root/assets.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
json.dump(value.get("assets", []), open(sys.argv[2], "w", encoding="utf-8"))
PY
read -r dmg_id dmg_name manifest_id < <(python3 - "$root/assets.json" <<'PY'
import json, sys
assets = json.load(open(sys.argv[1], encoding="utf-8"))
dmg = [x for x in assets if x.get("name", "").endswith(".dmg")]
manifest = [x for x in assets if x.get("name", "").endswith(".manifest.json")]
if len(dmg) != 1 or len(manifest) != 1: raise SystemExit("expected one DMG and one manifest asset")
print(dmg[0]["id"], dmg[0]["name"], manifest[0]["id"])
PY
)

download_asset() {
  local id=$1 output=$2 accept=$3 status
  status=$("$curl_cmd" --silent --show-error --location --output "$output" --write-out '%{http_code}' \
    --header "Accept: $accept" --header "Authorization: token ${HOMEBREW_GITHUB_API_TOKEN}" \
    "https://api.github.com/repos/horizonthinking/kuku-releases/releases/assets/$id")
  printf '%s /repos/horizonthinking/kuku-releases/releases/assets/%s %s\n' "$host" "$id" "$status"
  [[ "$status" == 200 ]]
}
download_asset "$manifest_id" "$root/manifest.json" application/octet-stream
expected_sha=$(python3 - "$root/manifest.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
print(value["dmg_sha256"])
PY
)
download_asset "$dmg_id" "$root/$dmg_name" application/octet-stream
observed_sha=$(shasum -a 256 "$root/$dmg_name" | awk '{print $1}')
[[ "$observed_sha" == "$expected_sha" ]] || {
  printf '%s dmg sha256 mismatch\n' "$host" >&2
  exit 1
}
printf '%s dmg sha256 ok\n' "$host"
