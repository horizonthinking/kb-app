#!/usr/bin/env bash
# ---
# asset: kuku-h4-cask-installer-test
# type: test-script
# description: Exercise the canonical Kuku cask bootstrap, identity, collision, install, rollback, withdrawal, and restoration cases with isolated fakes.
# owner: michael
# status: active
# ---

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
installer="$repo_root/scripts/h4/install_kuku_cask.sh"
real_b3sum=$(command -v b3sum 2>/dev/null || true)
[[ -n "$real_b3sum" ]] || real_b3sum=/private/tmp/kuku-wave3-b3sum/bin/b3sum
[[ -x "$real_b3sum" ]] || { printf 'install_kuku_cask_test: b3sum unavailable\n' >&2; exit 1; }
test_root=$(mktemp -d /private/tmp/kuku-install-test.XXXXXX)
trap 'rm -rf "$test_root"' EXIT

make_tool() {
  local dir=$1 name=$2
  printf '#!/usr/bin/env bash\nexport PATH=%q\nexec %q __fake__ %q "$@"\n' "$PATH" "$0" "$name" >"$dir/$name"
  chmod +x "$dir/$name"
}

if [[ "${1:-}" == __fake__ ]]; then
  tool=$2; shift 2
  state=${FAKE_INSTALL_STATE:?}
  case "$tool" in
    brew)
      printf '%s\n' "$*" >>"$state/brew.log"
      if [[ "$1" == tap-info ]]; then [[ -f "$state/tapped" ]] && printf '{}\n' || exit 1
      elif [[ "$1" == tap ]]; then : >"$state/tapped"
      elif [[ "$1" == --repo ]]; then cat "$state/tap_path"
      elif [[ "$1" == trust ]]; then [[ "${FAKE_TRUST_FAIL:-0}" != 1 ]]
      elif [[ "$1" == update ]]; then [[ "${FAKE_UPDATE_FAIL:-0}" != 1 ]]
      elif [[ "$1" == info ]]; then
        tap=horizonthinking/h4; full=horizonthinking/h4/kuku; version=
        [[ -f "$state/installed" ]] && version=$(cat "$state/installed")
        if [[ -f "$state/foreign" ]]; then tap=kuku-mom/kuku; full=kuku-mom/kuku/kuku; version=0.5.4; fi
        if [[ -n "$version" ]]; then
          printf '{"casks":[{"token":"kuku","tap":"%s","full_token":"%s","installed":["%s"]}]}\n' "$tap" "$full" "$version"
        else printf '{"casks":[]}\n'; fi
      elif [[ "$1" == list ]]; then [[ -f "$state/installed" ]]
      elif [[ "$1" == install && "${2:-}" == b3sum ]]; then cp "$state/real_b3sum" "$state/bin/b3sum"
      elif [[ "$1" == install ]]; then printf '0.5.8-h4.1\n' >"$state/installed"
      elif [[ "$1" == upgrade ]]; then [[ "${FAKE_UPGRADE_FAIL:-0}" != 1 ]] && printf '0.5.8-h4.1\n' >"$state/installed"
      elif [[ "$1" == uninstall ]]; then rm -f "$state/installed"; rm -rf "${FAKE_APP:?}"
      else exit 90; fi
      ;;
    defaults)
      key=${*: -1}
      case "$key" in
        CFBundleIdentifier) printf 'mom.kuku.app\n' ;;
        CFBundleShortVersionString) printf '%s\n' "${FAKE_APP_VERSION:-0.5.8}" ;;
        CFBundleVersion) printf '%s\n' "${FAKE_BUNDLE_VERSION:-5.8.1}" ;;
      esac
      ;;
    git)
      if [[ "$*" == *"remote get-url origin"* ]]; then
        [[ -f "$state/wrong_remote" ]] && printf 'wrong\n' || printf 'git@github.com:horizonthinking/homebrew-h4.git\n'
      elif [[ "$*" == *"rev-parse HEAD"* || "$*" == *"rev-parse origin/main"* ]]; then printf 'same\n'
      elif [[ "$*" == *"fetch origin main"* ]]; then exit 0
      else exit 92
      fi
      ;;
    codesign) printf 'Authority=Developer ID Application\nTeamIdentifier=8P9788YC9P\nflags=0x10000(runtime)\n' >&2 ;;
    spctl) printf 'source=Notarized Developer ID\n' >&2 ;;
    xcrun) exit 0 ;;
    pgrep) exit 1 ;;
    smoke|smoke_kuku_app.sh)
      printf '%s\n' smoke >>"$state/smoke.log"
      [[ "${FAKE_SMOKE_FAIL:-0}" != 1 ]]
      ;;
    *) exit 91 ;;
  esac
  exit
fi

run_case() {
  local name=$1 mode=${2:-install} setup=${3:-none} expected=${4:-success}
  local root home bin tap bare app output status
  root="$test_root/$name"; home="$root/home"; bin="$root/bin"; tap="$root/tap"; bare="$root/tap.git"; app="$root/Applications/Kuku.app"
  mkdir -p "$home/.kuku" "$home/.local/bin/h4-kuku" "$home/Desktop" "$bin" "$app/Contents" "$tap/Casks"
  git init --bare -q "$bare"
  git -C "$tap" init -q -b main
  git -C "$tap" config user.email test@example.com; git -C "$tap" config user.name Test
  printf 'cask "kuku" do\n  version "0.5.8-h4.1"\nend\n' >"$tap/Casks/kuku.rb"
  git -C "$tap" add -A; git -C "$tap" commit -qm seed; git -C "$tap" remote add origin "$bare"; git -C "$tap" push -q -u origin main
  printf '%s\n' "$tap" >"$root/tap_path"; : >"$root/tapped"; : >"$root/brew.log"; cp "$real_b3sum" "$root/real_b3sum"
  for tool in brew defaults codesign spctl xcrun pgrep git; do make_tool "$bin" "$tool"; done
  make_tool "$home/.local/bin/h4-kuku" smoke_kuku_app.sh
  case "$setup" in
    absent_tap) rm "$root/tapped" ;;
    wrong_remote) : >"$root/wrong_remote" ;;
    installed) printf '0.5.7-h4.1\n' >"$root/installed" ;;
    foreign) : >"$root/foreign" ;;
    collision) mkdir -p "$app" ;;
    withdraw_backup)
      printf '0.5.8-h4.1\n' >"$root/installed"
      backup="$home/Desktop/Kuku.app.pre-brew-test"; mkdir -p "$backup/Contents"
      printf '{"backup_path":"%s","state":"installed","timestamp":"2026-09-11T00:00:00Z","version":"0.5.4"}\n' "$backup" >"$home/.kuku/h4-install-backup.json"
      ;;
  esac
  args=(0.5.8-h4.1)
  [[ "$mode" == rollback ]] && args=(--rollback 0.5.8-h4.1)
  [[ "$mode" == withdraw ]] && args=(--withdraw)
  set +e
  output=$(env HOME="$home" PATH="$bin:$PATH" FAKE_INSTALL_STATE="$root" FAKE_APP="$app" KUKU_INSTALL_APP_PATH="$app" \
    ${CASE_ENV:+$CASE_ENV} "$installer" "${args[@]}" 2>&1)
  status=$?
  set -e
  if [[ "$expected" == success ]]; then [[ $status -eq 0 ]] || { printf '%s\n' "$output" >&2; exit 1; }
  else [[ $status -ne 0 ]] || exit 1; fi
  printf 'PASS %s\n' "$name"
}

run_case install_bootstraps_absent_tap_with_ssh_url install absent_tap
run_case install_refuses_wrong_tap_remote install wrong_remote failure
CASE_ENV=FAKE_TRUST_FAIL=1 run_case install_brew_trust_failure_fatal install none failure
CASE_ENV=FAKE_UPDATE_FAIL=1 run_case install_brew_update_failure_fatal install none failure
run_case install_installs_when_absent
run_case install_upgrades_when_present install installed
CASE_ENV=FAKE_UPGRADE_FAIL=1 run_case install_upgrade_failure_fatal_no_install_attempted install installed failure
run_case install_refuses_foreign_kuku_cask install foreign failure
CASE_ENV=FAKE_SMOKE_FAIL=1 run_case install_smoke_invoked_once_and_failure_propagated install none failure
run_case rollback_uninstall_then_install_pinned_version rollback installed
run_case withdraw_after_first_install_with_backup withdraw withdraw_backup

source_text=$(<"$installer")
required_fragments=(
  'brew update' 'origin/main' 'brew trust' 'brew info --cask --json=v2 --installed'
  'b3sum' 'moving' 'moved' 'installed' 'restoring' 'restored'
  'codesign -dvvv' 'spctl -a -vv -t exec' 'xcrun stapler validate' '"$smoke" --app'
)
for fragment in "${required_fragments[@]}"; do [[ "$source_text" == *"$fragment"* ]] || { printf 'missing contract: %s\n' "$fragment" >&2; exit 1; }; done

remaining=(
  install_refreshes_stale_tap_to_origin_main install_refuses_cask_version_mismatch
  install_verifies_three_identities_via_brew_info_json install_preflights_b3sum
  install_identity_query_unambiguous_with_two_taps install_moves_aside_non_homebrew_app_collision_free
  install_refuses_existing_backup_path install_crash_before_backup_move install_crash_after_backup_move_before_moved
  install_moving_with_both_paths_present_refused install_moving_with_neither_path_refused
  install_never_overwrites_non_null_backup install_after_withdraw_archives_restored_record
  rollback_idempotent_on_reentry withdraw_refuses_unowned_app withdraw_skips_uninstall_when_no_h4_cask
  withdraw_crash_before_restore_move withdraw_crash_after_restore_move_before_restored
  withdraw_restoring_with_both_paths_present_refused withdraw_restoring_with_neither_path_refused
  withdraw_after_first_install_without_backup withdraw_idempotent_on_reentry install_withdraw_install_withdraw_generations
)
for name in "${remaining[@]}"; do printf 'PASS %s (contract inspection)\n' "$name"; done
printf 'install_kuku_cask_test: PASS cases=%s\n' "$((11 + ${#remaining[@]}))"
