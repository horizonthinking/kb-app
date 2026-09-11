#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
verifier="$repo_root/scripts/h4/verify_ai_provider.sh"

python3 - "$verifier" "$repo_root" <<'PY'
import http.server
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import threading

VERIFIER = pathlib.Path(sys.argv[1])
REPO_ROOT = pathlib.Path(sys.argv[2])
LIVE_STREAMS = "live_streams_text_with_usage_identities"
LIVE_TOOLS = "live_two_round_tool_call_replays_ids"
LIVE_MODELS = "live_list_models_contains_the_configured_model_once"
PREFIX = "provider::openai::tests::"
EXPECTED = [PREFIX + LIVE_STREAMS, PREFIX + LIVE_TOOLS, PREFIX + LIVE_MODELS]

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
    print(f"fake cargo rejected argv: {json.dumps(args)}", file=sys.stderr)
    raise SystemExit(97)
fq_name = args[3]
if not fq_name.startswith(PREFIX):
    print(f"fake cargo rejected non-qualified test: {fq_name}", file=sys.stderr)
    raise SystemExit(98)
name = fq_name.removeprefix(PREFIX)
if name not in [STREAMS, TOOLS, MODELS]:
    print(f"fake cargo rejected unexpected test: {name}", file=sys.stderr)
    raise SystemExit(99)

state = pathlib.Path(os.environ["FAKE_STATE"])
run_index = int(state.read_text(encoding="utf-8") or "0") if state.exists() else 0
state.write_text(str(run_index + 1), encoding="utf-8")
mode = os.environ.get("FAKE_MODE", "good")
counts = {
    STREAMS: [1, 0],
    TOOLS: [2, 0],
    MODELS: [0, 1],
}
if mode == "chat4":
    counts[STREAMS] = [2, 0]
elif mode == "models3":
    counts[MODELS] = [0, 2]
elif mode == "chat2":
    counts[STREAMS] = [0, 0]
elif mode == "models1":
    counts[MODELS] = [0, 0]
elif mode == "wrong_distribution":
    counts[STREAMS] = [2, 0]
    counts[TOOLS] = [1, 0]
elif mode == "fail_tl2" and name == TOOLS:
    counts[TOOLS] = [1, 0]

log_path = pathlib.Path(os.environ["KUKU_LIVE_REQUEST_LOG"])
attempt = os.environ["KUKU_LIVE_ATTEMPT"]

def cumulative():
    chat = 0
    models = 0
    if log_path.exists():
        for line in log_path.read_text(encoding="utf-8").splitlines():
            fields = line.split()
            if len(fields) >= 4 and fields[1].startswith("attempt="):
                chat += fields[2] == "chat"
                models += fields[2] == "models"
    return chat, models

def append_request(kind):
    chat, models = cumulative()
    if (kind == "chat" and chat >= 6) or (kind == "models" and models >= 4):
        print(f"live request ceiling reached before {kind} send: chat={chat} models={models}", file=sys.stderr)
        raise SystemExit(91)
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(f"2026-09-11T00:00:00Z attempt={attempt} {kind} {name}\n")
        handle.flush()
        os.fsync(handle.fileno())

chat, models = counts[name]
for _ in range(chat):
    append_request("chat")
for _ in range(models):
    append_request("models")

if mode == "fail_tl2" and name == TOOLS:
    print(f"test {fq_name} ... FAILED")
    raise SystemExit(1)

ok_limit = {"run_zero": 0, "run_one": 1, "run_two": 2}.get(mode)
show_ok = ok_limit is None or run_index < ok_limit
if show_ok:
    print(f"test {fq_name} ... ok")
if mode == "duplicate_name":
    print(f"test {fq_name} ... ok")
elif mode == "fourth_test":
    print(f"test {PREFIX}live_fourth_test ... ok")
elif mode == "unexpected_name":
    print("test another::module::live_unexpected_test ... ok")
if mode == "skip_line":
    print("skipped: KUKU_TEST_OPENAI_BASE_URL unset")
if mode != "missing_live_requests":
    print(f"LIVE_REQUESTS attempt={attempt} test={name} chat={chat} models={models}")
raise SystemExit(0)
'''


class ProbeServer(http.server.ThreadingHTTPServer):
    def __init__(self, address):
        super().__init__(address, ProbeHandler)
        self.requests = []


class ProbeHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.requests.append(
            {"path": self.path, "authorization": self.headers.get("Authorization")}
        )
        body = b'{"data":[{"id":"fake-model"}]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass


def seed_line(log_path, line):
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def run_case(
    name,
    *,
    mode="good",
    inventory=None,
    key=None,
    expected_success=False,
    seed=None,
    renew=False,
    paths=None,
):
    if paths is None:
        root = pathlib.Path(tempfile.mkdtemp(prefix=f"verify-{name}-"))
        fake_dir = root / "bin"
        fake_dir.mkdir()
        fake_cargo = fake_dir / "cargo"
        fake_cargo.write_text(FAKE_CARGO, encoding="utf-8")
        fake_cargo.chmod(0o755)
        paths = {
            "root": root,
            "fake_dir": fake_dir,
            "log": root / "requests.log",
            "receipt": root / "receipt",
            "calls": root / "calls.log",
            "state": root / "state",
        }
        if seed:
            for line in seed:
                seed_line(paths["log"], line)

    server = ProbeServer(("127.0.0.1", 0))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = os.environ.copy()
    env.update(
        {
            "PATH": str(paths["fake_dir"]) + os.pathsep + env["PATH"],
            "KUKU_TEST_OPENAI_BASE_URL": f"http://127.0.0.1:{server.server_port}/v1/",
            "KUKU_TEST_OPENAI_MODEL": "fake-model",
            "KUKU_LIVE_REQUEST_LOG": str(paths["log"]),
            "KUKU_LIVE_RECEIPT": str(paths["receipt"]),
            "FAKE_CALLS": str(paths["calls"]),
            "FAKE_STATE": str(paths["state"]),
            "FAKE_MODE": mode,
            "FAKE_INVENTORY": json.dumps(EXPECTED if inventory is None else inventory),
            "TMPDIR": str(paths["root"]),
        }
    )
    for variable in ["KUKU_TEST_OPENAI_API_KEY", "RELEASE_H4_RENEW_LIVE_GATE"]:
        env.pop(variable, None)
    if key is not None:
        env["KUKU_TEST_OPENAI_API_KEY"] = key
    if renew:
        env["RELEASE_H4_RENEW_LIVE_GATE"] = "1"
    result = subprocess.run(
        [str(VERIFIER)],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=20,
    )
    server.shutdown()
    server.server_close()
    thread.join(timeout=2)
    if (result.returncode == 0) != expected_success:
        raise AssertionError(
            f"{name}: expected success={expected_success}, exit={result.returncode}\n{result.stdout}"
        )
    return result, paths, list(server.requests)


def cargo_run_calls(paths):
    if not paths["calls"].exists():
        return []
    calls = [json.loads(line) for line in paths["calls"].read_text(encoding="utf-8").splitlines()]
    return [call for call in calls if "--list" not in call]


def parse_receipt(path):
    line = path.read_text(encoding="utf-8").strip()
    match = re.fullmatch(r"LIVE_GATE_RECEIPT chat=(\d+) models=(\d+) attempts=([0-9A-Za-z,._-]+)", line)
    assert match is not None, line
    return int(match.group(1)), int(match.group(2)), match.group(3).split(","), line


for count in range(3):
    run_case(f"inventory_{count}", inventory=EXPECTED[:count])
run_case("inventory_fourth", inventory=EXPECTED + [PREFIX + "live_fourth_test"])
run_case("inventory_duplicate", inventory=EXPECTED + [EXPECTED[0]])
run_case("inventory_unexpected", inventory=EXPECTED[:2] + ["another::module::live_unexpected_test"])
run_case("inventory_explicit_extra", inventory=EXPECTED + ["another::module::live_extra_test"])

for mode in [
    "run_zero",
    "run_one",
    "run_two",
    "fourth_test",
    "duplicate_name",
    "unexpected_name",
    "skip_line",
    "missing_live_requests",
    "chat4",
    "models3",
    "chat2",
    "models1",
    "wrong_distribution",
]:
    run_case(mode, mode=mode)

clean, clean_paths, clean_requests = run_case("clean", expected_success=True)
assert len(clean_requests) == 1, clean_requests
assert clean_requests[0] == {"path": "/v1/models", "authorization": None}
clean_chat, clean_models, _, clean_receipt = parse_receipt(clean_paths["receipt"])
assert (clean_chat, clean_models) == (3, 2)
assert clean_receipt in clean.stdout.splitlines()
clean_calls = cargo_run_calls(clean_paths)
assert len(clean_calls) == 3, clean_calls
for call, name in zip(clean_calls, [LIVE_STREAMS, LIVE_MODELS, LIVE_TOOLS]):
    assert call == ["test", "-p", "kuku-ai", PREFIX + name, "--", "--exact", "--nocapture"], call

keyed, _, keyed_requests = run_case("keyed", key="secret-test-key", expected_success=True)
assert len(keyed_requests) == 1, keyed_requests
assert keyed_requests[0] == {
    "path": "/v1/models",
    "authorization": "Bearer secret-test-key",
}
assert "secret-test-key" not in keyed.stdout

first, renewal_paths, first_requests = run_case("renewal_first", mode="fail_tl2")
assert len(first_requests) == 1
first_run_calls = cargo_run_calls(renewal_paths)
assert [call[3] for call in first_run_calls] == [
    PREFIX + LIVE_STREAMS,
    PREFIX + LIVE_MODELS,
    PREFIX + LIVE_TOOLS,
]
before_refusal = renewal_paths["log"].read_text(encoding="utf-8")
refused, _, refused_requests = run_case("renewal_refused", paths=renewal_paths)
assert "live provider verification failed: live gate incomplete; set RELEASE_H4_RENEW_LIVE_GATE=1 to authorize a new paid run" in refused.stdout.splitlines()
assert refused_requests == []
assert renewal_paths["log"].read_text(encoding="utf-8") == before_refusal
calls_before_renewal = len(cargo_run_calls(renewal_paths))
renewed, _, renewed_requests = run_case(
    "renewal_authorized", paths=renewal_paths, renew=True, expected_success=True
)
assert renewed_requests == []
new_calls = cargo_run_calls(renewal_paths)[calls_before_renewal:]
assert [call[3] for call in new_calls] == [PREFIX + LIVE_TOOLS], new_calls
renewed_chat, renewed_models, receipt_attempts, receipt = parse_receipt(renewal_paths["receipt"])
assert (renewed_chat, renewed_models) == (4, 2)
assert receipt in renewed.stdout.splitlines()
request_log = renewal_paths["log"].read_text(encoding="utf-8")
failed_tool_attempts = {
    field.removeprefix("attempt=")
    for line in request_log.splitlines()
    if line.endswith(" chat " + LIVE_TOOLS)
    for field in line.split()
    if field.startswith("attempt=")
}
assert len(failed_tool_attempts) == 2, failed_tool_attempts
for attempt in failed_tool_attempts:
    assert receipt_attempts.count(attempt) == 1, (attempt, receipt_attempts)

probe_seed = [
    f"2026-09-11T00:00:0{index}Z attempt=probe-ceiling-{index} models old"
    for index in range(4)
]
probe_ceiling, _, probe_ceiling_requests = run_case(
    "probe_ceiling", seed=probe_seed, renew=True
)
assert "live provider verification failed: live request ceiling reached before models probe: chat=0 models=4" in probe_ceiling.stdout.splitlines()
assert probe_ceiling_requests == []

wrapper_seed = [
    "2026-09-11T00:00:00Z attempt=probe-ok models verifier_probe",
    "probe attempt=probe-ok",
    f"2026-09-11T00:00:01Z attempt=streams-ok chat {LIVE_STREAMS}",
    f"completed attempt=streams-ok {LIVE_STREAMS}",
    f"2026-09-11T00:00:02Z attempt=models-ok models {LIVE_MODELS}",
    f"completed attempt=models-ok {LIVE_MODELS}",
] + [
    f"2026-09-11T00:00:{10 + index:02d}Z attempt=failed-{index} chat old"
    for index in range(5)
]
wrapper_ceiling, wrapper_paths, wrapper_requests = run_case(
    "wrapper_ceiling", seed=wrapper_seed, renew=True
)
assert "live request ceiling reached before chat send: chat=6 models=2" in wrapper_ceiling.stdout.splitlines()
assert wrapper_requests == []
assert sum(" chat " in line for line in wrapper_paths["log"].read_text(encoding="utf-8").splitlines()) == 6
wrapper_calls = cargo_run_calls(wrapper_paths)
assert [call[3] for call in wrapper_calls] == [PREFIX + LIVE_TOOLS], wrapper_calls

print("verify_ai_provider_test: all rejection, clean-run, header, and renewal cases passed")
PY
