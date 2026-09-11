"""Compare expanded-engine transitions with independently exported V4 walks."""
import json, pathlib, subprocess, time

root = pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911')
data = root / 'data/verified-nsnb'
checks = json.loads((data / 'walk-checks.json').read_text())
command = ['/opt/homebrew/opt/openjdk/bin/java', '-Xmx256m', '-cp',
           str(root / 'tools/gh-adapter') + ':' + str(root / 'tools/graphhopper-web-11.0.jar'),
           'VerifiedHopper', str(data / 'verified-input.json'),
           str(root / 'data/gh-verified-nsnb-directed-v2')]
started = time.monotonic()
process = subprocess.run(command, input='\n'.join(map(json.dumps, checks)) + '\n',
                         capture_output=True, text=True, timeout=120)
(root / 'results/gh-real-walks.log').write_text(process.stdout + '\n' + process.stderr)
actual = [json.loads(line[7:]) for line in process.stdout.splitlines() if line.startswith('RESULT ')]
errors = [{'input': expected, 'actual': result} for expected, result in zip(checks, actual)
          if expected['accepted'] != result.get('accepted')]
report = {'walks': len(checks), 'responses': len(actual), 'mismatches': errors,
          'returncode': process.returncode, 'seconds': time.monotonic() - started,
          'scope': 'Bounded real walks, not exhaustive restriction coverage or a latency benchmark.'}
(root / 'results/gh-real-walks.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report))
assert process.returncode == 0 and len(actual) == len(checks) and not errors
