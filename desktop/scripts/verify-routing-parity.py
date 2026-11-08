"""Run offline routing scenarios using production Rust configurations."""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("routing_parity", Path(__file__).with_name("routing_parity.py"))
parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parity)


class DecisionUpstream(parity.Upstream):
    decisions = []
    probability = 0.99
    selected = "standard"

    def do_POST(self):
        if self.path != "/v1/systemone":
            type(self).judge_calls = parity.Upstream.judge_calls
            result = super().do_POST()
            parity.Upstream.judge_calls = type(self).judge_calls
            return result
        assert self.headers.get("Authorization") == "Bearer offline-test-key"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        type(self).decisions.append(body)
        answers = {}
        for key, question in body["questions"].items():
            if question["type"] == "noul":
                answers[key] = {"type": "noul", "noul": self.probability}
            elif question["type"] == "choice":
                if "capable" in question["criteria"]:
                    chosen = "capable" if self.probability > 0.6 else "efficient"
                    answers[key] = {"type": "choice", "choice": chosen, "probabilities": {"capable": self.probability, "efficient": 1 - self.probability}}
                else:
                    assert self.selected in question["criteria"]
                    answers[key] = {"type": "choice", "choice": self.selected}
            else:
                raise AssertionError(question)
        data = json.dumps({"id": "offline", "model": "jev-latest", "answers": answers}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def exercise_decisions(server, directory):
    results = []
    previous = os.environ.get("TYPESAFE_API_KEY")
    os.environ["TYPESAFE_API_KEY"] = "offline-test-key"
    try:
        for wire in ["chat", "responses"]:
            for name, probability, selected in [("capability-jev", 0.99, "model-1"), ("capability-jev", 0.01, "model-0"), ("llm_classifier-jev", 0.99, "model-1"), ("composite-jev", 0.99, "model-1")]:
                DecisionUpstream.probability = probability
                DecisionUpstream.decisions = []
                parity.Upstream.calls = []
                with parity.running_server(server, directory / f"{name}.toml") as url:
                    actual = parity.request(url, [{"role": "user", "content": "Implement a bounded change."}], wire)
                assert actual == selected, (name, wire, actual, selected)
                assert DecisionUpstream.decisions, (name, "No decision call")
                assert all(call["model"] != "jev-latest" for call in parity.Upstream.calls)
                results.append({"case": name, "wire": wire, "model": actual, "decisions": len(DecisionUpstream.decisions)})
    finally:
        if previous is None:
            os.environ.pop("TYPESAFE_API_KEY", None)
        else:
            os.environ["TYPESAFE_API_KEY"] = previous
    return results


def main():
    server = ROOT / "desktop/src-tauri/runtime/switchyard-server"
    parity.Upstream.judge_model = "judge-judge-model"
    original_run_case = parity.run_case

    def run_case(*args, **kwargs):
        if args[2] == "random":
            path = args[1] / "random.toml"
            text = path.read_text()
            suffix = '\nweights = [0.0, 1.0]\nseed = 7\n'
            assert text.endswith(suffix)
            path.write_text(text[:-len(suffix)].replace('[routes.main]\n', '[routes.main]\nweights = [0.0, 1.0]\nseed = 7\n'))
        result = original_run_case(*args, **kwargs)
        prompt = kwargs.get("prompt") or (args[7] if len(args) > 7 else None)
        if prompt:
            expected = (parity.PROMPTS / prompt).read_text().strip()
            calls = [call for call in parity.Upstream.calls if call["model"] == parity.Upstream.judge_model]
            assert calls, (result, "No judge call to verify")
            def texts(value):
                if isinstance(value, str):
                    yield value
                elif isinstance(value, dict):
                    for child in value.values():
                        yield from texts(child)
                elif isinstance(value, list):
                    for child in value:
                        yield from texts(child)
            for call in calls:
                assert any(expected in value for value in texts(call)), (result, "Native prompt changed")
        return result

    parity.run_case = run_case
    mock = http.server.ThreadingHTTPServer(("127.0.0.1", 0), DecisionUpstream)
    threading.Thread(target=mock.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="switchyard-rust-parity-") as temporary:
            directory = Path(temporary)
            subprocess.run(["cargo", "run", "--locked", "-p", "switchyard-desktop-core", "--example", "parity-fixtures", "--", temporary], cwd=ROOT / "desktop", check=True)
            for path in directory.glob("*.toml"):
                text = path.read_text().replace("http://127.0.0.1:4101/v1", f"http://127.0.0.1:{mock.server_port}/v1")
                text = text.replace("https://api.typesafe.ai/v1/systemone", f"http://127.0.0.1:{mock.server_port}/v1/systemone")
                path.write_text(text)
                subprocess.run([server, "--config", path, "--dry-run"], check=True, capture_output=True, env={**os.environ, "TYPESAFE_API_KEY": "offline-test-key"})
            results = parity.exercise(server, directory)
            results.extend(exercise_decisions(server, directory))
            print(json.dumps(results, indent=2))
            print(f"{len(results)} Rust-generated routing scenarios passed against the bundled server; no account or external provider used.")
    finally:
        mock.shutdown()
        mock.server_close()


if __name__ == "__main__":
    main()
