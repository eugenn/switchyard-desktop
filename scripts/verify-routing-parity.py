#!/usr/bin/env python3
"""Exercise production Swift configurations against the bundled Switchyard, offline.

Optional --reference-server runs the same cases through the original server.
Only disposable loopback ports and temporary files are used. No provider calls.
"""
import argparse
import contextlib
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
PROMPTS = ROOT / 'vendor/switchyard/crates/libsy/src/prompts'


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class Upstream(http.server.BaseHTTPRequestHandler):
    calls = []
    judge_calls = 0
    verdicts = []
    judge_model = 'judge-model'

    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.calls.append(body)
        text = 'Done.'
        if body['model'] == self.judge_model:
            type(self).judge_calls += 1
            verdict = self.verdicts.pop(0) if self.verdicts else 'APPROVE'
            text = verdict if isinstance(verdict, str) else json.dumps(verdict)
        response = {
            'id': f'resp_{len(self.calls)}', 'object': 'response', 'created_at': 1,
            'status': 'completed', 'model': body['model'],
            'output': [{'id': 'msg_1', 'type': 'message', 'role': 'assistant',
                        'status': 'completed', 'content': [{'type': 'output_text', 'text': text, 'annotations': []}]}],
            'usage': {'input_tokens': 10, 'output_tokens': 5, 'total_tokens': 15},
        }
        self.send_response(200)
        if body.get('stream'):
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            events = [
                {'type': 'response.created', 'response': {**response, 'status': 'in_progress', 'output': []}},
                {'type': 'response.output_item.added', 'output_index': 0,
                 'item': {**response['output'][0], 'status': 'in_progress', 'content': []}},
                {'type': 'response.content_part.added', 'output_index': 0, 'content_index': 0,
                 'item_id': 'msg_1', 'part': {'type': 'output_text', 'text': '', 'annotations': []}},
                {'type': 'response.output_text.delta', 'output_index': 0, 'content_index': 0,
                 'item_id': 'msg_1', 'delta': text},
                {'type': 'response.output_text.done', 'output_index': 0, 'content_index': 0,
                 'item_id': 'msg_1', 'text': text},
                {'type': 'response.output_item.done', 'output_index': 0, 'item': response['output'][0]},
                {'type': 'response.completed', 'response': response},
            ]
            for index, event in enumerate(events):
                event['sequence_number'] = index
                self.wfile.write(f'event: {event["type"]}\ndata: {json.dumps(event)}\n\n'.encode())
        else:
            data = json.dumps(response).encode()
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)


@contextlib.contextmanager
def running_server(binary, config):
    listen = port()
    with tempfile.TemporaryFile() as log:
        process = subprocess.Popen([str(binary), '--config', str(config), '--host', '127.0.0.1',
                                    '--port', str(listen)], stdout=log, stderr=log)
        try:
            url = f'http://127.0.0.1:{listen}'
            for _ in range(200):
                if process.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(log.read().decode())
                try:
                    urllib.request.urlopen(url + '/v1/models', timeout=1).close()
                    break
                except (OSError, urllib.error.URLError):
                    time.sleep(0.025)
            else:
                raise RuntimeError('Server did not become ready')
            yield url
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def request(url, messages, wire='chat', session='same-session', subagent=False):
    headers = {'Content-Type': 'application/json'}
    if session:
        headers['x-switchyard-session-id'] = session
    if subagent:
        headers['x-switchyard-is-subagent'] = 'true'
    body = {'model': 'switchyard-desktop', 'stream': False}
    if wire == 'chat':
        body['messages'] = messages
        endpoint = '/v1/chat/completions'
    else:
        endpoint = '/v1/responses'
        items = []
        for message in messages:
            if message.get('tool_calls'):
                for call in message['tool_calls']:
                    items.append({'type': 'function_call', 'call_id': call['id'], **call['function']})
            elif message['role'] == 'tool':
                items.append({'type': 'function_call_output', 'call_id': message['tool_call_id'],
                              'output': message['content']})
            else:
                items.append(message)
        body['input'] = items
    req = urllib.request.Request(url + endpoint, json.dumps(body).encode(), headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            data = json.load(response)
            return data.get('model')
    except urllib.error.HTTPError as error:
        raise RuntimeError(f'{error.code}: {error.read().decode()}') from error


def tool(name, output, index=1, arguments=None):
    return [{'role': 'assistant', 'content': None, 'tool_calls': [
        {'id': f'call_{index}', 'type': 'function', 'function': {
            'name': name, 'arguments': json.dumps(arguments or {})}}]},
        {'role': 'tool', 'tool_call_id': f'call_{index}', 'content': output}]


def forecast(probability):
    return {'crux': 'Implement and verify the requested change.', 'primary_rule': 'SUP-1',
            'capability_boundary': 'supported', 'p_solve': probability}


def run_case(binary, directory, name, histories, expected, verdicts=(), judge_count=0,
             prompt=None, wire='chat', session='same-session', subagent=False):
    Upstream.calls = []
    Upstream.judge_calls = 0
    Upstream.verdicts = list(verdicts)
    with running_server(binary, directory / f'{name}.toml') as url:
        actual = [request(url, history, wire, session, subagent) for history in histories]
    assert actual == expected, (name, wire, actual, expected)
    assert Upstream.judge_calls == judge_count, (name, 'judge calls', Upstream.judge_calls, judge_count)
    if prompt:
        original = (PROMPTS / prompt).read_text().strip()
        for call in Upstream.calls:
            if call['model'] != 'judge-model':
                continue
            # JSON roundtrip avoids escaping differences when inspecting the
            # actual wire request. The complete native prompt must reach it.
            def texts(value):
                if isinstance(value, str):
                    yield value
                elif isinstance(value, dict):
                    for child in value.values():
                        yield from texts(child)
                elif isinstance(value, list):
                    for child in value:
                        yield from texts(child)
            assert any(original in value for value in texts(call)), (name, 'native prompt changed')
    if name == 'stage-target-prompts':
        for call in Upstream.calls:
            model = call['model']
            expected_prompt = ('Efficient target: follow the settled plan.' if model == 'model-0'
                               else 'Capable target: diagnose before editing.')
            assert expected_prompt in json.dumps(call), (name, model, 'target prompt lost')
    if name in ('plan_execute', 'plan-execute-custom-tool'):
        planning_prompt = (PROMPTS / 'plan-execute/planning-system-prompt.md').read_text().strip()
        for call in Upstream.calls:
            instructions = call.get('instructions', '')
            assert (planning_prompt in instructions) == (call['model'] == 'model-1'), (
                name, call['model'], 'planning instructions do not match the serving phase')
    return {'case': name, 'wire': wire, 'models': actual, 'judge_calls': Upstream.judge_calls}


def exercise(binary, directory):
    opening = [{'role': 'user', 'content': 'Implement the change and run its tests.'}]
    continuation = opening + tool('read_file', 'File contents.')
    followup = continuation + [{'role': 'user', 'content': 'Now investigate the concurrency failure.'}]
    fatal = opening + tool('exec_command', 'fatal runtime error: out of memory')
    # Inspection can return source/log text that describes a failure. Only the
    # executed failing command should escalate the production Stage/Auto route.
    failure_text = 'fatal runtime error: out of memory'
    retrieved = opening + tool('exec_command', failure_text, arguments={'cmd': 'cat error.log'})
    executed_failure = opening + tool('exec_command', failure_text, arguments={'cmd': 'python app.py'})
    recovered = list(fatal)
    for i in range(2, 7):
        recovered += tool('apply_patch' if i % 2 == 0 else 'exec_command', '10 passed', i)
    results = []
    for wire in ('chat', 'responses'):
        for trigger, models, calls in [
            ('every_request', ['model-0', 'model-1', 'model-0'], 3),
            ('user_turn', ['model-0', 'model-0', 'model-1'], 2),
            ('new_session', ['model-0'] * 3, 1),
        ]:
            results.append(run_case(binary, directory, f'custom-{trigger}',
                [opening, continuation, followup], models,
                [{'decision': {'target': name}} for name in ['direct', 'standard', 'direct']], calls,
                wire=wire))
        for name in ('stage_router', 'auto'):
            results.append(run_case(binary, directory, name, [opening, fatal, recovered],
                                    ['model-0', 'model-1', 'model-0'], wire=wire))
            results.append(run_case(binary, directory, name, [opening, retrieved, executed_failure],
                                    ['model-0', 'model-0', 'model-1'], wire=wire))
        for name, mutation in [('plan_execute', 'apply_patch'),
                               ('plan-execute-custom-tool', 'update_inventory')]:
            results.append(run_case(binary, directory, name,
                [opening, continuation, opening + tool(mutation, 'Updated.'), opening],
                ['model-1', 'model-1', 'model-0', 'model-0'], wire=wire))
        results.append(run_case(binary, directory, 'capability', [opening, continuation, followup],
            ['model-0', 'model-1', 'model-0'], [forecast(.95), forecast(.05), forecast(.95)], 3,
            'capability-classifier/prompt.md', wire))
        results.append(run_case(binary, directory, 'composite', [opening, fatal, recovered, followup],
            ['model-0', 'model-1', 'model-0', 'model-1'], [forecast(.95), forecast(.05)], 2,
            'capability-classifier/prompt.md', wire))
        results.append(run_case(binary, directory, 'escalation', [opening, continuation, followup],
            ['model-0', 'model-1', 'model-1'],
            [{'escalate': True, 'category': 'repetition', 'new_evidence': True,
              'reason': 'The newest tool result repeats the failure.'}] * 2, 2,
            'escalation/prompt.md', wire))
        # Old evidence must not latch the route even when the judge asks to escalate.
        results.append(run_case(binary, directory, 'escalation', [opening, continuation, followup],
            ['model-0'] * 3,
            [{'escalate': True, 'category': 'repetition', 'new_evidence': False,
              'reason': 'Only an earlier failure is present.'}] * 3, 3,
            'escalation/prompt.md', wire))
        results.append(run_case(binary, directory, 'advisor', [opening], ['model-0'], ['APPROVE'], 1,
            'advisor-gate/reviewer-system-prompt.md', wire))
        results.append(run_case(binary, directory, 'passthrough', [opening, continuation],
                                ['model-0', 'model-0'], wire=wire))
    for trigger in ('user_turn', 'new_session'):
        results.append(run_case(binary, directory, f'custom-{trigger}', [opening, continuation],
            ['model-0', 'model-1'], [{'decision': {'target': 'direct'}},
                                    {'decision': {'target': 'standard'}}], 2, session=None))
    results.append(run_case(binary, directory, 'custom-every_request', [opening, continuation],
        ['model-1', 'model-0'], ['not valid JSON', {'decision': {'target': 'direct'}}], 2))
    results.append(run_case(binary, directory, 'stage-classifier', [opening, fatal],
        ['model-0', 'model-1'], [forecast(.95)], 1, 'capability-classifier/prompt.md'))
    results.append(run_case(binary, directory, 'stage-subagents', [opening], ['model-0']))
    results.append(run_case(binary, directory, 'stage-subagents', [opening], ['worker-model'], subagent=True))
    results.append(run_case(binary, directory, 'stage-target-prompts', [opening, fatal, recovered],
                            ['model-0', 'model-1', 'model-0']))
    # Seed and weights exercise the actual random route, without probabilistic assertions.
    random_path = directory / 'random.toml'
    random_path.write_text(random_path.read_text() + '\nweights = [0.0, 1.0]\nseed = 7\n')
    results.append(run_case(binary, directory, 'random', [opening] * 3, ['model-1'] * 3))
    random_path.write_text(random_path.read_text().split('\nweights =')[0])
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', type=Path, default=ROOT / 'build/switchyard-target/release/switchyard-server')
    parser.add_argument('--reference-server', type=Path)
    args = parser.parse_args()
    subprocess.run(['python3', str(ROOT / 'scripts/update-switchyard.py'), '--verify'], check=True)
    mock = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
    threading.Thread(target=mock.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='switchyard-desktop-parity-') as temporary:
            directory = Path(temporary)
            env = {**os.environ, 'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer',
                   'SWITCHYARD_DESKTOP_PARITY_FIXTURES': str(directory),
                   'SWITCHYARD_DESKTOP_TEST_SERVER': str(args.server.resolve()),
                   'SWITCHYARD_DESKTOP_PARITY_UPSTREAM': f'http://127.0.0.1:{mock.server_port}/v1'}
            result = subprocess.run(['swift', 'test', '--filter', 'nativeRoutingFixtures'],
                                    cwd=ROOT, env=env, capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
            actual = exercise(args.server.resolve(), directory)
            if args.reference_server:
                reference = exercise(args.reference_server.resolve(), directory)
                assert actual == reference, 'Bundled and original server decisions differ'
            print(json.dumps(actual, indent=2))
            print(f'{len(actual)} routing scenarios passed; native prompts verified on the wire.')
    finally:
        mock.shutdown()
        mock.server_close()


if __name__ == '__main__':
    main()
