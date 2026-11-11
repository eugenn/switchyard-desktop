#!/usr/bin/env python3
"""Restore the real provider and model on Codex turns routed through Switchyard.

A Codex session pointed at Switchyard records the route label it was
configured with (`model_provider = "switchyard-desktop"`,
`model = "switchyard-desktop"`) and never the model Switchyard picked for each
response. tokscale therefore reports those responses as
`switchyard-desktop/switchyard-desktop`, finds no price, and submits them at
$0.00 with the day marked cost-incomplete.

Switchyard's routing log has one row per upstream response with the agent
(Codex thread) id, the model that served it and its exact token counts. This
script matches every Codex `token_count` / `token_usage_record` to its row and
rewrites the rollout so tokscale attributes it to the real model:

  session_meta.model_provider             label -> --provider (openai)
  thread_settings.model_provider_id/model label -> --provider / turn's model
  token_count.info.model                  set to the matched model
  token_usage_record.model                set to the matched model
  turn_context.model, collaboration model label -> first model of the turn

A response with no log row (the log was cleared or written by another build)
takes the model of the nearest matched response in the same rollout, or
--fallback-model when nothing in the rollout matched. The report says how each
response was resolved. Classifier calls Switchyard made on its own are not in
Codex's rollout, so they are not added.

Dry-run by default. `--apply` first copies every file it changes into
--backup-dir (same relative path), then replaces the original atomically.
Re-running after `--apply` finds nothing to do, because the provider is no
longer the route label; restore from the backup to redo it.
After applying, re-run `tokscale submit` to resubmit the affected days.
"""
import argparse
import bisect
import collections
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HOME = Path.home()
APP_SUPPORT = (
    Path(os.environ['LOCALAPPDATA']) if sys.platform == 'win32' and 'LOCALAPPDATA' in os.environ
    else HOME / 'Library/Application Support'
)
# Every routing log a Switchyard build on this machine has written. Missing
# files are skipped. Rows are matched by Codex thread id and exact token
# counts, so reading a log that never served a session cannot misattribute it.
DEFAULT_LOGS = [
    APP_SUPPORT / 'switchyard-desktop/cross-platform/routing-log.jsonl',
    APP_SUPPORT / 'switchyard-desktop/routing-log.jsonl',
    APP_SUPPORT / 'ModelRouter/routing-log.jsonl',
    APP_SUPPORT / 'Viaro/routing-log.jsonl',
]


def parse_ts(value):
    try:
        return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (AttributeError, ValueError):
        return None


def usage_key(usage):
    """(input, output) identifies one response; cached/reasoning break ties."""
    if not isinstance(usage, dict):
        return None
    try:
        return (int(usage.get('input_tokens') or 0), int(usage.get('output_tokens') or 0),
                int(usage.get('cached_input_tokens') or 0),
                int(usage.get('reasoning_output_tokens') or 0))
    except (TypeError, ValueError):
        return None


class RoutingLog:
    def __init__(self, paths):
        self.rows = collections.defaultdict(list)  # agent id -> rows
        self.sources = []
        seen = set()
        for path in paths:
            if not path.is_file():
                continue
            count = 0
            with path.open(encoding='utf-8', errors='replace') as handle:
                for line in handle:
                    try:
                        row = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if 'outcome' in row or row.get('tier') == 'classifier' or not row.get('model'):
                        continue
                    agent = row.get('agent_id') or row.get('session_id')
                    key = (agent, row.get('ts'), row.get('prompt_tokens'), row.get('completion_tokens'))
                    if not agent or key in seen:
                        continue
                    seen.add(key)
                    row['_used'] = False
                    row['_ts'] = parse_ts(row.get('ts'))
                    self.rows[agent].append(row)
                    count += 1
            self.sources.append((path, count))

    def take(self, agent, usage, timestamp):
        """Consume the closest unused row for this response, or return None."""
        if usage is None:
            return None
        best = None
        for row in self.rows.get(agent, ()):
            if row['_used']:
                continue
            if (row.get('prompt_tokens'), row.get('completion_tokens')) != usage[:2]:
                continue
            exact = (row.get('cached_tokens') or 0) == usage[2]
            gap = abs((row['_ts'] or 0) - (timestamp or 0)) if timestamp and row['_ts'] else 1e12
            score = (not exact, gap)
            if best is None or score < best[0]:
                best = (score, row)
        if best is None:
            return None
        best[1]['_used'] = True
        return best[1]['model']


def read_lines(path):
    if path.suffix == '.zst':
        data = subprocess.run(['zstd', '-dcq', str(path)], check=True, capture_output=True).stdout
    else:
        data = path.read_bytes()
    return data.decode('utf-8').splitlines(keepends=True)


def write_lines(path, lines):
    data = ''.join(lines).encode('utf-8')
    if path.suffix == '.zst':
        data = subprocess.run(['zstd', '-q', '-c', '-19'], input=data, check=True,
                              capture_output=True).stdout
    mode = path.stat().st_mode
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix='.' + path.name + '.')
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode & 0o7777)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def session_provider(lines):
    for line in lines[:50]:
        if '"session_meta"' not in line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            return None
        if entry.get('type') == 'session_meta':
            return (entry.get('payload') or {}).get('model_provider')
    return None


def dump(entry):
    return json.dumps(entry, ensure_ascii=False, separators=(',', ':')) + '\n'


def repair(path, lines, args, log, replays):
    """Return (new lines, per-response resolutions) for one routed rollout."""
    entries = []
    for line in lines:
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            entries.append(None)

    agent = None
    for entry in entries:
        if entry and entry.get('type') == 'session_meta':
            agent = (entry.get('payload') or {}).get('id')
            break

    # Pass 1: resolve every response in file order.
    responses = []  # (index, kind, model or None)
    pending = None  # (usage key, model) from a token_usage_record awaiting its token_count
    last_total, last_model = None, None
    for index, entry in enumerate(entries):
        if not entry:
            continue
        payload = entry.get('payload') or {}
        timestamp = parse_ts(entry.get('timestamp'))
        if entry.get('type') == 'token_usage_record':
            key = usage_key(payload.get('usage'))
            model = log.take(agent, key, timestamp)
            pending = (key, model)
            responses.append([index, 'record', model, 'log' if model else None])
        elif entry.get('type') == 'event_msg' and payload.get('type') == 'token_count' \
                and isinstance(payload.get('info'), dict):
            info = payload['info']
            key = usage_key(info.get('last_token_usage'))
            total = usage_key(info.get('total_token_usage'))
            model, how = None, None
            if total and total in replays:
                model, how = replays[total], 'replay'
            elif total and total == last_total:
                # Codex re-emits the same snapshot (e.g. around compaction);
                # it is the same response, so it must not consume a log row.
                model, how = last_model, 'repeat' if last_model else None
            elif pending and pending[0] == key:
                model, how = pending[1], 'log' if pending[1] else None
            else:
                model = log.take(agent, key, timestamp)
                how = 'log' if model else None
            pending = None
            last_total, last_model = total, model
            responses.append([index, 'count', model, how])

    # Pass 2: fill gaps from the nearest matched response, then the fallback.
    matched = [i for i, r in enumerate(responses) if r[2]]
    for i, response in enumerate(responses):
        if response[2]:
            continue
        if matched:
            at = bisect.bisect_left(matched, i)
            near = min((matched[j] for j in (at - 1, at) if 0 <= j < len(matched)),
                       key=lambda j: abs(j - i))
            response[2], response[3] = responses[near][2], 'nearest'
        else:
            response[2], response[3] = args.fallback_model, 'fallback'

    by_index = {r[0]: r for r in responses}
    turn_models = {}  # turn_context index -> first model after it
    current_turn = None
    first_model = responses[0][2] if responses else args.fallback_model
    for index, entry in enumerate(entries):
        if entry and entry.get('type') == 'turn_context':
            current_turn = index
        elif index in by_index and current_turn is not None and current_turn not in turn_models:
            turn_models[current_turn] = by_index[index][2]

    # Pass 3: rewrite.
    label = args.label
    out = list(lines)
    last_turn_model = first_model
    for index, entry in enumerate(entries):
        if not entry:
            continue
        payload = entry.get('payload')
        if not isinstance(payload, dict):
            continue
        changed = False
        kind = entry.get('type')
        if kind == 'session_meta' and payload.get('model_provider') == label:
            payload['model_provider'] = args.provider
            changed = True
        elif kind == 'turn_context':
            last_turn_model = turn_models.get(index, last_turn_model)
            if payload.get('model') == label:
                payload['model'] = last_turn_model
                changed = True
            settings = (payload.get('collaboration_mode') or {}).get('settings')
            if isinstance(settings, dict) and settings.get('model') == label:
                settings['model'] = last_turn_model
                changed = True
        elif kind == 'world_state':
            state = payload.get('state')
            if isinstance(state, dict) and state.get('model') == label:
                state['model'] = last_turn_model
                changed = True
        elif kind == 'event_msg' and payload.get('type') == 'thread_settings_applied':
            settings = payload.get('thread_settings')
            if isinstance(settings, dict):
                if settings.get('model_provider_id') == label:
                    settings['model_provider_id'] = args.provider
                    changed = True
                if settings.get('model') == label:
                    settings['model'] = last_turn_model
                    changed = True
        if index in by_index:
            _, which, model, _ = by_index[index]
            target = payload['info'] if which == 'count' else payload
            if target.get('model') != model:
                target['model'] = model
                changed = True
            if which == 'count':
                total = usage_key(payload['info'].get('total_token_usage'))
                if total:
                    replays.setdefault(total, model)
        if changed:
            out[index] = dump(entry)
    return out, responses


def find_rollouts(codex_home):
    for folder in ('sessions', 'archived_sessions'):
        root = codex_home / folder
        if root.is_dir():
            for path in sorted(root.rglob('rollout-*')):
                if path.name.endswith(('.jsonl', '.jsonl.zst')):
                    yield path


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--codex-home', type=Path,
                        default=Path(os.environ.get('CODEX_HOME', HOME / '.codex')))
    parser.add_argument('--routing-log', type=Path, action='append',
                        help='routing log to read (repeatable; default: every known Switchyard log)')
    parser.add_argument('--label', default='switchyard-desktop',
                        help='route label Codex recorded as provider and model')
    parser.add_argument('--provider', default='openai',
                        help='provider that actually served the routed models')
    parser.add_argument('--fallback-model', default='gpt-6.1-sol',
                        help="model for a rollout with no log row at all (the route's efficient target)")
    parser.add_argument('--apply', action='store_true', help='rewrite the rollouts (default: dry run)')
    parser.add_argument('--backup-dir', type=Path,
                        help='where originals are copied before --apply '
                             '(default: <codex-home>/usage-repair-backup-<timestamp>)')
    parser.add_argument('--report', type=Path, help='write a JSON report here')
    args = parser.parse_args()

    log = RoutingLog(args.routing_log or DEFAULT_LOGS)
    for path, count in log.sources:
        print(f'log  {count:6d} responses  {path}')
    if not log.sources:
        print('warning: no routing log found; every response will use --fallback-model')

    stamp = dt.datetime.now().strftime('%Y%m%dT%H%M%S')
    backup_dir = args.backup_dir or args.codex_home / f'usage-repair-backup-{stamp}'
    replays = {}
    totals = collections.Counter()
    by_model = collections.defaultdict(collections.Counter)
    report = []
    changed_files = 0

    for path in find_rollouts(args.codex_home):
        try:
            lines = read_lines(path)
        except (OSError, subprocess.CalledProcessError, UnicodeDecodeError) as error:
            print(f'skip {path}: {error}', file=sys.stderr)
            continue
        if session_provider(lines) != args.label:
            continue
        new_lines, responses = repair(path, lines, args, log, replays)
        counts = [r for r in responses if r[1] == 'count']
        how = collections.Counter(r[3] for r in counts)
        models = collections.Counter(r[2] for r in counts)
        totals.update(how)
        for r in counts:
            by_model[r[2]][r[3]] += 1
        rel = path.relative_to(args.codex_home)
        print(f'{rel}: {len(counts)} responses  ' +
              ' '.join(f'{k}={v}' for k, v in sorted(how.items())) + '  ' +
              ', '.join(f'{m} x{n}' for m, n in models.most_common()))
        report.append({'file': str(rel), 'resolution': dict(how), 'models': dict(models)})
        if new_lines == lines:
            continue
        changed_files += 1
        if args.apply:
            target = backup_dir / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
            write_lines(path, new_lines)

    print()
    print(f'{len(report)} routed rollout(s), {sum(totals.values())} responses: ' +
          ', '.join(f'{k}={v}' for k, v in sorted(totals.items())))
    for model, how in sorted(by_model.items()):
        print(f'  {args.provider}/{model}: ' + ', '.join(f'{k}={v}' for k, v in sorted(how.items())))
    if args.report:
        args.report.write_text(json.dumps({'files': report, 'resolution': dict(totals)}, indent=2))
    if args.apply:
        print(f'rewrote {changed_files} file(s); originals in {backup_dir}')
        print('next: tokscale submit')
    else:
        print(f'dry run: {changed_files} file(s) would change; re-run with --apply')


if __name__ == '__main__':
    main()
