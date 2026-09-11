#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${KUKU_TEST_OPENAI_BASE_URL:-}" ]]; then
  echo "KUKU_TEST_OPENAI_BASE_URL is required" >&2
  exit 1
fi
if [[ -z "${KUKU_TEST_OPENAI_MODEL:-}" ]]; then
  echo "KUKU_TEST_OPENAI_MODEL is required" >&2
  exit 1
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

: "${KUKU_LIVE_REQUEST_LOG:=${TMPDIR:-/tmp}/kuku-ai-live-requests-${PPID}.log}"
: "${KUKU_LIVE_RECEIPT:=${KUKU_LIVE_REQUEST_LOG}.receipt}"
export KUKU_LIVE_REQUEST_LOG
mkdir -p "$(dirname "$KUKU_LIVE_REQUEST_LOG")"
touch "$KUKU_LIVE_REQUEST_LOG"

readonly live_streams="live_streams_text_with_usage_identities"
readonly live_tools="live_two_round_tool_call_replays_ids"
readonly live_models="live_list_models_contains_the_configured_model_once"
readonly live_prefix="provider::openai::tests::"
readonly -a live_order=("$live_streams" "$live_models" "$live_tools")

fail() {
  echo "live provider verification failed: $*" >&2
  exit 1
}

new_attempt() {
  uuidgen | tr '[:upper:]' '[:lower:]'
}

append_synced() {
  python3 - "$KUKU_LIVE_REQUEST_LOG" "$1" <<'PY'
import os
import sys

path, line = sys.argv[1:]
parent = os.path.dirname(path)
if parent:
    os.makedirs(parent, exist_ok=True)
with open(path, "a", encoding="utf-8") as handle:
    handle.write(line + "\n")
    handle.flush()
    os.fsync(handle.fileno())
PY
}

request_counts() {
  awk '
    NF >= 4 && $2 ~ /^attempt=/ && $3 == "chat" { chat += 1 }
    NF >= 4 && $2 ~ /^attempt=/ && $3 == "models" { models += 1 }
    END { printf "%d %d\n", chat + 0, models + 0 }
  ' "$KUKU_LIVE_REQUEST_LOG" 2>/dev/null || printf '0 0\n'
}

attempt_counts() {
  local attempt=$1
  awk -v wanted="attempt=${attempt}" '
    NF >= 4 && $2 == wanted && $3 == "chat" { chat += 1 }
    NF >= 4 && $2 == wanted && $3 == "models" { models += 1 }
    END { printf "%d %d\n", chat + 0, models + 0 }
  ' "$KUKU_LIVE_REQUEST_LOG"
}

completed_attempt() {
  local name=$1
  awk -v wanted="$name" '$1 == "completed" && $3 == wanted { sub(/^attempt=/, "", $2); print $2 }' "$KUKU_LIVE_REQUEST_LOG" 2>/dev/null
}

inventory_output=$(cargo test -p kuku-ai -- --list 2>&1) || {
  printf '%s\n' "$inventory_output" >&2
  fail "could not inventory live tests"
}
inventory=()
while IFS= read -r inventory_name; do
  inventory+=("$inventory_name")
done < <(
  printf '%s\n' "$inventory_output" |
    awk '$2 == "test" && $1 ~ /live_/ { sub(/:$/, "", $1); print $1 }'
)
expected_inventory=(
  "${live_prefix}${live_streams}"
  "${live_prefix}${live_tools}"
  "${live_prefix}${live_models}"
)
[[ ${#inventory[@]} -eq 3 ]] || fail "inventory must contain exactly three live_ tests; observed ${#inventory[@]}"
for expected in "${expected_inventory[@]}"; do
  count=0
  for observed in "${inventory[@]}"; do
    [[ "$observed" == "$expected" ]] && count=$((count + 1))
  done
  [[ $count -eq 1 ]] || fail "inventory must contain ${expected} exactly once; observed ${count}"
done
for observed in "${inventory[@]}"; do
  allowed=0
  for expected in "${expected_inventory[@]}"; do
    [[ "$observed" == "$expected" ]] && allowed=1
  done
  [[ $allowed -eq 1 ]] || fail "unexpected live_ test in inventory: ${observed}"
done

had_prior=0
if [[ -s "$KUKU_LIVE_REQUEST_LOG" ]]; then
  had_prior=1
  [[ "${RELEASE_H4_RENEW_LIVE_GATE:-}" == "1" ]] ||
    fail "live gate incomplete; set RELEASE_H4_RENEW_LIVE_GATE=1 to authorize a new paid run"
fi

probe_markers=$(awk '$1 == "probe" && $2 ~ /^attempt=/ { count += 1 } END { print count + 0 }' "$KUKU_LIVE_REQUEST_LOG" 2>/dev/null || printf '0')
if [[ $probe_markers -gt 1 ]]; then
  fail "expected at most one completed probe; observed ${probe_markers}"
fi
if [[ $probe_markers -eq 0 ]]; then
  read -r chat_count models_count <<<"$(request_counts)"
  [[ $models_count -lt 4 ]] || fail "live request ceiling reached before models probe: chat=${chat_count} models=${models_count}"
  probe_attempt=$(new_attempt)
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  append_synced "${timestamp} attempt=${probe_attempt} models verifier_probe"
  probe_base=$KUKU_TEST_OPENAI_BASE_URL
  while [[ "$probe_base" == */ ]]; do
    probe_base=${probe_base%/}
  done
  curl_args=(-sS --fail --output /dev/null "${probe_base}/models")
  if [[ -n "${KUKU_TEST_OPENAI_API_KEY:-}" ]]; then
    curl_args=(-sS --fail --output /dev/null -H "Authorization: Bearer ${KUKU_TEST_OPENAI_API_KEY}" "${probe_base}/models")
  fi
  curl "${curl_args[@]}" || fail "models probe failed"
  append_synced "probe attempt=${probe_attempt}"
fi

for name in "${live_order[@]}"; do
  existing_attempts=()
  while IFS= read -r existing_attempt; do
    existing_attempts+=("$existing_attempt")
  done < <(completed_attempt "$name")
  if [[ ${#existing_attempts[@]} -gt 1 ]]; then
    fail "test ${name} has duplicate completed markers"
  fi
  if [[ ${#existing_attempts[@]} -eq 1 ]]; then
    continue
  fi

  attempt=$(new_attempt)
  fq_name="${live_prefix}${name}"
  set +e
  test_output=$(KUKU_LIVE_ATTEMPT="$attempt" cargo test -p kuku-ai "$fq_name" -- --exact --nocapture 2>&1)
  test_status=$?
  set -e
  printf '%s\n' "$test_output"
  [[ $test_status -eq 0 ]] || fail "${name} exited ${test_status}"
  [[ "$test_output" != *"skipped: KUKU_TEST_OPENAI_BASE_URL unset"* ]] || fail "${name} was skipped"

  observed_live_tests=()
  while IFS= read -r observed_live_test; do
    observed_live_tests+=("$observed_live_test")
  done < <(
    printf '%s\n' "$test_output" |
      awk '$1 == "test" && $2 ~ /live_/ { print $2 }'
  )
  [[ ${#observed_live_tests[@]} -eq 1 ]] || fail "${name} must report exactly one live_ test; observed ${#observed_live_tests[@]}"
  [[ "${observed_live_tests[0]}" == "$fq_name" ]] || fail "${name} reported unexpected live_ test ${observed_live_tests[0]}"
  ok_count=$(printf '%s\n' "$test_output" | awk -v wanted="$fq_name" '$1 == "test" && $2 == wanted && $3 == "..." && $4 == "ok" { count += 1 } END { print count + 0 }')
  [[ $ok_count -eq 1 ]] || fail "${name} must report exactly one ok result; observed ${ok_count}"

  case "$name" in
    "$live_streams") expected_chat=1; expected_models=0 ;;
    "$live_tools") expected_chat=2; expected_models=0 ;;
    "$live_models") expected_chat=0; expected_models=1 ;;
    *) fail "internal error: unknown live test ${name}" ;;
  esac
  machine_line="LIVE_REQUESTS attempt=${attempt} test=${name} chat=${expected_chat} models=${expected_models}"
  legacy_line="LIVE_REQUESTS test=${name} chat=${expected_chat} models=${expected_models}"
  machine_count=$(printf '%s\n' "$test_output" | awk -v wanted="$machine_line" '$0 == wanted { count += 1 } END { print count + 0 }')
  legacy_count=$(printf '%s\n' "$test_output" | awk -v wanted="$legacy_line" '$0 == wanted { count += 1 } END { print count + 0 }')
  [[ $machine_count -eq 1 ]] || fail "${name} must print its attempt-scoped LIVE_REQUESTS line exactly once"
  [[ $legacy_count -eq 1 ]] || fail "${name} must print its LIVE_REQUESTS line exactly once"
  read -r attempt_chat attempt_models <<<"$(attempt_counts "$attempt")"
  [[ $attempt_chat -eq $expected_chat && $attempt_models -eq $expected_models ]] ||
    fail "${name} attempt ${attempt} request delta was chat=${attempt_chat} models=${attempt_models}; expected chat=${expected_chat} models=${expected_models}"
  append_synced "completed attempt=${attempt} ${name}"
done

probe_attempt=$(awk '$1 == "probe" && $2 ~ /^attempt=/ { sub(/^attempt=/, "", $2); print $2 }' "$KUKU_LIVE_REQUEST_LOG")
read -r probe_chat probe_models <<<"$(attempt_counts "$probe_attempt")"
[[ $probe_chat -eq 0 && $probe_models -eq 1 ]] || fail "probe attempt ${probe_attempt} request delta was chat=${probe_chat} models=${probe_models}; expected chat=0 models=1"

for name in "${live_order[@]}"; do
  attempts=()
  while IFS= read -r completed; do
    attempts+=("$completed")
  done < <(completed_attempt "$name")
  [[ ${#attempts[@]} -eq 1 ]] || fail "test ${name} must have exactly one completed marker"
  case "$name" in
    "$live_streams") expected_chat=1; expected_models=0 ;;
    "$live_tools") expected_chat=2; expected_models=0 ;;
    "$live_models") expected_chat=0; expected_models=1 ;;
  esac
  read -r attempt_chat attempt_models <<<"$(attempt_counts "${attempts[0]}")"
  [[ $attempt_chat -eq $expected_chat && $attempt_models -eq $expected_models ]] ||
    fail "completed ${name} attempt ${attempts[0]} has chat=${attempt_chat} models=${attempt_models}; expected chat=${expected_chat} models=${expected_models}"
done

read -r chat_count models_count <<<"$(request_counts)"
if [[ $had_prior -eq 0 ]]; then
  [[ $chat_count -eq 3 && $models_count -eq 2 ]] ||
    fail "clean live gate totals must be chat=3 models=2; observed chat=${chat_count} models=${models_count}"
else
  [[ $chat_count -le 6 && $models_count -le 4 ]] ||
    fail "renewed live gate exceeds ceiling: chat=${chat_count} models=${models_count}"
fi

attempt_ids=$(awk '
  {
    for (field_number = 1; field_number <= NF; field_number += 1) {
      if ($field_number ~ /^attempt=/) {
        value = $field_number
        sub(/^attempt=/, "", value)
        if (!seen[value]++) {
          ordered[++count] = value
        }
      }
    }
  }
  END {
    separator = ""
    for (j = 1; j <= count; j += 1) {
      printf "%s%s", separator, ordered[j]
      separator = ","
    }
    printf "\n"
  }
' "$KUKU_LIVE_REQUEST_LOG")
receipt="LIVE_GATE_RECEIPT chat=${chat_count} models=${models_count} attempts=${attempt_ids}"
python3 - "$KUKU_LIVE_RECEIPT" "$receipt" <<'PY'
import os
import sys

path, receipt = sys.argv[1:]
parent = os.path.dirname(path)
if parent:
    os.makedirs(parent, exist_ok=True)
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    handle.write(receipt + "\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, path)
PY
printf '%s\n' "$receipt"
