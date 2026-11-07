"""Offline native helper smoke. Never invokes Claude Code or reads user credentials."""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def read_message(process):
    ready, _, _ = select.select([process.stdout], [], [], 10)
    if not ready:
        raise RuntimeError("Native Claude helper did not respond within 10 seconds")
    line = process.stdout.readline()
    if not line:
        raise RuntimeError("Native Claude helper exited without a response")
    return json.loads(line)


def main():
    if sys.platform != "darwin":
        raise SystemExit("The staged native Claude helper currently targets macOS only")
    runtime = ROOT / "desktop/src-tauri/runtime"
    if (runtime / "switchyard-source.json").read_bytes() != (ROOT / "vendor/switchyard-source.json").read_bytes():
        raise SystemExit("Runtime snapshot mismatch")
    with tempfile.TemporaryDirectory(prefix="switchyard-claude-smoke-") as temporary:
        sandbox = Path(temporary)
        config = sandbox / "switchyard.toml"
        config.write_text('''schema_version = 1
[llm_clients.claude]
format = "anthropic_messages"
base_url = "http://127.0.0.1:1"
[targets.native]
id = "claude-test-offline"
llm_client = "claude"
[routes.claude]
id = "switchyard"
type = "passthrough"
target = "native"
''')
        environment = dict(os.environ, HOME=str(sandbox), USERPROFILE=str(sandbox),
                           CLAUDE_CONFIG_DIR=str(sandbox / "claude"), TMPDIR=str(sandbox))
        process = subprocess.Popen([runtime / "claude-plugin/bin/switchyard-claude", config],
                                   cwd=sandbox, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        try:
            directory = Path(read_message(process)["dir"])
            if directory.parent != sandbox:
                raise RuntimeError("Native helper created a directory outside the sandbox")
            request = {"session_id": "offline-smoke", "messages": [{"role": "user", "content": [{"type": "text", "text": "offline test"}]}]}
            (directory / "req-1.json").write_text(json.dumps(request))
            reply = read_message(process)
            if reply.get("model") != "claude-test-offline" or reply.get("error"):
                raise RuntimeError(f"Unexpected routing result: {reply}")
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=5)
            deadline = time.monotonic() + 2
            while directory.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            if directory.exists():
                raise RuntimeError("Native helper did not clean its private directory")
            template = (ROOT / "vendor/switchyard/examples/claude/switchyard.toml").read_text()
            config.write_text(template)
            process = subprocess.Popen([runtime / "claude-plugin/bin/switchyard-claude", config],
                                       cwd=sandbox, env=environment, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       text=True, start_new_session=True)
            directory = Path(read_message(process)["dir"])
            if directory.parent != sandbox:
                raise RuntimeError("Composite helper escaped the sandbox")
            (directory / "req-1.json").write_text(json.dumps(request))
            classifier = read_message(process)
            if classifier.get("id") != 1 or "classifier" not in classifier:
                raise RuntimeError(f"Expected native classifier delegation, received {classifier}")
            reply_file = directory / f'judge-1-{classifier["call"]}.json'
            reply_file.write_text(json.dumps({"text": json.dumps({"decision": {"target": "capable"}})}))
            reply = read_message(process)
            if reply.get("target") != "capable" or reply.get("algorithm") != "composite" or reply.get("error"):
                raise RuntimeError(f"Composite routing did not accept native classifier reply: {reply}")
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=5)
            if directory.exists():
                raise RuntimeError("Composite helper did not clean its private directory")
            print("Native Claude helper: passthrough, Composite native-classifier roundtrip, sandbox paths and cleanup passed")
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()


if __name__ == "__main__":
    main()
