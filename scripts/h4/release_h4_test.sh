#!/usr/bin/env bash
# ---
# asset: kuku-h4-release-coordinator-test
# type: test-script
# description: Behavioural git, lock, audit, recovery, publication-order, distribution, and cleanup tests for the H4 release coordinator.
# owner: michael
# status: active
# ---

set -euo pipefail

if [[ "${1:-}" == __git__ ]]; then
  shift
  state=${FAKE_RELEASE_STATE:?}
  printf 'git' >>"$state/calls.log"; printf ' %q' "$@" >>"$state/calls.log"; printf '\n' >>"$state/calls.log"
  if [[ " $* " == *' ls-remote '* && -f "$state/remote-oid-mismatch" ]]; then printf '%040d\trefs/tags/audit/kuku-0.5.8-h4.1\n' 0; exit 0; fi
  if [[ " $* " == *' fetch '* && -f "$state/hold-fetch" ]]; then
    : >"$state/fetch-entered"
    while [[ -f "$state/hold-fetch" ]]; do /bin/sleep 0.05; done
  fi
  if [[ " $* " == *' fetch '* && -f "$state/replace-owner-on-fetch" ]]; then
    rm "$state/replace-owner-on-fetch"
    OWNER="$state/lock/owner.json" /usr/bin/python3 - <<'PY'
import json,os
p=os.environ["OWNER"];v=json.load(open(p));v["nonce"]="replacement";json.dump(v,open(p,"w"))
PY
    exit 83
  fi
  exec "$FAKE_REAL_GIT" "$@"
fi

repo_root=$(git rev-parse --show-toplevel)
test_path="$repo_root/scripts/h4/release_h4_test.sh"
release_source="$repo_root/scripts/h4/release_h4.sh"
real_git=$(command -v git)
real_rg=$(command -v rg)
real_b3sum=$(command -v b3sum)
all_root=$(mktemp -d /private/tmp/kuku-release-test.XXXXXX)
trap '[[ "${KUKU_KEEP_TEST_ROOT:-0}" == 1 ]] || rm -rf "$all_root"' EXIT
release=0.5.8-h4.1
case_count=0

init_repo() {
  local work=$1 bare=$2
  "$real_git" init --bare -q "$bare"
  "$real_git" -C "$work" init -q -b main
  "$real_git" -C "$work" add -A
  "$real_git" -C "$work" -c user.name=Test -c user.email=test@invalid commit -qm seed
  "$real_git" -C "$work" remote add origin "$bare"
  "$real_git" -C "$work" push -q -u origin main
}

tag_repo() {
  local work=$1
  "$real_git" -C "$work" tag -a -m "Wave 3 audit $release" "audit/kuku-$release"
  "$real_git" -C "$work" push -q origin "refs/tags/audit/kuku-$release"
}

make_fixture() {
  name=$1
  root="$all_root/$name"
  kb="$root/kb"
  kb_bare="$root/kb.git"
  h4="$root/h4"
  h4_bare="$root/h4.git"
  artifacts="$root/artifacts"
  lock="$root/lock"
  bin="$root/bin"
  remote_hosts="$root/hosts"
  mkdir -p "$kb/scripts/h4/lib" "$kb/apps/desktop/src-tauri" "$h4/deploy/homebrew-tap/lib" \
    "$h4/deploy/homebrew-tap/templates" "$artifacts" "$bin" "$remote_hosts"
  cp "$release_source" "$kb/scripts/h4/release_h4.sh"
  cp "$repo_root/scripts/h4/install_kuku_cask.sh" "$kb/scripts/h4/install_kuku_cask.sh"
  cp "$repo_root/scripts/h4/smoke_kuku_app.sh" "$kb/scripts/h4/smoke_kuku_app.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "marker %s\\n" "$*" >>"$FAKE_RELEASE_STATE/calls.log"\n' >"$kb/scripts/h4/check_updater_marker.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "consumer local %s\\n" "$*" >>"$FAKE_RELEASE_STATE/calls.log"\n[[ ! -f "$FAKE_RELEASE_STATE/fail-consumer-local" ]]\n' >"$kb/scripts/h4/lib/consumer_access_check.sh"
  chmod +x "$kb/scripts/h4/"*.sh "$kb/scripts/h4/lib/"*.sh
  printf '{"version":"0.5.8","bundle":{"macOS":{"bundleVersion":"5.8.1"}}}\n' >"$kb/apps/desktop/src-tauri/tauri.h4.conf.json"
  printf 'tasks:\n  tauri-build-h4:\n    env:\n      VITE_KUKU_BUILD_LABEL: "h4.1"\n' >"$kb/apps/desktop/moon.yml"
  init_repo "$kb" "$kb_bare"
  tag_repo "$kb"

  make_fake_publisher "$h4/deploy/homebrew-tap/publish_kuku_cask.sh"
  printf 'template\n' >"$h4/deploy/homebrew-tap/templates/kuku.rb.tmpl"
  printf 'strategy\n' >"$h4/deploy/homebrew-tap/lib/kuku_private_github_release_download_strategy.rb"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$h4/deploy/homebrew-tap/publish_kuku_cask_test.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$h4/deploy/homebrew-tap/publish_kuku_cask_realbrew_test.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$h4/deploy/homebrew-tap/lib/publisher_preflight.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$h4/deploy/homebrew-tap/lib/readme_inventory_check.sh"
  printf 'registry\n' >"$h4/deploy/homebrew-tap/registry-homebrew-tap.yaml"
  chmod +x "$h4/deploy/homebrew-tap/"*.sh "$h4/deploy/homebrew-tap/lib/"*.sh
  init_repo "$h4" "$h4_bare"
  tag_repo "$h4"

  printf '{"state":"absent","id":101,"body":"","assets":[],"publication_calls":0,"dmg_uploads":0,"manifest_uploads":0}\n' >"$root/remote.json"
  : >"$root/calls.log"
  make_fake_gh
  make_fake_tools
  printf '#!/usr/bin/env bash\nexec %q __git__ "$@"\n' "$test_path" >"$bin/git"; chmod +x "$bin/git"
  printf '#!/usr/bin/env bash\nprintf "fake-process-start\\n"\n' >"$bin/ps"; chmod +x "$bin/ps"
  cp "$real_b3sum" "$bin/b3sum"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$real_rg" >"$bin/rg"; chmod +x "$bin/rg"
  export FAKE_RELEASE_STATE="$root" FAKE_REAL_GIT="$real_git"
}

make_fake_publisher() {
  local path=$1
  cat >"$path" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
action=$1; release=$2; root=${FAKE_RELEASE_STATE:?}; remote="$root/remote.json"
printf 'publisher %s\n' "$*" >>"$root/calls.log"
fail="$root/fail-publisher-$action"
[[ ! -f "$fail.before" ]] || { rm "$fail.before"; exit 71; }
case "$action" in
  reserve)
    read -r state id created < <(REMOTE="$remote" /usr/bin/python3 - <<'PY'
import json,os
p=os.environ["REMOTE"];v=json.load(open(p));created=False
if v["state"]=="absent": v["state"]="draft";created=True;json.dump(v,open(p,"w"))
print(v["state"],v["id"],str(created).lower())
PY
    )
    printf 'PUBLISH_RESERVE state=%s release_id=%s created=%s\n' "$state" "$id" "$created"
    ;;
  prepare)
    REMOTE="$remote" DMG="$4" PROV="$RELEASE_H4_ARTIFACT_ROOT/$release/provenance.json" /usr/bin/python3 - <<'PY'
import hashlib,json,os
p=os.environ["REMOTE"];v=json.load(open(p));
if not v["assets"]:
 d=hashlib.sha256(open(os.environ["DMG"],"rb").read()).hexdigest();m=hashlib.sha256(open(os.environ["PROV"],"rb").read()).hexdigest()
 v["assets"]=[{"id":201,"name":"Kuku-0.5.8-h4.1.dmg","digest":"sha256:"+d},{"id":202,"name":"Kuku-0.5.8-h4.1.manifest.json","digest":"sha256:"+m}];v["dmg_uploads"]+=1;v["manifest_uploads"]+=1
json.dump(v,open(p,"w"))
PY
    ;;
  publish-release)
    REMOTE="$remote" /usr/bin/python3 - <<'PY'
import json,os
p=os.environ["REMOTE"];v=json.load(open(p));
if v["state"]!="published":v["state"]="published";v["publication_calls"]+=1
json.dump(v,open(p,"w"))
PY
    ;;
  converge)
    RECEIPT="$4" HELPER_SHA="${RELEASE_H4_CONSUMER_HELPER_SHA256:?}" /usr/bin/python3 - <<'PY'
import json, os
value=json.load(open(os.environ["RECEIPT"],encoding="utf-8"))
assert set(value)=={"release_id","tag","dmg_asset_id","dmg_sha256","helper_sha256","hosts"}
assert value["release_id"]==101 and value["tag"]=="kuku-v0.5.8-h4.1"
assert value["helper_sha256"]==os.environ["HELPER_SHA"]
assert value["hosts"]=={"laptop-m3":"ok","ts-27-mac-mini":"ok","ts-home-mac-mini":"ok"}
PY
    ;;
  *) exit 2 ;;
esac
[[ ! -f "$fail.after" ]] || { rm "$fail.after"; exit 72; }
SH
  chmod +x "$path"
}

make_fake_gh() {
  cat >"$root/fake_gh.py" <<'PY'
import json,os,pathlib,sys
root=pathlib.Path(os.environ["FAKE_RELEASE_STATE"]);args=sys.argv[1:]
with (root/"calls.log").open("a") as h:h.write("gh "+" ".join(args)+"\n")
remote=json.load(open(root/"remote.json"))
if args[:2]==["api","--paginate"] and args[-1].endswith("/rulesets"):
 print("[]" if (root/"ruleset-missing").exists() else '[{"id":1,"target":"tag","enforcement":"active"}]');raise SystemExit
if args and args[0]=="api" and args[1].endswith("/rulesets/1"):
 if (root/"ruleset-disabled").exists(): enforcement="disabled"
 else: enforcement="active"
 include=[] if (root/"ruleset-excludes").exists() else ["refs/tags/audit/*"]
 print(json.dumps({"id":1,"target":"tag","enforcement":enforcement,"bypass_actors":[],"conditions":{"ref_name":{"include":include,"exclude":[]}},"rules":[{"type":"deletion"},{"type":"update","parameters":{"update_allows_fetch_and_merge":False}}]}));raise SystemExit
if args and args[0]=="api" and "/releases/101/assets" in args[1]: print(json.dumps(remote["assets"]));raise SystemExit
if args and args[0]=="api" and "/releases/101" in args[1]:
 if "--jq" in args and args[args.index("--jq")+1]==".body":sys.stdout.write(remote["body"])
 else:print(json.dumps({"id":101,"tag_name":"kuku-v0.5.8-h4.1","draft":remote["state"]!="published","immutable":remote["state"]=="published","assets":remote["assets"],"body":remote["body"]}))
 raise SystemExit
if args[:2]==["release","edit"] and "--notes-file" in args:
 remote["body"]=pathlib.Path(args[args.index("--notes-file")+1]).read_text();json.dump(remote,open(root/"remote.json","w"));raise SystemExit
raise SystemExit("unsupported gh "+repr(args))
PY
  printf '#!/usr/bin/env bash\nexec /usr/bin/python3 %q "$@"\n' "$root/fake_gh.py" >"$bin/gh"; chmod +x "$bin/gh"
}

make_fake_tools() {
  cat >"$bin/live-gate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root=${FAKE_RELEASE_STATE:?};printf 'live-gate\n' >>"$root/calls.log"
[[ ! -f "$root/fail-live" ]] || exit 61
verifier_sha=$(shasum -a 256 "$0"|awk '{print $1}')
fingerprint=$(VERIFIER="$verifier_sha" /usr/bin/python3 - <<'PY'
import hashlib,os
canonical="kuku-live-gate/1\nhttps://api.openai.com/v1\ngpt-5-nano\n"+os.environ["VERIFIER"]+"\nnone\n"
print(hashlib.sha256(canonical.encode()).hexdigest())
PY
)
printf 'probe attempt=p config=%s\ncompleted attempt=a config=%s live_streams_text_with_usage_identities\ncompleted attempt=b config=%s live_two_round_tool_call_replays_ids\ncompleted attempt=c config=%s live_list_models_contains_the_configured_model_once\n' "$fingerprint" "$fingerprint" "$fingerprint" "$fingerprint" >"$KUKU_LIVE_REQUEST_LOG"
prefix=$(shasum -a 256 "$KUKU_LIVE_REQUEST_LOG"|awk '{print $1}')
printf 'receipt config=%s chat=3 models=2 attempts=p,a,b,c log_sha256=%s\n' "$fingerprint" "$prefix" >>"$KUKU_LIVE_REQUEST_LOG"
printf 'LIVE_GATE_RECEIPT chat=3 models=2 attempts=p,a,b,c\n'
SH
  cat >"$bin/build" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root=${FAKE_RELEASE_STATE:?};printf 'build\n' >>"$root/calls.log";[[ ! -f "$root/fail-build" ]] || exit 62
mkdir -p "$RELEASE_H4_ARTIFACT_ROOT/0.5.8-h4.1/Kuku.app/Contents/MacOS";printf app >"$RELEASE_H4_ARTIFACT_ROOT/0.5.8-h4.1/Kuku.app/Contents/MacOS/kuku-app"
SH
  cat >"$bin/sign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root=${FAKE_RELEASE_STATE:?};printf 'sign\n' >>"$root/calls.log";[[ ! -f "$root/fail-sign" ]] || exit 63
printf dmg >"$2/Kuku-$3.dmg"
printf 'RESULT app_notary_submission_id=test-app\nRESULT dmg_notary_submission_id=test-dmg\n' >"$2/sign-notarize.out"
SH
  cat >"$bin/hdiutil" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root=${FAKE_RELEASE_STATE:?};printf 'hdiutil %s\n' "$*" >>"$root/calls.log"
if [[ "$1" == attach ]]; then
 mount=${*: -3:1};mkdir -p "$mount/Kuku.app/Contents/MacOS"
 /usr/bin/python3 - <<'PY'
import plistlib,sys
plistlib.dump({"system-entities":[{"dev-entry":"/dev/disk99"}]},sys.stdout.buffer)
PY
fi
SH
  cat >"$bin/smoke" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root=${FAKE_RELEASE_STATE:?};printf 'smoke\n' >>"$root/calls.log";app=$2
printf 'SMOKE index_count=1 executable_path=%s/Contents/MacOS/kuku-app settings_key=x\n' "$app"
SH
  cat >"$bin/gates" <<'SH'
#!/usr/bin/env bash
printf 'gates\n' >>"$FAKE_RELEASE_STATE/calls.log"
SH
  cat >"$bin/brew" <<'SH'
#!/usr/bin/env bash
printf 'brew %s\n' "$*" >>"$FAKE_RELEASE_STATE/calls.log"
if [[ "$*" == 'install b3sum' ]]; then cp "$FAKE_RELEASE_STATE/real-b3sum" "$FAKE_RELEASE_STATE/bin/b3sum";chmod +x "$FAKE_RELEASE_STATE/bin/b3sum";fi
SH
  cat >"$bin/tailscale" <<'SH'
#!/usr/bin/env bash
printf '{"Self":{"HostName":"not-laptop"}}\n'
SH
  cat >"$bin/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root=${FAKE_RELEASE_STATE:?};host=$1;shift;printf 'ssh %s %s\n' "$host" "$*" >>"$root/calls.log"
if [[ "$*" == *KUKU_CLEANUP_BUILD_WORKTREE=1* ]]; then
 build_src="$root/build-host-src"
 if [[ -e "$build_src" ]]; then
  [[ -z $("$FAKE_REAL_GIT" -C "$build_src" status --porcelain) ]] || exit 70
  "$FAKE_REAL_GIT" -C "$root/kb" worktree remove "$build_src"
 fi
 "$FAKE_REAL_GIT" -C "$root/kb" worktree prune
 exit 0
fi
[[ ! -f "$root/fail-consumer-$host" || "$*" != *consumer_access_check.sh* ]] || exit 64
if [[ "$*" == *consumer_access_check.sh* && "$host" == ts-home-mac-mini ]]; then
 if [[ "$*" != *--published* && -f "$root/fail-after-draft-precheck" ]]; then rm "$root/fail-after-draft-precheck";exit 68;fi
 if [[ "$*" == *--published* && -f "$root/fail-after-published-precheck" ]]; then rm "$root/fail-after-published-precheck";exit 69;fi
fi
if [[ "$*" == *'shasum -a 256'* ]]; then
 remote="$root/hosts/$host/.local/bin/h4-kuku/${*#*~/.local/bin/h4-kuku/}";remote=${remote%% *}
 [[ -f "$remote" ]] || exit 65
 if [[ -f "$root/corrupt-shipped" ]]; then exit 66;fi
 final=${remote%%.tmp.*};mv "$remote" "$final";chmod +x "$final"
fi
SH
  cat >"$bin/scp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
root=${FAKE_RELEASE_STATE:?};src=$1;dest=$2;host=${dest%%:*};rel=${dest#*:};target="$root/hosts/$host/$rel"
printf 'scp %s %s\n' "$src" "$dest" >>"$root/calls.log";[[ ! -f "$root/drop-scp" ]] || { rm "$root/drop-scp";exit 67; }
[[ ! -f "$root/missing-scp" || "$src" != */smoke_kuku_app.sh ]] || exit 0
mkdir -p "$(dirname "$target")";cp "$src" "$target"
SH
  chmod +x "$bin/"*
  cp "$real_b3sum" "$root/real-b3sum"
}

run_release() {
  expected=$1
  shift
  set +e
  HOME="$root/home" PATH="$bin:/usr/bin:/bin" TMPDIR=/private/tmp GH="$bin/gh" BREW="$bin/brew" \
    H4_CHECKOUT="$h4" H4_TAP_CHECKOUT="${tap_checkout_override:-$h4}" RELEASE_H4_TEST_MODE=1 RELEASE_H4_COORDINATOR_OK=1 RELEASE_H4_ARTIFACT_ROOT="$artifacts" \
    RELEASE_H4_LOCK_DIR="$lock" RELEASE_H4_BUILD_CMD="$bin/build" RELEASE_H4_SIGN_CMD="$bin/sign" \
    RELEASE_H4_LIVE_GATE_CMD="$bin/live-gate" RELEASE_H4_GATES_CMD="$bin/gates" RELEASE_H4_SELF_TEST_DEPTH=1 \
    RELEASE_H4_HDIUTIL_CMD="$bin/hdiutil" RELEASE_H4_SMOKE_CMD="$bin/smoke" RELEASE_H4_SSH_CMD="$bin/ssh" \
    RELEASE_H4_SCP_CMD="$bin/scp" "$kb/scripts/h4/release_h4.sh" "$@" >"$root/run.out" 2>&1
  status=$?
  set -e
  output=$(<"$root/run.out")
  if [[ "$expected" == success ]]; then [[ $status -eq 0 ]] || { printf 'CASE %s failed status=%s\n%s\n' "$name" "$status" "$output" >&2;exit 1; }
  else [[ $status -ne 0 ]] || { printf 'CASE %s unexpectedly succeeded\n%s\n' "$name" "$output" >&2;exit 1; };fi
}

run_audited_refusal() {
  expected=$1 operation=${2:-release}
  shift 2 || true
  set +e
  HOME="$root/home" PATH="$bin:/usr/bin:/bin" TMPDIR=/private/tmp GH="$bin/gh" H4_CHECKOUT="$h4" RELEASE_H4_TEST_MODE=1 \
    RELEASE_H4_STAGE=audited RELEASE_H4_ARTIFACT_ROOT="$artifacts" RELEASE_H4_LOCK_DIR="$lock" "$kb/scripts/h4/release_h4.sh" $operation "$release" >"$root/run.out" 2>&1
  status=$?
  set -e
  output=$(<"$root/run.out")
  [[ "$expected" == failure && $status -ne 0 ]]
}

remote_edit() {
  REMOTE="$root/remote.json" CODE="$1" /usr/bin/python3 - <<'PY'
import json,os
p=os.environ["REMOTE"];v=json.load(open(p));exec(os.environ["CODE"],{}, {"v":v});json.dump(v,open(p,"w"))
PY
}

remote_value() { REMOTE="$root/remote.json" KEY=$1 /usr/bin/python3 - <<'PY'
import json,os
print(json.load(open(os.environ["REMOTE"]))[os.environ["KEY"]])
PY
}

pass() { case_count=$((case_count + 1));printf 'PASS %s\n' "$1"; }
count_call() { rg -c "^$1" "$root/calls.log" || true; }
write_owner() {
  local owner_nonce=$1 owner_pid=$2 owner_release=${3:-$release} owner_start=${4:-fake-process-start}
  mkdir -p "$lock"
  OWNER="$lock/owner.json" NONCE="$owner_nonce" PID="$owner_pid" RELEASE="$owner_release" START="$owner_start" /usr/bin/python3 - <<'PY'
import json,os
json.dump({"nonce":os.environ["NONCE"],"pid":int(os.environ["PID"]),"release":os.environ["RELEASE"],"process_start":os.environ["START"]},open(os.environ["OWNER"],"w"))
PY
}

make_fixture dry_run_non_coordinator_zero_invocations
rm -rf "$artifacts" "$lock";: >"$root/calls.log"
output=$(HOME="$root/home" PATH="$bin:/usr/bin:/bin" "$kb/scripts/h4/release_h4.sh" "$release" --dry-run)
[[ "$output" == *'No lock, worktree, ssh, GitHub API, or manifest mutation was performed.'* && ! -e "$artifacts" && ! -e "$lock" && ! -s "$root/calls.log" ]]
pass "$name"

make_fixture coordinator_non_laptop_refused
set +e;HOME="$root/home" PATH="$bin:/usr/bin:/bin" RELEASE_H4_TEST_MODE=1 RELEASE_H4_ARTIFACT_ROOT="$artifacts" RELEASE_H4_LOCK_DIR="$lock" H4_CHECKOUT="$h4" "$kb/scripts/h4/release_h4.sh" cleanup "$release" >"$root/run.out" 2>&1;status=$?;set -e
[[ $status -ne 0 && $(count_call git) == 0 ]]
pass "$name"

for version_case in direct_release_refuses_h4_0 direct_release_refuses_h4_4; do
  make_fixture "$version_case";bad=0.5.8-h4.0;[[ "$version_case" != *_h4_4 ]] || bad=0.5.8-h4.4
  set +e;HOME="$root/home" PATH="$bin:/usr/bin:/bin" "$kb/scripts/h4/release_h4.sh" "$bad" --dry-run >/dev/null 2>&1;status=$?;set -e
  [[ $status -ne 0 && ! -s "$root/calls.log" ]];pass "$name"
done

make_fixture annotated_tag_with_distinct_oid_and_commit_accepted
run_release success cleanup "$release"
tag_oid=$($real_git -C "$kb" rev-parse "audit/kuku-$release");commit_oid=$($real_git -C "$kb" rev-parse "audit/kuku-$release^{commit}")
[[ "$tag_oid" != "$commit_oid" && ! -e "$artifacts/$release/src" ]]
pass "$name"

make_fixture launcher_refuses_stale_self
printf '\n# stale\n' >>"$kb/scripts/h4/release_h4.sh"
run_release failure cleanup "$release"
[[ "$output" == *'stale launcher'* ]]
pass "$name"

make_fixture missing_audit_tag_refused
$real_git -C "$kb" tag -d "audit/kuku-$release" >/dev/null
$real_git -C "$kb" push -q origin ":refs/tags/audit/kuku-$release"
run_release failure cleanup "$release"
[[ $(count_call gates) == 0 ]]
pass "$name"

make_fixture remote_audit_tag_mismatch_refused
: >"$root/remote-oid-mismatch";run_release failure cleanup "$release"
[[ "$output" == *'object id differs'* ]]
pass "$name"

make_fixture audit_tag_not_on_main_refused
$real_git -C "$kb" tag -d "audit/kuku-$release" >/dev/null
$real_git -C "$kb" checkout -q --orphan detached-audit
$real_git -C "$kb" rm -q -rf .;printf orphan >"$kb/orphan.txt";$real_git -C "$kb" add -A;$real_git -C "$kb" -c user.name=Test -c user.email=test@invalid commit -qm orphan
$real_git -C "$kb" tag -a -m audit "audit/kuku-$release";$real_git -C "$kb" push -q --force origin "refs/tags/audit/kuku-$release";$real_git -C "$kb" checkout -q main
run_release failure cleanup "$release"
[[ "$output" == *'not on origin/main'* ]]
pass "$name"

for rule_case in audit_ruleset_missing_refused audit_ruleset_disabled_refused audit_ruleset_excludes_tag_refused; do
  make_fixture "$rule_case";marker=ruleset-missing;[[ "$rule_case" != *disabled* ]] || marker=ruleset-disabled;[[ "$rule_case" != *excludes* ]] || marker=ruleset-excludes
  : >"$root/$marker";run_release failure cleanup "$release";[[ $(count_call gates) == 0 ]];pass "$name"
done

make_fixture live_pid_lock_refused
write_owner held $$
run_release failure cleanup "$release"
[[ "$output" == *'release lock is held'* && $(count_call git) == 0 ]]
pass "$name"

make_fixture dead_pid_lock_reclaimed
write_owner dead 999999
run_release success cleanup "$release"
[[ -n $(find "$root" -maxdepth 1 -name '.kuku-release.lock.stale-*' -print -quit) ]]
pass "$name"

make_fixture two_concurrent_invocations_one_wins
: >"$root/hold-fetch"
run_release success cleanup "$release" >"$root/background-driver.out" 2>&1 & first_pid=$!
for _ in $(seq 1 100);do [[ -f "$root/fetch-entered" ]]&&break;/bin/sleep .05;done
[[ -f "$root/fetch-entered" ]]
run_release failure cleanup "$release"
[[ "$output" == *'release lock is held'* ]]
rm "$root/hold-fetch";wait "$first_pid"
pass "$name"

make_fixture nonce_mismatch_on_release_preserves_replacement
: >"$root/replace-owner-on-fetch"
run_release failure cleanup "$release"
[[ -f "$lock/owner.json" && $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["nonce"])' "$lock/owner.json") == replacement ]]
pass "$name"

for auth_case in audited_stage_missing_owner_refused audited_stage_wrong_nonce_refused audited_stage_wrong_pid_refused inherited_lock_missing_owner_refused inherited_lock_wrong_nonce_refused inherited_lock_wrong_parent_refused; do
  make_fixture "$auth_case";mkdir -p "$lock"
  case "$auth_case" in
    *missing_owner*) : ;;
    *wrong_nonce*) write_owner other $$ ;;
    *wrong_pid*) write_owner test 999999 ;;
    *wrong_parent*) write_owner test 999999 ;;
  esac
  if [[ "$auth_case" == inherited* ]]; then
    set +e;HOME="$root/home" PATH="$bin:/usr/bin:/bin" RELEASE_H4_TEST_MODE=1 RELEASE_H4_STAGE=audited RELEASE_H4_LOCK_INHERITED=1 RELEASE_H4_LOCK_NONCE=test RELEASE_H4_LOCK_DIR="$lock" RELEASE_H4_ARTIFACT_ROOT="$artifacts" H4_CHECKOUT="$h4" "$kb/scripts/h4/release_h4.sh" cleanup-others "$release" >"$root/run.out" 2>&1;status=$?;set -e
  else
    set +e;HOME="$root/home" PATH="$bin:/usr/bin:/bin" RELEASE_H4_TEST_MODE=1 RELEASE_H4_STAGE=audited RELEASE_H4_LOCK_NONCE=test RELEASE_H4_LOCK_DIR="$lock" RELEASE_H4_ARTIFACT_ROOT="$artifacts" H4_CHECKOUT="$h4" "$kb/scripts/h4/release_h4.sh" "$release" >"$root/run.out" 2>&1;status=$?;set -e
  fi
  [[ $status -ne 0 && $(count_call gates) == 0 ]];pass "$name"
done

make_fixture complete_release_order_and_reuse
run_release success "$release"
python3 - "$root/calls.log" <<'PY'
import sys
lines=open(sys.argv[1]).read().splitlines()
need=["publisher reserve","live-gate","build","sign","publisher prepare","consumer local","publisher publish-release","publisher converge"]
positions=[]
for token in need:positions.append(next(i for i,v in enumerate(lines) if v.startswith(token)))
assert positions==sorted(positions),positions
PY
[[ $(remote_value dmg_uploads) == 1 && $(remote_value manifest_uploads) == 1 && $(remote_value publication_calls) == 1 ]]
builds=$(count_call build);signs=$(count_call sign);smokes=$(count_call smoke);live=$(count_call live-gate)
run_release success "$release"
[[ $(count_call build) == "$builds" && $(count_call sign) == "$signs" && $(count_call smoke) == "$smokes" && $(count_call live-gate) == "$live" ]]
[[ $(remote_value dmg_uploads) == 1 && $(remote_value manifest_uploads) == 1 && $(remote_value publication_calls) == 1 ]]
pass "$name"

release_boundary_case() {
  local boundary_name=$1 marker=$2
  make_fixture "$boundary_name"
  : >"$root/$marker"
  run_release failure "$release"
  if [[ "$marker" == fail-publisher-reserve.after ]]; then
    run_release failure "$release"
    [[ "$output" == *'this version is burned'* && $(remote_value dmg_uploads) == 0 && $(remote_value manifest_uploads) == 0 && $(remote_value publication_calls) == 0 ]]
  else
    local builds_before signs_before
    builds_before=$(count_call build);signs_before=$(count_call sign)
    run_release success "$release"
    [[ $(count_call build) == "$builds_before" && $(count_call sign) == "$signs_before" ]]
    [[ $(remote_value dmg_uploads) == 1 && $(remote_value manifest_uploads) == 1 && $(remote_value publication_calls) == 1 ]]
    python3 - "$root/calls.log" <<'PY'
import sys
lines=open(sys.argv[1],encoding="utf-8").read().splitlines()
post=max(i for i,line in enumerate(lines) if line.startswith("ssh ts-home-mac-mini ") and "--published" in line)
converge=[i for i,line in enumerate(lines) if line.startswith("publisher converge")]
assert converge and converge[-1] > post
PY
  fi
  pass "$name"
}

release_boundary_case crash_after_reserve_burns fail-publisher-reserve.after
release_boundary_case crash_after_prepare_resumes fail-publisher-prepare.after
release_boundary_case crash_after_draft_precheck_resumes fail-after-draft-precheck
release_boundary_case crash_before_publish_release_resumes fail-publisher-publish-release.before
release_boundary_case crash_after_publish_release_resumes fail-publisher-publish-release.after
release_boundary_case crash_after_post_publication_check_resumes fail-after-published-precheck
release_boundary_case crash_during_converge_resumes fail-publisher-converge.after

make_fixture published_start_zero_uploads_and_zero_publications
run_release success "$release"
dmg_uploads=$(remote_value dmg_uploads);manifest_uploads=$(remote_value manifest_uploads);publications=$(remote_value publication_calls)
: >"$root/calls.log"
run_release success "$release"
[[ $(count_call live-gate) == 0 && $(count_call build) == 0 && $(count_call sign) == 0 ]]
[[ $(remote_value dmg_uploads) == "$dmg_uploads" && $(remote_value manifest_uploads) == "$manifest_uploads" && $(remote_value publication_calls) == "$publications" ]]
pass "$name"

make_valid_remote_receipt() {
  local scratch="$root/receipt.log" verifier_sha fingerprint line
  KUKU_LIVE_REQUEST_LOG="$scratch" FAKE_RELEASE_STATE="$root" KUKU_TEST_OPENAI_BASE_URL=https://api.openai.com/v1 KUKU_TEST_OPENAI_MODEL=gpt-5-nano "$bin/live-gate" >/dev/null
  line=$(tail -1 "$scratch")
  kb_sha=$($real_git -C "$kb" rev-parse "audit/kuku-$release^{commit}");h4_sha=$($real_git -C "$h4" rev-parse "audit/kuku-$release^{commit}")
  BODY=$(LINE="$line" KB="$kb_sha" H4="$h4_sha" /usr/bin/python3 - <<'PY'
import json,os
print(json.dumps({"receipt":os.environ["LINE"],"kb_app_sha":os.environ["KB"],"h4_sha":os.environ["H4"]},separators=(",",":")))
PY
  )
}

make_fixture draft_complete_reuses_receipt
make_valid_remote_receipt;remote_edit "v['state']='draft';v['body']='$BODY'"
: >"$root/calls.log";run_release success "$release"
[[ $(count_call live-gate) == 0 ]]
pass "$name"

make_fixture draft_without_receipt_burned_zero_live_build_upload
remote_edit "v['state']='draft';v['body']=''"
run_release failure "$release"
[[ "$output" == *'this version is burned'* && $(count_call live-gate) == 0 && $(count_call build) == 0 && $(remote_value dmg_uploads) == 0 ]]
pass "$name"

make_fixture artifact_root_removed_after_live_gate_reuses_receipt
: >"$root/fail-build";run_release failure "$release";live=$(count_call live-gate);rm -rf "$artifacts";mkdir -p "$artifacts";rm "$root/fail-build"
run_release success "$release"
[[ $(count_call live-gate) == "$live" ]]
pass "$name"

make_fixture stale_smoke_receipt_reentered_without_build
run_release success "$release";builds=$(count_call build);smokes=$(count_call smoke)
python3 - "$artifacts/$release/smoke_receipt.json" <<'PY'
import json,sys
p=sys.argv[1];v=json.load(open(p));v["dmg_sha256"]="0"*64;json.dump(v,open(p,"w"))
PY
run_release success "$release"
[[ $(count_call build) == "$builds" && $(count_call smoke) -eq $((smokes+1)) ]]
pass "$name"

make_fixture b3sum_preflight_installs_when_absent
rm "$bin/b3sum";run_release success "$release"
[[ -x "$bin/b3sum" && $(count_call 'brew install b3sum') == 1 ]]
pass "$name"

make_fixture consumer_precheck_one_host_failure_zero_publish
: >"$root/fail-consumer-ts-home-mac-mini";run_release failure "$release"
[[ $(remote_value publication_calls) == 0 && $(count_call 'publisher publish-release') == 0 ]]
pass "$name"

for install_case in install_creates_target_directory install_interrupted_upload_then_retry install_refuses_stale_script install_refuses_missing_script; do
  make_fixture "$install_case"
  [[ "$install_case" != install_interrupted_upload_then_retry ]] || : >"$root/drop-scp"
  [[ "$install_case" != install_refuses_stale_script ]] || : >"$root/corrupt-shipped"
  [[ "$install_case" != install_refuses_missing_script ]] || : >"$root/missing-scp"
  expected=success;[[ "$install_case" != install_interrupted_upload_then_retry && "$install_case" != install_creates_target_directory ]] || expected=success
  if [[ "$install_case" == install_interrupted_upload_then_retry ]];then run_release failure install "$release" laptop-m3;run_release success install "$release" laptop-m3
  elif [[ "$install_case" == install_creates_target_directory ]];then run_release success install "$release" laptop-m3
  else run_release failure install "$release" laptop-m3;fi
  CASE_KIND="$install_case" python3 - "$root/calls.log" <<'PY'
import os, sys
lines=open(sys.argv[1],encoding="utf-8").read().splitlines()
scripts=("install_kuku_cask.sh",) if os.environ["CASE_KIND"]=="install_refuses_stale_script" else ("install_kuku_cask.sh","smoke_kuku_app.sh")
for script in scripts:
    copies=[i for i,line in enumerate(lines) if line.startswith("scp ") and f"/{script} " in line]
    assert copies, (script,"no copy")
    copy=copies[-1]
    assert ".local/bin/h4-kuku/"+script+".tmp." in lines[copy]
    assert any(i<copy and line=="ssh laptop-m3 install -d -m 0755 ~/.local/bin/h4-kuku" for i,line in enumerate(lines))
    assert any(i>copy and line.startswith("ssh laptop-m3 shasum -a 256 ~/.local/bin/h4-kuku/"+script+".tmp.") and "&& mv -f " in line for i,line in enumerate(lines))
installs=sum(line.startswith("ssh laptop-m3 bash -lc") for line in lines)
if os.environ["CASE_KIND"] in {"install_creates_target_directory","install_interrupted_upload_then_retry"}: assert installs==1
else: assert installs==0
PY
  if [[ "$install_case" == install_creates_target_directory || "$install_case" == install_interrupted_upload_then_retry ]];then [[ -f "$remote_hosts/laptop-m3/.local/bin/h4-kuku/install_kuku_cask.sh" && -f "$remote_hosts/laptop-m3/.local/bin/h4-kuku/smoke_kuku_app.sh" ]];fi
  pass "$name"
done

make_fixture cleanup_removes_five_worktrees_preserves_artifacts
tap_checkout_override="$root/tap";tap_bare="$root/tap.git";mkdir -p "$tap_checkout_override";printf tap >"$tap_checkout_override/README.md";init_repo "$tap_checkout_override" "$tap_bare"
mkdir -p "$artifacts/$release";printf keep >"$artifacts/$release/Kuku-$release.dmg"
$real_git -C "$h4" worktree add --detach "$artifacts/$release/h4-audited" origin/main >/dev/null
$real_git -C "$h4" worktree add --detach "$artifacts/$release/h4-publish" origin/main >/dev/null
$real_git -C "$tap_checkout_override" worktree add --detach "$artifacts/$release/tap-publish" origin/main >/dev/null
$real_git -C "$kb" worktree add --detach "$root/build-host-src" origin/main >/dev/null
run_release success cleanup "$release"
[[ ! -e "$artifacts/$release/src" && ! -e "$artifacts/$release/h4-audited" && ! -e "$artifacts/$release/h4-publish" && ! -e "$artifacts/$release/tap-publish" && ! -e "$root/build-host-src" && -f "$artifacts/$release/Kuku-$release.dmg" ]]
pass "$name"

make_fixture cleanup_refuses_dirty_worktree
unset tap_checkout_override
# Arrange a real release-owned h4 worktree, dirty it, then retry cleanup.
$real_git -C "$h4" worktree add --detach "$artifacts/$release/h4-publish" origin/main >/dev/null
printf dirty >"$artifacts/$release/h4-publish/dirty.txt"
run_release failure cleanup "$release"
[[ "$output" == *'dirty worktree refused'* ]]
pass "$name"

[[ $case_count -eq 43 ]]
printf 'release_h4_test: PASS cases=%s\n' "$case_count"
