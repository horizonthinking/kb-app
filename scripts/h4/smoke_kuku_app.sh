#!/usr/bin/env bash
# ---
# asset: kuku-application-smoke
# type: test-script
# description: Launch an exact Kuku.app against a temporary one-note vault and require one indexed FTS result while restoring user settings.
# owner: michael
# status: active
# ---

set -euo pipefail

app_path=/Applications/Kuku.app
if [[ "${1:-}" == "--app" ]]; then
  app_path=${2:-}
  shift 2
fi
[[ $# -eq 0 && -d "$app_path" ]] || {
  printf 'usage: smoke_kuku_app.sh [--app <Kuku.app>]\n' >&2
  exit 2
}
command -v b3sum >/dev/null 2>&1 || {
  printf 'b3sum missing; run brew install b3sum\n' >&2
  exit 1
}

data_root="$HOME/.kuku"
settings_path="$data_root/settings.json"
indexer_path="$data_root/plugins/core-indexer/settings.json"
search_root="$data_root/search"
work_root=$(mktemp -d "${TMPDIR:-/private/tmp}/kuku-smoke.XXXXXX")
vault_path="$work_root/vault"
backup_root="$work_root/backups"
snapshot_before="$work_root/search-before"
screenshot="$work_root/kuku-smoke.png"
token="kukusmoke$(date +%s)$$"
db_path=
cleanup_started=0

mkdir -p "$vault_path" "$backup_root" "$search_root"
printf '# Smoke\n\n%s\n' "$token" >"$vault_path/smoke.md"
find "$search_root" -maxdepth 1 -type f -name '*.sqlite3' -print | sort >"$snapshot_before"

backup_file() {
  local source=$1 name=$2
  if [[ -f "$source" ]]; then
    cp "$source" "$backup_root/$name"
    : >"$backup_root/$name.present"
  fi
}

restore_file() {
  local target=$1 name=$2 replacement
  if [[ -f "$backup_root/$name.present" ]]; then
    mkdir -p "$(dirname "$target")"
    replacement="$target.restore.$$"
    cp "$backup_root/$name" "$replacement" || return 1
    mv -f "$replacement" "$target" || return 1
  else
    rm -f "$target" || return 1
  fi
}

wait_for_exit() {
  local limit=${KUKU_SMOKE_EXIT_POLLS:-50}
  for ((i = 0; i < limit; i++)); do
    pgrep -x Kuku >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  return 1
}

cleanup() {
  local incoming=$? cleanup_status=0 after_snapshot
  [[ $cleanup_started -eq 0 ]] || exit "$incoming"
  cleanup_started=1
  set +e
  pkill -x Kuku >/dev/null 2>&1
  wait_for_exit || cleanup_status=1
  restore_file "$settings_path" settings.json || cleanup_status=1
  restore_file "$indexer_path" indexer.json || cleanup_status=1
  if [[ -n "$db_path" ]]; then
    rm -f "$db_path" "$db_path-wal" "$db_path-shm" || cleanup_status=1
  fi
  after_snapshot="$work_root/search-after"
  find "$search_root" -maxdepth 1 -type f -name '*.sqlite3' -print | sort >"$after_snapshot"
  cmp -s "$snapshot_before" "$after_snapshot" || cleanup_status=1
  if [[ $cleanup_status -ne 0 ]]; then
    printf 'smoke_kuku_app: restoration failed; work files retained at %s\n' "$work_root" >&2
    exit 1
  fi
  rm -rf "$work_root"
  exit "$incoming"
}
trap cleanup EXIT INT TERM

backup_file "$settings_path" settings.json
backup_file "$indexer_path" indexer.json
pkill -x Kuku >/dev/null 2>&1 || true
wait_for_exit || {
  printf 'smoke_kuku_app: Kuku did not quit before configuration\n' >&2
  exit 1
}

mkdir -p "$(dirname "$settings_path")" "$(dirname "$indexer_path")"
python3 - "$settings_path" "$vault_path" <<'PY'
import json
import os
import sys

path, vault = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle)
except (FileNotFoundError, json.JSONDecodeError):
    value = {}
value["last_opened_vault"] = vault
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, path)
PY
python3 - "$indexer_path" <<'PY'
import json
import os
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle)
except (FileNotFoundError, json.JSONDecodeError):
    value = {}
value["storageLocation"] = "app-global"
value["reindexOnVaultOpen"] = True
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, path)
PY

canonical_vault=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$vault_path")
path_hash=$(printf '%s' "$canonical_vault" | b3sum --no-names | tr -d '[:space:]')
[[ "$path_hash" =~ ^[0-9a-f]{64}$ ]] || {
  printf 'smoke_kuku_app: invalid BLAKE3 output: %s\n' "$path_hash" >&2
  exit 1
}
db_path="$search_root/$path_hash.sqlite3"

open "$app_path"
pid=
for ((i = 0; i < ${KUKU_SMOKE_LAUNCH_POLLS:-100}; i++)); do
  mapfile_output=$(pgrep -x Kuku 2>/dev/null || true)
  count=$(printf '%s\n' "$mapfile_output" | awk 'NF { count++ } END { print count + 0 }')
  if [[ $count -eq 1 ]]; then
    pid=$mapfile_output
    break
  fi
  sleep 0.1
done
[[ -n "$pid" ]] || {
  printf 'smoke_kuku_app: expected exactly one Kuku process\n' >&2
  exit 1
}
executable=$(ps -o comm= -p "$pid" | sed 's/^[[:space:]]*//')
case "$executable" in
  "$app_path"/Contents/MacOS/*) ;;
  *) printf 'smoke_kuku_app: executable outside requested bundle: %s\n' "$executable" >&2; exit 1 ;;
esac

index_count=0
poll_seconds=${KUKU_SMOKE_POLL_SECONDS:-60}
for ((i = 0; i < poll_seconds; i++)); do
  if [[ -f "$db_path" ]]; then
    index_count=$(sqlite3 "$db_path" "SELECT count(*) FROM chunks_fts WHERE chunks_fts MATCH '$token';" 2>/dev/null || printf '0')
    [[ "$index_count" == "1" ]] && break
  fi
  sleep 1
done
[[ "$index_count" == "1" ]] || {
  printf 'smoke_kuku_app: expected index count 1, observed %s at %s\n' "$index_count" "$db_path" >&2
  exit 1
}

if ! screencapture -x "$screenshot" 2>/dev/null; then
  printf 'SMOKE_UNKNOWN screenshot=unavailable\n'
fi
printf 'SMOKE index_count=1 executable_path=%s settings_key=last_opened_vault storage_key=storageLocation storage_value=app-global reindex_key=reindexOnVaultOpen blake3_input=%s\n' "$executable" "$canonical_vault"
