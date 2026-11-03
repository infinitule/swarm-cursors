#!/usr/bin/env python3
"""Small action-selection benchmark; never controls any application."""
import argparse
import json
import pathlib
import statistics
import time
import urllib.request

root = pathlib.Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--model', default='qwen3.5:0.8b')
parser.add_argument('--output', required=True)
parser.add_argument('--think', action='store_true')
args = parser.parse_args()
schema = json.loads((root / 'action-schema.json').read_text())
system = (root / 'planner-system.txt').read_text()
results = []
for case in json.loads((root / 'tests/cases.json').read_text()):
    payload = dict(model=args.model, system=system,
                   prompt=json.dumps({k: case[k] for k in ('goal', 'ui')}),
                   format=schema, stream=False, think=args.think, keep_alive='10m',
                   options=dict(temperature=0, num_ctx=8192, num_predict=768 if args.think else 160))
    start = time.perf_counter()
    row = dict(name=case['name'], expected=case['expected'])
    try:
        request = urllib.request.Request('http://127.0.0.1:11434/api/generate',
            data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=120) as response:
            data = json.load(response)
        answer = json.loads(data['response'])
        row.update(answer=answer, passed=all(answer.get(k) == v for k, v in case['expected'].items()),
            load_seconds=data.get('load_duration', 0) / 1e9,
            tokens_per_second=data.get('eval_count', 0) / max(data.get('eval_duration', 0) / 1e9, .0001))
    except Exception as error:
        row.update(passed=False, error=str(error))
    row['wall_seconds'] = time.perf_counter() - start
    results.append(row)
    print(json.dumps(row), flush=True)
report = dict(model=args.model, num_ctx=8192, thinking=args.think, system_prompt=system, cases=results, passed=sum(r['passed'] for r in results),
    count=len(results), median_wall_seconds=statistics.median(r['wall_seconds'] for r in results),
    caveat='Six synthetic text-only cases, not a desktop reliability or vision benchmark.')
pathlib.Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({k:v for k,v in report.items() if k not in ('cases', 'system_prompt')}), flush=True)
