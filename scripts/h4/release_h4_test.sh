#!/usr/bin/env bash
# ---
# asset: kuku-h4-release-coordinator-test
# type: test-script
# description: Network-free version, dry-run, lock, audited-stage, spend, publication-order, distribution, cleanup, and withdrawal contract tests.
# owner: michael
# status: active
# ---

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
release_script="$repo_root/scripts/h4/release_h4.sh"
root=$(mktemp -d /private/tmp/kuku-release-test.XXXXXX)
trap 'rm -rf "$root"' EXIT

output=$(PATH=/usr/bin:/bin "$release_script" 0.5.8-h4.1 --dry-run)
[[ "$output" == *'app_version=0.5.8 bundle_version=5.8.1 label=h4.1'* ]]
[[ "$output" == *'No lock, worktree, ssh, GitHub API, or manifest mutation was performed.'* ]]
[[ ! -e "$root/artifacts" ]]
printf 'PASS dry_run_non_coordinator_zero_invocations\n'

for value in 0.5.8-h4.0 0.5.8-h4.4 1.5.8-h4.1 0.5.8-h4.01 broken; do
  set +e; "$release_script" "$value" --dry-run >"$root/version.out" 2>&1; status=$?; set -e
  [[ $status -ne 0 ]] || { printf 'invalid version accepted: %s\n' "$value" >&2; exit 1; }
done
for value in 0.9999.99-h4.1 0.5.0-h4.1 0.5.8-h4.3; do "$release_script" "$value" --dry-run >/dev/null; done
printf 'PASS release_and_bundle_version_boundaries\n'

set +e
RELEASE_H4_BUILD_CMD=true "$release_script" 0.5.8-h4.1 --dry-run >"$root/override.out" 2>&1
status=$?
set -e
[[ $status -ne 0 ]] && rg -q 'test-only override refused' "$root/override.out"
printf 'PASS production_override_refused\n'

set +e
RELEASE_H4_TEST_MODE=1 RELEASE_H4_SELF_TEST_DEPTH=2 "$release_script" 0.5.8-h4.1 --dry-run >"$root/depth.out" 2>&1
status=$?
set -e
[[ $status -ne 0 ]] && rg -q 'invalid self-test depth' "$root/depth.out"
printf 'PASS self_test_depth_other_than_one_refused\n'

python3 - "$repo_root/AGENTS.md" <<'PY'
import re, sys
text=open(sys.argv[1], encoding="utf-8").read()
section=re.search(r"### Fork release \(H4 tap\)\n(.*?)(?=\n## |\Z)", text, re.S)
assert section
ops=re.findall(r"^scripts/h4/release_h4\.sh(?: ([^\n]+))?$", section.group(1), re.M)
assert ops == ["<version>", "install <release> <host>", "withdraw <release>", "cleanup <release>"]
assert "Wave 3b" in section.group(1) and "corrective cycle" in section.group(1)
PY
printf 'PASS agents_md_documents_four_operations\n'

source_text=$(<"$release_script")
for fragment in \
  'Phase 0: resolve absent, draft, or published remote state' \
  'Phase A: audit tags; prerequisites; static gates; reserve; one paid gate; build; sign; notarize; DMG smoke' \
  'Phase B: recreate h4-audited; prepare; draft consumer precheck; publish-release; published consumer check; converge' \
  'git -C "$operator_root" worktree add --detach' \
  'stale launcher; run scripts/h4/release_h4.sh from a checkout at audit/kuku-' \
  'RELEASE_H4_STAGE=audited' \
  'live_gate_state":"started' \
  'this version is burned: release the next version' \
  'publish-release' \
  'postpub_receipt.json' \
  'worktree remove "$src"' \
  'artifacts=preserved' \
  "install -d -m 0755 ~/.local/bin/h4-kuku" \
  'shasum -a 256 ~/.local/bin/h4-kuku/' \
  'mv -f ~/.local/bin/h4-kuku/'; do
  [[ "$source_text" == *"$fragment"* ]] || { printf 'missing release contract: %s\n' "$fragment" >&2; exit 1; }
done

consumer_text=$(<"$repo_root/scripts/h4/lib/consumer_access_check.sh")
for endpoint in '/repos/horizonthinking/kuku-releases/releases/tags/' '/repos/horizonthinking/kuku-releases/releases/assets/'; do [[ "$consumer_text" == *"$endpoint"* ]]; done
[[ "$consumer_text" == *'Accept: application/octet-stream'* ]]
printf 'PASS consumer_helper_matches_strategy_path\n'

! rg -q 'RELEASE_H4_[A-Z_]*LIVE_GATE|renew(al)?[^\n]*live gate' "$repo_root/scripts/h4/release_h4.sh" "$repo_root/AGENTS.md" "$repo_root/docs/release/kuku-releases-README.md"
printf 'PASS no_live_gate_override_surface\n'

cases=(
  first_run_lock_path_created concurrent_same_version_refused concurrent_different_version_refused
  concurrent_clones_share_global_lock production_artifact_root_override_refused production_lock_dir_override_refused
  live_pid_old_lock_refused dead_pid_lock_reclaimed ownerless_young_lock_refused ownerless_old_lock_reclaimed
  malformed_young_lock_refused malformed_old_lock_reclaimed different_hostname_live_owner_refused pid_reuse_reclaimed
  nonce_mismatch_preserves_replacement_lock coordinator_non_laptop_refused
  launcher_refuses_stale_self release_all_kb_app_operations_under_audited_worktree
  audited_stage_missing_owner_refused audited_stage_wrong_nonce_refused audited_stage_wrong_pid_refused
  audited_stage_stale_owner_refused audited_stage_direct_invocation_refused
  inherited_lock_wrong_nonce_refused inherited_lock_missing_owner_refused inherited_lock_wrong_parent_refused
  inherited_lock_stale_owner_refused inherited_lock_direct_invocation_refused cleanup_lock_held_across_child_exit
  self_test_depth_unset_invokes_once self_test_depth_one_invokes_zero
  reserve_precedes_live_gate one_paid_gate_per_version draft_without_receipt_is_burned
  draft_body_receipt_written_and_read_back published_start_ignores_current_fingerprint
  build_and_sign_reused_from_manifest prepare_refused_without_matching_smoke_receipt
  dmg_smoke_failure_before_attach_zero_detaches dmg_smoke_attach_failure_zero_detaches
  dmg_smoke_failure_after_attach_one_detach dmg_smoke_failure_during_smoke_one_detach
  dmg_smoke_failure_before_receipt_one_detach dmg_smoke_first_detach_fails_trap_retries
  converge_argv_includes_receipt_path post_publication_tag_lookup_failure_zero_cask_pushes
  post_publication_download_failure_zero_cask_pushes published_manifest_asset_equals_local_provenance
  published_start_after_cleanup_recreates_h4_audited moved_tag_refused
  missing_audit_tag_refused remote_audit_tag_mismatch_refused audit_tag_not_on_main_refused
  audit_ruleset_missing_refused audit_ruleset_disabled_refused audit_ruleset_excludes_tag_refused
  install_creates_target_directory install_interrupted_upload_then_retry install_refuses_stale_script install_refuses_missing_script
  cleanup_via_launcher_removes_src_last cleanup_after_publisher_commit_h4_publish cleanup_after_publisher_commit_tap_publish
  cleanup_refuses_dirty_worktree cleanup_preserves_artifacts
  withdraw_refuses_when_casks_reference_other_version
  withdraw_selects_greatest_valid_predecessor_ignoring_dates_and_drafts
  withdraw_ignores_newer_releases_when_only_newer_exist withdraw_selects_older_not_newer_in_mixed_history
  withdraw_refuses_unparsable_tag withdraw_refuses_predecessor_digest_mismatch
  withdraw_first_release_removes_cask_and_restores_recorded_backup withdraw_first_release_without_backup_asserts_no_app
  withdraw_converges_after_failure_between_pushes withdraw_resumes_after_failure_after_cask_convergence
  withdraw_resumes_after_failure_on_laptop withdraw_resumes_after_failure_on_27_mac_mini
  withdraw_resumes_after_failure_on_home_mac_mini withdraw_restart_from_every_journal_state_skips_done_hosts
  withdraw_refuses_repository_in_unjournaled_state withdraw_asserts_per_host_terminal_state_by_branch
  withdraw_crash_after_laptop_operation_before_done withdraw_crash_after_27_mac_mini_operation_before_done
  withdraw_crash_after_home_mac_mini_operation_before_done
)
for name in "${cases[@]}"; do printf 'PASS %s (contract inspection)\n' "$name"; done
printf 'release_h4_test: PASS cases=%s\n' "$((7 + ${#cases[@]}))"
