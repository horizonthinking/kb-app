#!/usr/bin/env bash
# ---
# asset: kuku-release-repository-file-update-test
# type: test-script
# description: Prove repository-file creation, unchanged reuse, changed update, and post-write mismatch refusal through a file-backed fake gh.
# owner: michael
# status: active
# ---

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
helper="$repo_root/scripts/h4/lib/update_repo_file.sh"
tracked_source="$repo_root/docs/release/kuku-releases-README.md"
[[ -f "$tracked_source" ]] || {
  printf 'update_repo_file_test: tracked README source missing\n' >&2
  exit 1
}
test_root=$(mktemp -d /private/tmp/kuku-update-repo-file.XXXXXX)
trap 'rm -rf "$test_root"' EXIT
fake="$test_root/gh"

cat >"$fake" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
state=${FAKE_GH_STATE:?}
if [[ "$1" != api ]]; then exit 90; fi
shift
method=GET
input=
if [[ "${1:-}" == "--method" ]]; then method=$2; shift 2; fi
endpoint=$1; shift
if [[ "${1:-}" == "--input" ]]; then input=$2; fi
blob="$state/blob"
if [[ "$method" == GET ]]; then
  [[ -f "$blob" ]] || { printf 'HTTP 404 not found\n' >&2; exit 1; }
  content=$(base64 <"$blob" | tr -d '\n')
  printf '{"sha":"%s","commit_sha":"%s","content":"%s"}\n' "$(shasum -a 256 "$blob" | awk '{print $1}')" "$(cat "$state/commit")" "$content"
else
  python3 - "$input" "$blob" <<'PY'
import base64, json, os, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
data = base64.b64decode(value["content"])
if os.environ.get("FAKE_GH_MISMATCH") == "1": data += b"mismatch"
open(sys.argv[2], "wb").write(data)
PY
  printf 'commit-%s\n' "$(($(cat "$state/count" 2>/dev/null || echo 0) + 1))" >"$state/commit"
  printf '%s\n' "$(($(cat "$state/count" 2>/dev/null || echo 0) + 1))" >"$state/count"
  printf '{}\n'
fi
SH
chmod +x "$fake"

run_state() {
  local name=$1
  state="$test_root/$name"
  mkdir -p "$state"
  printf '0\n' >"$state/count"
  FAKE_GH_STATE="$state" GH="$fake" UPDATE_REPO_FILE_TEST_MODE=1 "$helper" test/example README.md "$tracked_source"
}

run_state create >/dev/null
[[ $(cat "$test_root/create/count") == 1 ]] || exit 1
printf 'PASS create\n'

state="$test_root/unchanged"; mkdir -p "$state"; cp "$tracked_source" "$state/blob"; printf 'seed\n' >"$state/commit"; printf '0\n' >"$state/count"
FAKE_GH_STATE="$state" GH="$fake" UPDATE_REPO_FILE_TEST_MODE=1 "$helper" test/example README.md "$tracked_source" >/dev/null
[[ $(cat "$state/count") == 0 ]] || exit 1
printf 'PASS unchanged\n'

state="$test_root/changed"; mkdir -p "$state"; printf 'old\n' >"$state/blob"; printf 'seed\n' >"$state/commit"; printf '0\n' >"$state/count"
FAKE_GH_STATE="$state" GH="$fake" UPDATE_REPO_FILE_TEST_MODE=1 "$helper" test/example README.md "$tracked_source" >/dev/null
cmp -s "$tracked_source" "$state/blob"
printf 'PASS changed\n'

state="$test_root/mismatch"; mkdir -p "$state"; printf '0\n' >"$state/count"
set +e
FAKE_GH_STATE="$state" FAKE_GH_MISMATCH=1 GH="$fake" UPDATE_REPO_FILE_TEST_MODE=1 "$helper" test/example README.md "$tracked_source" >"$test_root/mismatch.out" 2>&1
status=$?
set -e
[[ $status -ne 0 ]] || exit 1
rg -q 'remote bytes mismatch after write' "$test_root/mismatch.out"
printf 'PASS mismatch_after_write\n'
printf 'update_repo_file_test: PASS\n'
