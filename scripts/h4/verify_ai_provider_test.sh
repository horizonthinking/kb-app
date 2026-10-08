#!/usr/bin/env bash
# ---
# asset: kuku-verify-openai-provider-test
# type: test-script
# description: Regression-test the live-provider verifier with a local probe server and a request-counting fake cargo.
# owner: michael
# status: active
# ---

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
verifier="$repo_root/scripts/h4/verify_ai_provider.sh"

python3 - "$verifier" "$repo_root" <<'PY'
import hashlib
import http.server
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import threading
import urllib.parse

VERIFIER = pathlib.Path(sys.argv[1])
ROOT = pathlib.Path(sys.argv[2])
STREAMS = "live_streams_text_with_usage_identities"
TOOLS = "live_two_round_tool_call_replays_ids"
MODELS = "live_list_models_contains_the_configured_model_once"
PREFIX = "provider::openai::tests::"
EXPECTED = [PREFIX + STREAMS, PREFIX + TOOLS, PREFIX + MODELS]

FAKE_CARGO = r'''#!/usr/bin/env python3
import json
import os
import pathlib
import sys

STREAMS = "live_streams_text_with_usage_identities"
TOOLS = "live_two_round_tool_call_replays_ids"
MODELS = "live_list_models_contains_the_configured_model_once"
PREFIX = "provider::openai::tests::"
args = sys.argv[1:]
calls = pathlib.Path(os.environ["FAKE_CALLS"])
with calls.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(args) + "\n")
if "--list" in args:
    for name in json.loads(os.environ["FAKE_INVENTORY"]):
        print(f"{name}: test")
    raise SystemExit(0)
if len(args) != 7 or args[:3] != ["test", "-p", "kuku-ai"] or args[4:] != ["--", "--exact", "--nocapture"]:
    raise SystemExit(97)
fq_name = args[3]
if not fq_name.startswith(PREFIX):
    raise SystemExit(98)
name = fq_name.removeprefix(PREFIX)
if name not in [STREAMS, TOOLS, MODELS]:
    raise SystemExit(99)
mode = os.environ.get("FAKE_MODE", "good")
state = pathlib.Path(os.environ["FAKE_STATE"])
index = int(state.read_text() or "0") if state.exists() else 0
state.write_text(str(index + 1))
counts = {STREAMS: [1, 0], TOOLS: [2, 0], MODELS: [0, 1]}
if mode == "chat4": counts[STREAMS] = [2, 0]; counts[TOOLS] = [2, 0]
if mode == "models3": counts[MODELS] = [0, 2]
if mode == "chat2": counts[TOOLS] = [1, 0]
if mode == "models1": counts[MODELS] = [0, 0]
if mode == "wrong_distribution": counts[STREAMS] = [2, 0]; counts[TOOLS] = [1, 0]
log = pathlib.Path(os.environ["KUKU_LIVE_REQUEST_LOG"])
attempt = os.environ["KUKU_LIVE_ATTEMPT"]
fingerprint = os.environ["KUKU_LIVE_CONFIG_FINGERPRINT"]

def current():
    chat = models = 0
    if log.exists():
        for line in log.read_text().splitlines():
            fields = line.split()
            if len(fields) == 5 and fields[2].startswith("config="):
                chat += fields[3] == "chat"
                models += fields[3] == "models"
    return chat, models

def append(kind):
    chat, models = current()
    if (kind == "chat" and chat >= 3) or (kind == "models" and models >= 2):
        print(f"live request ceiling reached before {kind} send: chat={chat} models={models}", file=sys.stderr)
        raise SystemExit(91)
    row_fingerprint = "0" * 64 if mode == "wrong_fingerprint" else fingerprint
    with log.open("a") as handle:
        handle.write(f"2026-09-11T00:00:00Z attempt={attempt} config={row_fingerprint} {kind} {name}\n")
        handle.flush()
        os.fsync(handle.fileno())

for _ in range(counts[name][0]): append("chat")
for _ in range(counts[name][1]): append("models")
if mode == "bad_marker":
    with log.open("a") as handle: handle.write("not-a-valid-marker\n")
ok_limit = {"run_zero": 0, "run_one": 1, "run_two": 2}.get(mode)
if ok_limit is None or index < ok_limit:
    print(f"test {fq_name} ... ok")
if mode == "duplicate_name": print(f"test {fq_name} ... ok")
if mode == "fourth_test": print(f"test {PREFIX}live_fourth_test ... ok")
if mode == "unexpected_name": print("test another::live_unexpected ... ok")
if mode == "skip_line": print("skipped: KUKU_TEST_OPENAI_BASE_URL unset")
if mode != "missing_live_requests":
    print(f"LIVE_REQUESTS attempt={attempt} test={name} chat={counts[name][0]} models={counts[name][1]}")
'''


class Server(http.server.ThreadingHTTPServer):
    def __init__(self, status=200):
        super().__init__(("127.0.0.1", 0), Handler)
        self.status = status
        self.requests = []


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.requests.append({"path": self.path, "authorization": self.headers.get("Authorization")})
        body = b'{"data":[{"id":"fake-model"}]}'
        self.send_response(self.server.status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass


def run_case(name, *, mode="good", inventory=None, key=None, success=False, existing=None, probe_status=200):
    root = pathlib.Path(tempfile.mkdtemp(prefix=f"verify-{name}-"))
    fake_bin = root / "bin"
    fake_bin.mkdir()
    cargo = fake_bin / "cargo"
    cargo.write_text(FAKE_CARGO)
    cargo.chmod(0o755)
    log = root / "requests.log"
    if existing is not None:
        log.write_text(existing)
    server = Server(probe_status)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = os.environ.copy()
    env.update({
        "PATH": str(fake_bin) + os.pathsep + env["PATH"],
        "KUKU_TEST_OPENAI_BASE_URL": f"http://127.0.0.1:{server.server_port}/v1/",
        "KUKU_TEST_OPENAI_MODEL": "fake-model",
        "KUKU_LIVE_REQUEST_LOG": str(log),
        "KUKU_LIVE_RECEIPT": str(root / "receipt.json"),
        "FAKE_CALLS": str(root / "calls.log"),
        "FAKE_STATE": str(root / "state"),
        "FAKE_MODE": mode,
        "FAKE_INVENTORY": json.dumps(EXPECTED if inventory is None else inventory),
    })
    env.pop("KUKU_TEST_OPENAI_API_KEY", None)
    if key is not None:
        env["KUKU_TEST_OPENAI_API_KEY"] = key
    result = subprocess.run([str(VERIFIER)], cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    server.shutdown(); server.server_close(); thread.join(timeout=2)
    if (result.returncode == 0) != success:
        raise AssertionError(f"{name}: expected success={success}, exit={result.returncode}\n{result.stdout}")
    calls_path = root / "calls.log"
    calls = [json.loads(line) for line in calls_path.read_text().splitlines()] if calls_path.exists() else []
    return result, root, list(server.requests), calls


for count in range(3):
    run_case(f"inventory_{count}", inventory=EXPECTED[:count])
run_case("inventory_fourth", inventory=EXPECTED + [PREFIX + "live_fourth_test"])
run_case("inventory_duplicate", inventory=EXPECTED + [EXPECTED[0]])
run_case("inventory_unexpected", inventory=EXPECTED[:2] + ["other::live_unexpected"])
for mode in ["run_zero", "run_one", "run_two", "fourth_test", "duplicate_name", "unexpected_name", "skip_line", "missing_live_requests", "chat4", "models3", "chat2", "models1", "wrong_distribution", "wrong_fingerprint", "bad_marker"]:
    run_case(mode, mode=mode)

existing, _, requests, calls = run_case("verifier_refuses_existing_log", existing="already spent\n")
assert "request log already contains data" in existing.stdout
assert requests == [] and calls == []

probe, _, requests, calls = run_case("probe_failure_stops_before_any_test", probe_status=500)
assert "models probe failed" in probe.stdout
assert len(requests) == 1
assert [call for call in calls if "--list" not in call] == []

clean, clean_root, clean_requests, clean_calls = run_case("clean", success=True)
assert clean_requests == [{"path": "/v1/models", "authorization": None}]
run_calls = [call for call in clean_calls if "--list" not in call]
assert [call[3] for call in run_calls] == EXPECTED
for call in run_calls:
    assert call[:3] == ["test", "-p", "kuku-ai"] and call[4:] == ["--", "--exact", "--nocapture"]
log_bytes = (clean_root / "requests.log").read_bytes()
lines = log_bytes.splitlines(keepends=True)
assert lines[-1].decode().startswith("receipt config=")
prefix = b"".join(lines[:-1])
receipt_fields = dict(field.split("=", 1) for field in lines[-1].decode().strip().split()[1:])
assert receipt_fields["chat"] == "3" and receipt_fields["models"] == "2"
assert receipt_fields["log_sha256"] == hashlib.sha256(prefix).hexdigest()
assert re.fullmatch(r"LIVE_GATE_RECEIPT chat=3 models=2 attempts=[0-9a-f,-]+", clean.stdout.splitlines()[-1])
receipt = json.loads((clean_root / "receipt.json").read_text())
assert receipt["log_sha256"] == receipt_fields["log_sha256"]
assert receipt["chat"] == 3 and receipt["models"] == 2 and len(receipt["attempts"]) == 4

keyed, _, keyed_requests, _ = run_case("keyed", key="secret-test-key", success=True)
assert keyed_requests == [{"path": "/v1/models", "authorization": "Bearer secret-test-key"}]
assert "secret-test-key" not in keyed.stdout

vectors = json.loads((ROOT / "scripts/h4/fixtures/live_gate_fingerprint_vectors.json").read_text())
for vector in vectors:
    parsed = urllib.parse.urlsplit(vector["base_url"].strip())
    host = parsed.hostname.lower()
    if ":" in host: host = f"[{host}]"
    port = f":{parsed.port}" if parsed.port is not None else ""
    path = parsed.path.rstrip("/") or "/v1"
    base = f"{parsed.scheme.lower()}://{host}{port}{path}"
    key = (vector.get("api_key") or "").strip()
    key_hash = hashlib.sha256(key.encode()).hexdigest() if key else "none"
    canonical = f"kuku-live-gate/1\n{base}\n{vector['model']}\n{vector['verifier_sha256'].lower()}\n{key_hash}\n"
    assert hashlib.sha256(canonical.encode()).hexdigest() == vector["expected"]

source = VERIFIER.read_text()
rust_source = (ROOT / "crates/kuku-ai/src/provider/openai.rs").read_text()
assert not re.search(r"RELEASE_H4_[A-Z_]*LIVE_GATE", source)
assert not re.search(r"RELEASE_H4_[A-Z_]*LIVE_GATE", rust_source)
assert "refuses_send_on_missing_or_mismatched_fingerprint" in rust_source
assert "chat >= 3" in rust_source and "models >= 2" in rust_source
print("verify_ai_provider_test: PASS")
PY
