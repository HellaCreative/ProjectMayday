"""Build a separate private app from verified native-v6 source snapshots.

No accepted app edits, provisioning, portal access, installation or publication.
Device artifact is deliberately unsigned; simulator artifact is ad-hoc signed.
"""
import argparse, hashlib, json, pathlib, plistlib, shutil, subprocess

p = argparse.ArgumentParser()
p.add_argument('--snapshot', required=True, type=pathlib.Path)
p.add_argument('--packs', required=True, type=pathlib.Path)
p.add_argument('--fixtures', required=True, type=pathlib.Path)
p.add_argument('--out', required=True, type=pathlib.Path)
p.add_argument('--platform', choices=['iphoneos', 'iphonesimulator'], required=True)
a = p.parse_args()
if a.out.exists(): raise RuntimeError('Use a fresh output directory')
sha = lambda b: hashlib.sha256(b).hexdigest()
receipt = json.loads((a.snapshot/'build.json').read_text())
if receipt['returncode'] or receipt['changedDuringBuild'] or not receipt['cancellationPrototype']:
    raise RuntimeError('Requires successful pinned cancellation snapshot')
source = {}
for name, digest in receipt['compiledSwiftHashes'].items():
    data = (a.snapshot/name).read_bytes()
    if sha(data) != digest: raise RuntimeError('Snapshot changed: ' + name)
    if name != 'NativeWorkloadProbe.swift': source[name] = data
for f in pathlib.Path(__file__).parent.glob('*.swift'): source[f.name] = f.read_bytes()
resources = {name: (a.packs/name).read_bytes() for name in ['graph.v4.bin', 'geometry.v1.bin']}
resources['UrbanSettlements.json'] = (a.snapshot/'UrbanSettlements.json').read_bytes()
for name in ['graph.v4.bin', 'geometry.v1.bin']:
    expected = {'graph.v4.bin': '91a10b490918531de330b9bcd2209de1708a4beb50625bfab4969e59e23d551d',
                'geometry.v1.bin': 'b4ee898537829666f3825ff50e3bff2a73f9b423a558ffde814a1abdd75649ac'}[name]
    if sha(resources[name]) != expected: raise RuntimeError('NS pack identity mismatch')
if sha(resources['UrbanSettlements.json']) != 'ebb0383d62dbe22e985bbd3b2c3193d25bfc97f26dbd761b269cc6182bc19831':
    raise RuntimeError('Urban metadata identity mismatch')
fixtures = json.loads(a.fixtures.read_bytes())
base = fixtures[0]
queries = []
for case, profile, extra in [
    ('Clean baseline', 'clean', {}), ('Dirt cancellation', 'dirt', {'cancelAfterMillis': 20}),
    ('Clean recovery', 'clean', {}), ('Dirt time budget', 'dirt', {'searchBudgetMillis': 20}),
    ('Dirt recovery', 'dirt', {}), ('Balanced baseline', 'balanced', {})]:
    queries.append({**base, 'case': case, 'profile': profile, **extra})
resources['queries.json'] = json.dumps(queries, indent=2).encode()
app = a.out/'DIRTPhoneLab.app'
app.mkdir(parents=True)
src = a.out/'Sources'; src.mkdir()
for name, data in source.items(): (src/name).write_bytes(data)
for name, data in resources.items(): (app/name).write_bytes(data)
manifest = {'version': 1, 'snapshotReceiptSHA256': sha((a.snapshot/'build.json').read_bytes()),
            'sourceHashes': {n: sha(d) for n,d in source.items()},
            'resourceHashes': {n: sha(d) for n,d in resources.items()},
            'fixtureSourceSHA256': sha(a.fixtures.read_bytes()),
            'scope': 'NS roads only; same cancellation snapshot as native-v6; no native fuel proof.'}
(app/'probe-manifest.json').write_text(json.dumps(manifest, indent=2))
platform = 'iPhoneOS' if a.platform == 'iphoneos' else 'iPhoneSimulator'
info = {'CFBundleIdentifier': 'local.dirt.experiments.phonelab20260911', 'CFBundleName': 'DIRT Phone Lab',
        'CFBundleDisplayName': 'DIRT Phone Lab', 'CFBundleExecutable': 'DIRTPhoneLab',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.1', 'CFBundleVersion': '1',
        'CFBundleSupportedPlatforms': [platform], 'MinimumOSVersion': '17.0',
        'UIDeviceFamily': [1], 'UILaunchScreen': {}, 'LSRequiresIPhoneOS': True,
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
        'UIFileSharingEnabled': True, 'LSSupportsOpeningDocumentsInPlace': True}
(app/'Info.plist').write_bytes(plistlib.dumps(info))
sdk = subprocess.check_output(['xcrun', '--sdk', a.platform, '--show-sdk-path'], text=True).strip()
target = 'arm64-apple-ios17.0' + ('-simulator' if a.platform == 'iphonesimulator' else '')
command = ['xcrun', '--sdk', a.platform, 'swiftc', '-O', '-parse-as-library', '-sdk', sdk,
           '-target', target, '-module-name', 'DIRTPhoneLab', *map(str, sorted(src.glob('*.swift'))),
           '-o', str(app/'DIRTPhoneLab')]
with (a.out/'build.log').open('w') as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
if result.returncode == 0 and a.platform == 'iphonesimulator':
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
build = {'returncode': result.returncode, 'command': command, 'platform': a.platform,
         'manifestSHA256': sha((app/'probe-manifest.json').read_bytes()),
         'builderSHA256': sha(pathlib.Path(__file__).read_bytes()),
         'deviceSigning': 'none', 'installed': False,
         'appBytes': sum(f.stat().st_size for f in app.rglob('*') if f.is_file())}
if result.returncode == 0: build['executableSHA256'] = sha((app/'DIRTPhoneLab').read_bytes())
(a.out/'build.json').write_text(json.dumps(build, indent=2))
print(json.dumps(build))
raise SystemExit(result.returncode)
