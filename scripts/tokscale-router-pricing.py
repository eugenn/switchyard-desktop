#!/usr/bin/env python3
"""Teach tokscale what a routed Codex turn actually cost.

Codex records the route label it was configured with -- `switchyard-desktop`,
`switchyard/codex-auto` -- and never the model Switchyard picked for the turn,
so tokscale finds no authoritative price for that label and submits the usage
at $0.00 with the day marked cost-incomplete.

This writes one `custom-pricing.json` entry per route label, which tokscale
consults before every other pricing source:

  passthrough route -> its single target's rates, copied verbatim (exact)
  routing route     -> per-bucket rates weighted by the tokens each target
                       actually served, read from Switchyard's routing log
                       (an estimate, only as representative as the log)

Buckets are weighted the way tokscale's own Codex parser splits a turn:
cached prompt tokens are billed at the cache-read rate, the rest of the prompt
at the input rate, and the whole completion (reasoning included) at the output
rate.

Re-run this after upstream model prices change, after a route's targets change,
and whenever the routing log has grown; then re-run `tokscale submit` so the
days that went out cost-incomplete are resubmitted with a real cost.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import tomllib

HOME = Path.home()

# Configurations this machine routes through. Every one is optional: a missing
# path is skipped, so the same defaults work before and after either router is
# set up.
DEFAULT_ROUTES = [
    HOME / 'Library/Application Support/switchyard-desktop/routes.toml',
    HOME / 'Projects/personal/NVIDIA/scratch/codex-claude-router/routes.toml',
]
DEFAULT_LOGS = [
    HOME / 'Library/Application Support/switchyard-desktop/routing-log.jsonl',
    HOME / 'Projects/personal/NVIDIA/scratch/codex-claude-router/routing.jsonl',
]

PER_MILLION = 1_000_000.0

# tokscale's `pricing --json` bucket names, and the custom-pricing.json field
# each one is written back as.
BUCKETS = {
    'input': ('inputCostPerToken', 'input_cost_per_million_tokens'),
    'output': ('outputCostPerToken', 'output_cost_per_million_tokens'),
    'cache_read': (
        'cacheReadInputTokenCost',
        'cache_read_input_token_cost_per_million_tokens',
    ),
    'cache_write': (
        'cacheCreationInputTokenCost',
        'cache_creation_input_token_cost_per_million_tokens',
    ),
}


def config_dir():
    """Where tokscale keeps custom-pricing.json, using its own resolution order."""
    override = os.environ.get('TOKSCALE_CONFIG_DIR')
    if override:
        return Path(override)
    xdg = os.environ.get('XDG_CONFIG_HOME')
    if xdg:
        return Path(xdg) / 'tokscale'
    return HOME / '.config/tokscale'


def tokscale_command(explicit):
    """The tokscale that resolves upstream prices and reads back the result.

    Defaults to the published CLI rather than a binary on PATH: the rates
    written here have to be the ones the tokscale that submits would have used,
    and an installed binary can be several majors behind both the pricing data
    and custom-pricing support itself.
    """
    if explicit:
        return explicit.split()
    return ['npx', '-y', 'tokscale@latest']


def load_routes(path):
    """Map every route id in a Switchyard config to the models it can serve.

    Returns `{route_id: (kind, [model_id, ...])}`, where a `passthrough` route
    carries exactly one model and any other route carries its candidates. The
    target *names* used by a route are resolved to the model ids Switchyard
    sends upstream, which are the ids tokscale prices.
    """
    with path.open('rb') as handle:
        config = tomllib.load(handle)

    targets = {
        name: entry['id']
        for name, entry in config.get('targets', {}).items()
        if isinstance(entry, dict) and 'id' in entry
    }

    routes = {}
    for name, route in config.get('routes', {}).items():
        if not isinstance(route, dict) or 'id' not in route:
            continue
        kind = route.get('type', '')
        if kind == 'passthrough':
            names = [route.get('target')]
        else:
            names = list(route.get('targets') or [])
            names += [route.get('capable_target'), route.get('efficient_target')]
            names += list(route.get('models', {}).get('any') or [])
            names.append(route.get('default_target'))
        # The classifier's own target is deliberately kept: its turns are billed
        # to the same route in the log, so its tokens belong in the mix.
        names.append(route.get('classifier_target'))

        models = []
        for target_name in names:
            model = targets.get(target_name)
            if model and model not in models:
                models.append(model)
        if not models:
            print(f'  ! {path.name}: route {name} has no resolvable target', file=sys.stderr)
            continue
        if kind == 'passthrough' and len(models) > 1:
            kind = 'routing'
        routes[route['id']] = (kind, models)
    return routes


def load_log(path):
    """Read one Switchyard routing log into per-label, per-model bucket sums."""
    mix = {}
    skipped = 0
    for line in path.read_text(encoding='utf-8', errors='replace').splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            skipped += 1
            continue
        label = row.get('route_id')
        model = row.get('model')
        if not label or not model:
            # Pre-`route_id` Switchyard builds, and rows written before a route
            # was resolved. Nothing attributes them to a label, so they are not
            # evidence about any label's mix.
            skipped += 1
            continue

        prompt = max(int(row.get('prompt_tokens') or 0), 0)
        cached = max(int(row.get('cached_tokens') or 0), 0)
        cached = min(cached, prompt)
        per_model = mix.setdefault(label, {}).setdefault(
            model, {'input': 0, 'output': 0, 'cache_read': 0, 'cache_write': 0, 'rows': 0}
        )
        per_model['input'] += prompt - cached
        per_model['cache_read'] += cached
        # `reasoning_tokens` is a subset of `completion_tokens` here, exactly as
        # in Codex's own snapshots, and tokscale prices both at the output rate.
        per_model['output'] += max(int(row.get('completion_tokens') or 0), 0)
        per_model['cache_write'] += max(int(row.get('cache_creation_tokens') or 0), 0)
        per_model['rows'] += 1
    return mix, skipped


def merge_mix(into, other):
    for label, models in other.items():
        target = into.setdefault(label, {})
        for model, buckets in models.items():
            existing = target.setdefault(
                model, {'input': 0, 'output': 0, 'cache_read': 0, 'cache_write': 0, 'rows': 0}
            )
            for key, value in buckets.items():
                existing[key] += value


class Prices:
    """Per-token rates for one model, as tokscale itself resolves them."""

    def __init__(self, command):
        self.command = command
        self.cache = {}

    def get(self, model):
        if model in self.cache:
            return self.cache[model]
        result = subprocess.run(
            self.command + ['pricing', model, '--json'],
            capture_output=True,
            text=True,
        )
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError:
            raise SystemExit(
                f'{" ".join(self.command)} pricing {model} --json failed:\n'
                f'{result.stdout}{result.stderr}'
            )
        if 'pricing' not in payload:
            raise SystemExit(
                f'tokscale has no price for {model}: {payload.get("error", payload)}.\n'
                'Add it to custom-pricing.json by hand, then re-run.'
            )
        rates = {
            bucket: payload['pricing'].get(json_key)
            for bucket, (json_key, _) in BUCKETS.items()
        }
        self.cache[model] = rates
        return rates


def blend(models, prices):
    """Token-weighted rate per bucket across the models a label actually used.

    Weighting each bucket by its own tokens is what makes the total right: the
    cache-read rate is the average over cached tokens, not over all tokens, so
    the label's cost over the logged period equals the sum of the real
    per-model costs. A model that publishes no rate for a bucket is dropped
    from that bucket only, and its weight is renormalized away.
    """
    rates = {}
    notes = []
    fallback_weight = {
        model: sum(buckets[bucket] for bucket in BUCKETS) for model, buckets in models.items()
    }
    for bucket in BUCKETS:
        weighted = 0.0
        total = 0.0
        missing = []
        for model, buckets in models.items():
            rate = prices.get(model)[bucket]
            weight = buckets[bucket]
            if rate is None:
                if weight:
                    missing.append(model)
                continue
            weighted += rate * weight
            total += weight
        if total > 0:
            rates[bucket] = weighted / total
        else:
            # The logged turns never touched this bucket (Codex writes no cache
            # -creation tokens at all). A future turn still might, and a bucket
            # a custom entry omits makes tokscale call the whole entry
            # incomplete, so fall back to weighting by each model's share of
            # every logged token.
            weighted = 0.0
            total = 0.0
            for model, buckets in models.items():
                rate = prices.get(model)[bucket]
                if rate is None:
                    continue
                weighted += rate * fallback_weight[model]
                total += fallback_weight[model]
            if total > 0:
                rates[bucket] = weighted / total
        if missing:
            notes.append(f'no {bucket} rate published for {", ".join(sorted(missing))}')
    return rates, notes


def entry_for(rates):
    entry = {}
    for bucket, (_, field) in BUCKETS.items():
        rate = rates.get(bucket)
        if rate is None:
            continue
        entry[field] = float(f'{rate * PER_MILLION:.10g}')
    return entry


def describe_mix(models):
    total = sum(sum(buckets[bucket] for bucket in BUCKETS) for buckets in models.values())
    parts = []
    for model, buckets in sorted(
        models.items(), key=lambda item: -sum(item[1][bucket] for bucket in BUCKETS)
    ):
        share = sum(buckets[bucket] for bucket in BUCKETS) / total * 100 if total else 0.0
        parts.append(f'{model} {share:.0f}% ({buckets["rows"]} turns)')
    return ', '.join(parts)


def logged_cost(models, prices):
    """What the logged turns cost at real per-model rates, as a sanity check."""
    total = 0.0
    for model, buckets in models.items():
        rates = prices.get(model)
        for bucket in BUCKETS:
            rate = rates[bucket]
            if rate:
                total += rate * buckets[bucket]
    return total


def main():
    parser = argparse.ArgumentParser(
        description='Write tokscale custom pricing for Switchyard route labels.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        '--routes',
        action='append',
        type=Path,
        help='Switchyard routes.toml (repeatable). Defaults to the switchyard-desktop '
        'and manual-experiment configs.',
    )
    parser.add_argument(
        '--routing-log',
        action='append',
        type=Path,
        help='Switchyard routing log JSONL (repeatable). Defaults to the logs '
        'written beside those configs.',
    )
    parser.add_argument(
        '--label',
        action='append',
        default=[],
        metavar='LABEL=MODEL[,MODEL...]',
        help='Price a label whose route config is gone, or override one that is '
        'not. One model prices it exactly; several are blended from the log.',
    )
    parser.add_argument('--out', type=Path, help='custom-pricing.json to update.')
    parser.add_argument(
        '--tokscale',
        help='tokscale command (default: npx -y tokscale@latest; pass an installed '
        'binary to skip the download, if it is current enough to read custom pricing).',
    )
    parser.add_argument('--dry-run', action='store_true', help='Print the entries, write nothing.')
    args = parser.parse_args()

    route_paths = args.routes if args.routes is not None else DEFAULT_ROUTES
    log_paths = args.routing_log if args.routing_log is not None else DEFAULT_LOGS
    out_path = args.out or (config_dir() / 'custom-pricing.json')
    command = tokscale_command(args.tokscale)

    routes = {}
    for path in route_paths:
        if not path.exists():
            print(f'  - no route config at {path}')
            continue
        found = load_routes(path)
        routes.update(found)
        print(f'  + {len(found)} routes from {path}')

    for override in args.label:
        label, _, models = override.partition('=')
        models = [model.strip() for model in models.split(',') if model.strip()]
        if not label or not models:
            raise SystemExit(f'--label expects LABEL=MODEL[,MODEL...], got {override!r}')
        routes[label] = ('passthrough' if len(models) == 1 else 'routing', models)

    mix = {}
    for path in log_paths:
        if not path.exists():
            print(f'  - no routing log at {path}')
            continue
        found, skipped = load_log(path)
        merge_mix(mix, found)
        rows = sum(buckets['rows'] for models in found.values() for buckets in models.values())
        note = f', {skipped} unattributable rows skipped' if skipped else ''
        print(f'  + {rows} routed turns from {path}{note}')

    if not routes:
        raise SystemExit('No route configs found. Pass --routes or --label.')

    prices = Prices(command)
    entries = {}
    print()
    for label, (kind, models) in sorted(routes.items()):
        observed = mix.get(label, {})
        if kind == 'passthrough':
            model = models[0]
            entries[label] = entry_for(prices.get(model))
            print(f'{label}\n  exact: always {model}')
            continue
        if not observed:
            print(
                f'{label}\n  ! skipped: no routed turns for this label in any log. '
                f'Run switchyard-server with --routing-log-file, or pass '
                f'--label {label}=<model>.'
            )
            continue
        unknown = sorted(set(observed) - set(models))
        if unknown:
            print(f'{label}\n  ! log names targets the config does not: {", ".join(unknown)}')
        else:
            print(label)
        rates, notes = blend(observed, prices)
        if rates.get('input') is None or rates.get('output') is None:
            print('  ! skipped: no input/output rate could be blended')
            continue
        entries[label] = entry_for(rates)
        print(f'  blended: {describe_mix(observed)}')
        print(f'  logged turns cost ${logged_cost(observed, prices):.2f} at real per-model rates')
        for note in notes:
            print(f'  ! {note}')

    if not entries:
        raise SystemExit('\nNothing to write.')

    bucket_of = {field: bucket for bucket, (_, field) in BUCKETS.items()}
    print('\nEntries ($ per million tokens):')
    for label, entry in sorted(entries.items()):
        rates = ' '.join(f'{bucket_of[field]}={value:g}' for field, value in entry.items())
        print(f'  {label}: {rates}')

    if args.dry_run:
        print(f'\nDry run: {out_path} left unchanged.')
        return

    existing = {'models': {}}
    if out_path.exists():
        try:
            existing = json.loads(out_path.read_text(encoding='utf-8'))
        except json.JSONDecodeError as error:
            raise SystemExit(f'{out_path} is not valid JSON ({error}); refusing to overwrite it.')
        if not isinstance(existing.get('models'), dict):
            raise SystemExit(f'{out_path} has no "models" object; refusing to overwrite it.')
        backup = out_path.with_suffix(f'.json.bak-{time.strftime("%Y%m%dT%H%M%S")}')
        shutil.copy2(out_path, backup)
        print(f'\nBacked up {out_path} to {backup}')

    # Only the labels this script owns are replaced; every other entry in the
    # file is the user's and survives untouched.
    existing['models'].update(entries)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    temp = out_path.with_suffix('.json.tmp')
    temp.write_text(json.dumps(existing, indent=2) + '\n', encoding='utf-8')
    os.replace(temp, out_path)
    print(f'Wrote {len(entries)} entries to {out_path}')

    print('\nVerifying:')
    for label in sorted(entries):
        result = subprocess.run(
            command + ['pricing', label, '--json'], capture_output=True, text=True
        )
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError:
            print(f'  ? {label}: could not read tokscale output')
            continue
        source = payload.get('source', 'none')
        if source.lower() == 'custom':
            print(f'  ok: {label}')
        else:
            print(
                f'  NOT custom ({source}): {label} -- this tokscale does not read '
                f'{out_path}; it is likely too old.'
            )

    print('\nRe-run `tokscale submit` to resubmit the cost-incomplete days with a real cost.')


if __name__ == '__main__':
    main()
