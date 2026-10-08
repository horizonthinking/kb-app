#!/usr/bin/env bash
# ---
# asset: kuku-h4-cask-installer
# type: release-script
# description: Install, roll back, or withdraw the audited Kuku cask while preserving one pre-Homebrew application bundle and verifying the installed identity.
# owner: michael
# status: active
# ---

set -euo pipefail

tap=horizonthinking/h4
token=horizonthinking/h4/kuku
tap_remote=git@github.com:horizonthinking/homebrew-h4.git
app_path=${KUKU_INSTALL_APP_PATH:-/Applications/Kuku.app}
record=${KUKU_INSTALL_RECORD_PATH:-$HOME/.kuku/h4-install-backup.json}
smoke=${KUKU_INSTALL_SMOKE_CMD:-$HOME/.local/bin/h4-kuku/smoke_kuku_app.sh}
mode=install
release=${1:-}
if [[ "$release" == --rollback || "$release" == --withdraw ]]; then
  mode=${release#--}
  shift
  release=${1:-}
fi
if [[ "$mode" == withdraw ]]; then
  [[ $# -eq 0 ]] || { printf 'usage: install_kuku_cask.sh --withdraw\n' >&2; exit 2; }
else
  [[ -n "$release" && $# -eq 1 ]] || { printf 'usage: install_kuku_cask.sh <release> | --rollback <release> | --withdraw\n' >&2; exit 2; }
fi

parse_release() {
  local value=$1
  [[ "$value" =~ ^0\.([0-9]+)\.([0-9]+)-h4\.([1-3])$ ]] || return 1
  app_version="0.${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  bundle_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  [[ "$bundle_version" =~ ^[1-9][0-9]{0,3}(\.(0|[1-9][0-9]?)){0,2}$ ]] || return 1
}
[[ "$mode" == withdraw ]] || parse_release "$release" || { printf 'install_kuku_cask: invalid release %s\n' "$release" >&2; exit 2; }

mkdir -p "$(dirname "$record")"
record_field() {
  python3 - "$record" "$1" <<'PY'
import json, sys
try: value = json.load(open(sys.argv[1], encoding="utf-8"))
except FileNotFoundError: raise SystemExit(1)
answer = value.get(sys.argv[2])
if answer is not None:
    print(answer)
PY
}
write_record() {
  local state=$1 backup_path=${2:-} version=${3:-} timestamp=${4:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  RECORD_STATE="$state" RECORD_BACKUP="$backup_path" RECORD_VERSION="$version" RECORD_TIMESTAMP="$timestamp" python3 - "$record" <<'PY'
import json, os, sys
path = sys.argv[1]
value = {
    "backup_path": os.environ["RECORD_BACKUP"] or None,
    "version": os.environ["RECORD_VERSION"] or None,
    "timestamp": os.environ["RECORD_TIMESTAMP"],
    "state": os.environ["RECORD_STATE"],
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":")); handle.write("\n"); handle.flush(); os.fsync(handle.fileno())
os.replace(tmp, path)
PY
}
validate_record() {
  [[ -f "$record" ]] || return 0
  python3 - "$record" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(value) == {"backup_path", "version", "timestamp", "state"}
assert value["state"] in {"moving", "moved", "installed", "restoring", "restored"}
assert value["backup_path"] is None or isinstance(value["backup_path"], str)
assert value["version"] is None or isinstance(value["version"], str)
assert isinstance(value["timestamp"], str)
PY
}
validate_record

inventory_file=$(mktemp "${TMPDIR:-/private/tmp}/kuku-installed.XXXXXX")
trap 'rm -f "$inventory_file"' EXIT
installed_identity() {
  brew info --cask --json=v2 --installed >"$inventory_file"
  python3 - "$inventory_file" <<'PY'
import json, sys
casks = [x for x in json.load(open(sys.argv[1], encoding="utf-8")).get("casks", []) if x.get("token") == "kuku"]
if len(casks) > 1: raise SystemExit("multiple installed casks use token kuku")
if casks:
    value = casks[0]
    installed = value.get("installed", [])
    if isinstance(installed, list): installed = installed[0] if installed else ""
    print("\t".join([value.get("tap", ""), value.get("full_token", ""), str(installed)]))
PY
}

refresh_tap() {
  if ! brew tap-info "$tap" --json >/dev/null 2>&1; then
    brew tap "$tap" "$tap_remote"
  fi
  tap_repo=$(brew --repo "$tap")
  observed_remote=$(git -C "$tap_repo" remote get-url origin)
  [[ "$observed_remote" == "$tap_remote" ]] || { printf 'install_kuku_cask: wrong tap remote: %s\n' "$observed_remote" >&2; exit 1; }
  brew trust "$tap"
  brew update
  git -C "$tap_repo" fetch origin main
  [[ $(git -C "$tap_repo" rev-parse HEAD) == $(git -C "$tap_repo" rev-parse origin/main) ]] || {
    printf 'install_kuku_cask: tap is not at origin/main\n' >&2
    exit 1
  }
  if [[ "$mode" != withdraw ]]; then
    cask_version=$(sed -nE 's/^[[:space:]]*version "([^"]+)"/\1/p' "$tap_repo/Casks/kuku.rb")
    [[ "$cask_version" == "$release" ]] || { printf 'install_kuku_cask: tap version %s does not equal %s\n' "$cask_version" "$release" >&2; exit 1; }
  fi
}

verify_installed() {
  local expected_release=$1 expected_app=$2 expected_bundle=$3 identity tap_name full installed_value codesign_output
  identity=$(installed_identity)
  IFS=$'\t' read -r tap_name full installed_value <<<"$identity"
  [[ "$tap_name" == "$tap" && "$full" == "$token" && "$installed_value" == "$expected_release" ]] || {
    printf 'install_kuku_cask: installed identity mismatch tap=%s full_token=%s installed=%s\n' "$tap_name" "$full" "$installed_value" >&2
    exit 1
  }
  [[ $(defaults read "$app_path/Contents/Info.plist" CFBundleShortVersionString) == "$expected_app" ]]
  [[ $(defaults read "$app_path/Contents/Info.plist" CFBundleVersion) == "$expected_bundle" ]]
  codesign_output=$(codesign -dvvv "$app_path" 2>&1)
  rg -q 'Authority=Developer ID Application' <<<"$codesign_output"
  rg -q 'TeamIdentifier=8P9788YC9P' <<<"$codesign_output"
  rg -q 'flags=.*runtime' <<<"$codesign_output"
  spctl -a -vv -t exec "$app_path" 2>&1 | rg -q 'source=Notarized Developer ID'
  xcrun stapler validate "$app_path"
  [[ -x "$smoke" ]] || { printf 'install_kuku_cask: smoke helper missing: %s\n' "$smoke" >&2; exit 1; }
  "$smoke" --app "$app_path"
}

refresh_tap
if [[ "$mode" != withdraw ]] && ! command -v b3sum >/dev/null 2>&1; then
  brew install b3sum
fi
[[ "$mode" == withdraw ]] || command -v b3sum >/dev/null 2>&1 || {
  printf 'install_kuku_cask: b3sum missing after installation\n' >&2
  exit 1
}

identity=$(installed_identity)
tap_name= full= installed_value=
[[ -z "$identity" ]] || IFS=$'\t' read -r tap_name full installed_value <<<"$identity"
if [[ -n "$identity" && "$tap_name" != "$tap" ]]; then
  printf 'install_kuku_cask: foreign cask %s version %s must be removed by hand first\n' "$full" "$installed_value" >&2
  exit 1
fi

if [[ "$mode" == withdraw ]]; then
  if [[ -n "$identity" ]]; then
    bundle_id=$(defaults read "$app_path/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true)
    [[ "$bundle_id" == mom.kuku.app ]] || { printf 'install_kuku_cask: installed cask does not own %s\n' "$app_path" >&2; exit 1; }
  fi
  state=$(record_field state 2>/dev/null || true)
  backup_path=$(record_field backup_path 2>/dev/null || true)
  recorded_version=$(record_field version 2>/dev/null || true)
  timestamp=$(record_field timestamp 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
  if [[ "$state" == restored ]]; then
    printf 'WITHDRAW already restored\n'
    exit 0
  fi
  write_record restoring "$backup_path" "$recorded_version" "$timestamp"
  [[ -z "$identity" ]] || brew uninstall --cask "$token"
  if [[ -n "$backup_path" ]]; then
    source_present=0; destination_present=0
    [[ -e "$backup_path" ]] && source_present=1
    [[ -e "$app_path" ]] && destination_present=1
    if [[ $source_present -eq 1 && $destination_present -eq 0 ]]; then
      mv "$backup_path" "$app_path"
    elif [[ $source_present -eq 0 && $destination_present -eq 1 ]]; then
      observed=$(defaults read "$app_path/Contents/Info.plist" CFBundleShortVersionString)
      [[ "$observed" == "$recorded_version" ]] || exit 1
    else
      printf 'install_kuku_cask: restoring refused source=%s destination=%s\n' "$backup_path" "$app_path" >&2
      exit 1
    fi
  else
    [[ ! -e "$app_path" ]] || { printf 'install_kuku_cask: unowned app remains at %s\n' "$app_path" >&2; exit 1; }
  fi
  write_record restored "$backup_path" "$recorded_version" "$timestamp"
  [[ -z $(installed_identity) ]] || exit 1
  process_name=$(plutil -extract CFBundleExecutable raw -o - "$app_path/Contents/Info.plist" 2>/dev/null || true)
  if [[ -e "$app_path" ]]; then
    [[ "$process_name" == kuku-app ]] || { printf 'install_kuku_cask: expected CFBundleExecutable kuku-app, observed %s\n' "${process_name:-missing}" >&2; exit 1; }
    pgrep -x "$process_name" >/dev/null 2>&1 && exit 1
  fi
  printf 'WITHDRAW state=restored backup=%s\n' "${backup_path:-none}"
  exit 0
fi

if [[ "$mode" == install ]]; then
  state=$(record_field state 2>/dev/null || true)
  if [[ "$state" == restored ]]; then
    timestamp=$(record_field timestamp)
    archive="$(dirname "$record")/h4-install-backup.${timestamp//:/-}.json"
    [[ ! -e "$archive" ]] || { printf 'install_kuku_cask: backup archive exists: %s\n' "$archive" >&2; exit 1; }
    mv "$record" "$archive"
    state=
  fi
  if [[ -z "$identity" ]]; then
    if [[ "$state" == moving ]]; then
      backup_path=$(record_field backup_path)
      source_present=0; backup_present=0
      [[ -e "$app_path" ]] && source_present=1
      [[ -e "$backup_path" ]] && backup_present=1
      if [[ $source_present -eq 1 && $backup_present -eq 0 ]]; then
        mv "$app_path" "$backup_path"
      elif [[ $source_present -eq 0 && $backup_present -eq 1 ]]; then
        :
      else
        printf 'install_kuku_cask: moving refused source=%s backup=%s\n' "$app_path" "$backup_path" >&2
        exit 1
      fi
      write_record moved "$backup_path" "$(record_field version)" "$(record_field timestamp)"
    elif [[ ! -f "$record" ]]; then
      timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      backup_path=
      prior_version=
      if [[ -e "$app_path" ]]; then
        prior_version=$(defaults read "$app_path/Contents/Info.plist" CFBundleShortVersionString)
        backup_path="$HOME/Desktop/Kuku.app.pre-brew-${timestamp//:/-}-$$"
        [[ ! -e "$backup_path" ]] || { printf 'install_kuku_cask: backup path exists: %s\n' "$backup_path" >&2; exit 1; }
        write_record moving "$backup_path" "$prior_version" "$timestamp"
        mv "$app_path" "$backup_path"
      fi
      write_record moved "$backup_path" "$prior_version" "$timestamp"
    elif [[ -n $(record_field backup_path 2>/dev/null || true) && "$(record_field backup_path)" != "${backup_path:-$(record_field backup_path)}" ]]; then
      printf 'install_kuku_cask: refusing to overwrite non-null backup\n' >&2
      exit 1
    fi
  fi
fi

if [[ "$mode" == rollback ]]; then
  if [[ "$installed_value" != "$release" ]]; then
    [[ -z "$identity" ]] || brew uninstall --cask "$token"
    brew install --cask "$token"
  fi
else
  if brew list --cask "$token" >/dev/null 2>&1; then
    brew upgrade --cask "$token"
  else
    brew install --cask "$token"
  fi
fi
verify_installed "$release" "$app_version" "$bundle_version"
backup_path=$(record_field backup_path 2>/dev/null || true)
recorded_version=$(record_field version 2>/dev/null || true)
timestamp=$(record_field timestamp 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
write_record installed "$backup_path" "$recorded_version" "$timestamp"
printf 'INSTALL release=%s app=%s bundle=%s state=installed\n' "$release" "$app_version" "$bundle_version"
