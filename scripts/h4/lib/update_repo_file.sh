#!/usr/bin/env bash
# ---
# asset: kuku-release-repository-file-update
# type: release-script
# description: Atomically create or update one GitHub repository file from an audited local source and verify the committed bytes.
# owner: michael
# status: active
# ---

set -euo pipefail

repo=${1:-}
remote_path=${2:-}
local_file=${3:-}
[[ -n "$repo" && -n "$remote_path" && -f "$local_file" && $# -eq 3 ]] || {
  printf 'usage: update_repo_file.sh <owner/repo> <remote-path> <local-file>\n' >&2
  exit 2
}

gh_cmd=${GH:-gh}
script_path=${BASH_SOURCE[0]}
repo_root=$(git -C "$(dirname "$script_path")" rev-parse --show-toplevel)
for audited_path in "$script_path" "$local_file"; do
  [[ "${UPDATE_REPO_FILE_TEST_MODE:-0}" == 1 ]] && continue
  relative=${audited_path#"$repo_root"/}
  tracked_hash=$(git -C "$repo_root" rev-parse "HEAD:$relative" 2>/dev/null) || {
    printf 'update_repo_file: %s is not tracked at HEAD\n' "$relative" >&2
    exit 1
  }
  observed_hash=$(git -C "$repo_root" hash-object "$audited_path")
  [[ "$tracked_hash" == "$observed_hash" ]] || {
    printf 'update_repo_file: modified bytes refused: %s\n' "$relative" >&2
    exit 1
  }
done

work_root=$(mktemp -d "${TMPDIR:-/private/tmp}/kuku-repo-file.XXXXXX")
trap 'rm -rf "$work_root"' EXIT
before_json="$work_root/before.json"
after_json="$work_root/after.json"
payload="$work_root/payload.json"

remote_sha=
if "$gh_cmd" api "repos/$repo/contents/$remote_path" >"$before_json" 2>"$work_root/read.err"; then
  remote_sha=$(python3 - "$before_json" "$work_root/remote" <<'PY'
import base64, json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
open(sys.argv[2], "wb").write(base64.b64decode(value["content"]))
print(value["sha"])
PY
  )
  if cmp -s "$local_file" "$work_root/remote"; then
    printf 'UPDATE_REPO_FILE unchanged repo=%s path=%s commit=%s\n' "$repo" "$remote_path" "$remote_sha"
    exit 0
  fi
elif ! rg -q 'HTTP 404|not found' "$work_root/read.err"; then
  cat "$work_root/read.err" >&2
  exit 1
fi

python3 - "$local_file" "$remote_path" "$remote_sha" >"$payload" <<'PY'
import base64, json, sys
source, path, sha = sys.argv[1:]
payload = {
    "message": f"docs: update {path}",
    "content": base64.b64encode(open(source, "rb").read()).decode(),
}
if sha:
    payload["sha"] = sha
json.dump(payload, sys.stdout, separators=(",", ":"))
PY
"$gh_cmd" api --method PUT "repos/$repo/contents/$remote_path" --input "$payload" >"$work_root/write.json"
"$gh_cmd" api "repos/$repo/contents/$remote_path" >"$after_json"
commit_sha=$(python3 - "$after_json" "$work_root/verified" <<'PY'
import base64, json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
open(sys.argv[2], "wb").write(base64.b64decode(value["content"]))
print(value.get("commit_sha", value["sha"]))
PY
)
cmp -s "$local_file" "$work_root/verified" || {
  printf 'update_repo_file: remote bytes mismatch after write: %s/%s\n' "$repo" "$remote_path" >&2
  exit 1
}
printf 'UPDATE_REPO_FILE updated repo=%s path=%s commit=%s\n' "$repo" "$remote_path" "$commit_sha"
