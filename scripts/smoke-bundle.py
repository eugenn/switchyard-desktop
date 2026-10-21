#!/usr/bin/env python3
"""Exercise the packaged gateway and server offline using a local mock provider."""
import http.server
import importlib.util
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

app = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parent.parent
runtime = app / 'Contents/Resources/LiteLLM'
spec = importlib.util.spec_from_file_location('routing_parity', root / 'scripts/verify-routing-parity.py')
parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parity)

def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def ready(process, url):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for _ in range(180):
        if process.poll() is not None:
            raise RuntimeError(f'Server exited: {process.returncode}')
        try:
            with opener.open(url, timeout=0.5) as response:
                if response.status == 200:
                    return json.loads(response.read())
        except (OSError, ValueError):
            pass
        time.sleep(0.25)
    raise RuntimeError(f'Server readiness timed out: {url}')

with tempfile.TemporaryDirectory(prefix='switchyard-desktop-smoke-') as directory, \
        http.server.ThreadingHTTPServer(('127.0.0.1', 0), parity.Upstream) as upstream:
    threading.Thread(target=upstream.serve_forever, daemon=True).start()
    work = Path(directory)
    llm_port, sy_port = port(), port()
    config = work / 'litellm.yaml'
    config.write_text(json.dumps({'model_list': [{'model_name': 'smoke-efficient', 'litellm_params': {'model': 'openai/smoke-efficient', 'api_key': 'offline-smoke-key', 'api_base': f'http://127.0.0.1:{upstream.server_port}/v1'}}]}))
    sy_config = work / 'routes.toml'
    sy_config.write_text((root / 'configs/switchyard/smoke.toml').read_text().replace('127.0.0.1:1/v1', f'127.0.0.1:{llm_port}/v1'))
    environment = {'HOME': directory, 'PATH': '/usr/bin:/bin', 'LITELLM_LOCAL_MODEL_COST_MAP': 'True', 'LITELLM_TELEMETRY': 'False'}
    children = []
    with (work / 'servers.log').open('w+') as log:
        try:
            llm = subprocess.Popen([str(runtime / 'bin/python3.12'), '-I', '-u', str(runtime / 'launcher.py'), '--config', str(config), '--host', '127.0.0.1', '--port', str(llm_port)], cwd=directory, env=environment, stdout=log, stderr=log)
            children.append(llm)
            ready(llm, f'http://127.0.0.1:{llm_port}/health/liveliness')
            routing_log = work / 'routing-log.jsonl'
            sy = subprocess.Popen([str(app / 'Contents/Helpers/switchyard-server'), '--config', str(sy_config), '--host', '127.0.0.1', '--port', str(sy_port), '--routing-log-file', str(routing_log)], cwd=directory, env=environment, stdout=log, stderr=log)
            children.append(sy)
            models = ready(sy, f'http://127.0.0.1:{sy_port}/v1/models')
            assert any(item['id'] == 'switchyard-desktop' for item in models['data'])
            assert models['models'] == [], 'Discovery must preserve Codex catalog and instructions'
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            for stream in (False, True):
                request = urllib.request.Request(
                    f'http://127.0.0.1:{sy_port}/v1/responses',
                    json.dumps({'model': 'switchyard-desktop', 'stream': stream,
                                'input': [{'role': 'user', 'content': 'Offline bundle integration check.'}]}).encode(),
                    {'Content-Type': 'application/json', 'x-switchyard-origin': 'codex-cli',
                     'x-switchyard-session-id': 'bundle-smoke'},
                )
                with opener.open(request, timeout=30) as response:
                    body = response.read().decode()
                    if not stream:
                        assert json.loads(body).get('model') == 'smoke-efficient'
                    if stream:
                        assert 'text/event-stream' in response.headers['Content-Type']
                        assert 'response.completed' in body and 'Done.' in body
                        assert 'response.failed' not in body
                    else:
                        payload = json.loads(body)
                        assert payload['status'] == 'completed'
                        assert payload['output'][0]['content'][0]['text'] == 'Done.'
            with opener.open(f'http://127.0.0.1:{sy_port}/v1/stats', timeout=5) as response:
                stats = json.load(response)
            assert stats['total_requests'] == 2 and stats['total_errors'] == 0, stats
            records = [json.loads(line) for line in routing_log.read_text().splitlines()]
            assert len(records) == 2, records
            assert all(record['origin'] == 'codex-cli' for record in records), records
            assert len(parity.Upstream.calls) == 2
            print('Packaged LiteLLM and Switchyard: discovery, buffered/streaming Responses, stats and routing log passed with a temporary HOME and local mock provider.')
        except Exception:
            log.flush()
            log.seek(0)
            print(log.read()[-6000:], file=sys.stderr)
            raise
        finally:
            upstream.shutdown()
            for process in reversed(children):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
