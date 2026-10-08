#!/usr/bin/env bash
# ---
# asset: kuku-verify-openai-provider
# type: test-script
# description: Run the exact three OpenAI-compatible live tests with a fingerprinted, fail-closed HTTP-attempt ledger.
# owner: michael
# status: active
# ---

set -euo pipefail

fail() {
  printf 'live provider verification failed: %s\n' "$*" >&2
  exit 1
}

for required in KUKU_TEST_OPENAI_BASE_URL KUKU_TEST_OPENAI_MODEL KUKU_LIVE_REQUEST_LOG; do
  [[ -n "${!required:-}" ]] || fail "${required} is required"
done
[[ ! -s "$KUKU_LIVE_REQUEST_LOG" ]] || fail "request log already contains data: ${KUKU_LIVE_REQUEST_LOG}"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"
mkdir -p "$(dirname "$KUKU_LIVE_REQUEST_LOG")"
: >"$KUKU_LIVE_REQUEST_LOG"
: "${KUKU_LIVE_RECEIPT:=${KUKU_LIVE_REQUEST_LOG}.receipt.json}"
export KUKU_LIVE_REQUEST_LOG KUKU_LIVE_RECEIPT

readonly live_streams=live_streams_text_with_usage_identities
readonly live_tools=live_two_round_tool_call_replays_ids
readonly live_models=live_list_models_contains_the_configured_model_once
readonly live_prefix=provider::openai::tests::
readonly -a live_order=("$live_streams" "$live_tools" "$live_models")

KUKU_LIVE_VERIFIER_SHA256=$(shasum -a 256 "$repo_root/scripts/h4/verify_ai_provider.sh" | awk '{print $1}')
export KUKU_LIVE_VERIFIER_SHA256

KUKU_LIVE_CONFIG_FINGERPRINT=$(python3 - "$KUKU_LIVE_VERIFIER_SHA256" <<'PY'
import hashlib
import os
import sys
import urllib.parse

raw = os.environ["KUKU_TEST_OPENAI_BASE_URL"].strip()
parsed = urllib.parse.urlsplit(raw)
if parsed.scheme.lower() not in {"http", "https"} or not parsed.hostname:
    raise SystemExit("invalid OpenAI base URL")
if parsed.username or parsed.password or parsed.query or parsed.fragment:
    raise SystemExit("OpenAI base URL must not contain userinfo, query, or fragment")
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
    f"{sys.argv[1].lower()}\n"
    f"{key_hash}\n"
)
print(hashlib.sha256(canonical.encode()).hexdigest())
PY
) || fail "could not compute configuration fingerprint"
export KUKU_LIVE_CONFIG_FINGERPRINT

new_attempt() {
  uuidgen | tr '[:upper:]' '[:lower:]'
}

append_synced() {
  python3 - "$KUKU_LIVE_REQUEST_LOG" "$1" <<'PY'
import os
import sys

with open(sys.argv[1], "a", encoding="utf-8") as handle:
    handle.write(sys.argv[2] + "\n")
    handle.flush()
    os.fsync(handle.fileno())
PY
}

validate_ledger() {
  awk -v config="$KUKU_LIVE_CONFIG_FINGERPRINT" -v s="$live_streams" -v t="$live_tools" -v m="$live_models" '
    function request_row() {
      return NF == 5 && $1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ &&
        $2 ~ /^attempt=[0-9A-Za-z._-]+$/ && $3 == "config=" config &&
        ($4 == "chat" || $4 == "models") && $5 ~ /^[0-9A-Za-z._-]+$/
    }
    function probe_marker() {
      return NF == 3 && $1 == "probe" && $2 ~ /^attempt=[0-9A-Za-z._-]+$/ && $3 == "config=" config
    }
    function completed_marker() {
      return NF == 4 && $1 == "completed" && $2 ~ /^attempt=[0-9A-Za-z._-]+$/ &&
        $3 == "config=" config && ($4 == s || $4 == t || $4 == m)
    }
    function receipt_marker() {
      return NF == 6 && $1 == "receipt" && $2 == "config=" config && $3 == "chat=3" &&
        $4 == "models=2" && $5 ~ /^attempts=[0-9A-Za-z,._-]+$/ && $6 ~ /^log_sha256=[0-9a-f]{64}$/
    }
    !(request_row() || probe_marker() || completed_marker() || receipt_marker()) { bad = 1 }
    END { exit bad }
  ' "$KUKU_LIVE_REQUEST_LOG" || fail "request log contains a row outside the exact marker syntax"
}

request_counts() {
  awk '$3 ~ /^config=/ && $4 == "chat" { chat++ } $3 ~ /^config=/ && $4 == "models" { models++ } END { print chat + 0, models + 0 }' "$KUKU_LIVE_REQUEST_LOG"
}

attempt_counts() {
  awk -v attempt="attempt=$1" '$2 == attempt && $4 == "chat" { chat++ } $2 == attempt && $4 == "models" { models++ } END { print chat + 0, models + 0 }' "$KUKU_LIVE_REQUEST_LOG"
}

inventory_output=$(TMPDIR=/private/tmp cargo test -p kuku-ai -- --list 2>&1) || {
  printf '%s\n' "$inventory_output" >&2
  fail "could not inventory live tests"
}
inventory=()
while IFS= read -r inventory_name; do
  inventory+=("$inventory_name")
done < <(printf '%s\n' "$inventory_output" | awk '$2 == "test" && $1 ~ /live_/ { sub(/:$/, "", $1); print $1 }')
expected_inventory=("${live_prefix}${live_streams}" "${live_prefix}${live_tools}" "${live_prefix}${live_models}")
[[ ${#inventory[@]} -eq 3 ]] || fail "inventory must contain exactly three live_ tests; observed ${#inventory[@]}"
for expected in "${expected_inventory[@]}"; do
  count=$(printf '%s\n' "${inventory[@]}" | awk -v wanted="$expected" '$0 == wanted { count++ } END { print count + 0 }')
  [[ $count -eq 1 ]] || fail "inventory must contain ${expected} exactly once; observed ${count}"
done

probe_attempt=$(new_attempt)
read -r chat_count models_count <<<"$(request_counts)"
[[ $chat_count -le 3 && $models_count -lt 2 ]] || fail "live request ceiling reached before models probe: chat=${chat_count} models=${models_count}"
append_synced "$(date -u +%Y-%m-%dT%H:%M:%SZ) attempt=${probe_attempt} config=${KUKU_LIVE_CONFIG_FINGERPRINT} models verifier_probe"
validate_ledger
probe_base=$(python3 - <<'PY'
import os
print(os.environ["KUKU_TEST_OPENAI_BASE_URL"].strip().rstrip("/"))
PY
)
curl_args=(-sS --fail --output /dev/null "${probe_base}/models")
if [[ -n "${KUKU_TEST_OPENAI_API_KEY:-}" ]]; then
  curl_args=(-sS --fail --output /dev/null -H "Authorization: Bearer ${KUKU_TEST_OPENAI_API_KEY}" "${probe_base}/models")
fi
curl "${curl_args[@]}" || fail "models probe failed"
append_synced "probe attempt=${probe_attempt} config=${KUKU_LIVE_CONFIG_FINGERPRINT}"

attempt_ids=("$probe_attempt")
for name in "${live_order[@]}"; do
  attempt=$(new_attempt)
  attempt_ids+=("$attempt")
  fq_name="${live_prefix}${name}"
  set +e
  test_output=$(KUKU_LIVE_ATTEMPT="$attempt" TMPDIR=/private/tmp cargo test -p kuku-ai "$fq_name" -- --exact --nocapture 2>&1)
  test_status=$?
  set -e
  printf '%s\n' "$test_output"
  [[ $test_status -eq 0 ]] || fail "${name} exited ${test_status}"
  [[ "$test_output" != *"skipped: KUKU_TEST_OPENAI_BASE_URL unset"* ]] || fail "${name} was skipped"
  ok_count=$(printf '%s\n' "$test_output" | awk -v wanted="$fq_name" '$1 == "test" && $2 == wanted && $3 == "..." && $4 == "ok" { count++ } END { print count + 0 }')
  [[ $ok_count -eq 1 ]] || fail "${name} must report exactly one ok result; observed ${ok_count}"
  observed_count=$(printf '%s\n' "$test_output" | awk '$1 == "test" && $2 ~ /live_/ { count++ } END { print count + 0 }')
  [[ $observed_count -eq 1 ]] || fail "${name} must report exactly one live_ test; observed ${observed_count}"
  case "$name" in
    "$live_streams") expected_chat=1; expected_models=0 ;;
    "$live_tools") expected_chat=2; expected_models=0 ;;
    "$live_models") expected_chat=0; expected_models=1 ;;
    *) fail "unexpected live test ${name}" ;;
  esac
  machine_line="LIVE_REQUESTS attempt=${attempt} test=${name} chat=${expected_chat} models=${expected_models}"
  [[ $(printf '%s\n' "$test_output" | awk -v wanted="$machine_line" '$0 == wanted { count++ } END { print count + 0 }') -eq 1 ]] ||
    fail "${name} must print its attempt-scoped LIVE_REQUESTS line exactly once"
  validate_ledger
  read -r attempt_chat attempt_models <<<"$(attempt_counts "$attempt")"
  [[ $attempt_chat -eq $expected_chat && $attempt_models -eq $expected_models ]] ||
    fail "${name} attempt ${attempt} request delta was chat=${attempt_chat} models=${attempt_models}; expected chat=${expected_chat} models=${expected_models}"
  append_synced "completed attempt=${attempt} config=${KUKU_LIVE_CONFIG_FINGERPRINT} ${name}"
done

validate_ledger
read -r chat_count models_count <<<"$(request_counts)"
[[ $chat_count -eq 3 && $models_count -eq 2 ]] || fail "clean live gate totals must be chat=3 models=2; observed chat=${chat_count} models=${models_count}"
attempt_csv=$(IFS=,; printf '%s' "${attempt_ids[*]}")
log_sha256=$(shasum -a 256 "$KUKU_LIVE_REQUEST_LOG" | awk '{print $1}')
append_synced "receipt config=${KUKU_LIVE_CONFIG_FINGERPRINT} chat=3 models=2 attempts=${attempt_csv} log_sha256=${log_sha256}"
validate_ledger

python3 - "$KUKU_LIVE_RECEIPT" "$KUKU_LIVE_CONFIG_FINGERPRINT" "$attempt_csv" "$log_sha256" <<'PY'
import datetime
import json
import os
import sys

path, fingerprint, attempts, log_sha256 = sys.argv[1:]
temporary = path + ".tmp"
payload = {
    "fingerprint": fingerprint,
    "chat": 3,
    "models": 2,
    "attempts": attempts.split(","),
    "log_sha256": log_sha256,
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, path)
PY

printf 'LIVE_GATE_RECEIPT chat=3 models=2 attempts=%s\n' "$attempt_csv"
