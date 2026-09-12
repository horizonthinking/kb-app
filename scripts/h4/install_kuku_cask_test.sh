#!/usr/bin/env bash
# ---
# asset: kuku-h4-cask-installer-test
# type: test-script
# description: Behavioural tests for Kuku cask bootstrap, identity, collision, install, rollback, withdrawal, and recovery.
# owner: michael
# status: active
# ---

set -euo pipefail

make_tool() {
  local name=$1
  printf '#!/usr/bin/env bash\nexec %q __fake__ %q "$@"\n' "$0" "$name" >"$bin/$name"
  chmod +x "$bin/$name"
}

if [[ "${1:-}" == __fake__ ]]; then
  tool=$2
  shift 2
  state=${FAKE_INSTALL_STATE:?}
  printf '%s' "$tool" >>"$state/calls.log"
  printf ' %q' "$@" >>"$state/calls.log"
  printf '\n' >>"$state/calls.log"
  case "$tool" in
    brew)
      command=${1:-}
      case "$command" in
        tap-info) [[ -f "$state/tapped" ]] ;;
        tap)
          [[ "$*" == 'tap horizonthinking/h4 git@github.com:horizonthinking/homebrew-h4.git' ]]
          : >"$state/tapped"
          ;;
        --repo) printf '%s\n' "$state/tap" ;;
        trust) [[ ! -f "$state/fail_trust" ]] || exit 40 ;;
        update)
          [[ ! -f "$state/fail_update" ]] || exit 41
          cp "$state/origin_head" "$state/local_head"
          ;;
        info)
          [[ "$*" == 'info --cask --json=v2 --installed' ]] || exit 42
          if [[ -f "$state/installed" ]]; then
            version=$(<"$state/installed")
            tap_name=horizonthinking/h4
            full_token=horizonthinking/h4/kuku
            if [[ -f "$state/foreign" ]]; then
              tap_name=kuku-mom/kuku
              full_token=kuku-mom/kuku/kuku
            fi
            printf '{"casks":[{"token":"kuku","tap":"%s","full_token":"%s","installed":["%s"]}' "$tap_name" "$full_token" "$version"
            [[ ! -f "$state/two_taps" ]] || printf ',{"token":"other","tap":"kuku-mom/kuku","full_token":"kuku-mom/kuku/other","installed":["1.0"]}'
            printf ']}\n'
          else
            printf '{"casks":[]}\n'
          fi
          ;;
        list) [[ -f "$state/installed" ]] ;;
        install)
          if [[ "${2:-}" == b3sum ]]; then
            cp "$state/real_b3sum" "$state/bin/b3sum"
            chmod +x "$state/bin/b3sum"
          else
            version=$(sed -nE 's/^[[:space:]]*version "([^"]+)"/\1/p' "$state/tap/Casks/kuku.rb")
            printf '%s\n' "$version" >"$state/installed"
            mkdir -p "$FAKE_APP/Contents"
            printf '%s\n' "${version%%-h4.*}" >"$FAKE_APP/Contents/version"
          fi
          ;;
        upgrade)
          [[ ! -f "$state/fail_upgrade" ]] || exit 43
          version=$(sed -nE 's/^[[:space:]]*version "([^"]+)"/\1/p' "$state/tap/Casks/kuku.rb")
          printf '%s\n' "$version" >"$state/installed"
          mkdir -p "$FAKE_APP/Contents"
          printf '%s\n' "${version%%-h4.*}" >"$FAKE_APP/Contents/version"
          ;;
        uninstall)
          rm -f "$state/installed"
          rm -rf "$FAKE_APP"
          ;;
        *) exit 44 ;;
      esac
      ;;
    git)
      if [[ "$*" == *'remote get-url origin'* ]]; then
        [[ ! -f "$state/wrong_remote" ]] && printf '%s\n' 'git@github.com:horizonthinking/homebrew-h4.git' || printf '%s\n' wrong
      elif [[ "$*" == *'fetch origin main'* ]]; then
        :
      elif [[ "$*" == *'rev-parse origin/main'* ]]; then
        cat "$state/origin_head"
      elif [[ "$*" == *'rev-parse HEAD'* ]]; then
        cat "$state/local_head"
      else
        exit 45
      fi
      ;;
    defaults)
      key=${*: -1}
      case "$key" in
        CFBundleIdentifier) [[ ! -f "$state/unowned" ]] && printf 'mom.kuku.app\n' || printf 'com.example.foreign\n' ;;
        CFBundleShortVersionString)
          plist=${*: -2:1}
          version_file=${plist%/Contents/Info.plist}/Contents/version
          [[ -f "$version_file" ]] && cat "$version_file" || printf '0.5.4\n'
          ;;
        CFBundleVersion) printf '5.8.1\n' ;;
        CFBundleExecutable) printf 'kuku-app\n' ;;
        *) exit 46 ;;
      esac
      ;;
    plutil)
      [[ "$*" == "-extract CFBundleExecutable raw -o - $FAKE_APP/Contents/Info.plist" ]] || exit 46
      printf 'kuku-app\n'
      ;;
    codesign) printf 'Authority=Developer ID Application\nTeamIdentifier=8P9788YC9P\nflags=0x10000(runtime)\n' >&2 ;;
    spctl) printf 'source=Notarized Developer ID\n' >&2 ;;
    xcrun) : ;;
    pgrep)
      [[ "$*" == '-x kuku-app' ]] || exit 47
      exit 1
      ;;
    smoke)
      printf 'smoke\n' >>"$state/smoke.log"
      [[ ! -f "$state/fail_smoke" ]] || exit 51
      ;;
    mv)
      source_path=${*: -2:1}
      target_path=${*: -1}
      if [[ "$source_path" == *Kuku.app* || "$target_path" == *Kuku.app* ]]; then
        if [[ -f "$state/mv_fail_before" ]]; then rm -f "$state/mv_fail_before"; exit 48; fi
        if [[ -f "$state/mv_fail_after" ]]; then
          /bin/mv "$source_path" "$target_path"
          rm -f "$state/mv_fail_after"
          exit 49
        fi
      fi
      /bin/mv "$@"
      ;;
    date)
      count=0
      [[ ! -f "$state/date_count" ]] || count=$(<"$state/date_count")
      count=$((count + 1))
      printf '%s\n' "$count" >"$state/date_count"
      timestamp=$(printf '2026-09-11T00:00:%02dZ' "$count")
      if [[ -f "$state/date_creates_backup" ]]; then
        mkdir -p "$HOME/Desktop/Kuku.app.pre-brew-${timestamp//:/-}-$PPID"
        rm -f "$state/date_creates_backup"
      fi
      printf '%s\n' "$timestamp"
      ;;
    rg) exec "$FAKE_REAL_RG" "$@" ;;
    *) exit 50 ;;
  esac
  exit 0
fi

repo_root=$(git rev-parse --show-toplevel)
installer="$repo_root/scripts/h4/install_kuku_cask.sh"
real_b3sum=$(command -v b3sum)
real_rg=$(command -v rg)
test_root=$(mktemp -d /private/tmp/kuku-install-test.XXXXXX)
trap 'rm -rf "$test_root"' EXIT
case_count=0

new_case() {
  name=$1
  root="$test_root/$name"
  home="$root/home"
  bin="$root/bin"
  tap_repo="$root/tap"
  app="$root/Applications/Kuku.app"
  record="$home/.kuku/h4-install-backup.json"
  mkdir -p "$home/.kuku" "$home/.local/bin/h4-kuku" "$home/Desktop" "$bin" "$tap_repo/Casks" "$(dirname "$app")"
  printf 'cask "kuku" do\n  version "0.5.8-h4.1"\nend\n' >"$tap_repo/Casks/kuku.rb"
  printf 'origin-main\n' >"$root/origin_head"
  printf 'origin-main\n' >"$root/local_head"
  : >"$root/tapped"
  : >"$root/calls.log"
  : >"$root/smoke.log"
  cp "$real_b3sum" "$root/real_b3sum"
  for tool in brew defaults plutil git codesign spctl xcrun pgrep mv date rg; do make_tool "$tool"; done
  make_tool smoke
  /bin/mv "$bin/smoke" "$home/.local/bin/h4-kuku/smoke_kuku_app.sh"
  cp "$real_b3sum" "$bin/b3sum"
  export FAKE_INSTALL_STATE="$root" FAKE_APP="$app" FAKE_REAL_RG="$real_rg"
}

set_installed() {
  local version=${1:-0.5.8-h4.1}
  printf '%s\n' "$version" >"$root/installed"
  mkdir -p "$app/Contents"
  printf '%s\n' "${version%%-h4.*}" >"$app/Contents/version"
}

set_collision() {
  mkdir -p "$app/Contents"
  printf '0.5.4\n' >"$app/Contents/version"
  printf 'pre-homebrew\n' >"$app/original-marker"
}

write_record_fixture() {
  local record_state=$1 backup=${2:-} version=${3:-}
  RECORD_PATH="$record" RECORD_STATE="$record_state" RECORD_BACKUP="$backup" RECORD_VERSION="$version" python3 - <<'PY'
import json, os
value={"backup_path":os.environ["RECORD_BACKUP"] or None,"version":os.environ["RECORD_VERSION"] or None,"timestamp":"2026-09-10T00:00:00Z","state":os.environ["RECORD_STATE"]}
with open(os.environ["RECORD_PATH"],"w",encoding="utf-8") as handle: json.dump(value,handle); handle.write("\n")
PY
}

run_installer() {
  expected=$1
  shift
  set +e
  output=$(HOME="$home" PATH="$bin:/usr/bin:/bin" TMPDIR=/private/tmp KUKU_INSTALL_APP_PATH="$app" KUKU_INSTALL_RECORD_PATH="$record" \
    KUKU_INSTALL_SMOKE_CMD="$home/.local/bin/h4-kuku/smoke_kuku_app.sh" "$installer" "$@" 2>&1)
  status=$?
  set -e
  if [[ "$expected" == success ]]; then
    [[ $status -eq 0 ]] || { printf 'CASE %s failed status=%s\n%s\n' "$name" "$status" "$output" >&2; exit 1; }
  else
    [[ $status -ne 0 ]] || { printf 'CASE %s unexpectedly succeeded\n%s\n' "$name" "$output" >&2; exit 1; }
  fi
}

pass() { case_count=$((case_count + 1)); printf 'PASS %s\n' "$1"; }
count_calls() { rg -c "^$1( |$)" "$root/calls.log" || true; }

new_case install_bootstraps_absent_tap_with_ssh_url
rm "$root/tapped"
run_installer success 0.5.8-h4.1
[[ $(rg -c '^brew tap horizonthinking/h4 git@github\.com:horizonthinking/homebrew-h4\.git$' "$root/calls.log") == 1 ]]
pass "$name"

new_case install_refuses_wrong_tap_remote
: >"$root/wrong_remote"
run_installer failure 0.5.8-h4.1
[[ $(count_calls 'brew install') == 0 ]]
pass "$name"

new_case install_brew_trust_failure_fatal
: >"$root/fail_trust"
run_installer failure 0.5.8-h4.1
[[ $(count_calls 'brew update') == 0 ]]
pass "$name"

new_case install_brew_update_failure_fatal
: >"$root/fail_update"
run_installer failure 0.5.8-h4.1
[[ $(count_calls 'brew install') == 0 ]]
pass "$name"

new_case install_refreshes_stale_tap_to_origin_main
printf 'stale\n' >"$root/local_head"
run_installer success 0.5.8-h4.1
[[ $(<"$root/local_head") == origin-main && $(count_calls 'brew update') == 1 ]]
pass "$name"

new_case install_refuses_cask_version_mismatch
sed -i '' 's/0.5.8-h4.1/0.5.7-h4.1/' "$tap_repo/Casks/kuku.rb"
run_installer failure 0.5.8-h4.1
[[ $(count_calls 'brew install') == 0 ]]
pass "$name"

new_case install_installs_when_absent
run_installer success 0.5.8-h4.1
[[ $(<"$root/installed") == 0.5.8-h4.1 && $(count_calls 'brew install') == 1 ]]
pass "$name"

new_case install_upgrades_when_present
set_installed 0.5.7-h4.1
run_installer success 0.5.8-h4.1
[[ $(<"$root/installed") == 0.5.8-h4.1 && $(count_calls 'brew upgrade') == 1 ]]
pass "$name"

new_case install_upgrade_failure_fatal_no_install_attempted
set_installed 0.5.7-h4.1
: >"$root/fail_upgrade"
run_installer failure 0.5.8-h4.1
[[ $(count_calls 'brew upgrade') == 1 && $(count_calls 'brew install') == 0 ]]
pass "$name"

new_case install_verifies_three_identities_via_brew_info_json
run_installer success 0.5.8-h4.1
[[ $(rg -c '^brew info --cask --json=v2 --installed$' "$root/calls.log") -ge 3 ]]
[[ $(rg -c 'CFBundleShortVersionString$' "$root/calls.log") == 1 && $(rg -c 'CFBundleVersion$' "$root/calls.log") == 1 ]]
pass "$name"

new_case install_smoke_invoked_once_and_failure_propagated
: >"$root/fail_smoke"
run_installer failure 0.5.8-h4.1
[[ $(wc -l <"$root/smoke.log" | tr -d ' ') == 1 ]]
pass "$name"

new_case install_preflights_b3sum
rm "$bin/b3sum"
run_installer success 0.5.8-h4.1
[[ -x "$bin/b3sum" && $(rg -c '^brew install b3sum$' "$root/calls.log") == 1 ]]
pass "$name"

new_case install_refuses_foreign_kuku_cask
set_installed 0.5.4
: >"$root/foreign"
run_installer failure 0.5.8-h4.1
[[ "$output" == *'must be removed by hand first'* && $(count_calls 'brew upgrade') == 0 ]]
pass "$name"

new_case install_identity_query_unambiguous_with_two_taps
: >"$root/two_taps"
run_installer success 0.5.8-h4.1
[[ $(rg -c '^brew info --cask --json=v2 --installed$' "$root/calls.log") -ge 3 ]]
! rg -q '^brew info .*horizonthinking/h4/kuku' "$root/calls.log"
pass "$name"

new_case install_moves_aside_non_homebrew_app_collision_free
set_collision
run_installer success 0.5.8-h4.1
backup=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["backup_path"])' "$record")
[[ -f "$backup/original-marker" && -d "$app" && "$backup" != "$app" ]]
pass "$name"

new_case install_refuses_existing_backup_path
set_collision
: >"$root/date_creates_backup"
run_installer failure 0.5.8-h4.1
[[ "$output" == *'backup path exists'* && -f "$app/original-marker" ]]
pass "$name"

new_case install_crash_before_backup_move
set_collision
: >"$root/mv_fail_before"
run_installer failure 0.5.8-h4.1
[[ $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$record") == moving && -f "$app/original-marker" ]]
run_installer success 0.5.8-h4.1
[[ $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$record") == installed ]]
pass "$name"

new_case install_crash_after_backup_move_before_moved
set_collision
: >"$root/mv_fail_after"
run_installer failure 0.5.8-h4.1
backup=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["backup_path"])' "$record")
[[ ! -e "$app" && -f "$backup/original-marker" ]]
run_installer success 0.5.8-h4.1
pass "$name"

new_case install_moving_with_both_paths_present_refused
set_collision
backup="$home/Desktop/existing-backup.app"; mkdir -p "$backup"
write_record_fixture moving "$backup" 0.5.4
run_installer failure 0.5.8-h4.1
[[ "$output" == *'moving refused'* ]]
pass "$name"

new_case install_moving_with_neither_path_refused
backup="$home/Desktop/missing-backup.app"
write_record_fixture moving "$backup" 0.5.4
run_installer failure 0.5.8-h4.1
[[ "$output" == *'moving refused'* ]]
pass "$name"

new_case install_never_overwrites_non_null_backup
backup="$home/Desktop/original-backup.app"; mkdir -p "$backup"
write_record_fixture moved "$backup" 0.5.4
run_installer success 0.5.8-h4.1
[[ $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["backup_path"])' "$record") == "$backup" && -d "$backup" ]]
pass "$name"

new_case install_after_withdraw_archives_restored_record
set_collision
write_record_fixture restored "$home/Desktop/consumed.app" 0.5.4
run_installer success 0.5.8-h4.1
[[ -f "$home/.kuku/h4-install-backup.2026-09-10T00-00-00Z.json" ]]
[[ $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$record") == installed ]]
pass "$name"

new_case rollback_uninstall_then_install_pinned_version
set_installed 0.5.7-h4.1
run_installer success --rollback 0.5.8-h4.1
[[ $(count_calls 'brew uninstall') == 1 && $(count_calls 'brew install') == 1 && $(<"$root/installed") == 0.5.8-h4.1 ]]
pass "$name"

new_case rollback_idempotent_on_reentry
set_installed 0.5.8-h4.1
run_installer success --rollback 0.5.8-h4.1
[[ $(count_calls 'brew uninstall') == 0 && $(count_calls 'brew install') == 0 ]]
pass "$name"

new_case withdraw_refuses_unowned_app
set_installed
: >"$root/unowned"
write_record_fixture installed '' ''
run_installer failure --withdraw
[[ "$output" == *'does not own'* && $(count_calls 'brew uninstall') == 0 ]]
pass "$name"

new_case withdraw_skips_uninstall_when_no_h4_cask
write_record_fixture moved '' ''
run_installer success --withdraw
[[ $(count_calls 'brew uninstall') == 0 && $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$record") == restored ]]
pass "$name"

new_case withdraw_crash_before_restore_move
set_installed
backup="$home/Desktop/Kuku.prebrew.app"; mkdir -p "$backup/Contents"; printf '0.5.4\n' >"$backup/Contents/version"
write_record_fixture installed "$backup" 0.5.4
: >"$root/mv_fail_before"
run_installer failure --withdraw
[[ -d "$backup" && ! -e "$app" ]]
run_installer success --withdraw
[[ -d "$app" && ! -e "$backup" ]]
pass "$name"

new_case withdraw_crash_after_restore_move_before_restored
set_installed
backup="$home/Desktop/Kuku.prebrew.app"; mkdir -p "$backup/Contents"; printf '0.5.4\n' >"$backup/Contents/version"
write_record_fixture installed "$backup" 0.5.4
: >"$root/mv_fail_after"
run_installer failure --withdraw
[[ ! -e "$backup" && -d "$app" ]]
run_installer success --withdraw
[[ $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$record") == restored ]]
pass "$name"

new_case withdraw_restoring_with_both_paths_present_refused
set_collision
backup="$home/Desktop/Kuku.prebrew.app"; mkdir -p "$backup"
write_record_fixture restoring "$backup" 0.5.4
run_installer failure --withdraw
[[ "$output" == *'restoring refused'* ]]
pass "$name"

new_case withdraw_restoring_with_neither_path_refused
backup="$home/Desktop/Kuku.prebrew.app"
write_record_fixture restoring "$backup" 0.5.4
run_installer failure --withdraw
[[ "$output" == *'restoring refused'* ]]
pass "$name"

new_case withdraw_after_first_install_with_backup
set_collision
run_installer success 0.5.8-h4.1
backup=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["backup_path"])' "$record")
run_installer success --withdraw
[[ -f "$app/original-marker" && ! -e "$backup" && ! -e "$root/installed" ]]
pass "$name"

new_case withdraw_after_first_install_without_backup
run_installer success 0.5.8-h4.1
run_installer success --withdraw
[[ ! -e "$app" && ! -e "$root/installed" ]]
pass "$name"

new_case withdraw_idempotent_on_reentry
set_collision
run_installer success 0.5.8-h4.1
run_installer success --withdraw
uninstalls=$(count_calls 'brew uninstall')
run_installer success --withdraw
[[ $(count_calls 'brew uninstall') == "$uninstalls" && "$output" == *'already restored'* ]]
pass "$name"

new_case install_withdraw_install_withdraw_generations
set_collision
run_installer success 0.5.8-h4.1
first_backup=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["backup_path"])' "$record")
run_installer success --withdraw
run_installer success 0.5.8-h4.1
second_backup=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["backup_path"])' "$record")
[[ "$first_backup" != "$second_backup" && -f "$home/.kuku/h4-install-backup.2026-09-11T00-00-01Z.json" ]]
run_installer success --withdraw
[[ -f "$app/original-marker" && $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$record") == restored ]]
pass "$name"

[[ $case_count -eq 34 ]]
printf 'install_kuku_cask_test: PASS cases=%s\n' "$case_count"
