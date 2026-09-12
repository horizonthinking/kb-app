#!/usr/bin/env bash
# ---
# asset: kuku-application-smoke-test
# type: test-script
# description: Exercise Kuku application smoke success, restoration, process-path refusal, timeout, missing-tool, and shared-vector cases.
# owner: michael
# status: active
# ---

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
smoke="$repo_root/scripts/h4/smoke_kuku_app.sh"
real_b3sum=$(command -v b3sum 2>/dev/null || true)
[[ -n "$real_b3sum" ]] || real_b3sum=/private/tmp/kuku-wave3-b3sum/bin/b3sum
[[ -x "$real_b3sum" ]] || {
  printf 'smoke_kuku_app_test: b3sum unavailable\n' >&2
  exit 1
}

run_case() {
  local name=$1 mode=${2:-happy} originals=${3:-present}
  local root home fake app output status
  root=$(mktemp -d "/private/tmp/smoke-${name}.XXXXXX")
  home="$root/home"
  fake="$root/bin"
  app="$root/Kuku.app"
  mkdir -p "$home/.kuku/plugins/core-indexer" "$home/.kuku/search" "$fake" "$app/Contents/MacOS"
  if [[ "$originals" == present ]]; then
    printf '{"existing":true}\n' >"$home/.kuku/settings.json"
    printf '{"existingIndexer":true}\n' >"$home/.kuku/plugins/core-indexer/settings.json"
  fi
  cp "$real_b3sum" "$fake/b3sum"
  for command in open pgrep pkill ps sqlite3 screencapture mv sleep; do
    printf '#!/usr/bin/env bash\nexec %q %q "$@"\n' "$repo_root/scripts/h4/smoke_kuku_app_test.sh" "$command" >"$fake/$command"
    chmod +x "$fake/$command"
  done
  set +e
  output=$(HOME="$home" PATH="$fake:/usr/bin:/bin" FAKE_SMOKE_ROOT="$root" FAKE_SMOKE_MODE="$mode" FAKE_APP="$app" KUKU_SMOKE_POLL_SECONDS=2 KUKU_SMOKE_LAUNCH_POLLS=2 KUKU_SMOKE_EXIT_POLLS=2 "$smoke" --app "$app" 2>&1)
  status=$?
  set -e
  if [[ "$mode" == happy || "$mode" == absent ]]; then
    [[ $status -eq 0 ]] || { printf '%s\n' "$output" >&2; exit 1; }
    [[ "$output" == *"SMOKE index_count=1"* ]] || exit 1
  else
    [[ $status -ne 0 ]] || { printf '%s unexpectedly succeeded\n' "$name" >&2; exit 1; }
  fi
  if [[ "$mode" == restore_fail ]]; then
    [[ "$output" == *"restoration failed"* ]] || exit 1
  elif [[ "$originals" == present ]]; then
    [[ $(cat "$home/.kuku/settings.json") == '{"existing":true}' ]] || exit 1
    [[ $(cat "$home/.kuku/plugins/core-indexer/settings.json") == '{"existingIndexer":true}' ]] || exit 1
  else
    [[ ! -e "$home/.kuku/settings.json" && ! -e "$home/.kuku/plugins/core-indexer/settings.json" ]] || exit 1
  fi
  if [[ "$mode" != restore_fail ]]; then
    [[ -z $(find "$home/.kuku/search" -type f -print -quit) ]] || exit 1
  fi
  printf 'PASS %s\n' "$name"
}

if [[ "${1:-}" == "open" || "${1:-}" == "pgrep" || "${1:-}" == "pkill" || "${1:-}" == "ps" || "${1:-}" == "sqlite3" || "${1:-}" == "screencapture" || "${1:-}" == "mv" || "${1:-}" == "sleep" ]]; then
  command=$1
  shift
  python3 - "$command" "$@" <<'PY'
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys

command = sys.argv[1]
args = sys.argv[2:]
root = pathlib.Path(os.environ["FAKE_SMOKE_ROOT"])
mode = os.environ.get("FAKE_SMOKE_MODE", "happy")
running = root / "running"
if command == "open":
    running.write_text("4242")
    settings = json.loads((pathlib.Path.home() / ".kuku/settings.json").read_text())
    vault = str(pathlib.Path(settings["last_opened_vault"]).resolve())
    b3sum = shutil.which("b3sum")
    digest = subprocess.check_output([b3sum, "--no-names"], input=vault.encode()).decode().strip()
    db = pathlib.Path.home() / ".kuku/search" / f"{digest}.sqlite3"
    db.touch()
elif command == "pgrep":
    if running.exists(): print("4242")
    else: raise SystemExit(1)
elif command == "pkill":
    running.unlink(missing_ok=True)
elif command == "ps":
    if mode == "outside": print("/Applications/Other.app/Contents/MacOS/Kuku")
    else: print(os.environ["FAKE_APP"] + "/Contents/MacOS/Kuku")
elif command == "sqlite3":
    print("0" if mode == "never_one" else "1")
elif command == "screencapture":
    pathlib.Path(args[-1]).touch()
elif command == "mv":
    source, target = pathlib.Path(args[-2]), pathlib.Path(args[-1])
    if mode == "restore_fail" and ".restore." in source.name:
        raise SystemExit(1)
    os.replace(source, target)
elif command == "sleep":
    pass
PY
  exit
fi

run_case happy happy present
run_case index_count_never_one never_one present
run_case executable_outside_bundle outside present
run_case absent_original_settings absent absent
run_case restoration_failure_is_fatal restore_fail present

empty_root=$(mktemp -d /private/tmp/smoke-missing-b3.XXXXXX)
mkdir -p "$empty_root/Kuku.app"
set +e
missing_output=$(HOME="$empty_root" PATH=/usr/bin:/bin "$smoke" --app "$empty_root/Kuku.app" 2>&1)
missing_status=$?
set -e
[[ $missing_status -ne 0 && "$missing_output" == *"b3sum missing; run brew install b3sum"* ]] || exit 1
printf 'PASS b3sum_missing_refused\n'

python3 - "$repo_root/apps/desktop/src-tauri/fixtures/search_db_path_vectors.json" "$real_b3sum" <<'PY'
import json
import subprocess
import sys

for vector in json.load(open(sys.argv[1], encoding="utf-8")):
    observed = subprocess.check_output([sys.argv[2], "--no-names"], input=vector["canonical_path"].encode()).decode().strip()
    assert observed == vector["expected_hex"], (vector, observed)
print("PASS vector_file_derivation")
PY
printf 'smoke_kuku_app_test: PASS\n'
