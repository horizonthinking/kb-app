#!/usr/bin/env bash
# ---
# asset: kuku-h4-release-coordinator
# type: release-script
# description: Single locked launcher and audited coordinator for Kuku build, publication, installation, withdrawal, and worktree cleanup.
# owner: michael
# status: active
# ---

set -euo pipefail

script_path=${BASH_SOURCE[0]}
if ! operator_root=$(git -C "$(dirname "$script_path")" rev-parse --show-toplevel 2>/dev/null); then
  operator_root=$(cd "$(dirname "$script_path")/../.." && pwd)
fi
test_mode=${RELEASE_H4_TEST_MODE:-0}
stage=${RELEASE_H4_STAGE:-launcher}
dry_run=0
args=("$@")
if [[ " ${args[*]} " == *' --dry-run '* ]]; then dry_run=1; fi

operation=release
release=${1:-}
case "$release" in
  install|withdraw|cleanup)
    operation=$release
    release=${2:-}
    ;;
  cleanup-others)
    [[ "$stage" == audited ]] || { printf 'release_h4: cleanup-others is an internal audited-stage operation\n' >&2; exit 2; }
    operation=$release
    release=${2:-}
    ;;
esac
[[ -n "$release" ]] || { printf 'usage: release_h4.sh <version> [--dry-run] | install <release> <host> | withdraw <release> | cleanup <release>\n' >&2; exit 2; }
case "$operation" in
  release) [[ $# -eq 1 || ( $# -eq 2 && "${2:-}" == --dry-run ) ]] ;;
  install) [[ $# -eq 3 ]] ;;
  withdraw|cleanup|cleanup-others) [[ $# -eq 2 ]] ;;
esac || { printf 'usage: release_h4.sh <version> [--dry-run] | install <release> <host> | withdraw <release> | cleanup <release>\n' >&2; exit 2; }
[[ "$release" =~ ^0\.([0-9]+)\.([0-9]+)-h4\.([1-3])$ ]] || {
  [[ "$release" == [0-9]* ]] && printf 'release_h4: version scheme needs revisiting: %s\n' "$release" >&2 || printf 'release_h4: invalid release: %s\n' "$release" >&2
  exit 2
}
minor=${BASH_REMATCH[1]}; patch=${BASH_REMATCH[2]}; attempt=${BASH_REMATCH[3]}
app_version="0.$minor.$patch"
bundle_version="$minor.$patch.$attempt"
[[ "$bundle_version" =~ ^[1-9][0-9]{0,3}(\.(0|[1-9][0-9]?)){0,2}$ ]] || { printf 'release_h4: invalid bundle version %s\n' "$bundle_version" >&2; exit 2; }

if [[ "$operation" == install ]]; then
  host=${3:-}
  [[ "$host" == laptop-m3 || "$host" == ts-27-mac-mini || "$host" == ts-home-mac-mini ]] || { printf 'release_h4: invalid install host %s\n' "$host" >&2; exit 2; }
fi

override_names=(RELEASE_H4_BUILD_CMD RELEASE_H4_BUILD_HOST RELEASE_H4_SIGN_CMD RELEASE_H4_LIVE_GATE_CMD RELEASE_H4_GATES_CMD RELEASE_H4_HDIUTIL_CMD RELEASE_H4_SMOKE_CMD RELEASE_H4_SELF_TEST_CMD RELEASE_H4_SELF_TEST_DEPTH RELEASE_H4_SSH_CMD RELEASE_H4_SCP_CMD RELEASE_H4_CURL_CMD RELEASE_H4_ARTIFACT_ROOT RELEASE_H4_LOCK_DIR RELEASE_H4_COORDINATOR_OK GH BREW)
if [[ "$test_mode" != 1 && "$stage" == launcher ]]; then
  for name in "${override_names[@]}"; do
    if python3 -c 'import os,sys;raise SystemExit(0 if sys.argv[1] in os.environ else 1)' "$name"; then
      printf 'release_h4: test-only override refused outside test mode: %s\n' "$name" >&2
      exit 1
    fi
  done
elif [[ "$dry_run" != 1 ]]; then
  [[ "${RELEASE_H4_ARTIFACT_ROOT:-}" == /private/tmp/* && "${H4_CHECKOUT:-}" == /private/tmp/* ]] || {
    printf 'release_h4: test roots must be under /private/tmp\n' >&2
    exit 1
  }
fi

if [[ ${RELEASE_H4_SELF_TEST_DEPTH+x} == x ]]; then
  [[ "$test_mode" == 1 && "$RELEASE_H4_SELF_TEST_DEPTH" == 1 ]] || { printf 'release_h4: invalid self-test depth\n' >&2; exit 1; }
fi

if [[ $dry_run -eq 1 ]]; then
  printf 'DRY_RUN operation=%s release=%s app_version=%s bundle_version=%s label=h4.%s\n' "$operation" "$release" "$app_version" "$bundle_version" "$attempt"
  printf '%s\n' \
    'Phase 0: resolve absent, draft, or published remote state' \
    'Phase A: audit tags; prerequisites; static gates; reserve; one paid gate; build; sign; notarize; DMG smoke' \
    'Phase B: recreate h4-audited; prepare; draft consumer precheck; publish-release; published consumer check; converge' \
    'No lock, worktree, ssh, GitHub API, or manifest mutation was performed.'
  exit 0
fi

artifact_root=${RELEASE_H4_ARTIFACT_ROOT:-$HOME/projects/apps/kb-app/release-artifacts/h4}
release_root="$artifact_root/$release"
lock_dir=${RELEASE_H4_LOCK_DIR:-$HOME/Library/Application Support/H4/kuku-release.lock}
ssh_cmd=${RELEASE_H4_SSH_CMD:-ssh}
scp_cmd=${RELEASE_H4_SCP_CMD:-scp}
gh_cmd=${GH:-gh}
h4_checkout=${H4_CHECKOUT:-$HOME/projects/h4}
h4_audited="$release_root/h4-audited"
nonce=${RELEASE_H4_LOCK_NONCE:-}
lock_owned=0

process_start() { ps -o lstart= -p "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
owner_matches() {
  [[ -f "$lock_dir/owner.json" ]] || return 1
  OWNER_NONCE="$nonce" python3 - "$lock_dir/owner.json" "$release" "$1" <<'PY'
import json, os, sys
value=json.load(open(sys.argv[1], encoding="utf-8"))
assert value["nonce"] == os.environ["OWNER_NONCE"]
assert value["release"] == sys.argv[2]
assert str(value["pid"]) == sys.argv[3]
print(value["process_start"])
PY
}
release_lock() {
  local incoming=$?
  if [[ $lock_owned -eq 1 && -f "$lock_dir/owner.json" ]]; then
    current=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["nonce"])' "$lock_dir/owner.json" 2>/dev/null || true)
    [[ "$current" != "$nonce" ]] || rm -rf "$lock_dir"
  fi
  exit "$incoming"
}
trap release_lock EXIT INT TERM

assert_coordinator() {
  [[ "$test_mode" == 1 && "${RELEASE_H4_COORDINATOR_OK:-0}" == 1 ]] && return
  observed=$(tailscale status --self --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["HostName"])')
  [[ "$observed" == laptop-m3 ]] || { printf 'release_h4: coordinator must be laptop-m3, observed %s\n' "$observed" >&2; exit 1; }
}
acquire_lock() {
  local parent age owner_pid owner_start actual_start stale=0
  parent=$(dirname "$lock_dir"); mkdir -p "$parent"; parent=$(realpath "$parent"); lock_dir="$parent/$(basename "$lock_dir")"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    if [[ -f "$lock_dir/owner.json" ]]; then
      read -r owner_pid owner_start < <(python3 - "$lock_dir/owner.json" <<'PY' 2>/dev/null || printf 'malformed malformed\n'
import json, sys
v=json.load(open(sys.argv[1], encoding="utf-8")); print(v["pid"], v["process_start"].replace(" ", "\x1f"))
PY
      )
      owner_start=${owner_start//$'\x1f'/ }
      if ! kill -0 "$owner_pid" 2>/dev/null; then stale=1
      else actual_start=$(process_start "$owner_pid"); [[ "$actual_start" == "$owner_start" ]] || stale=1; fi
    else
      age=$(( $(date +%s) - $(stat -f %m "$lock_dir") )); (( age > 600 )) && stale=1
    fi
    [[ $stale -eq 1 ]] || { printf 'release_h4: release lock is held: %s\n' "$lock_dir" >&2; exit 1; }
    mv "$lock_dir" "$parent/.kuku-release.lock.stale-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir "$lock_dir"
  fi
  nonce=$(openssl rand -hex 16)
  process_start_value=$(process_start $$)
  OWNER_NONCE="$nonce" OWNER_START="$process_start_value" OWNER_RELEASE="$release" python3 - "$lock_dir/owner.json" <<'PY'
import json, os, socket, sys
path=sys.argv[1]; tmp=path+".tmp"
with open(tmp,"w",encoding="utf-8") as h:
 json.dump({"host":socket.gethostname(),"pid":os.getppid(),"release":os.environ["OWNER_RELEASE"],"started_at":__import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),"process_start":os.environ["OWNER_START"],"nonce":os.environ["OWNER_NONCE"]},h)
 h.flush(); os.fsync(h.fileno())
os.replace(tmp,path)
PY
  # Python's parent above is this shell's pid.
  lock_owned=1
  export RELEASE_H4_LOCK_DIR="$lock_dir" RELEASE_H4_LOCK_NONCE="$nonce"
}

authenticate_audited_lock() {
  expected_parent=$$
  [[ "${RELEASE_H4_LOCK_INHERITED:-0}" == 1 ]] && expected_parent=$PPID
  recorded_start=$(owner_matches "$expected_parent") || { printf 'release_h4: audited lock authentication failed\n' >&2; exit 1; }
  [[ $(process_start "$expected_parent") == "$recorded_start" ]] || { printf 'release_h4: audited lock owner is stale\n' >&2; exit 1; }
}

ship_script() {
  local host_name=$1 relative=$2 remote_name hash temporary
  remote_name=$(basename "$relative"); temporary="$remote_name.tmp.$nonce"
  hash=$(git -C "$operator_root" cat-file -p "audit/kuku-$release:$relative" | shasum -a 256 | awk '{print $1}')
  "$ssh_cmd" "$host_name" 'install -d -m 0755 ~/.local/bin/h4-kuku'
  "$scp_cmd" "$operator_root/$relative" "$host_name:.local/bin/h4-kuku/$temporary"
  "$ssh_cmd" "$host_name" "shasum -a 256 ~/.local/bin/h4-kuku/$temporary | awk -v expected='$hash' '{exit (\\$1 == expected ? 0 : 1)}' && mv -f ~/.local/bin/h4-kuku/$temporary ~/.local/bin/h4-kuku/$remote_name && chmod 0755 ~/.local/bin/h4-kuku/$remote_name"
}

run_install() {
  ship_script "$host" scripts/h4/install_kuku_cask.sh
  ship_script "$host" scripts/h4/smoke_kuku_app.sh
  "$ssh_cmd" "$host" "bash -lc '~/.local/bin/h4-kuku/install_kuku_cask.sh $release'"
}

run_consumer_access_checks() {
  local mode=$1 identifier=$2 helper relative remote_args consumer_host
  relative=scripts/h4/lib/consumer_access_check.sh
  helper="$operator_root/$relative"
  remote_args="$identifier"
  if [[ "$mode" == published ]]; then remote_args="--published $identifier"; fi
  if [[ "$mode" == published ]]; then
    "$helper" --published "$identifier"
  else
    "$helper" "$identifier"
  fi
  for consumer_host in ts-27-mac-mini ts-home-mac-mini; do
    ship_script "$consumer_host" "$relative"
    "$ssh_cmd" "$consumer_host" "bash -lc '~/.local/bin/h4-kuku/consumer_access_check.sh $remote_args'"
  done
}

cleanup_others() {
  for path in "$release_root/h4-audited" "$release_root/h4-publish" "$release_root/tap-publish"; do
    [[ ! -e "$path" ]] || { [[ -z $(git -C "$path" status --porcelain) ]] || { printf 'release_h4: dirty worktree refused: %s\n' "$path" >&2; exit 1; }; git -C "$h4_checkout" worktree remove "$path"; }
  done
  git -C "$h4_checkout" worktree prune
  printf 'CLEANUP_OTHERS release=%s artifacts=preserved\n' "$release"
}

ensure_h4_audited() {
  local commit
  git -C "$h4_checkout" fetch origin main --tags
  [[ $(git -C "$h4_checkout" cat-file -t "audit/kuku-$release") == tag ]] || {
    printf 'release_h4: h4 audit tag is absent or not annotated\n' >&2
    exit 1
  }
  commit=$(git -C "$h4_checkout" rev-parse "audit/kuku-$release^{commit}")
  git -C "$h4_checkout" merge-base --is-ancestor "$commit" origin/main
  if [[ -e "$h4_audited" ]]; then
    [[ -z $(git -C "$h4_audited" status --porcelain) ]] || { printf 'release_h4: dirty h4-audited worktree refused\n' >&2; exit 1; }
    git -C "$h4_checkout" worktree remove "$h4_audited"
  fi
  git -C "$h4_checkout" worktree add --detach "$h4_audited" "$commit"
  [[ -z $(git -C "$h4_audited" status --porcelain) ]]
}

run_remote_build_and_sign() {
  local build_host=${RELEASE_H4_BUILD_HOST:-ts-27-mac-mini}
  local remote_root="/Users/michasmi/projects/apps/kb-app/release-artifacts/h4/$release"
  local remote_dmg="$remote_root/Kuku-$release.dmg"
  local local_dmg="$release_root/Kuku-$release.dmg"
  local sign_output="$release_root/sign-notarize.out" expected_sha observed_sha
  "$ssh_cmd" "$build_host" "RELEASE='$release' REMOTE_ROOT='$remote_root' bash -s" <<'REMOTE' | tee "$sign_output"
set -euo pipefail
export PATH=/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export TMPDIR=/private/tmp
repo="$HOME/projects/apps/kb-app"
src="$REMOTE_ROOT/src"
tag="audit/kuku-$RELEASE"
git -C "$repo" fetch origin main --tags
[[ $(git -C "$repo" cat-file -t "$tag") == tag ]]
commit=$(git -C "$repo" rev-parse "$tag^{commit}")
git -C "$repo" merge-base --is-ancestor "$commit" origin/main
if [[ -e "$src" ]]; then
  [[ $(git -C "$src" rev-parse HEAD) == "$commit" && -z $(git -C "$src" status --porcelain) ]]
else
  mkdir -p "$REMOTE_ROOT"
  git -C "$repo" worktree add --detach "$src" "$commit"
fi
command -v b3sum >/dev/null 2>&1 || brew install b3sum
"$src/scripts/h4/build_h4.sh"
app="$src/target/release/bundle/macos/Kuku.app"
"$src/scripts/h4/check_updater_marker.sh" "$app"

driver="$REMOTE_ROOT/gui-sign.sh"
out="$REMOTE_ROOT/gui-sign.out"
err="$REMOTE_ROOT/gui-sign.err"
label="com.h4.kuku-release.${RELEASE//[^A-Za-z0-9]/-}"
plist="$HOME/Library/LaunchAgents/$label.plist"
cat >"$driver" <<DRIVER
#!/bin/bash
set -euo pipefail
export PATH=/opt/homebrew/bin:\$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export HOME=\$HOME
"$src/scripts/h4/sign_notarize_dmg.sh" "$app" "$REMOTE_ROOT" "$RELEASE"
DRIVER
chmod 0700 "$driver"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
: >"$out"; : >"$err"
cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$driver</string></array>
<key>EnvironmentVariables</key><dict><key>HOME</key><string>$HOME</string><key>PATH</key><string>/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>$out</string>
<key>StandardErrorPath</key><string>$err</string>
</dict></plist>
PLIST
plutil -lint "$plist" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$plist"
finished=0
for _ in $(seq 1 120); do
  sleep 10
  state=$(launchctl print "gui/$(id -u)/$label" 2>/dev/null | awk -F'= ' '/^[[:space:]]*state =/{print $2; exit}' || true)
  if [[ "$state" == "not running" || -z "$state" ]]; then finished=1; break; fi
done
[[ $finished -eq 1 ]] || { printf 'remote signing LaunchAgent timed out\n' >&2; exit 1; }
exit_code=$(launchctl print "gui/$(id -u)/$label" 2>/dev/null | awk -F'= ' '/last exit code/{print $2; exit}' || printf '99')
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
mv "$plist" "$REMOTE_ROOT/$label.plist.completed"
cat "$out"
if [[ "$exit_code" != 0 ]]; then tail -40 "$err" >&2; exit "$exit_code"; fi
[[ -f "$REMOTE_ROOT/Kuku-$RELEASE.dmg" ]]
REMOTE
  "$scp_cmd" "$build_host:$remote_dmg" "$local_dmg.tmp"
  mv "$local_dmg.tmp" "$local_dmg"
  expected_sha=$(sed -nE 's/^RESULT dmg_sha256=(.*)$/\1/p' "$sign_output" | tail -1)
  observed_sha=$(shasum -a 256 "$local_dmg" | awk '{print $1}')
  [[ -n "$expected_sha" && "$observed_sha" == "$expected_sha" ]] || { printf 'release_h4: DMG transfer digest mismatch\n' >&2; exit 1; }
}

ensure_dmg_smoke_receipt() {
  local dmg=$1 dmg_sha=$2 kb_sha=$3 h4_sha=$4
  local receipt="$release_root/smoke_receipt.json" smoke_sha
  smoke_sha=$(shasum -a 256 "$operator_root/scripts/h4/smoke_kuku_app.sh" | awk '{print $1}')
  if [[ -f "$receipt" ]] && RECEIPT_DMG_SHA="$dmg_sha" RECEIPT_KB_SHA="$kb_sha" RECEIPT_H4_SHA="$h4_sha" RECEIPT_SMOKE_SHA="$smoke_sha" python3 - "$receipt" <<'PY'
import json, os, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(value) == {"dmg_sha256", "kb_app_sha", "h4_sha", "smoke_script_sha256", "host", "mounted_app_path", "observed_executable_path", "index_count", "timestamp"}
assert value["dmg_sha256"] == os.environ["RECEIPT_DMG_SHA"]
assert value["kb_app_sha"] == os.environ["RECEIPT_KB_SHA"]
assert value["h4_sha"] == os.environ["RECEIPT_H4_SHA"]
assert value["smoke_script_sha256"] == os.environ["RECEIPT_SMOKE_SHA"]
assert value["host"] == "laptop-m3"
assert isinstance(value["mounted_app_path"], str) and value["mounted_app_path"].endswith("/Kuku.app")
assert isinstance(value["observed_executable_path"], str) and value["observed_executable_path"].startswith(value["mounted_app_path"] + "/Contents/MacOS/")
assert value["index_count"] == 1
assert isinstance(value["timestamp"], str)
PY
  then
    printf 'DMG_SMOKE receipt=reused path=%s\n' "$receipt"
    return
  fi

  (
    set -euo pipefail
    local mount_root attach_plist device= mounted=0 smoke_output observed_executable hdiutil_cmd smoke_cmd cleanup_status=0
    mount_root=$(mktemp -d /private/tmp/kuku-dmg-smoke.XXXXXX)
    mkdir "$mount_root/mount"
    attach_plist="$mount_root/attach.plist"
    hdiutil_cmd=${RELEASE_H4_HDIUTIL_CMD:-hdiutil}
    smoke_cmd=${RELEASE_H4_SMOKE_CMD:-$operator_root/scripts/h4/smoke_kuku_app.sh}
    cleanup_mount() {
      local incoming=$?
      if [[ $mounted -eq 1 ]]; then
        "$hdiutil_cmd" detach -force "$device" >/dev/null 2>&1 || cleanup_status=1
      fi
      if [[ $cleanup_status -ne 0 ]]; then
        printf 'release_h4: DMG detach failed for %s\n' "$device" >&2
        exit 1
      fi
      exit "$incoming"
    }
    trap cleanup_mount EXIT INT TERM
    "$hdiutil_cmd" attach -nobrowse -readonly -mountpoint "$mount_root/mount" -plist "$dmg" >"$attach_plist"
    device=$(python3 - "$attach_plist" <<'PY'
import plistlib, sys
value = plistlib.load(open(sys.argv[1], "rb"))
devices = [item.get("dev-entry") for item in value.get("system-entities", []) if item.get("dev-entry")]
assert len(devices) >= 1
print(devices[0])
PY
    )
    mounted=1
    [[ -d "$mount_root/mount/Kuku.app" ]]
    smoke_output=$("$smoke_cmd" --app "$mount_root/mount/Kuku.app")
    printf '%s\n' "$smoke_output"
    rg -q '^SMOKE index_count=1 ' <<<"$smoke_output"
    observed_executable=$(sed -nE 's/^SMOKE index_count=1 executable_path=([^ ]+) .*/\1/p' <<<"$smoke_output")
    [[ "$observed_executable" == "$mount_root/mount/Kuku.app/Contents/MacOS/"* ]]
    "$hdiutil_cmd" detach "$device" >/dev/null
    mounted=0
    RECEIPT_PATH="$receipt" RECEIPT_DMG_SHA="$dmg_sha" RECEIPT_KB_SHA="$kb_sha" RECEIPT_H4_SHA="$h4_sha" RECEIPT_SMOKE_SHA="$smoke_sha" RECEIPT_APP="$mount_root/mount/Kuku.app" RECEIPT_EXECUTABLE="$observed_executable" python3 - <<'PY'
import datetime, json, os
path = os.environ["RECEIPT_PATH"]
value = {
    "dmg_sha256": os.environ["RECEIPT_DMG_SHA"],
    "kb_app_sha": os.environ["RECEIPT_KB_SHA"],
    "h4_sha": os.environ["RECEIPT_H4_SHA"],
    "smoke_script_sha256": os.environ["RECEIPT_SMOKE_SHA"],
    "host": "laptop-m3",
    "mounted_app_path": os.environ["RECEIPT_APP"],
    "observed_executable_path": os.environ["RECEIPT_EXECUTABLE"],
    "index_count": 1,
    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, path)
PY
  )
}

write_withdraw_journal() {
  local path=$1 branch=$2 target=${3:-} host=${4:-} state=${5:-}
  JOURNAL_PATH="$path" JOURNAL_SOURCE="$release" JOURNAL_BRANCH="$branch" JOURNAL_TARGET="$target" JOURNAL_HOST="$host" JOURNAL_STATE="$state" python3 - <<'PY'
import datetime, json, os
path = os.environ["JOURNAL_PATH"]
try:
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle)
except FileNotFoundError:
    value = {
        "source_version": os.environ["JOURNAL_SOURCE"],
        "branch": os.environ["JOURNAL_BRANCH"],
        "target_version": os.environ["JOURNAL_TARGET"] or None,
        "hosts": {name: "pending" for name in ("laptop-m3", "ts-27-mac-mini", "ts-home-mac-mini")},
        "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
assert set(value) == {"source_version", "branch", "target_version", "hosts", "created_at"}
assert value["source_version"] == os.environ["JOURNAL_SOURCE"]
assert value["branch"] == os.environ["JOURNAL_BRANCH"]
assert (value["target_version"] or "") == os.environ["JOURNAL_TARGET"]
assert set(value["hosts"]) == {"laptop-m3", "ts-27-mac-mini", "ts-home-mac-mini"}
assert all(state in {"pending", "applying", "done"} for state in value["hosts"].values())
if os.environ["JOURNAL_HOST"]:
    assert os.environ["JOURNAL_HOST"] in value["hosts"]
    assert os.environ["JOURNAL_STATE"] in {"pending", "applying", "done"}
    value["hosts"][os.environ["JOURNAL_HOST"]] = os.environ["JOURNAL_STATE"]
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, path)
PY
}

withdraw_host_state() {
  python3 - "$1" "$2" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["hosts"][sys.argv[2]])
PY
}

converge_withdraw_repo() {
  local source=$1 kind=$2 target_cask=${3:-} attempt=1 worktree cask_path strategy_path changes bad
  worktree="$release_root/${kind}-publish"
  while (( attempt <= 5 )); do
    git -C "$source" fetch origin main
    if [[ -e "$worktree" ]]; then
      [[ -z $(git -C "$worktree" status --porcelain) ]] || { printf 'release_h4: dirty publication worktree refused\n' >&2; exit 1; }
      git -C "$source" worktree remove "$worktree"
    fi
    git -C "$source" worktree add --detach "$worktree" origin/main
    if [[ "$kind" == h4 ]]; then
      cask_path="$worktree/deploy/homebrew-tap/Casks/kuku.rb"
      strategy_path="$worktree/deploy/homebrew-tap/lib/kuku_private_github_release_download_strategy.rb"
    else
      cask_path="$worktree/Casks/kuku.rb"
      strategy_path="$worktree/lib/kuku_private_github_release_download_strategy.rb"
    fi
    if [[ -n "$target_cask" ]]; then
      mkdir -p "$(dirname "$cask_path")" "$(dirname "$strategy_path")"
      cp "$target_cask" "$cask_path"
      cp "$h4_audited/deploy/homebrew-tap/lib/kuku_private_github_release_download_strategy.rb" "$strategy_path"
    else
      [[ ! -e "$cask_path" ]] || mv "$cask_path" "$release_root/$(basename "$kind")-kuku.rb.removed"
    fi
    changes=$(git -C "$worktree" status --porcelain)
    if [[ -n "$changes" ]]; then
      bad=$(awk '{print $2}' <<<"$changes" | rg -v '^(Casks/kuku.rb|lib/kuku_private_github_release_download_strategy.rb|deploy/homebrew-tap/Casks/kuku.rb|deploy/homebrew-tap/lib/kuku_private_github_release_download_strategy.rb)$' || true)
      [[ -z "$bad" ]] || { printf 'release_h4: withdrawal changed non-owned path %s\n' "$bad" >&2; exit 1; }
      git -C "$worktree" add -A
      git -C "$worktree" -c user.name=KukuPublisher -c user.email=kuku-publisher@invalid commit -qm "withdraw kuku $release"
      if ! git -C "$worktree" push origin HEAD:main; then
        ((attempt++))
        continue
      fi
    fi
    [[ -z $(git -C "$worktree" status --porcelain) ]]
    git -C "$source" worktree remove "$worktree"
    git -C "$source" worktree prune
    return 0
  done
  printf 'release_h4: withdrawal convergence failed after five attempts\n' >&2
  exit 1
}

run_withdraw() {
  local releases_json predecessor= branch target_cask= withdraw_root journal consumer_host state installer_args
  local manifest_id manifest_digest dmg_digest predecessor_id manifest_path
  ensure_h4_audited
  tap_checkout=${H4_TAP_CHECKOUT:-$h4_checkout/live/homebrew-h4}
  [[ -d "$tap_checkout/.git" || -f "$tap_checkout/.git" ]] || { printf 'release_h4: tap checkout missing: %s\n' "$tap_checkout" >&2; exit 1; }
  releases_json=$("$gh_cmd" api --paginate repos/horizonthinking/kuku-releases/releases)
  predecessor=$(RELEASES_JSON="$releases_json" python3 - "$release" <<'PY'
import json, os, re, sys
current = sys.argv[1]
pattern = re.compile(r"^kuku-v0\.([0-9]+)\.([0-9]+)-h4\.([1-3])$")
current_match = pattern.fullmatch("kuku-v" + current)
assert current_match
current_key = tuple(map(int, current_match.groups()))
values = json.loads(os.environ["RELEASES_JSON"])
if values and isinstance(values[0], list): values = [item for page in values for item in page]
candidates = []
for value in values:
    if value.get("draft") or not value.get("immutable"): continue
    tag = value.get("tag_name", "")
    if not tag.startswith("kuku-v"): continue
    match = pattern.fullmatch(tag)
    if not match: raise SystemExit(f"unparsable published Kuku tag: {tag}")
    key = tuple(map(int, match.groups()))
    if key < current_key: candidates.append((key, tag.removeprefix("kuku-v"), value["id"]))
if candidates:
    _, version, release_id = max(candidates)
    print(version, release_id)
PY
  )
  withdraw_root="$artifact_root/withdraw-$release"
  mkdir -p "$withdraw_root"
  journal="$withdraw_root/journal.json"
  if [[ -n "$predecessor" ]]; then
    read -r predecessor predecessor_id <<<"$predecessor"
    branch=later-release
    assets_json=$("$gh_cmd" api "repos/horizonthinking/kuku-releases/releases/$predecessor_id/assets")
    read -r manifest_id manifest_digest dmg_digest < <(ASSETS_JSON="$assets_json" python3 - "$predecessor" <<'PY'
import json, os, sys
version = sys.argv[1]
assets = json.loads(os.environ["ASSETS_JSON"])
manifest = [x for x in assets if x.get("name") == f"Kuku-{version}.manifest.json"]
dmg = [x for x in assets if x.get("name") == f"Kuku-{version}.dmg"]
assert len(manifest) == len(dmg) == 1
print(manifest[0]["id"], manifest[0]["digest"].removeprefix("sha256:"), dmg[0]["digest"].removeprefix("sha256:"))
PY
    )
    manifest_path="$withdraw_root/Kuku-$predecessor.manifest.json"
    "$gh_cmd" api -H 'Accept: application/octet-stream' "repos/horizonthinking/kuku-releases/releases/assets/$manifest_id" >"$manifest_path.tmp"
    [[ $(shasum -a 256 "$manifest_path.tmp" | awk '{print $1}') == "$manifest_digest" ]] || exit 1
    mv "$manifest_path.tmp" "$manifest_path"
    [[ $(python3 - "$manifest_path" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["dmg_sha256"])
PY
    ) == "$dmg_digest" ]] || { printf 'release_h4: predecessor DMG digest mismatch\n' >&2; exit 1; }
    target_cask="$withdraw_root/kuku.rb"
    sed -e "s/@VERSION@/$predecessor/g" -e "s/@SHA256@/$dmg_digest/g" "$h4_audited/deploy/homebrew-tap/templates/kuku.rb.tmpl" >"$target_cask"
    source "$h4_audited/deploy/homebrew-tap/lib/publisher_preflight.sh"
    validate_kuku_cask "$target_cask" "$h4_audited/deploy/homebrew-tap/lib/kuku_private_github_release_download_strategy.rb" "$predecessor" "$dmg_digest"
    installer_args="--rollback $predecessor"
  else
    branch=first-release
    installer_args=--withdraw
  fi
  write_withdraw_journal "$journal" "$branch" "$predecessor"
  converge_withdraw_repo "$h4_checkout" h4 "$target_cask"
  converge_withdraw_repo "$tap_checkout" tap "$target_cask"
  for consumer_host in laptop-m3 ts-27-mac-mini ts-home-mac-mini; do
    state=$(withdraw_host_state "$journal" "$consumer_host")
    [[ "$state" != done ]] || continue
    write_withdraw_journal "$journal" "$branch" "$predecessor" "$consumer_host" applying
    if [[ "$consumer_host" == laptop-m3 ]]; then
      "$operator_root/scripts/h4/install_kuku_cask.sh" $installer_args
    else
      ship_script "$consumer_host" scripts/h4/install_kuku_cask.sh
      ship_script "$consumer_host" scripts/h4/smoke_kuku_app.sh
      "$ssh_cmd" "$consumer_host" "bash -lc '~/.local/bin/h4-kuku/install_kuku_cask.sh $installer_args'"
    fi
    write_withdraw_journal "$journal" "$branch" "$predecessor" "$consumer_host" done
  done
  printf 'WITHDRAW release=%s branch=%s target=%s hosts=3\n' "$release" "$branch" "${predecessor:-none}"
}

run_audited_release() {
  local config moon_value config_app config_bundle publisher release_id receipt_line helper_sha reserve_created current_fingerprint draft_body
  config="$operator_root/apps/desktop/src-tauri/tauri.h4.conf.json"
  read -r config_app config_bundle < <(python3 - "$config" <<'PY'
import json,sys
v=json.load(open(sys.argv[1])); print(v["version"],v["bundle"]["macOS"]["bundleVersion"])
PY
  )
  [[ "$config_app" == "$app_version" && "$config_bundle" == "$bundle_version" ]] || { printf 'release_h4: build identity mismatch\n' >&2; exit 1; }
  moon_value=$(python3 - "$operator_root/apps/desktop/moon.yml" <<'PY'
import re,sys
t=open(sys.argv[1]).read(); m=re.search(r'tauri-build-h4:.*?VITE_KUKU_BUILD_LABEL:\s*"?([^"\n]+)',t,re.S); print(m.group(1).strip())
PY
  )
  [[ "$moon_value" == "h4.$attempt" ]] || { printf 'release_h4: build label mismatch\n' >&2; exit 1; }
  mkdir -p "$release_root"
  command -v b3sum >/dev/null 2>&1 || brew install b3sum
  command -v b3sum >/dev/null 2>&1

  gates_cmd=${RELEASE_H4_GATES_CMD:-"pnpm moon run kuku-ai:test kuku-ai:lint-check kuku-ai:format-check desktop:test-ts desktop:lint-ts-check desktop:format-ts-check desktop:test-rust desktop:lint-rust-check desktop:format-rust-check web:test"}
  bash -lc "$gates_cmd"
  if [[ "${RELEASE_H4_SELF_TEST_DEPTH:-0}" != 1 ]]; then
    self_test=${RELEASE_H4_SELF_TEST_CMD:-scripts/h4/release_h4_test.sh}
    RELEASE_H4_SELF_TEST_DEPTH=1 "$self_test"
  fi

  ensure_h4_audited
  publisher="$h4_audited/deploy/homebrew-tap/publish_kuku_cask.sh"
  reserve_output=$("$publisher" reserve "$release")
  release_id=$(sed -nE 's/.*release_id=([0-9]+).*/\1/p' <<<"$reserve_output")
  reserve_created=$(sed -nE 's/.*created=(true|false).*/\1/p' <<<"$reserve_output")
  [[ -n "$release_id" ]] || { printf 'release_h4: reserve did not return a release id\n' >&2; exit 1; }
  [[ "$reserve_created" == true || "$reserve_created" == false ]] || { printf 'release_h4: reserve did not return its creation state\n' >&2; exit 1; }

  journal="$release_root/manifest.json"
  live_log="$release_root/live-gate.log"
  live_cmd=${RELEASE_H4_LIVE_GATE_CMD:-scripts/h4/verify_ai_provider.sh}
  export KUKU_TEST_OPENAI_BASE_URL=https://api.openai.com/v1
  export KUKU_TEST_OPENAI_MODEL=gpt-5-nano
  export KUKU_TEST_OPENAI_STRICT_TEXT=1
  verifier_path=$live_cmd
  [[ "$verifier_path" == /* ]] || verifier_path="$operator_root/$verifier_path"
  verifier_sha=$(shasum -a 256 "$verifier_path" | awk '{print $1}')
  current_fingerprint=$(KUKU_LIVE_VERIFIER_SHA256="$verifier_sha" python3 - <<'PY'
import hashlib
import os
import urllib.parse

parsed = urllib.parse.urlsplit(os.environ["KUKU_TEST_OPENAI_BASE_URL"].strip())
host = parsed.hostname.lower()
if ":" in host:
    host = f"[{host}]"
port = f":{parsed.port}" if parsed.port is not None else ""
path = parsed.path.rstrip("/") or "/v1"
base = f"{parsed.scheme.lower()}://{host}{port}{path}"
key = os.environ.get("KUKU_TEST_OPENAI_API_KEY", "").strip()
key_hash = hashlib.sha256(key.encode()).hexdigest() if key else "none"
canonical = (
    "kuku-live-gate/1\n"
    f"{base}\n"
    f"{os.environ['KUKU_TEST_OPENAI_MODEL']}\n"
    f"{os.environ['KUKU_LIVE_VERIFIER_SHA256'].lower()}\n"
    f"{key_hash}\n"
)
print(hashlib.sha256(canonical.encode()).hexdigest())
PY
  )
  "$gh_cmd" api "repos/horizonthinking/kuku-releases/releases/$release_id" --jq .body >"$release_root/draft-body.remote"
  draft_body=$(<"$release_root/draft-body.remote")
  receipt_line=
  if [[ -n "$draft_body" && "$draft_body" != null ]]; then
    if ! receipt_line=$(python3 - "$release_root/draft-body.remote" "$current_fingerprint" "$live_log" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

body_path, expected_fingerprint, log_path = sys.argv[1:]
value = json.load(open(body_path, encoding="utf-8"))
if set(value) != {"receipt", "kb_app_sha", "h4_sha"}:
    raise SystemExit(1)
receipt = value["receipt"]
pattern = re.compile(
    r"^receipt config=([0-9a-f]{64}) chat=3 models=2 "
    r"attempts=([0-9A-Za-z._-]+(?:,[0-9A-Za-z._-]+){3}) log_sha256=([0-9a-f]{64})$"
)
match = pattern.fullmatch(receipt) if isinstance(receipt, str) else None
if match is None or match.group(1) != expected_fingerprint:
    raise SystemExit(1)
path = pathlib.Path(log_path)
if path.exists():
    data = path.read_bytes()
    lines = data.splitlines(keepends=True)
    receipts = [index for index, line in enumerate(lines) if line.startswith(b"receipt ")]
    if receipts != [len(lines) - 1] or not data.endswith(b"\n"):
        raise SystemExit(1)
    if lines[-1].decode().rstrip("\n") != receipt:
        raise SystemExit(1)
    if hashlib.sha256(b"".join(lines[:-1])).hexdigest() != match.group(3):
        raise SystemExit(1)
print(receipt)
PY
    ); then
      printf 'release_h4: draft kuku-v%s exists without a valid live-gate receipt; this version is burned: release the next version\n' "$release" >&2
      exit 1
    fi
    printf 'LIVE_GATE_REUSE release=%s fingerprint=%s requests=0\n' "$release" "$current_fingerprint"
  else
    [[ "$reserve_created" == true ]] || {
      printf 'release_h4: draft kuku-v%s exists without a valid live-gate receipt; this version is burned: release the next version\n' "$release" >&2
      exit 1
    }
    printf '{"release":"%s","live_gate_state":"started","release_id":%s}\n' "$release" "$release_id" >"$journal.tmp"
    mv "$journal.tmp" "$journal"
    [[ ! -s "$live_log" ]] || { printf 'release_h4: non-empty live-gate log before first paid request; version is burned\n' >&2; exit 1; }
    KUKU_LIVE_REQUEST_LOG="$live_log" "$live_cmd" | tee "$release_root/live-gate.out"
    receipt_line=$(tail -1 "$live_log")
    [[ "$receipt_line" == "receipt config=$current_fingerprint chat=3 models=2 attempts="*" log_sha256="* ]] || exit 1
    printf '{"receipt":%s,"kb_app_sha":"%s","h4_sha":"%s"}\n' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$receipt_line")" "$(git rev-parse HEAD)" "$(git -C "$h4_audited" rev-parse HEAD)" >"$release_root/draft-body.json"
    "$gh_cmd" release edit "kuku-v$release" --repo horizonthinking/kuku-releases --draft --notes-file "$release_root/draft-body.json"
    "$gh_cmd" api "repos/horizonthinking/kuku-releases/releases/$release_id" --jq .body >"$release_root/draft-body.readback"
    cmp -s "$release_root/draft-body.json" "$release_root/draft-body.readback" || { printf 'release_h4: draft-body receipt readback mismatch; version is burned\n' >&2; exit 1; }
  fi

  if [[ "$test_mode" == 1 ]]; then
    build_cmd=${RELEASE_H4_BUILD_CMD:-scripts/h4/build_h4.sh}
    sign_cmd=${RELEASE_H4_SIGN_CMD:-scripts/h4/sign_notarize_dmg.sh}
    "$build_cmd"
    "$operator_root/scripts/h4/check_updater_marker.sh" "$release_root/Kuku.app"
    "$sign_cmd" "$release_root/Kuku.app" "$release_root" "$release"
  else
    run_remote_build_and_sign
  fi
  dmg="$release_root/Kuku-$release.dmg"; [[ -f "$dmg" ]] || { printf 'release_h4: DMG missing after sign stage\n' >&2; exit 1; }
  dmg_sha=$(shasum -a 256 "$dmg" | awk '{print $1}')
  helper_sha=$(shasum -a 256 "$operator_root/scripts/h4/lib/consumer_access_check.sh" | awk '{print $1}')
  kb_sha=$(git rev-parse HEAD)
  h4_sha=$(git -C "$h4_audited" rev-parse HEAD)
  ensure_dmg_smoke_receipt "$dmg" "$dmg_sha" "$kb_sha" "$h4_sha"
  kb_tag_object=$(git rev-parse "audit/kuku-$release")
  h4_tag_object=$(git -C "$h4_checkout" rev-parse "audit/kuku-$release")
  app_notary_id=$(sed -nE 's/^RESULT app_notary_submission_id=(.*)$/\1/p' "$release_root/sign-notarize.out" 2>/dev/null | tail -1)
  dmg_notary_id=$(sed -nE 's/^RESULT dmg_notary_submission_id=(.*)$/\1/p' "$release_root/sign-notarize.out" 2>/dev/null | tail -1)
  if [[ "$test_mode" != 1 ]]; then [[ -n "$app_notary_id" && -n "$dmg_notary_id" ]] || { printf 'release_h4: notarization ids missing\n' >&2; exit 1; }; fi
  PROVENANCE_PATH="$release_root/provenance.json" SMOKE_PATH="$release_root/smoke_receipt.json" REVIEWED_KB_SHA="$kb_sha" REVIEWED_H4_SHA="$h4_sha" KB_TAG_OBJECT="$kb_tag_object" H4_TAG_OBJECT="$h4_tag_object" APP_VERSION="$app_version" BUNDLE_VERSION="$bundle_version" RELEASE_VERSION="$release" DMG_SHA="$dmg_sha" LIVE_RECEIPT="$receipt_line" APP_NOTARY_ID="$app_notary_id" DMG_NOTARY_ID="$dmg_notary_id" python3 - <<'PY'
import json, os
path = os.environ["PROVENANCE_PATH"]
with open(os.environ["SMOKE_PATH"], encoding="utf-8") as handle:
    smoke = json.load(handle)
value = {
    "reviewed_kb_app_sha": os.environ["REVIEWED_KB_SHA"],
    "reviewed_h4_sha": os.environ["REVIEWED_H4_SHA"],
    "kb_app_audit_tag_object_id": os.environ["KB_TAG_OBJECT"],
    "h4_audit_tag_object_id": os.environ["H4_TAG_OBJECT"],
    "build_sha": os.environ["REVIEWED_KB_SHA"],
    "app_version": os.environ["APP_VERSION"],
    "bundle_version": os.environ["BUNDLE_VERSION"],
    "release_version": os.environ["RELEASE_VERSION"],
    "dmg_sha256": os.environ["DMG_SHA"],
    "notarization_submission_ids": {
        "app": os.environ["APP_NOTARY_ID"],
        "dmg": os.environ["DMG_NOTARY_ID"],
    },
    "live_gate_receipt": os.environ["LIVE_RECEIPT"],
    "smoke_receipt": smoke,
}
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, path)
PY
  "$publisher" prepare "$release" "$dmg_sha" "$dmg"
  run_consumer_access_checks draft "$release_id"
  "$publisher" publish-release "$release" "$release_id"
  run_consumer_access_checks published "kuku-v$release"
  receipt="$release_root/postpub_receipt.json"
  assets_json=$("$gh_cmd" api "repos/horizonthinking/kuku-releases/releases/$release_id/assets")
  dmg_asset_id=$(ASSETS_JSON="$assets_json" python3 - "$release" "$dmg_sha" <<'PY'
import json, os, sys
release, expected = sys.argv[1:]
name = f"Kuku-{release}.dmg"
matches = [asset for asset in json.loads(os.environ["ASSETS_JSON"]) if asset.get("name") == name]
assert len(matches) == 1
assert matches[0].get("digest") == f"sha256:{expected}"
print(matches[0]["id"])
PY
  )
  RECEIPT_PATH="$receipt" RECEIPT_ID="$release_id" RECEIPT_TAG="kuku-v$release" RECEIPT_ASSET_ID="$dmg_asset_id" RECEIPT_DMG_SHA="$dmg_sha" RECEIPT_HELPER_SHA="$helper_sha" python3 - <<'PY'
import json, os
path = os.environ["RECEIPT_PATH"]
value = {
    "release_id": int(os.environ["RECEIPT_ID"]),
    "tag": os.environ["RECEIPT_TAG"],
    "dmg_asset_id": int(os.environ["RECEIPT_ASSET_ID"]),
    "dmg_sha256": os.environ["RECEIPT_DMG_SHA"],
    "helper_sha256": os.environ["RECEIPT_HELPER_SHA"],
    "hosts": {"laptop-m3": "ok", "ts-27-mac-mini": "ok", "ts-home-mac-mini": "ok"},
}
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, path)
PY
  RELEASE_H4_CONSUMER_HELPER_SHA256="$helper_sha" "$publisher" converge "$release" "$release_id" "$receipt"
  printf 'RELEASE release=%s state=published\n' "$release"
}

if [[ "$stage" == audited || "$operation" == cleanup-others ]]; then
  authenticate_audited_lock
  [[ "${RELEASE_H4_LOCK_INHERITED:-0}" == 1 ]] || lock_owned=1
  audited_root=$(git rev-parse --show-toplevel)
  [[ "$audited_root" == "$operator_root" ]] || exit 1
  if [[ "$operation" == install ]]; then run_install
  elif [[ "$operation" == cleanup-others ]]; then cleanup_others
  elif [[ "$operation" == withdraw ]]; then run_withdraw
  else run_audited_release
  fi
  exit 0
fi

assert_coordinator
acquire_lock
mkdir -p "$release_root"
git -C "$operator_root" fetch origin --tags
audit_commit=$(git -C "$operator_root" rev-parse "audit/kuku-$release^{commit}")
git -C "$operator_root" merge-base --is-ancestor "$audit_commit" origin/main
running_hash=$(git -C "$operator_root" hash-object "$script_path")
audited_hash=$(git -C "$operator_root" rev-parse "audit/kuku-$release:scripts/h4/release_h4.sh")
[[ "$running_hash" == "$audited_hash" ]] || { printf 'release_h4: stale launcher; run scripts/h4/release_h4.sh from a checkout at audit/kuku-%s\n' "$release" >&2; exit 1; }
src="$release_root/src"
if [[ -e "$src" ]]; then
  [[ $(git -C "$src" rev-parse HEAD) == "$audit_commit" && -z $(git -C "$src" status --porcelain) ]] || exit 1
else
  git -C "$operator_root" worktree add --detach "$src" "$audit_commit"
fi

if [[ "$operation" == cleanup ]]; then
  RELEASE_H4_STAGE=audited RELEASE_H4_LOCK_INHERITED=1 "$src/scripts/h4/release_h4.sh" cleanup-others "$release"
  [[ -z $(git -C "$src" status --porcelain) ]] || exit 1
  git -C "$operator_root" worktree remove "$src"
  git -C "$operator_root" worktree prune
  printf 'CLEANUP release=%s src_removed_last=true artifacts=preserved\n' "$release"
  exit 0
fi

export RELEASE_H4_STAGE=audited RELEASE_H4_LOCK_NONCE="$nonce"
cd "$src"
exec "$src/scripts/h4/release_h4.sh" "$@"
