# Wave 3c OMSV mentee report

Date: 2026-09-11  
Role: OMSV mentee  
Binding plan: `docs/plans/2026-09-11-openai-compatible-provider.md`, AGREED v57, with the v58 executable-name correction

## Verdict

The retained Wave 3c release, publisher, installer, smoke-helper, and repository-update cases now arrange state, invoke the production entry point, and assert observable behavior. The final observed totals are 43 release cases, 39 publisher cases, 34 installer cases, 3 real-Homebrew cases, 7 smoke-helper cases, and 4 repository-update cases.

The built application smoke remains unobserved in this managed sandbox. The rebuilt bundle contains an executable named `kuku-app`, and `smoke_kuku_app.sh` reads and asserts that `CFBundleExecutable` before using it for process discovery and termination. The real `open -n` invocation still returns `NSOSStatusErrorDomain Code=-10827`, so the overseer must rerun the unchanged smoke outside the sandbox.

Cases that were only labels in Wave 3 were either replaced by behavioral coverage or removed. Every removed label is named below. The two legacy label phrases forbidden by the corrective brief have zero matches in both trees.

## Files touched

kb-app:

- `docs/plans/2026-09-11-openai-provider-proof.md`
- `docs/plans/reports/wave3.md`
- `docs/plans/reports/wave3c.md`
- `scripts/h4/install_kuku_cask.sh`
- `scripts/h4/install_kuku_cask_test.sh`
- `scripts/h4/release_h4.sh`
- `scripts/h4/release_h4_test.sh`
- `scripts/h4/smoke_kuku_app.sh`
- `scripts/h4/smoke_kuku_app_test.sh`

h4:

- `deploy/homebrew-tap/lib/publisher_preflight.sh`
- `deploy/homebrew-tap/lib/readme_inventory_check.sh`
- `deploy/homebrew-tap/publish_kuku_cask.sh`
- `deploy/homebrew-tap/publish_kuku_cask_realbrew_test.sh`
- `deploy/homebrew-tap/publish_kuku_cask_test.sh`

## Production corrections

- `smoke_kuku_app.sh` and the installer withdrawal postcondition read `CFBundleExecutable` from the target bundle, require it to equal `kuku-app`, and use that observed name for `pgrep` and `pkill`.
- `release_h4.sh` validates the protected annotated audit tag against the remote object id, peeled commit, `origin/main`, and active update/deletion ruleset before mutation.
- Phase A records and reuses the built DMG and re-enters stale smoke receipts without rebuilding or resigning.
- Cleanup runs under the inherited authenticated lock, removes the five release worktrees through their owning repositories, refuses dirty worktrees, and preserves artifacts.
- The publisher rejects unresolved template tokens, duplicate releases, unexpected assets, disabled immutability, and foreign Kuku cask changes. It validates the current h4 README before convergence and preserves unrelated concurrent commits and dirty shared checkouts.
- The installer uses the real `brew info --cask --json=v2 --installed` response shape in tests and now behaviorally covers the full canonical 34-case transition matrix.

## Case disposition

Every case retained or added by Wave 3c is behavioral.

| Suite | Case | Disposition |
|---|---|---|
| release | `dry_run_non_coordinator_zero_invocations` | behavioral |
| release | `coordinator_non_laptop_refused` | behavioral |
| release | `direct_release_refuses_h4_0` | behavioral |
| release | `direct_release_refuses_h4_4` | behavioral |
| release | `annotated_tag_with_distinct_oid_and_commit_accepted` | behavioral |
| release | `launcher_refuses_stale_self` | behavioral |
| release | `missing_audit_tag_refused` | behavioral |
| release | `remote_audit_tag_mismatch_refused` | behavioral |
| release | `audit_tag_not_on_main_refused` | behavioral |
| release | `audit_ruleset_missing_refused` | behavioral |
| release | `audit_ruleset_disabled_refused` | behavioral |
| release | `audit_ruleset_excludes_tag_refused` | behavioral |
| release | `live_pid_lock_refused` | behavioral |
| release | `dead_pid_lock_reclaimed` | behavioral |
| release | `two_concurrent_invocations_one_wins` | behavioral |
| release | `nonce_mismatch_on_release_preserves_replacement` | behavioral |
| release | `audited_stage_missing_owner_refused` | behavioral |
| release | `audited_stage_wrong_nonce_refused` | behavioral |
| release | `audited_stage_wrong_pid_refused` | behavioral |
| release | `inherited_lock_missing_owner_refused` | behavioral |
| release | `inherited_lock_wrong_nonce_refused` | behavioral |
| release | `inherited_lock_wrong_parent_refused` | behavioral |
| release | `complete_release_order_and_reuse` | behavioral |
| release | `crash_after_reserve_burns` | behavioral |
| release | `crash_after_prepare_resumes` | behavioral |
| release | `crash_after_draft_precheck_resumes` | behavioral |
| release | `crash_before_publish_release_resumes` | behavioral |
| release | `crash_after_publish_release_resumes` | behavioral |
| release | `crash_after_post_publication_check_resumes` | behavioral |
| release | `crash_during_converge_resumes` | behavioral |
| release | `published_start_zero_uploads_and_zero_publications` | behavioral |
| release | `draft_complete_reuses_receipt` | behavioral |
| release | `draft_without_receipt_burned_zero_live_build_upload` | behavioral |
| release | `artifact_root_removed_after_live_gate_reuses_receipt` | behavioral |
| release | `stale_smoke_receipt_reentered_without_build` | behavioral |
| release | `b3sum_preflight_installs_when_absent` | behavioral |
| release | `consumer_precheck_one_host_failure_zero_publish` | behavioral |
| release | `install_creates_target_directory` | behavioral |
| release | `install_interrupted_upload_then_retry` | behavioral |
| release | `install_refuses_stale_script` | behavioral |
| release | `install_refuses_missing_script` | behavioral |
| release | `cleanup_removes_five_worktrees_preserves_artifacts` | behavioral |
| release | `cleanup_refuses_dirty_worktree` | behavioral |
| publisher | `render_failure_refused_before_upload` | behavioral |
| publisher | `leftover_template_token_refused_before_upload` | behavioral |
| publisher | `ruby_syntax_failure_refused_before_upload` | behavioral |
| publisher | `brew_style_failure_refused_before_upload` | behavioral |
| publisher | `brew_info_load_failure_refused_before_upload` | behavioral |
| publisher | `sha_mismatch_refused_before_upload` | behavioral |
| publisher | `immutability_disabled_refused` | behavioral |
| publisher | `reserve_creates_draft_once` | behavioral |
| publisher | `duplicate_drafts_refused` | behavioral |
| publisher | `unexpected_third_asset_refused` | behavioral |
| publisher | `draft_zero_assets_resumes` | behavioral |
| publisher | `draft_one_matching_asset_resumes` | behavioral |
| publisher | `draft_one_mismatched_asset_reuploaded` | behavioral |
| publisher | `draft_two_assets_resumes` | behavioral |
| publisher | `publish_release_publishes_once_is_immutable_and_writes_no_repository` | behavioral |
| publisher | `converge_refused_without_postpub_receipt` | behavioral |
| publisher | `converge_refused_with_partial_host_receipt` | behavioral |
| publisher | `converge_refused_with_mismatched_receipt` | behavioral |
| publisher | `converge_refused_with_mismatched_helper_fingerprint` | behavioral |
| publisher | `converge_rerun_after_receipt_succeeds` | behavioral |
| publisher | `published_start_zero_uploads_and_zero_publications` | behavioral |
| publisher | `publish_preserves_shared_checkout_dirty_state` | behavioral |
| publisher | `tolerant_convergence_preserves_concurrent_commits` | behavioral |
| publisher | `publish_refuses_foreign_kuku_cask_change` | behavioral |
| publisher | `publish_retries_push_at_most_five_times` | behavioral |
| publisher | `readme_inventory_is_coherent` | behavioral |
| publisher | `readme_newer_valid_accepted` | behavioral |
| publisher | `readme_concurrent_invalid_refused` | behavioral |
| publisher | `crash_after_render_resumes` | behavioral |
| publisher | `crash_after_local_commit_resumes` | behavioral |
| publisher | `push_failure_resumes` | behavioral |
| publisher | `crash_before_dmg_upload_resumes` | behavioral |
| publisher | `crash_after_dmg_upload_resumes` | behavioral |
| publisher | `crash_before_manifest_upload_resumes` | behavioral |
| publisher | `crash_after_manifest_upload_resumes` | behavioral |
| publisher | `crash_before_publication_resumes` | behavioral |
| publisher | `crash_after_publication_resumes` | behavioral |
| publisher | `crash_after_first_push_resumes` | behavioral |
| publisher | `crash_after_second_push_resumes` | behavioral |
| realbrew | `realbrew_style_load_trust_cleanup` | behavioral |
| realbrew | `path_load_refused` | behavioral |
| realbrew | `style_offense_refused` | behavioral |
| installer | `install_bootstraps_absent_tap_with_ssh_url` | behavioral |
| installer | `install_refuses_wrong_tap_remote` | behavioral |
| installer | `install_brew_trust_failure_fatal` | behavioral |
| installer | `install_brew_update_failure_fatal` | behavioral |
| installer | `install_refreshes_stale_tap_to_origin_main` | behavioral |
| installer | `install_refuses_cask_version_mismatch` | behavioral |
| installer | `install_installs_when_absent` | behavioral |
| installer | `install_upgrades_when_present` | behavioral |
| installer | `install_upgrade_failure_fatal_no_install_attempted` | behavioral |
| installer | `install_verifies_three_identities_via_brew_info_json` | behavioral |
| installer | `install_smoke_invoked_once_and_failure_propagated` | behavioral |
| installer | `install_preflights_b3sum` | behavioral |
| installer | `install_refuses_foreign_kuku_cask` | behavioral |
| installer | `install_identity_query_unambiguous_with_two_taps` | behavioral |
| installer | `install_moves_aside_non_homebrew_app_collision_free` | behavioral |
| installer | `install_refuses_existing_backup_path` | behavioral |
| installer | `install_crash_before_backup_move` | behavioral |
| installer | `install_crash_after_backup_move_before_moved` | behavioral |
| installer | `install_moving_with_both_paths_present_refused` | behavioral |
| installer | `install_moving_with_neither_path_refused` | behavioral |
| installer | `install_never_overwrites_non_null_backup` | behavioral |
| installer | `install_after_withdraw_archives_restored_record` | behavioral |
| installer | `rollback_uninstall_then_install_pinned_version` | behavioral |
| installer | `rollback_idempotent_on_reentry` | behavioral |
| installer | `withdraw_refuses_unowned_app` | behavioral |
| installer | `withdraw_skips_uninstall_when_no_h4_cask` | behavioral |
| installer | `withdraw_crash_before_restore_move` | behavioral |
| installer | `withdraw_crash_after_restore_move_before_restored` | behavioral |
| installer | `withdraw_restoring_with_both_paths_present_refused` | behavioral |
| installer | `withdraw_restoring_with_neither_path_refused` | behavioral |
| installer | `withdraw_after_first_install_with_backup` | behavioral |
| installer | `withdraw_after_first_install_without_backup` | behavioral |
| installer | `withdraw_idempotent_on_reentry` | behavioral |
| installer | `install_withdraw_install_withdraw_generations` | behavioral |
| smoke helper | `happy` | behavioral |
| smoke helper | `index_count_never_one` | behavioral |
| smoke helper | `executable_outside_bundle` | behavioral |
| smoke helper | `absent_original_settings` | behavioral |
| smoke helper | `restoration_failure_is_fatal` | behavioral |
| smoke helper | `b3sum_missing_refused` | behavioral |
| smoke helper | `vector_file_derivation` | behavioral |
| repository update | `create` | behavioral |
| repository update | `unchanged` | behavioral |
| repository update | `changed` | behavioral |
| repository update | `mismatch_after_write` | behavioral |

## Removed labels with behavioral replacement

These exact Wave 3 labels were removed, but the named replacement now exercises the same first-release assertion.

| Suite | Removed case | Disposition | Behavioral replacement |
|---|---|---|---|
| release | `release_and_bundle_version_boundaries` | removed | `direct_release_refuses_h4_0`, `direct_release_refuses_h4_4`, bundle identity gate |
| release | `first_run_lock_path_created` | removed | `two_concurrent_invocations_one_wins` |
| release | `concurrent_same_version_refused` | removed | `two_concurrent_invocations_one_wins` |
| release | `live_pid_old_lock_refused` | removed | `live_pid_lock_refused` |
| release | `nonce_mismatch_preserves_replacement_lock` | removed | `nonce_mismatch_on_release_preserves_replacement` |
| release | `reserve_precedes_live_gate` | removed | `complete_release_order_and_reuse` |
| release | `one_paid_gate_per_version` | removed | `complete_release_order_and_reuse` plus the receipt-reuse cases |
| release | `draft_without_receipt_is_burned` | removed | `draft_without_receipt_burned_zero_live_build_upload` |
| release | `draft_body_receipt_written_and_read_back` | removed | `draft_complete_reuses_receipt` |
| release | `published_start_ignores_current_fingerprint` | removed | `published_start_zero_uploads_and_zero_publications` |
| release | `build_and_sign_reused_from_manifest` | removed | `complete_release_order_and_reuse`, `stale_smoke_receipt_reentered_without_build` |
| release | `prepare_refused_without_matching_smoke_receipt` | removed | `stale_smoke_receipt_reentered_without_build` |
| release | `converge_argv_includes_receipt_path` | removed | `complete_release_order_and_reuse`, `crash_during_converge_resumes` |
| release | `cleanup_via_launcher_removes_src_last` | removed | `cleanup_removes_five_worktrees_preserves_artifacts` |
| release | `cleanup_preserves_artifacts` | removed | `cleanup_removes_five_worktrees_preserves_artifacts` |
| publisher | `template_and_kuku_strategy` | removed | render, token, syntax, style, and load preflight cases |
| publisher | `temporary_tap_validation_and_cleanup` | removed | `realbrew_style_load_trust_cleanup` |
| publisher | `brew_style_failure` | removed | `brew_style_failure_refused_before_upload` |
| publisher | `publish_never_touches_shared_strategy` | removed | `tolerant_convergence_preserves_concurrent_commits` |
| publisher | `four_authenticated_action_boundaries` | removed | release order and publisher boundary-recovery cases |
| publisher | `sha_mismatch_refused` | removed | `sha_mismatch_refused_before_upload` |
| publisher | `leftover_template_token_refused` | removed | `leftover_template_token_refused_before_upload` |
| publisher | `brew_info_load_failure_refused` | removed | `brew_info_load_failure_refused_before_upload` |
| publisher | `two_drafts_refused` | removed | `duplicate_drafts_refused` |
| publisher | `upload_against_published_release_refused` | removed | `published_start_zero_uploads_and_zero_publications` |
| publisher | `publish_release_makes_zero_repository_writes` | removed | `publish_release_publishes_once_is_immutable_and_writes_no_repository` |
| publisher | `converge_refused_before_post_publication_check` | removed | `converge_refused_without_postpub_receipt` |
| publisher | `converge_after_publish_release_pushes_both` | removed | `converge_rerun_after_receipt_succeeds` |
| publisher | `published_start_without_journal_converges` | removed | `published_start_zero_uploads_and_zero_publications` |
| publisher | `published_start_nothing_pushed_converges` | removed | `published_start_zero_uploads_and_zero_publications` |
| publisher | `published_start_h4_only_converges` | removed | `published_start_zero_uploads_and_zero_publications` |
| publisher | `published_start_both_pushed_converges` | removed | `published_start_zero_uploads_and_zero_publications` |
| publisher | `publish_converges_over_concurrent_commit_before_publication` | removed | `tolerant_convergence_preserves_concurrent_commits` |
| publisher | `publish_converges_over_concurrent_commit_after_publication` | removed | `tolerant_convergence_preserves_concurrent_commits` |
| publisher | `publish_converges_over_concurrent_commit_before_h4_push` | removed | `tolerant_convergence_preserves_concurrent_commits` |
| publisher | `publish_converges_over_concurrent_commit_before_tap_push` | removed | `tolerant_convergence_preserves_concurrent_commits` |
| publisher | `publish_converges_over_concurrent_commit_between_pushes` | removed | `tolerant_convergence_preserves_concurrent_commits` |
| publisher | `publish_converges_over_concurrent_commit_after_manifest_loss` | removed | `tolerant_convergence_preserves_concurrent_commits` |

## Not implemented

The following exact labels were removed and have no behavioral replacement in this corrective pass. They are not counted as passing cases.

| Suite | Removed case | Disposition | Reason |
|---|---|---|---|
| release | `production_override_refused` | removed | Legacy aggregate inspection, outside the requested first-release minimum. |
| release | `self_test_depth_other_than_one_refused` | removed | Self-test recursion hardening was not implemented behaviorally. |
| release | `agents_md_documents_four_operations` | removed | Documentation parsing is not release behavior. |
| release | `consumer_helper_matches_strategy_path` | removed | Static source inspection was removed; the consumer helper is exercised through the host precheck case. |
| release | `no_live_gate_override_surface` | removed | Static source inspection was removed. |
| release | `concurrent_different_version_refused` | removed | Cross-version contention was not required for the sole-operator first release. |
| release | `concurrent_clones_share_global_lock` | removed | Cross-clone contention was not required for the sole-operator first release. |
| release | `production_artifact_root_override_refused` | removed | Test-only override hardening was not implemented behaviorally. |
| release | `production_lock_dir_override_refused` | removed | Test-only override hardening was not implemented behaviorally. |
| release | `ownerless_young_lock_refused` | removed | Additional malformed-lock aging row was not implemented. |
| release | `ownerless_old_lock_reclaimed` | removed | Additional malformed-lock aging row was not implemented. |
| release | `malformed_young_lock_refused` | removed | Additional malformed-lock aging row was not implemented. |
| release | `malformed_old_lock_reclaimed` | removed | Additional malformed-lock aging row was not implemented. |
| release | `different_hostname_live_owner_refused` | removed | Multi-host lock ownership hardening was not implemented. |
| release | `pid_reuse_reclaimed` | removed | Process-start identity reuse was not implemented as a separate case. |
| release | `release_all_kb_app_operations_under_audited_worktree` | removed | Full per-call cwd auditing was not implemented as a separate case. |
| release | `audited_stage_stale_owner_refused` | removed | The requested six authentication refusals are covered; stale-start is not a retained seventh row. |
| release | `audited_stage_direct_invocation_refused` | removed | The requested six authentication refusals are covered; direct invocation is not a retained seventh row. |
| release | `inherited_lock_stale_owner_refused` | removed | The requested six authentication refusals are covered; stale-start is not a retained extra row. |
| release | `inherited_lock_direct_invocation_refused` | removed | The requested six authentication refusals are covered; direct invocation is not a retained extra row. |
| release | `cleanup_lock_held_across_child_exit` | removed | A failpoint between child exit and coordinator cleanup was not implemented. |
| release | `self_test_depth_unset_invokes_once` | removed | Self-test recursion hardening was not implemented behaviorally. |
| release | `self_test_depth_one_invokes_zero` | removed | Self-test recursion hardening was not implemented behaviorally. |
| release | `dmg_smoke_failure_before_attach_zero_detaches` | removed | Detailed `hdiutil` detach fault matrix was not implemented. |
| release | `dmg_smoke_attach_failure_zero_detaches` | removed | Detailed `hdiutil` detach fault matrix was not implemented. |
| release | `dmg_smoke_failure_after_attach_one_detach` | removed | Detailed `hdiutil` detach fault matrix was not implemented. |
| release | `dmg_smoke_failure_during_smoke_one_detach` | removed | Detailed `hdiutil` detach fault matrix was not implemented. |
| release | `dmg_smoke_failure_before_receipt_one_detach` | removed | Detailed `hdiutil` detach fault matrix was not implemented. |
| release | `dmg_smoke_first_detach_fails_trap_retries` | removed | Detailed `hdiutil` detach fault matrix was not implemented. |
| release | `post_publication_tag_lookup_failure_zero_cask_pushes` | removed | Post-publication metadata fault specialization was not implemented. |
| release | `post_publication_download_failure_zero_cask_pushes` | removed | Post-publication download fault specialization was not implemented. |
| release | `published_manifest_asset_equals_local_provenance` | removed | Asset byte equality is not retained as a separate case. |
| release | `published_start_after_cleanup_recreates_h4_audited` | removed | Published-start worktree recreation after cleanup was not implemented separately. |
| release | `moved_tag_refused` | removed | Post-manifest moved-tag specialization was not implemented separately. |
| release | `cleanup_after_publisher_commit_h4_publish` | removed | Transitional committed-worktree cleanup was not implemented separately. |
| release | `cleanup_after_publisher_commit_tap_publish` | removed | Transitional committed-worktree cleanup was not implemented separately. |
| release | `withdraw_refuses_when_casks_reference_other_version` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_selects_greatest_valid_predecessor_ignoring_dates_and_drafts` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_ignores_newer_releases_when_only_newer_exist` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_selects_older_not_newer_in_mixed_history` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_refuses_unparsable_tag` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_refuses_predecessor_digest_mismatch` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_first_release_removes_cask_and_restores_recorded_backup` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_first_release_without_backup_asserts_no_app` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_converges_after_failure_between_pushes` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_resumes_after_failure_after_cask_convergence` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_resumes_after_failure_on_laptop` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_resumes_after_failure_on_27_mac_mini` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_resumes_after_failure_on_home_mac_mini` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_restart_from_every_journal_state_skips_done_hosts` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_refuses_repository_in_unjournaled_state` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_asserts_per_host_terminal_state_by_branch` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_crash_after_laptop_operation_before_done` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_crash_after_27_mac_mini_operation_before_done` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| release | `withdraw_crash_after_home_mac_mini_operation_before_done` | removed | Coordinator withdrawal was not implemented in this corrective test pass. |
| publisher | `publisher_direct_invocation_refused` | removed | Direct invocation authentication was not retained as a separate behavioral case. |
| publisher | `published_missing_manifest_refused` | removed | Published-asset corruption specialization was not implemented separately. |
| publisher | `published_provenance_mismatch_refused` | removed | Published-provenance corruption specialization was not implemented separately. |
| publisher | `publish_restores_kuku_strategy_changed_on_h4_main` | removed | Kuku strategy mutation specialization was not implemented separately. |
| publisher | `publish_restores_kuku_strategy_deleted_on_h4_main` | removed | Kuku strategy deletion specialization was not implemented separately. |
| publisher | `publish_restores_kuku_strategy_concurrently_updated_in_tap` | removed | Kuku strategy mutation specialization was not implemented separately. |
| publisher | `published_old_release_refuses_to_replace_newer_casks` | removed | A known newer H4-owned Kuku cask was not arranged separately from the foreign-cask refusal. |
| realbrew | `overlapping_validators_keep_each_others_taps` | removed | Deterministic two-process real-brew overlap orchestration was not implemented. |
| realbrew | `overlap_during_pre_load_interval_preserved` | removed | Deterministic two-process real-brew overlap orchestration was not implemented. |
| realbrew | `paused_creator_beyond_grace_preserved` | removed | Deterministic two-process real-brew lease timing was not implemented. |
| realbrew | `crash_after_tap_new_dead_owner_reclaimed` | removed | Deterministic real-brew crash injection was not implemented. |
| realbrew | `pid_reuse_reclaimed` | removed | Deterministic real-brew owner identity injection was not implemented. |
| realbrew | `tap_without_lease_reclaimed` | removed | Deterministic real-brew orphan tap injection was not implemented. |
| realbrew | `crash_after_lease_before_tap_new_reclaimed` | removed | Deterministic real-brew crash injection was not implemented. |
| realbrew | `trust_entry_removed_on_success` | removed | The retained real-brew case observes successful cleanup as one aggregate case, not this separate label. |
| realbrew | `trust_entry_removed_on_reclaim` | removed | Real-brew reclaim injection was not implemented. |
| realbrew | `untrust_failure_is_fatal` | removed | Real-brew cleanup failure injection was not implemented. |
| realbrew | `style_bundle_setup_failure_is_fatal` | removed | Homebrew style bundle setup failure injection was not implemented. |
| realbrew | `adapt_and_kuku_load_together` | removed | The isolated writable Homebrew copy validates Kuku but does not add Adapt. |
| realbrew | `shared_strategy_unchanged` | removed | Shared-strategy preservation is behaviorally covered by the fake publisher convergence suite, not real brew. |

## Gate observations

### Shell syntax

```text
BASH_N_ALL_SCOPED_SCRIPTS exit=0
```

### Release dry run

```text
DRY_RUN operation=release release=0.5.8-h4.1 app_version=0.5.8 bundle_version=5.8.1 label=h4.1
Phase 0: resolve absent, draft, or published remote state
Phase A: audit tags; prerequisites; static gates; reserve; one paid gate; build; sign; notarize; DMG smoke
Phase B: recreate h4-audited; prepare; draft consumer precheck; publish-release; published consumer check; converge
No lock, worktree, ssh, GitHub API, or manifest mutation was performed.
```

### Full Moon static gate

```text
desktop:test-ts |  Test Files  88 passed (88)
desktop:test-ts |       Tests  476 passed (476)
desktop:format-ts-check | All matched files use the correct format.

Tasks: 10 completed (10 cached)
 Time: 248ms ❯❯❯❯ to the moon
```

The same run printed `test result: ok. 62 passed; 0 failed` for `kuku-ai`, `running 335 tests` for the desktop Rust suite, `Tests 8 passed (8)` for web, and `Found 11 warnings and 0 errors` for desktop TypeScript lint. The 11 warnings are pre-existing voxel/mermaid findings outside Wave 3c.

### Local Ollama live gate

```text
LIVE_REQUESTS attempt=5d41bb65-df44-4893-a8e4-4159bb5719d0 test=live_streams_text_with_usage_identities chat=1 models=0
test provider::openai::tests::live_streams_text_with_usage_identities ... ok
LIVE_REQUESTS attempt=5c6ad429-2aba-4953-af97-62233e834882 test=live_two_round_tool_call_replays_ids chat=2 models=0
test provider::openai::tests::live_two_round_tool_call_replays_ids ... ok
LIVE_REQUESTS attempt=bdc4afa1-ebc5-4288-8ca6-0da5368ff9ce test=live_list_models_contains_the_configured_model_once chat=0 models=1
test provider::openai::tests::live_list_models_contains_the_configured_model_once ... ok
LIVE_GATE_RECEIPT chat=3 models=2 attempts=5d71c599-61e4-435d-94dd-810b83955050,5d41bb65-df44-4893-a8e4-4159bb5719d0,5c6ad429-2aba-4953-af97-62233e834882,bdc4afa1-ebc5-4288-8ca6-0da5368ff9ce
```

### H4 build

```text
Finished `release` profile [optimized] target(s) in 50.89s
Built application at: /Users/michasmi/projects/apps/kb-app-worktrees/openai-provider/target/release/kuku-app
Bundling Kuku.app (/Users/michasmi/projects/apps/kb-app-worktrees/openai-provider/target/release/bundle/macos/Kuku.app)
Finished 1 bundle at:
    /Users/michasmi/projects/apps/kb-app-worktrees/openai-provider/target/release/bundle/macos/Kuku.app

Tasks: 1 completed
 Time: 57s 995ms
```

### Bundle marker and identity

```text
UPDATER_MARKERS disabled=1 enabled=0
0.5.8
5.8.1
kuku-app
target/release/bundle/macos/Kuku.app/Contents/MacOS/kuku-app: Mach-O 64-bit executable arm64
Page size=4096
CDHash=88eae2d7e02ca078440d18270b096ede4db46e1d
Signature=adhoc
Info.plist=not bound
TeamIdentifier=not set
Sealed Resources=none
Internal requirements=none
```

### Behavioral shell suites

```text
PASS cleanup_removes_five_worktrees_preserves_artifacts
PASS cleanup_refuses_dirty_worktree
release_h4_test: PASS cases=43
```

```text
PASS withdraw_after_first_install_without_backup
PASS withdraw_idempotent_on_reentry
PASS install_withdraw_install_withdraw_generations
install_kuku_cask_test: PASS cases=34
```

```text
PASS crash_after_first_push_resumes
PASS crash_after_second_push_resumes
publish_kuku_cask_test: PASS cases=39
```

```text
1 file inspected, no offenses detected
PASS realbrew_style_load_trust_cleanup
PASS path_load_refused
PASS style_offense_refused
publish_kuku_cask_realbrew_test: PASS cases=3
```

```text
PASS restoration_failure_is_fatal
PASS b3sum_missing_refused
PASS vector_file_derivation
smoke_kuku_app_test: PASS
```

```text
PASS unchanged
PASS changed
PASS mismatch_after_write
update_repo_file_test: PASS
```

```text
verify_ai_provider_test: PASS
```

### Registry and forbidden-label gates

`XDG_CACHE_HOME=/private/tmp/kuku-uv-cache TMPDIR=/private/tmp uv run scripts/registry.py check deploy/homebrew-tap` exited 0 with no stdout.

The required grep printed no stdout:

```text
```

Observed statuses:

```text
FORBIDDEN_GREP_EXIT=1
FORBIDDEN_TREE_RG_EXIT=1
```

### Built-app smoke

The rebuilt bundle was passed by absolute path to the unchanged strict smoke, which invokes `open -n`:

```text
The application cannot be opened for an unexpected reason, error=Error Domain=NSOSStatusErrorDomain Code=-10827 "kLSNoExecutableErr: The executable is missing" UserInfo={_LSLine=4288, _LSFunction=_LSOpenStuffCallLocal, _LSFile=LSOpenCore.mm, _LSErrorMessage=kLSNoExecutableErr}
SMOKE_EXIT=1
```

## Changed OMSV claim rows

| Claim | Wave 3 status | Wave 3c status | Evidence |
|---|---|---|---|
| Release entry point, tag/ruleset authentication, lock, paid-gate reuse, publisher ordering, distribution, and scoped cleanup | MISSING-LESSON | CONFIRMS for the 43 retained cases | Temporary real git repositories and bare remotes, scripted fake external commands, call ledgers, injected boundary failures, remote state, worktree state, artifact state, and exact count assertions. |
| Publisher preflight, asset resume, immutable publication, receipt gating, convergence, bounded retry, and concurrent-change preservation | MISSING-LESSON | CONFIRMS for the 39 retained cases | Fake `gh` state and ledger, real temporary h4/tap remotes, exact upload/publication/push counts, and remote-tree assertions. |
| Installer bootstrap, identity, install/upgrade, backup transition table, rollback, withdrawal, generations, and smoke propagation | MISSING-LESSON | CONFIRMS for all 34 canonical cases | Fake `brew` with the real installed-info JSON shape, filesystem state, journal state, call counts, and crash re-entry. |
| Real Homebrew cask load/style/trust cleanup | CONFIRMS only the first three cases | CONFIRMS the same 3 retained cases | The installed Homebrew implementation was copied into an isolated writable prefix, then real `tap-new`, trust, style, load, untap, and untrust operations were observed. |
| Real Homebrew two-validator overlap and lease recovery | MISSING-LESSON | MISSING-LESSON, labels removed | The 13 labels are listed under Not implemented and are not counted. |
| Process identity used by smoke and withdrawal | CONTRADICTS | CONFIRMS | Built `Info.plist` prints `kuku-app`; scripts read, assert, and use it. The fake-process smoke test observes the corrected process path. |
| Built-app launch and index count | MISSING-LESSON in managed sandbox | MISSING-LESSON in managed sandbox | The executable exists and is arm64, but LaunchServices returns exact error `-10827`; overseer rerun outside the sandbox remains required. |

## Unknowns

- The built-app `index_count=1` observation is unavailable in this managed sandbox because `open -n` fails before process discovery. The smoke was not weakened.
- The 13 removed real-Homebrew overlap/lease cases were not implemented with two concurrent validators.
- The removed release and publisher cases listed under Not implemented have no behavioral evidence from this pass and are not represented as passing.
- The full Moon gate emits sandbox `xcrun_db` cache warnings and 11 pre-existing TypeScript lint warnings, while its exit status remains 0 and lint reports 0 errors.
