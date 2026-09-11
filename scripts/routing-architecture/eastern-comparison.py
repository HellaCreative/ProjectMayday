"""Resume serial eastern experiments after the existing native build driver.

OSRM extraction exceeded the RSS guard after emitting its completion log. Downstream
checks are explicitly salvage diagnostics, not a successful budgeted preprocessing run.
"""
import json, pathlib, subprocess, time

root = pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911')
here = pathlib.Path(__file__).resolve().parent
python = str(root / 'tools/venv/bin/python')
results = root / 'results/eastern-road'
results.mkdir(exist_ok=True)
while not (root / 'results/valhalla-eastern-tiles.json').exists():
    time.sleep(2)

def run(name, command, seconds=600):
    return subprocess.run([python, str(here / 'guarded-run.py'), '--out',
        str(results / (name + '.guard.json')), '--seconds', str(seconds), '--', *command],
        stdin=subprocess.DEVNULL).returncode == 0

cases = ['ns-short-balanced-road', 'qc-long-balanced-road', 'on-long-balanced-road',
         'nsnb-balanced-road', 'bangor-road', 'ns-on-road', 'wv-road']

def bench(engine, dataset='eastern', mode='default'):
    for case in cases:
        for repetition in range(3):
            name = f'{engine}-{mode}-{case}-{repetition}'
            if not run(name, [python, str(here / 'road-bench.py'), engine, case,
                             str(results / (name + '.json')), '--dataset', dataset,
                             '--mode', mode, '--repeat', '6']):
                break  # Preserve failure; do not repeat an expensive known failure.

valhalla = json.loads((root / 'results/valhalla-eastern-tiles.json').read_text())
if valhalla['returncode'] == 0 and not valhalla['guardFailure']:
    bench('valhalla')

if run('osrm-salvage-partition', [python, '-m', 'osrm', 'partition', '-t', '1',
                               str(root / 'data/eastern-260907.osrm')], 1800):
    if run('osrm-salvage-customize', [python, '-m', 'osrm', 'customize', '-t', '1',
                                   str(root / 'data/eastern-260907.osrm')], 1800):
        bench('osrm')

config = (root / 'tools/graphhopper-eastern.yml').read_text()
config = config.replace('/data/graphhopper-eastern', '/data/graphhopper-eastern-lm')
config = config.replace('  profiles_ch:\n    - profile: car', '  profiles_ch: []')
target = root / 'tools/graphhopper-eastern-lm.yml'
target.write_text(config)
if run('gh-lm-import', ['/opt/homebrew/opt/openjdk/bin/java', '-Xmx2g', '-jar',
                       str(root / 'tools/graphhopper-web-11.0.jar'), 'import', str(target)], 1800):
    bench('graphhopper', dataset='eastern-lm', mode='lm')
print('Eastern road diagnostics complete; inspect all guards and scope before comparison.', flush=True)
